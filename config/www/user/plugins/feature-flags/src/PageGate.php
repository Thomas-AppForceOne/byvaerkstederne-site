<?php
/**
 * PageGate — pure decision function for page-level feature gating.
 *
 * Given a page's header (either an object exposing a `feature` property or a
 * plain associative array) and a FlagStoreInterface, return a Decision
 * indicating whether the page should render (ALLOW) or be replaced with a
 * 404 (NOT_FOUND). Separated from the event handler so it can be unit
 * tested without booting Grav.
 *
 * Fail-closed contract (applied here and relied on by the handler):
 *   - header absent / no `feature:` key  -> ALLOW
 *   - `feature:` present but null/bool/
 *     int/array/empty-string             -> NOT_FOUND + warning
 *   - `feature:` is an unknown enum name -> NOT_FOUND + warning
 *   - `feature:` maps to an enum case
 *     that resolves disabled             -> NOT_FOUND (no warning — normal)
 *   - `feature:` maps to a known-enabled
 *     flag                               -> ALLOW
 *
 * The class never throws on a malformed header — a caught Throwable from
 * FlagStore resolves to NOT_FOUND with a warning so a bug in the store
 * cannot accidentally render a flagged page.
 *
 * Why this lives in its own class (see
 * not_found_replacement_strategy_is_safe in the sprint contract): the event
 * handler only decides "render or replace", it never reaches into the
 * container to swap `$grav['page']` based on flag resolution logic.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags;

use Psr\Log\LoggerInterface;
use Psr\Log\NullLogger;

final class PageGate
{
    public const ALLOW = 'allow';
    public const NOT_FOUND = 'not_found';

    private FlagStoreInterface $store;
    private LoggerInterface $logger;
    private ?string $environment;

    public function __construct(
        FlagStoreInterface $store,
        ?LoggerInterface $logger = null,
        ?string $environment = null
    ) {
        $this->store = $store;
        $this->logger = $logger ?? new NullLogger();
        $this->environment = $environment;
    }

    /**
     * Extract the raw `feature:` value from a header in a shape-tolerant way.
     * Grav typically passes a `Header` object (ArrayAccess + magic get), but
     * in tests we pass plain arrays. stdClass is handled as a convenience.
     *
     * Returns `null` when the key is absent — this is the common "no gating"
     * path and MUST short-circuit to ALLOW without logging.
     */
    public static function extractFeatureValue(mixed $header): mixed
    {
        if ($header === null) {
            return null;
        }
        if (is_array($header)) {
            return $header['feature'] ?? null;
        }
        if ($header instanceof \ArrayAccess) {
            // ArrayAccess offsetExists may return false even when Grav's
            // Header object has it set via __set. Try both paths.
            if ($header->offsetExists('feature')) {
                return $header['feature'];
            }
        }
        if (is_object($header) && isset($header->feature)) {
            return $header->feature;
        }
        return null;
    }

    /**
     * Decide whether a page should render or be replaced with a themed 404.
     *
     * @param mixed       $header Page header (array, object, ArrayAccess).
     * @param string|null $route  Page route for diagnostic logging.
     * @return self::ALLOW|self::NOT_FOUND
     */
    public function decide(mixed $header, ?string $route = null): string
    {
        $value = self::extractFeatureValue($header);

        // No `feature:` key — the untouched path, the only path exercised
        // for 99%+ of pages on the site. MUST NOT log here.
        if ($value === null) {
            return self::ALLOW;
        }

        // Non-string: fail-closed.
        if (!is_string($value)) {
            $this->logWarning(
                'Non-string feature value in page frontmatter; treating as disabled.',
                'non_string_value',
                $this->safeScalar($value),
                $route,
                ['value_type' => gettype($value)]
            );
            return self::NOT_FOUND;
        }

        // Empty string: fail-closed.
        if ($value === '') {
            $this->logWarning(
                'Empty feature value in page frontmatter; treating as disabled.',
                'empty_value',
                '',
                $route
            );
            return self::NOT_FOUND;
        }

        // Enum lookup. tryFrom returns null for unknown names — fail-closed.
        $flag = FeatureFlag::tryFrom($value);
        if ($flag === null) {
            $this->logWarning(
                'Unknown feature flag in page frontmatter; treating as disabled.',
                'unknown_name',
                $this->safeScalar($value),
                $route
            );
            return self::NOT_FOUND;
        }

        // Known enum case: defer to the store. Defensive try/catch so that
        // a bug in the store still yields a themed 404, never a 500.
        try {
            $enabled = $this->store->isEnabled($flag);
        } catch (\Throwable $e) {
            $this->logWarning(
                'FlagStore threw while resolving a page-gated flag; treating as disabled.',
                'store_exception',
                $flag->value,
                $route,
                ['exception_class' => get_class($e)]
            );
            return self::NOT_FOUND;
        }

        return $enabled ? self::ALLOW : self::NOT_FOUND;
    }

    /**
     * PSR-3 warning emission with a strict, allow-list context shape.
     * Never includes stack traces, session data, cookies, POST bodies, or
     * PII — only: flag name, reason code, route, environment, optional
     * value_type for debugging non-string inputs.
     *
     * @param array<string,scalar|null> $extra
     */
    private function logWarning(
        string $message,
        string $reason,
        string $flag,
        ?string $route,
        array $extra = []
    ): void {
        $context = [
            'flag'        => $flag,
            'reason'      => $reason,
            'route'       => $route !== null ? $this->safeRoute($route) : null,
            'environment' => $this->environment,
        ];
        foreach ($extra as $k => $v) {
            // Allow-list: only simple scalars may piggyback.
            if (is_scalar($v) || $v === null) {
                $context[$k] = $v;
            }
        }
        $this->logger->warning($message, $context);
    }

    private function safeScalar(mixed $value): string
    {
        if (is_string($value)) {
            return strlen($value) > 64 ? substr($value, 0, 64) . '…' : $value;
        }
        if (is_bool($value)) {
            return $value ? 'true(bool)' : 'false(bool)';
        }
        if (is_int($value) || is_float($value)) {
            return (string) $value;
        }
        if ($value === null) {
            return 'null';
        }
        if (is_array($value)) {
            return 'array(' . count($value) . ')';
        }
        if (is_object($value)) {
            return 'object(' . get_class($value) . ')';
        }
        return gettype($value);
    }

    private function safeRoute(string $route): string
    {
        return strlen($route) > 128 ? substr($route, 0, 128) . '…' : $route;
    }
}
