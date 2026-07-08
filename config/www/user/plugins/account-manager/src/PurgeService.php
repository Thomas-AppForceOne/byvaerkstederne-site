<?php
/**
 * PurgeService — scheduled hard delete + anonymization
 * (account_self_service_specification.md §7).
 *
 * Runs when `now ≥ deletion_requested_at + window`. Removes the account
 * file and anonymizes every store that references the account, replacing
 * the username with a per-account random tombstone (`deleted-<random>`,
 * generated at delete time, never persisted in any mapping) so counts and
 * one-per-user invariants survive while re-identification is impossible.
 * Content the member authored STAYS — events keep running, suggestions and
 * reports stay on the roadmap.
 *
 * The INVENTORY constants below are the single place to extend when a new
 * store starts referencing accounts (e.g. the event-RSVP signups, whose
 * treatment will be REMOVE — the seat is freed — once that spec lands).
 *
 * Idempotent by construction: no lapsed accounts ⇒ no-op; no matching
 * fields ⇒ stores untouched. Runs unflagged (see the plugin README): a
 * member who consented to deletion must be deleted on schedule even if the
 * self-service surface was turned off afterwards.
 */

declare(strict_types=1);

namespace Grav\Plugin\AccountManager;

use Grav\Common\Grav;
use Symfony\Component\Yaml\Yaml;

final class PurgeService
{
    /**
     * Keyed YAML stores under user-data://flex-objects. `fields` are
     * scalar item fields rewritten to the tombstone when they equal the
     * username; `rekey` are username-keyed maps whose key is moved to the
     * tombstone (values — e.g. vote flags — unchanged).
     */
    private const YAML_STORES = [
        'begivenheder.yaml' => [
            'fields' => ['owner', 'created_by', 'updated_by'],
            'rekey' => [],
        ],
        'roadmap-items.yaml' => [
            'fields' => ['submitter_username', 'source_username'],
            'rekey' => ['votes', 'vote_history'],
        ],
        'feature-suggestions.yaml' => [
            'fields' => ['username', 'source_username'],
            'rekey' => [],
        ],
        'bug-reports.yaml' => [
            'fields' => ['username', 'submitter_username'],
            'rekey' => [],
        ],
        // Event signups (event_rsvp spec): once landed, its store joins here
        // with treatment REMOVE — the member no longer exists, the seat is
        // freed.
    ];

    /** Append-only JSONL logs: per-line JSON fields rewritten to the tombstone. */
    private const JSONL_LOGS = [
        'user-data://flex-objects/events-audit.jsonl' => ['actor'],
        'user-data://account-manager/account-audit.jsonl' => ['actor'],
    ];

    private Grav $grav;

    public function __construct(Grav $grav)
    {
        $this->grav = $grav;
    }

    /** Scheduler entry point (registered in onSchedulerInitialized). */
    public static function runScheduled(): void
    {
        $grav = Grav::instance();
        $service = new self($grav);
        foreach ($service->findLapsed(time()) as $username) {
            $service->purge($username);
        }
    }

    /**
     * Accounts whose regret window has lapsed.
     *
     * @return list<string>
     */
    public function findLapsed(int $now): array
    {
        $dir = $this->grav['locator']->findResource('account://');
        if (!is_string($dir) || !is_dir($dir)) {
            return [];
        }

        $windowDays = (int)$this->grav['config']->get('plugins.account-manager.deletion.window_days', 30);
        $lapsed = [];
        foreach (glob($dir . '/*.yaml') ?: [] as $path) {
            $data = $this->parseYamlFile($path);
            $requestedAt = (string)($data['deletion_requested_at'] ?? '');
            if ($requestedAt === '') {
                continue;
            }
            $requestedTs = strtotime($requestedAt);
            if ($requestedTs !== false && $now >= $requestedTs + $windowDays * 86400) {
                $lapsed[] = basename($path, '.yaml');
            }
        }
        return $lapsed;
    }

    /**
     * Hard-delete one account and anonymize its footprint (§7).
     *
     * @return array{tombstone:string,hits:list<string>}
     */
    public function purge(string $username): array
    {
        // Capture the identifiers for the completeness check BEFORE the
        // file is removed. Raw parse — no session/instance caches.
        $dir = $this->grav['locator']->findResource('account://');
        $accountPath = is_string($dir) ? $dir . '/' . $username . '.yaml' : null;
        $data = $accountPath ? $this->parseYamlFile($accountPath) : [];
        $email = (string)($data['email'] ?? '');
        $fullname = (string)($data['fullname'] ?? '');

        // Per-account random tombstone — generated here, never persisted in
        // any username→tombstone mapping.
        $tombstone = 'deleted-' . bin2hex(random_bytes(8));

        // 1. Anonymize every inventoried store.
        foreach (self::YAML_STORES as $file => $treatment) {
            $path = $this->flexStorePath($file);
            if ($path !== null) {
                $this->anonymizeYamlStore($path, $treatment['fields'], $treatment['rekey'], $username, $tombstone);
            }
        }
        foreach (self::JSONL_LOGS as $uri => $fields) {
            $path = $this->grav['locator']->findResource($uri);
            if (is_string($path) && is_file($path)) {
                $this->anonymizeJsonlLog($path, $fields, $username, $tombstone);
            }
        }

        // 2. Remember-me tokens (file keyed by sha1(username) — direct
        //    removal; the login plugin's services may not be booted in the
        //    scheduler/CLI context).
        $rememberDir = $this->grav['locator']->findResource('user-data://rememberme');
        if (is_string($rememberDir)) {
            @unlink($rememberDir . '/' . sha1($username) . '.yaml');
        }

        // 3. Delete the account file and drop the stale Flex accounts index
        //    (UserCollection::delete() only unlinks the YAML; the on-disk
        //    index under user/data/flex/indexes/ would keep the username —
        //    same recovery the deploy account scripts perform).
        $this->grav['accounts']->delete($username);
        $indexPath = $this->grav['locator']->findResource('user-data://flex/indexes/accounts.yaml');
        if (is_string($indexPath) && is_file($indexPath)) {
            @unlink($indexPath);
        }
        $this->clearCaches();

        // 4. Audit — tombstone id only, never the username (this log was
        //    itself just rewritten to the tombstone).
        (new AccountAuditLog($this->grav))->append('hard_delete', $tombstone);

        // 5. Deterministic completeness check (§7, also the test oracle):
        //    zero case-insensitive hits for the identifiers across
        //    user/accounts/ and user/data/.
        $hits = $this->footprintHits(array_values(array_filter([$username, $email, $fullname])));
        if ($hits !== []) {
            error_log('account-manager purge: identifiers survived for tombstone ' . $tombstone . ': ' . implode(', ', $hits));
        }

        return ['tombstone' => $tombstone, 'hits' => $hits];
    }

    /**
     * Case-insensitive identifier search across user/accounts/ and
     * user/data/ — returns "file: needle" hits (empty = clean).
     *
     * @param list<string> $needles
     * @return list<string>
     */
    public function footprintHits(array $needles): array
    {
        $roots = [];
        foreach (['account://', 'user-data://'] as $uri) {
            $dir = $this->grav['locator']->findResource($uri);
            if (is_string($dir) && is_dir($dir)) {
                $roots[] = $dir;
            }
        }

        $hits = [];
        foreach ($roots as $root) {
            $iterator = new \RecursiveIteratorIterator(
                new \RecursiveDirectoryIterator($root, \FilesystemIterator::SKIP_DOTS)
            );
            foreach ($iterator as $file) {
                if (!$file->isFile()) {
                    continue;
                }
                $content = @file_get_contents($file->getPathname());
                if ($content === false) {
                    continue;
                }
                foreach ($needles as $needle) {
                    if ($needle !== '' && stripos($content, $needle) !== false) {
                        $hits[] = $file->getPathname() . ': ' . $needle;
                    }
                }
            }
        }
        return $hits;
    }

    // -------------------------------------------------------------------------
    // Store writers
    // -------------------------------------------------------------------------

    /**
     * Locked read-modify-write on a keyed YAML store (the house
     * flock/ftruncate pattern — bug-report saveRoadmapItemAtomic precedent).
     *
     * @param list<string> $fields
     * @param list<string> $rekeyMaps
     */
    private function anonymizeYamlStore(string $path, array $fields, array $rekeyMaps, string $username, string $tombstone): void
    {
        if (!is_file($path)) {
            return;
        }
        $fh = fopen($path, 'c+');
        if ($fh === false || !flock($fh, LOCK_EX)) {
            if ($fh !== false) {
                fclose($fh);
            }
            throw new \RuntimeException("account-manager purge: cannot lock {$path}");
        }
        try {
            $data = Yaml::parse((string)stream_get_contents($fh)) ?: [];
            $changed = false;
            foreach ($data as &$item) {
                if (!is_array($item)) {
                    continue;
                }
                foreach ($fields as $field) {
                    if (($item[$field] ?? null) === $username) {
                        $item[$field] = $tombstone;
                        $changed = true;
                    }
                }
                foreach ($rekeyMaps as $map) {
                    if (isset($item[$map]) && is_array($item[$map]) && array_key_exists($username, $item[$map])) {
                        $item[$map][$tombstone] = $item[$map][$username];
                        unset($item[$map][$username]);
                        $changed = true;
                    }
                }
            }
            unset($item);

            if ($changed) {
                $yaml = Yaml::dump($data, 6, 2, Yaml::DUMP_MULTI_LINE_LITERAL_BLOCK);
                ftruncate($fh, 0);
                rewind($fh);
                fwrite($fh, $yaml);
                fflush($fh);
            }
        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
    }

    /**
     * One-time sanctioned rewrite of an append-only JSONL log: the named
     * per-line fields move to the tombstone, structure preserved (§7).
     *
     * @param list<string> $fields
     */
    private function anonymizeJsonlLog(string $path, array $fields, string $username, string $tombstone): void
    {
        $fh = fopen($path, 'c+');
        if ($fh === false || !flock($fh, LOCK_EX)) {
            if ($fh !== false) {
                fclose($fh);
            }
            throw new \RuntimeException("account-manager purge: cannot lock {$path}");
        }
        try {
            $lines = preg_split('/\n/', (string)stream_get_contents($fh)) ?: [];
            $changed = false;
            foreach ($lines as $i => $line) {
                if (trim($line) === '') {
                    continue;
                }
                $record = json_decode($line, true);
                if (!is_array($record)) {
                    continue; // never destroy an unparsable line
                }
                $lineChanged = false;
                foreach ($fields as $field) {
                    if (($record[$field] ?? null) === $username) {
                        $record[$field] = $tombstone;
                        $lineChanged = true;
                    }
                }
                if ($lineChanged) {
                    $lines[$i] = json_encode($record, JSON_UNESCAPED_UNICODE);
                    $changed = true;
                }
            }

            if ($changed) {
                ftruncate($fh, 0);
                rewind($fh);
                fwrite($fh, implode("\n", $lines));
                fflush($fh);
            }
        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private function flexStorePath(string $file): ?string
    {
        $dir = $this->grav['locator']->findResource('user-data://flex-objects');
        return is_string($dir) ? $dir . '/' . $file : null;
    }

    /** @return array<string,mixed> */
    private function parseYamlFile(string $path): array
    {
        if (!is_file($path)) {
            return [];
        }
        try {
            $parsed = Yaml::parse((string)file_get_contents($path));
            return is_array($parsed) ? $parsed : [];
        } catch (\Throwable $e) {
            return [];
        }
    }

    /**
     * Flex user-accounts cache + render cache — deletions must be visible
     * immediately (EventRepository::bustRenderCache precedent). Both are
     * defensive: the flex service may be absent in CLI/scheduler contexts.
     */
    private function clearCaches(): void
    {
        try {
            $flex = $this->grav['flex'] ?? null;
            if ($flex !== null) {
                $flex->getDirectory('user-accounts')?->clearCache();
            }
        } catch (\Throwable $e) {
            // best-effort
        }
        try {
            $this->grav['cache']->getCacheDriver()->deleteAll();
        } catch (\Throwable $e) {
            // best-effort
        }
    }
}
