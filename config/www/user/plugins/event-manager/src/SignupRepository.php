<?php
/**
 * SignupRepository — the dedicated signup store for events
 * (event_rsvp_specification.md §2). Owns
 * `user/data/flex-objects/event-signups.yaml`, a map of
 *   event key → username → { ts, mode }
 *
 * Signups live OUTSIDE the event object on purpose: every event edit rewrites
 * the whole Flex object, so keeping signups there would let a concurrent
 * signup-vs-edit clobber either write. This store isolates the two write
 * paths and — critically — performs the capacity check inside the SAME
 * exclusive lock as the write, so two racing signups can never exceed
 * capacity (§3).
 *
 * The atomic write is the bug-report plugin's strong pattern
 * (BugReportPlugin::saveRoadmapItemAtomic): fopen('c+') → flock(LOCK_EX) →
 * read+parse → mutate → ftruncate/rewind/fwrite → unlock in `finally`. This
 * is deliberately NOT roadmap's file_put_contents(LOCK_EX), which is not a
 * read-modify-write under one lock and therefore cannot enforce capacity
 * atomically.
 *
 * The class takes an explicit data-file path rather than a Grav instance so
 * the toggle/capacity logic is unit-testable against a temp file; the plugin
 * resolves the locator path and constructs it (see EventManagerPlugin).
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager;

use Symfony\Component\Yaml\Yaml;

final class SignupRepository
{
    /** Result of a toggle(): a signup was added, removed, or refused (full). */
    public const SIGNED_UP = 'signed_up';
    public const WITHDRAWN = 'withdrawn';
    public const FULL = 'full';

    /** The mode stamped for binding, capacity-bound signups. */
    public const MODE_TILMELD = 'tilmeld';

    private string $dataFile;

    public function __construct(string $dataFile)
    {
        $this->dataFile = $dataFile;
    }

    /**
     * Toggle the caller's signup/interest for an event. Idempotent and
     * reversible from the same call: an existing signup is withdrawn; a new
     * one is added. For a capacity-limited Tilmeld event, $capacity is the
     * bounded integer and the check runs inside the write lock — a signup
     * that would exceed it returns FULL and writes nothing. Pass null for
     * unlimited events and for Interesseret (never capacity-bound, §1.4).
     *
     * @return self::SIGNED_UP|self::WITHDRAWN|self::FULL
     */
    public function toggle(string $eventKey, string $username, string $mode, ?int $capacity = null): string
    {
        $result = self::WITHDRAWN;

        $this->mutate(function (array $map) use ($eventKey, $username, $mode, $capacity, &$result): array {
            $attendees = isset($map[$eventKey]) && is_array($map[$eventKey]) ? $map[$eventKey] : [];

            if (array_key_exists($username, $attendees)) {
                // Withdraw — reverse of a prior signup, regardless of mode.
                unset($attendees[$username]);
                $result = self::WITHDRAWN;
            } else {
                // Signing up. Capacity is enforced here, inside the lock, so
                // two racing signups cannot both pass the check.
                if ($capacity !== null && $this->confirmedCount($attendees) >= $capacity) {
                    $result = self::FULL;
                    return $map; // no mutation
                }
                $attendees[$username] = [
                    'ts' => gmdate('Y-m-d\TH:i:s\Z'),
                    'mode' => $mode,
                ];
                $result = self::SIGNED_UP;
            }

            if ($attendees === []) {
                unset($map[$eventKey]); // keep the file free of empty events
            } else {
                $map[$eventKey] = $attendees;
            }
            return $map;
        });

        return $result;
    }

    /**
     * Number of signups for an event. With $mode given, only entries stamped
     * with that mode are counted (capacity is measured against Tilmeld
     * signups); with null, every signup is counted.
     */
    public function countFor(string $eventKey, ?string $mode = null): int
    {
        $attendees = $this->attendeesMap($eventKey);
        if ($mode === null) {
            return count($attendees);
        }
        $n = 0;
        foreach ($attendees as $entry) {
            if (($entry['mode'] ?? '') === $mode) {
                $n++;
            }
        }
        return $n;
    }

    public function isSignedUp(string $eventKey, string $username): bool
    {
        return array_key_exists($username, $this->attendeesMap($eventKey));
    }

    /**
     * The attendee list for an event, oldest signup first: each row carries
     * `username`, `ts` and `mode`. Full-name resolution is the caller's job
     * (via Grav's accounts at render time) — never stored here (§2).
     *
     * @return list<array{username:string, ts:string, mode:string}>
     */
    public function attendeesFor(string $eventKey): array
    {
        $rows = [];
        foreach ($this->attendeesMap($eventKey) as $username => $entry) {
            $rows[] = [
                'username' => (string)$username,
                'ts' => (string)($entry['ts'] ?? ''),
                'mode' => (string)($entry['mode'] ?? ''),
            ];
        }
        usort($rows, static fn (array $a, array $b): int => strcmp($a['ts'], $b['ts']));
        return $rows;
    }

    /**
     * Drop all signups for an event — used by the hard-delete path so a
     * permanently removed event leaves no orphaned signup rows behind.
     */
    public function deleteFor(string $eventKey): void
    {
        $this->mutate(static function (array $map) use ($eventKey): array {
            unset($map[$eventKey]);
            return $map;
        });
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    /** Count of capacity-bound (Tilmeld) signups among an event's attendees. */
    private function confirmedCount(array $attendees): int
    {
        $n = 0;
        foreach ($attendees as $entry) {
            if (is_array($entry) && ($entry['mode'] ?? '') === self::MODE_TILMELD) {
                $n++;
            }
        }
        return $n;
    }

    /** @return array<string, array<string,mixed>> the attendee map for one event */
    private function attendeesMap(string $eventKey): array
    {
        $map = $this->readMap();
        $attendees = $map[$eventKey] ?? [];
        return is_array($attendees) ? $attendees : [];
    }

    /**
     * Unlocked read for the count/list accessors. Reads tolerate a slightly
     * stale view (a concurrent toggle in flight); only toggle() itself must
     * be serialised, which it is via mutate().
     *
     * @return array<string, array<string,mixed>>
     */
    private function readMap(): array
    {
        if (!is_file($this->dataFile)) {
            return [];
        }
        $content = @file_get_contents($this->dataFile);
        if ($content === false || trim($content) === '') {
            return [];
        }
        $parsed = Yaml::parse($content);
        return is_array($parsed) ? $parsed : [];
    }

    /**
     * Read-modify-write the whole file under one exclusive lock. The callback
     * receives the parsed map and returns the new map to persist (returning
     * the map unchanged is a valid no-op — e.g. a rejected over-capacity
     * signup).
     *
     * @param callable(array<string,mixed>):array<string,mixed> $fn
     */
    private function mutate(callable $fn): void
    {
        $dir = dirname($this->dataFile);
        if (!is_dir($dir)) {
            @mkdir($dir, 0750, true);
        }

        $fh = fopen($this->dataFile, 'c+');
        if ($fh === false) {
            throw new \RuntimeException('cannot open signup store for writing: ' . $this->dataFile);
        }

        try {
            if (!flock($fh, LOCK_EX)) {
                throw new \RuntimeException('cannot lock signup store');
            }

            $content = stream_get_contents($fh);
            $map = [];
            if ($content !== false && trim($content) !== '') {
                $parsed = Yaml::parse($content);
                if (is_array($parsed)) {
                    $map = $parsed;
                }
            }

            $newMap = $fn($map);

            $yaml = $newMap === [] ? '' : Yaml::dump($newMap, 4, 2);
            ftruncate($fh, 0);
            rewind($fh);
            fwrite($fh, $yaml);
            fflush($fh);
        } finally {
            flock($fh, LOCK_UN);
            fclose($fh);
        }
    }
}
