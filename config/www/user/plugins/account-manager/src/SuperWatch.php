<?php
/**
 * SuperWatch — the site's own answer to "who is a super-admin, and did that
 * change without anyone saying so?"
 *
 * WHY THIS EXISTS ALONGSIDE deploy/manage-super.sh's ALERT
 * -------------------------------------------------------
 * The tool alerts when the tool is used. That covers the tidy path and
 * nothing else: a hand-edited account YAML over SSH, a restored backup, a
 * change made in the admin panel, or a future script nobody remembers to
 * wire up all produce a new super in silence. A notification that depends on
 * the actor choosing to notify is not a control.
 *
 * So the site compares state instead. It records the set of supers it knows
 * about and, on every run, reports what appeared or vanished since. That
 * catches every path, including the ones that have not been invented yet.
 * The tool's own mail stays as the fast path — this is the backstop that
 * makes the guarantee hold.
 *
 * FIRST RUN records the baseline WITHOUT alerting. Alerting on every
 * existing super the first time would teach the reader to ignore the mail,
 * which is the failure mode this is built against.
 */

declare(strict_types=1);

namespace Grav\Plugin\AccountManager;

use Grav\Common\Grav;
use Symfony\Component\Yaml\Yaml;

final class SuperWatch
{
    private const BASELINE_FILE = 'super-baseline.yaml';

    private Grav $grav;

    public function __construct(Grav $grav)
    {
        $this->grav = $grav;
    }

    /**
     * Every ENABLED account holding admin.super, as username => email.
     *
     * This is the single definition of "a super" for the plugin: the mail
     * recipient resolver reads it too, so a change here can never leave the
     * alerting and the addressing disagreeing about who counts.
     *
     * Read-only YAML sweep of account://, the same shape PurgeService uses
     * for whole-directory work. A malformed account is skipped rather than
     * allowed to silence the rest.
     *
     * @return array<string,string>
     */
    public function supers(): array
    {
        $found = [];
        $dir = $this->grav['locator']->findResource('account://');
        if (!is_string($dir) || !is_dir($dir)) {
            return $found;
        }
        foreach (glob($dir . '/*.yaml') ?: [] as $path) {
            try {
                $data = Yaml::parse((string)file_get_contents($path));
            } catch (\Throwable $e) {
                continue;
            }
            if (!is_array($data)) {
                continue;
            }
            $super = $data['access']['admin']['super'] ?? false;
            if ($super !== true && $super !== 1 && $super !== 'true' && $super !== '1') {
                continue;
            }
            if ((string)($data['state'] ?? 'enabled') !== 'enabled') {
                continue;
            }
            $found[basename($path, '.yaml')] = trim((string)($data['email'] ?? ''));
        }
        ksort($found);
        return $found;
    }

    /**
     * Compare the current supers against the recorded baseline.
     *
     * @param bool $dryRun report only — no baseline write, no mail, no audit
     * @return array{first_run:bool,added:array<string,string>,removed:array<string,string>,current:array<string,string>}
     */
    public function check(bool $dryRun = false): array
    {
        $current = $this->supers();
        $baseline = $this->readBaseline();
        $firstRun = $baseline === null;

        $known = $firstRun ? $current : $baseline;
        $added = array_diff_key($current, $known);
        $removed = array_diff_key($known, $current);

        $result = [
            'first_run' => $firstRun,
            'added' => $added,
            'removed' => $removed,
            'current' => $current,
        ];

        if ($dryRun) {
            return $result;
        }

        // Alert on additions only. A REMOVED super is recorded in the audit
        // log but not mailed: losing an admin is disruptive, not dangerous,
        // and the people who would receive the mail are the ones who would
        // notice anyway.
        foreach ($added as $username => $email) {
            $this->audit('detected_super_added', $username);
            try {
                (new AccountEmail($this->grav))->sendSuperGrantedAlert(
                    (string)$username,
                    (string)$email,
                    'ukendt — opdaget af sitet',
                    gmdate('Y-m-d H:i:s'),
                    'account-manager super-watch'
                );
            } catch (\Throwable $e) {
                // The detection still stands and is in the audit log; a mail
                // failure must not stop the baseline from moving forward, or
                // every later run would re-alert on the same account.
                $this->grav['log']->error(
                    'account-manager super-watch: alert failed for ' . $username . ': ' . $e->getMessage()
                );
            }
        }
        foreach ($removed as $username => $email) {
            $this->audit('detected_super_removed', (string)$username);
        }

        $this->writeBaseline($current);

        return $result;
    }

    /** Scheduler entry point (registered in onSchedulerInitialized). */
    public static function runScheduled(): void
    {
        try {
            (new self(Grav::instance()))->check();
        } catch (\Throwable $e) {
            error_log('account-manager super-watch failed: ' . $e->getMessage());
        }
    }

    /** @return array<string,string>|null null when no baseline exists yet */
    private function readBaseline(): ?array
    {
        $file = $this->baselinePath();
        if ($file === null || !is_file($file)) {
            return null;
        }
        try {
            $data = Yaml::parse((string)file_get_contents($file));
        } catch (\Throwable $e) {
            // A corrupt baseline must not be treated as "no supers known" —
            // that would alert on every existing super. Treat it as absent,
            // which re-baselines silently and logs the reason.
            $this->grav['log']->error('account-manager super-watch: unreadable baseline, re-recording');
            return null;
        }
        $supers = is_array($data) ? ($data['supers'] ?? null) : null;
        return is_array($supers) ? array_map('strval', $supers) : null;
    }

    /** @param array<string,string> $supers */
    private function writeBaseline(array $supers): void
    {
        $file = $this->baselinePath();
        if ($file === null) {
            return;
        }
        $payload = [
            'recorded_at' => gmdate('Y-m-d\TH:i:s\Z'),
            'supers' => $supers,
        ];
        $tmp = $file . '.tmp';
        if (file_put_contents($tmp, Yaml::dump($payload, 4, 2)) === false || !rename($tmp, $file)) {
            @unlink($tmp);
            $this->grav['log']->error('account-manager super-watch: could not write the baseline');
        }
    }

    private function baselinePath(): ?string
    {
        $dir = $this->grav['locator']->findResource('user-data://account-manager', true, true);
        if (!is_string($dir)) {
            return null;
        }
        if (!is_dir($dir) && !@mkdir($dir, 0750, true) && !is_dir($dir)) {
            return null;
        }
        return $dir . '/' . self::BASELINE_FILE;
    }

    private function audit(string $action, string $username): void
    {
        try {
            (new AccountAuditLog($this->grav))->append($action, 'system:super-watch', [
                'target_username' => $username,
            ]);
        } catch (\Throwable $e) {
            $this->grav['log']->error('account-manager super-watch: audit write failed: ' . $e->getMessage());
        }
    }
}
