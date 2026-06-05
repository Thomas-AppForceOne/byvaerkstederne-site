<?php
/**
 * TwigHelpers — the string -> enum conversion shim for the two Twig
 * functions exposed by this plugin.
 *
 *   feature_enabled(string $name): bool
 *   enabled_features(): array<string>
 *
 * Kept as a plain PHP class (no Twig dependency in the class itself) so
 * unit tests can exercise the conversion + fail-closed behavior without
 * booting Twig or Grav. The plugin entry file wires these two methods
 * into \Twig\TwigFunction instances inside onTwigInitialized.
 *
 * Fail-closed contract (invariant):
 *   - Unknown flag name            -> false + one warning
 *   - Non-string / non-scalar arg  -> false + one warning
 *   - Empty string                 -> false + one warning
 *   - FlagStore threw              -> false (no warning — already logged inside store)
 * Never throws; every call returns bool.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags;

use Psr\Log\LoggerInterface;
use Psr\Log\NullLogger;

final class TwigHelpers
{
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
     * Resolve a flag name (as a template would pass it) to a boolean.
     *
     * Accepts mixed intentionally: Twig can pass anything a template author
     * writes (null from a missing variable, an array, an object). We refuse
     * to fatal — fail-closed with a warning is the contract.
     */
    public function featureEnabled(mixed $name): bool
    {
        // 1. Type guard. Only strings can name a flag.
        if (!is_string($name)) {
            $this->logger->warning(
                'Unknown feature flag.',
                [
                    'flag'        => $this->safeScalar($name),
                    'reason'      => 'non_string_argument',
                    'arg_type'    => gettype($name),
                    'environment' => $this->environment,
                ]
            );
            return false;
        }

        // 2. Empty string guard. FeatureFlag::tryFrom('') would return null,
        //    but emitting an explicit reason makes operator logs clearer.
        if ($name === '') {
            $this->logger->warning(
                'Unknown feature flag.',
                [
                    'flag'        => '',
                    'reason'      => 'empty_string',
                    'environment' => $this->environment,
                ]
            );
            return false;
        }

        // 3. Enum lookup — tryFrom() returns null for unknown strings,
        //    preserving fail-closed behavior.
        $flag = FeatureFlag::tryFrom($name);
        if ($flag === null) {
            $this->logger->warning(
                'Unknown feature flag.',
                [
                    'flag'        => $this->safeScalar($name),
                    'reason'      => 'unknown_name',
                    'environment' => $this->environment,
                ]
            );
            return false;
        }

        // 4. Delegate to the store. Defensive try/catch: a store bug must
        //    never bubble up and 500 a template render. Fail closed.
        try {
            return $this->store->isEnabled($flag);
        } catch (\Throwable $e) {
            return false;
        }
    }

    /**
     * List enabled flags as their backed string values.
     *
     * @return list<string>
     */
    public function enabledFeatures(): array
    {
        try {
            $enabled = $this->store->getEnabledFlags();
        } catch (\Throwable $e) {
            return [];
        }

        $out = [];
        foreach ($enabled as $flag) {
            if ($flag instanceof FeatureFlag) {
                $out[] = $flag->value;
            }
        }
        return $out;
    }

    /**
     * Same log-safe rendering pattern as FlagStore::safeScalar. Caps string
     * length so a maliciously long template string cannot flood logs.
     */
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
}
