<?php
/**
 * CollectionFilter — strips feature-gated-disabled entries from an iterable
 * of pages/rows.
 *
 * Accepts any of:
 *   - Grav Page objects (header() method returns a Header/object).
 *   - Plain associative arrays with a `header` key (array or object).
 *   - Plain associative arrays with a top-level `feature` key.
 *   - Any object exposing a `header` property or `header()` method.
 *
 * Produces a numerically-indexed array (list) of the surviving entries in
 * input order.
 *
 * Entries pass through iff:
 *   - no `feature:` value is declared in the entry's header, OR
 *   - the declared value is a known FeatureFlag enum case AND
 *     FlagStore::isEnabled returns true for it.
 *
 * All other shapes (unknown enum name, non-string value, empty string,
 * store exception) are stripped — fail-closed.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags;

final class CollectionFilter
{
    private PageGate $gate;

    public function __construct(PageGate $gate)
    {
        $this->gate = $gate;
    }

    /**
     * @param  iterable<mixed> $pages
     * @return list<mixed>
     */
    public function filter(iterable $pages): array
    {
        $out = [];
        foreach ($pages as $entry) {
            if ($this->shouldShow($entry)) {
                $out[] = $entry;
            }
        }
        return $out;
    }

    /**
     * Decide whether a single entry should survive the filter. Exposed so
     * callers can apply it to non-iterable single-page checks too.
     */
    public function shouldShow(mixed $entry): bool
    {
        $header = $this->extractHeader($entry);
        return $this->gate->decide($header, $this->extractRouteForLog($entry)) === PageGate::ALLOW;
    }

    /**
     * Best-effort header extraction. Covers:
     *   - Grav Page: ->header() returns Header object.
     *   - Plain array with 'header' sub-array.
     *   - Plain array with a top-level 'feature' (treated as header-of-one).
     *   - Object with public $header.
     */
    private function extractHeader(mixed $entry): mixed
    {
        if (is_array($entry)) {
            if (array_key_exists('header', $entry)) {
                return $entry['header'];
            }
            // Flat shape: treat the row itself as the header.
            if (array_key_exists('feature', $entry)) {
                return $entry;
            }
            return null;
        }
        if (is_object($entry)) {
            if (method_exists($entry, 'header')) {
                try {
                    return $entry->header();
                } catch (\Throwable $e) {
                    return null;
                }
            }
            if (property_exists($entry, 'header') || isset($entry->header)) {
                return $entry->header ?? null;
            }
            if (isset($entry->feature)) {
                return $entry;
            }
        }
        return null;
    }

    /**
     * Pull a best-effort route string for diagnostic logging only. Never
     * fails; returns null when no obvious identifier is present.
     */
    private function extractRouteForLog(mixed $entry): ?string
    {
        if (is_object($entry)) {
            if (method_exists($entry, 'route')) {
                try {
                    $r = $entry->route();
                    return is_string($r) ? $r : null;
                } catch (\Throwable $e) {
                    return null;
                }
            }
            if (isset($entry->route) && is_string($entry->route)) {
                return $entry->route;
            }
        }
        if (is_array($entry) && isset($entry['route']) && is_string($entry['route'])) {
            return $entry['route'];
        }
        return null;
    }
}
