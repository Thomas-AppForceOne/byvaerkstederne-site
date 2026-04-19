<?php
/**
 * FlagStoreInterface — contract for the flag resolver.
 *
 * The entire public surface of the feature-flags plugin that the rest of
 * the site may depend upon. Kept intentionally small; the fail-closed
 * contract (every unknown / missing / malformed input resolves to false)
 * lives in the implementation.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags;

interface FlagStoreInterface
{
    /**
     * True iff the flag is configured with the exact string "true".
     * Any other configured value resolves false (fail-closed).
     */
    public function isEnabled(FeatureFlag $flag): bool;

    /**
     * True iff the flag's key is present in the configured map, regardless
     * of whether the value is valid. Distinguishes "present-but-disabled"
     * from "absent" for operator tooling.
     */
    public function isConfigured(FeatureFlag $flag): bool;

    /**
     * @return list<FeatureFlag> All flags whose isEnabled() is true.
     */
    public function getEnabledFlags(): array;

    /**
     * @return array<string,bool> Map of every declared flag's string value
     *                            to its resolved boolean. Shape is stable —
     *                            keys are exactly the FeatureFlag::cases().
     */
    public function allFlags(): array;

    /**
     * Diagnostic snapshot of resolver state. Not wired to HTTP.
     *
     * @return array{enabled: list<string>, configured: list<string>, all: array<string,bool>}
     */
    public function debug(): array;
}
