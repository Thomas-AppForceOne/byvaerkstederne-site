<?php
/**
 * AuditLog — append-only actor trail for event mutations
 * (frontend_event_crud_specification.md §10).
 *
 * Live-tier event data sits in the non-versioned <tier>data/ directory, so
 * git history never covers mutations; this log is the authoritative record
 * of who did what. One JSON object per line, written with fopen('a') +
 * flock(LOCK_EX) — a true append that never rewrites prior lines. This is
 * deliberately NOT the house load-mutate-file_put_contents YAML pattern,
 * which rewrites the whole file on every write and is therefore neither
 * append-only nor immutable.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager;

use Grav\Common\Grav;

final class AuditLog
{
    private const FILENAME = 'events-audit.jsonl';

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
     * @param array<string,mixed> $context optional before/after snapshots
     */
    public function append(string $action, string $key, string $actor, array $context = []): void
    {
        $record = array_merge([
            'ts' => gmdate('Y-m-d\TH:i:s\Z'),
            'actor' => $actor,
            'action' => $action,
            'key' => $key,
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
            error_log('event-manager audit append failed: ' . $e->getMessage());
        }
    }

    private function logPath(): string
    {
        $dir = $this->grav['locator']->findResource('user-data://flex-objects', true, true);
        if (!is_dir($dir)) {
            mkdir($dir, 0750, true);
        }
        return $dir . '/' . self::FILENAME;
    }
}
