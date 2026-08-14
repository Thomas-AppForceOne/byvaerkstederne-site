<?php
/**
 * AccountAuditLog — append-only actor trail for account self-service
 * mutations (account_self_service_specification.md §4.1).
 *
 * Live-tier account data sits in non-versioned directories, so git history
 * never covers these mutations; this log is the authoritative record of who
 * did what. One JSON object per line, written with fopen('a') +
 * flock(LOCK_EX) — a true append that never rewrites prior lines (the same
 * deliberate departure from the house YAML pattern as the event-manager
 * audit log).
 *
 * Records carry action, actor and timestamp ONLY — never addresses, tokens,
 * or password material. At hard delete the purge job rewrites the actor
 * fields to the per-account tombstone, so this file survives anonymization.
 */

declare(strict_types=1);

namespace Grav\Plugin\AccountManager;

use Grav\Common\Grav;

final class AccountAuditLog
{
    private const FILENAME = 'account-audit.jsonl';

    private Grav $grav;

    public function __construct(Grav $grav)
    {
        $this->grav = $grav;
    }

    /**
     * Append one immutable audit record. Failures are swallowed after an
     * error-log attempt: the mutation has already been decided, and a full
     * audit disk must not take the feature down — but we never silently
     * drop a record without a trace in the PHP error log.
     *
     * @param array<string,mixed> $context sparse extra fields — no PII
     */
    public function append(string $action, string $actor, array $context = []): void
    {
        $record = array_merge([
            'ts' => gmdate('Y-m-d\TH:i:s\Z'),
            'actor' => $actor,
            'action' => $action,
        ], $context);

        try {
            $path = $this->logPath();
            $line = json_encode($record, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR) . "\n";

            $fh = fopen($path, 'a');
            if ($fh === false) {
                throw new \RuntimeException('cannot open audit log for append');
            }
            try {
                if (!flock($fh, LOCK_EX)) {
                    throw new \RuntimeException('cannot lock audit log');
                }
                fwrite($fh, $line);
                fflush($fh);
                flock($fh, LOCK_UN);
            } finally {
                fclose($fh);
            }
        } catch (\Throwable $e) {
            error_log('account-manager audit append failed: ' . $e->getMessage());
        }
    }

    private function logPath(): string
    {
        $dir = $this->grav['locator']->findResource('user-data://account-manager', true, true);
        if (!is_dir($dir)) {
            mkdir($dir, 0750, true);
        }
        return $dir . '/' . self::FILENAME;
    }
}
