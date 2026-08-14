<?php
/**
 * Scheduler Trigger plugin for Byværkstederne.
 *
 * WHY
 * ---
 * Grav's scheduler only runs when something invokes `bin/grav scheduler`.
 * one.com offers no cron on this hosting plan and has no `crontab` in its
 * SSH shell, so the tier's scheduled work — the account purge and the
 * privilege-escalation watch — simply never ran (observed: every job showed
 * "Last Run: Never", including Grav's own cache jobs).
 *
 * This exposes one token-gated URL that an external cron service calls. The
 * alternative was letting a CI runner hold the hosting SSH password; that
 * credential opens dev, test AND staging, while this token can do exactly
 * one thing: make the site perform its own scheduled housekeeping a little
 * sooner than it otherwise would.
 *
 * SECURITY POSTURE
 * ----------------
 *  - The token lives in the tier's live-state data dir, never in the repo
 *    and never in a deployed release. Rotating it is a one-line SSH write.
 *  - A wrong, missing or absent token produces Grav's ordinary themed 404 —
 *    not a 403 — because the handler simply returns and lets the request
 *    fall through. The endpoint is therefore indistinguishable from a page
 *    that does not exist, which is the same no-enumeration posture the
 *    account endpoints already follow.
 *  - Comparison is constant-time.
 *  - A successful call answers 204 with an empty body: no job names, no
 *    counts, nothing that turns a leaked URL into a status page.
 *  - Calls closer together than min_interval are answered identically but do
 *    not re-run anything, so the endpoint cannot be used to make the site
 *    work harder than its schedule intends.
 *
 * GET is accepted because that is what cron services send. Normally a GET
 * should not have side effects; here the effect is idempotent housekeeping
 * behind a secret URL, and refusing GET would mean refusing every free cron
 * service.
 */

declare(strict_types=1);

namespace Grav\Plugin;

use Grav\Common\Grav;
use Grav\Common\Plugin;
use Grav\Framework\Psr7\Response;

class SchedulerTriggerPlugin extends Plugin
{
    /** Live-state dir holding the token and the last-run marker. */
    private const STATE_DIR = 'user-data://scheduler-trigger';
    private const TOKEN_FILE = 'token';
    private const LAST_RUN_FILE = 'last-run';

    public static function getSubscribedEvents(): array
    {
        return [
            'onPluginsInitialized' => ['onPluginsInitialized', 0],
        ];
    }

    public function onPluginsInitialized(): void
    {
        if ($this->isAdmin() || !$this->config->get('plugins.scheduler-trigger.enabled')) {
            return;
        }
        // Priority 100000: ahead of the feature-flags page gate and every
        // other page handler. This route carries no page, and the request
        // must never reach page rendering.
        $this->enable(['onPageInitialized' => ['onPageInitialized', 100000]]);
    }

    public function onPageInitialized(): void
    {
        $route = (string)$this->config->get('plugins.scheduler-trigger.route', '/scheduler-trigger');
        if ($route === '' || $this->grav['uri']->path() !== $route) {
            return;
        }

        $expected = $this->readToken();
        $presented = (string)($_GET['token'] ?? $_POST['token'] ?? '');

        // Every rejection returns silently: the request then produces Grav's
        // normal themed 404, identical to any unknown URL. No branch here may
        // answer differently, or the endpoint becomes discoverable.
        if ($expected === '' || $presented === '' || !hash_equals($expected, $presented)) {
            return;
        }

        if ($this->due()) {
            $this->runScheduler();
        }

        // 204 either way — a caller cannot tell a real run from a throttled
        // one, and there is nothing for a leaked URL to report.
        $this->grav->close(new Response(204, ['Cache-Control' => 'no-store'], ''));
    }

    /** The tier's token, or '' when none is provisioned. */
    private function readToken(): string
    {
        $dir = $this->grav['locator']->findResource(self::STATE_DIR, true, true);
        if (!is_string($dir)) {
            return '';
        }
        $file = $dir . '/' . self::TOKEN_FILE;
        if (!is_file($file)) {
            return '';
        }
        $token = trim((string)file_get_contents($file));
        // A short token would make the constant-time compare pointless; treat
        // anything implausible as "not provisioned" rather than trusting it.
        return strlen($token) >= 32 ? $token : '';
    }

    /** True when enough time has passed since the last real run. */
    private function due(): bool
    {
        $interval = (int)$this->config->get('plugins.scheduler-trigger.min_interval', 60);
        if ($interval <= 0) {
            return true;
        }
        $file = $this->markerPath();
        if ($file === null) {
            return true;
        }
        if (is_file($file)) {
            $last = (int)trim((string)file_get_contents($file));
            if ($last > 0 && (time() - $last) < $interval) {
                return false;
            }
        }
        @file_put_contents($file, (string)time());
        return true;
    }

    private function markerPath(): ?string
    {
        $dir = $this->grav['locator']->findResource(self::STATE_DIR, true, true);
        return is_string($dir) ? $dir . '/' . self::LAST_RUN_FILE : null;
    }

    /**
     * Run the due jobs. Failures are logged and swallowed: the caller is a
     * cron service that can do nothing with an error page, and a job that
     * throws must not turn into a 500 that some monitoring reads as "the
     * site is down".
     */
    private function runScheduler(): void
    {
        try {
            $scheduler = $this->grav['scheduler'];
            $scheduler->run();
            $this->grav['log']->info('scheduler-trigger: ran due jobs');
        } catch (\Throwable $e) {
            $this->grav['log']->error('scheduler-trigger: run failed: ' . $e->getMessage());
        }
    }
}
