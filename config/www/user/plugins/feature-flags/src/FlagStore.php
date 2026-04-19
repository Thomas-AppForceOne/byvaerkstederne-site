<?php
/**
 * FlagStore — parses Grav's merged `features.enabled` config and resolves
 * FeatureFlag enum cases to booleans according to the spec's 4-branch table:
 *
 *   missing key      -> false, isConfigured=false, no warning
 *   value === "true" -> true,  isConfigured=true,  no warning
 *   value === "false"-> false, isConfigured=true,  no warning
 *   anything else    -> false, isConfigured=true,  warning logged
 *
 * The single most important correctness property: NO input path — missing,
 * malformed, wrong-type, attacker-crafted — may flip a flag to true. Every
 * branch below has an explicit fall-through to false.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags;

use Psr\Log\LoggerInterface;
use Psr\Log\NullLogger;

final class FlagStore implements FlagStoreInterface
{
    private LoggerInterface $logger;
    private ?string $environment;

    /**
     * The result of the 5-step load: a map of known flag string -> resolved bool.
     * Exactly four keys (one per FeatureFlag case), populated by load().
     *
     * @var array<string,bool>
     */
    private array $resolved;

    /**
     * The set of keys from the raw config that matched a known FeatureFlag,
     * regardless of whether the value was valid. Used by isConfigured().
     *
     * @var array<string,true>
     */
    private array $configuredKeys = [];

    /**
     * @param mixed                $rawEnabled  The value of `features.enabled`
     *                                          from merged Grav config.
     *                                          Expected to be an array; any
     *                                          other shape triggers a warning
     *                                          and fail-closed behavior.
     * @param LoggerInterface|null $logger      Optional PSR-3 logger; defaults
     *                                          to NullLogger if not provided
     *                                          (useful for unit tests).
     * @param string|null          $environment Optional environment identifier
     *                                          (hostname / env label) included
     *                                          in every warning context.
     */
    public function __construct(mixed $rawEnabled, ?LoggerInterface $logger = null, ?string $environment = null)
    {
        $this->logger = $logger ?? new NullLogger();
        $this->environment = $environment;
        $this->resolved = $this->seedAllFalse();
        $this->load($rawEnabled);
    }

    /**
     * The 5-step load procedure:
     *   1. Seed every known flag to false.
     *   2. Validate the top-level shape: must be array (or null/empty-array
     *      to mean "no overrides"). Non-array shapes warn and stop.
     *   3. Iterate entries. Skip non-string keys with a warning.
     *   4. Skip keys that do not match a FeatureFlag case (warning).
     *   5. For keys that do match: exact-string "true" => true,
     *      exact-string "false" => false (no warning), anything else =>
     *      false + warning.
     *
     * @param mixed $rawEnabled
     */
    private function load(mixed $rawEnabled): void
    {
        // Step 2: top-level shape validation. null and [] are the "no
        // overrides" case — no warning; everything else is a misconfig.
        if ($rawEnabled === null || $rawEnabled === []) {
            return;
        }
        if (!is_array($rawEnabled)) {
            $this->logger->warning(
                'features.enabled is not an array; ignoring all feature flag overrides.',
                [
                    'raw_type'    => gettype($rawEnabled),
                    'raw_value'   => $this->safeScalar($rawEnabled),
                    'environment' => $this->environment,
                ]
            );
            return;
        }

        // Step 3–5: iterate entries.
        $knownValues = $this->knownFlagValues();

        foreach ($rawEnabled as $key => $value) {
            // Step 3: non-string keys are rejected. YAML can produce int
            // keys from list-shaped configs; those cannot identify a flag.
            if (!is_string($key)) {
                $this->logger->warning(
                    'Feature flag key is not a string; ignoring.',
                    [
                        'key_type'    => gettype($key),
                        'raw_value'   => $this->safeScalar($value),
                        'environment' => $this->environment,
                    ]
                );
                continue;
            }

            // Step 4: unknown keys (not matching any FeatureFlag case) are
            // ignored with a warning so stale staging config surfaces.
            if (!isset($knownValues[$key])) {
                $this->logger->warning(
                    'Unknown feature flag key in config; ignoring.',
                    [
                        'flag'        => $key,
                        'raw_value'   => $this->safeScalar($value),
                        'environment' => $this->environment,
                    ]
                );
                continue;
            }

            // Known key: mark configured regardless of value validity.
            $this->configuredKeys[$key] = true;

            // Step 5: value validation. Exact-string comparison only —
            // never loose equality, never filter_var(BOOLEAN). "TRUE",
            // int 1, bool true, null, arrays, objects all fall through.
            if ($value === 'true') {
                $this->resolved[$key] = true;
                continue;
            }
            if ($value === 'false') {
                $this->resolved[$key] = false;
                continue;
            }

            // Invalid value for a known flag: fail closed + warn.
            $this->logger->warning(
                'Invalid value for feature flag; must be exact string "true" or "false". Treating as disabled.',
                [
                    'flag'        => $key,
                    'raw_value'   => $this->safeScalar($value),
                    'raw_type'    => gettype($value),
                    'environment' => $this->environment,
                ]
            );
            // Explicit fail-closed assignment (defense in depth; already
            // seeded false in step 1 but we want the intent in the code).
            $this->resolved[$key] = false;
        }
    }

    public function isEnabled(FeatureFlag $flag): bool
    {
        return $this->resolved[$flag->value] ?? false;
    }

    public function isConfigured(FeatureFlag $flag): bool
    {
        return isset($this->configuredKeys[$flag->value]);
    }

    /** @return list<FeatureFlag> */
    public function getEnabledFlags(): array
    {
        $out = [];
        foreach (FeatureFlag::cases() as $case) {
            if ($this->resolved[$case->value] ?? false) {
                $out[] = $case;
            }
        }
        return $out;
    }

    /** @return array<string,bool> */
    public function allFlags(): array
    {
        // Rebuild in declaration order so the returned shape is stable and
        // independent of YAML iteration order. Only includes declared flags.
        $out = [];
        foreach (FeatureFlag::cases() as $case) {
            $out[$case->value] = $this->resolved[$case->value] ?? false;
        }
        return $out;
    }

    /**
     * @return array{enabled: list<string>, configured: list<string>, all: array<string,bool>}
     */
    public function debug(): array
    {
        $enabled = [];
        foreach ($this->getEnabledFlags() as $flag) {
            $enabled[] = $flag->value;
        }

        $configured = [];
        foreach (FeatureFlag::cases() as $case) {
            if (isset($this->configuredKeys[$case->value])) {
                $configured[] = $case->value;
            }
        }

        return [
            'enabled'    => $enabled,
            'configured' => $configured,
            'all'        => $this->allFlags(),
        ];
    }

    /**
     * @return array<string,bool> Every declared FeatureFlag case pre-seeded to false.
     */
    private function seedAllFalse(): array
    {
        $out = [];
        foreach (FeatureFlag::cases() as $case) {
            $out[$case->value] = false;
        }
        return $out;
    }

    /**
     * @return array<string,true> Known flag string values as a set.
     */
    private function knownFlagValues(): array
    {
        $out = [];
        foreach (FeatureFlag::cases() as $case) {
            $out[$case->value] = true;
        }
        return $out;
    }

    /**
     * Render any PHP value as a short, log-safe scalar string. Never dumps
     * full arrays/objects — YAML might smuggle deep structures and we do
     * not want logs to echo them. Strings beyond 64 chars are truncated.
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
