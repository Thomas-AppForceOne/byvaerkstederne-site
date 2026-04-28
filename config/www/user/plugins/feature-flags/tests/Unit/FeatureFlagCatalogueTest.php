<?php
/**
 * Sprint 1 rollout-catalogue coverage.
 *
 * These tests pin down three properties the rollout spec depends on:
 *
 *   1. Every flag named in the rollout catalogue is a declared FeatureFlag
 *      enum case.
 *   2. The `staging.hackersbychoice.dk` profile's features.yaml resolves to N/N
 *      catalogue flags enabled; the `test.hackersbychoice.dk` profile's
 *      features.yaml resolves to 0/N catalogue flags enabled (where N is
 *      count(self::CATALOGUE) — the count is no longer a stable 17 after
 *      post-Sprint-1 additions like privacy_policy and placeholder-CTA
 *      gates).
 *   3. The strict-string `"true"`/`"false"` rule still holds for the newly
 *      added flags (typos fail closed with a warning), and a missing
 *      features.yaml does not crash — it just resolves everything false
 *      without raising.
 *
 * The tests parse the checked-in YAML files directly via Symfony YAML
 * (already present in the composer.lock via phpunit/phpunit's transitive
 * dependencies), so they fail if someone edits the YAML out from under
 * the catalogue. They do not boot Grav — Grav integration is exercised
 * separately via the `grav_boots_cleanly_under_both_profiles` criterion.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags\Tests\Unit;

use Grav\Plugin\FeatureFlags\FeatureFlag;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\Tests\Support\ArrayLogger;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Yaml\Yaml;

final class FeatureFlagCatalogueTest extends TestCase
{
    private const CATALOGUE = [
        'roadmap',
        'feature_suggestion',
        'bug_report',
        'community_footer_column',
        'membership_signup',
        'newsletter_signup',
        'event_highlight',
        'press_page',
        'minutes_archive',
        'workshop_calendar',
        'workshop_calendar_filters',
        'workshop_calendar_featured',
        'press_assets_download',
        'press_stats',
        'contact_page',
        'statutes_page',
        'privacy_policy',
        'event_rsvp',
        'workshop_project_blueprints',
        'workshop_workday_signup',
        'kulturhus_program',
        'kulturhus_volunteer',
        'donation_mobilepay',
        'gear_donation',
        'social_media_links',
        'makerspace_meeting_link',
    ];

    /** Absolute path to `config/www/user/env/`. */
    private static function envRoot(): string
    {
        // tests/Unit -> tests -> plugins/feature-flags -> plugins -> user -> www -> config
        return dirname(__DIR__, 4) . '/env';
    }

    private static function loadProfileYaml(string $host): mixed
    {
        $path = self::envRoot() . "/{$host}/config/features.yaml";
        if (!is_file($path)) {
            return null;
        }
        $parsed = Yaml::parseFile($path);
        if (!is_array($parsed)) {
            return null;
        }
        // Grav presents the `features.enabled` sub-tree to FlagStore; the
        // YAML file itself is keyed by `enabled:`.
        return $parsed['enabled'] ?? null;
    }

    // -------- (1) Enum coverage --------

    public function testEveryCatalogueFlagIsADeclaredEnumCase(): void
    {
        $declared = array_map(
            static fn (FeatureFlag $c): string => $c->value,
            FeatureFlag::cases()
        );

        foreach (self::CATALOGUE as $flag) {
            $this->assertContains(
                $flag,
                $declared,
                "Catalogue flag `{$flag}` must be a declared FeatureFlag enum case."
            );
        }
    }

    public function testCatalogueValuesHelperMatchesDeclaredOrder(): void
    {
        $this->assertSame(self::CATALOGUE, FeatureFlag::catalogueValues());
    }

    // -------- (2) Profile resolution --------

    public function testStagingProfileEnablesAllCatalogueFlags(): void
    {
        $enabled = self::loadProfileYaml('staging.hackersbychoice.dk');
        $this->assertIsArray($enabled, 'staging.hackersbychoice.dk features.yaml must parse to an array.');

        $logger = new ArrayLogger();
        $store = new FlagStore($enabled, $logger, 'staging.hackersbychoice.dk');

        $enabledCount = 0;
        $total = count(self::CATALOGUE);
        foreach (self::CATALOGUE as $flagValue) {
            $case = FeatureFlag::from($flagValue);
            $this->assertTrue(
                $store->isEnabled($case),
                "Staging profile must enable `{$flagValue}` ({$total}/{$total} rule)."
            );
            $enabledCount++;
        }
        $this->assertSame($total, $enabledCount, "Staging must flip exactly {$total} catalogue flags on.");

        // And the profile must not emit any warnings — that would mean a
        // malformed value or unknown key slipped in.
        $this->assertSame(
            [],
            $logger->warnings(),
            'Staging profile must load cleanly with zero FlagStore warnings.'
        );
    }

    public function testPublicDemoProfileDisablesAllCatalogueFlags(): void
    {
        $enabled = self::loadProfileYaml('test.hackersbychoice.dk');
        // `enabled: {}` parses to an empty array, which FlagStore treats
        // identically to "no overrides" (no warnings).
        $this->assertTrue(
            $enabled === null || $enabled === [],
            'test.hackersbychoice.dk features.yaml must declare an empty enabled map.'
        );

        $logger = new ArrayLogger();
        $store = new FlagStore($enabled, $logger, 'test.hackersbychoice.dk');

        foreach (self::CATALOGUE as $flagValue) {
            $case = FeatureFlag::from($flagValue);
            $this->assertFalse(
                $store->isEnabled($case),
                "Public-demo profile must disable `{$flagValue}` (0/N rule)."
            );
            $this->assertFalse(
                $store->isConfigured($case),
                "Public-demo profile must leave `{$flagValue}` unconfigured (missing-key rule)."
            );
        }

        $this->assertSame(
            [],
            $logger->warnings(),
            'Empty enabled map must not warn.'
        );
    }

    public function testPublicDemoYamlPayloadIsFlagMetadataOnly(): void
    {
        $this->assertFlagPayloadIsMetadataOnly('test.hackersbychoice.dk');
    }

    public function testStagingYamlPayloadIsFlagMetadataOnly(): void
    {
        $this->assertFlagPayloadIsMetadataOnly('staging.hackersbychoice.dk');
    }

    /**
     * Enforces "no secrets in profile files" structurally: the parsed
     * `enabled:` map must contain only declared FeatureFlag keys mapped
     * to the literal strings `"true"` or `"false"`. Nothing else — no
     * nested maps, no free-form strings, no credentials shaped as values.
     */
    private function assertFlagPayloadIsMetadataOnly(string $host): void
    {
        $path = self::envRoot() . "/{$host}/config/features.yaml";
        $this->assertFileExists($path);

        $parsed = Yaml::parseFile($path);
        $this->assertIsArray($parsed, "{$host} features.yaml must parse to an array.");
        $this->assertSame(
            ['enabled'],
            array_keys($parsed),
            "{$host} features.yaml must expose exactly one top-level key `enabled`."
        );

        $enabled = $parsed['enabled'];
        // `enabled: {}` parses to `[]` under Symfony YAML; treat that as "no overrides".
        if ($enabled === null || $enabled === []) {
            return;
        }
        $this->assertIsArray($enabled, "{$host} features.yaml `enabled` must be a map.");

        $declared = array_map(
            static fn (FeatureFlag $c): string => $c->value,
            FeatureFlag::cases()
        );
        foreach ($enabled as $key => $value) {
            $this->assertIsString($key, "{$host}: every enabled key must be a string flag name.");
            $this->assertContains(
                $key,
                $declared,
                "{$host}: `{$key}` is not a declared FeatureFlag case."
            );
            $this->assertContains(
                $value,
                ['true', 'false'],
                "{$host}: flag `{$key}` must map to the literal string \"true\" or \"false\"."
            );
        }
    }

    // -------- (3) Invalid-value / missing-file handling for new flags --------

    /**
     * @return array<string,array{0:mixed}>
     *
     * Exercises the strict-string rule for a representative sample of the
     * newly-added catalogue flags. The rule itself is already proven in
     * FlagStoreTest for `roadmap`; here we demonstrate the same
     * behaviour against the new cases so a future `isEnabled()` short-cut
     * that accidentally whitelisted certain values would fail.
     */
    public static function invalidValuesForCatalogueFlags(): array
    {
        return [
            'roadmap=tru'                     => ['roadmap', 'tru'],
            'feature_suggestion=True-mixed'   => ['feature_suggestion', 'True'],
            'bug_report=1-string'             => ['bug_report', '1'],
            'community_footer_column=int1'    => ['community_footer_column', 1],
            'membership_signup=bool-true'     => ['membership_signup', true],
            'newsletter_signup=yes'           => ['newsletter_signup', 'yes'],
            'workshop_calendar=null'          => ['workshop_calendar', null],
            'statutes_page=array'             => ['statutes_page', ['true']],
            'press_assets_download=TRUE'      => ['press_assets_download', 'TRUE'],
        ];
    }

    /** @dataProvider invalidValuesForCatalogueFlags */
    public function testInvalidValueForCatalogueFlagFailsClosedWithWarning(
        string $flagValue,
        mixed $invalid
    ): void {
        $case = FeatureFlag::from($flagValue);
        $logger = new ArrayLogger();
        $store = new FlagStore([$flagValue => $invalid], $logger, 'staging.hackersbychoice.dk');

        $this->assertFalse(
            $store->isEnabled($case),
            "Invalid value must never enable `{$flagValue}`."
        );
        $this->assertTrue(
            $store->isConfigured($case),
            "Present-but-invalid key must still mark `{$flagValue}` as configured."
        );
        $this->assertCount(
            1,
            $logger->warnings(),
            'Exactly one warning per invalid value.'
        );
        $this->assertStringStartsWith(
            'Invalid value for feature flag',
            $logger->warnings()[0]['message']
        );
    }

    public function testMissingFeaturesYamlDoesNotCrashAndFailsAllClosed(): void
    {
        // Simulate Grav presenting `features.enabled` as null because no
        // features.yaml existed on the host. This is the exact shape
        // FlagStore receives when a fresh environment directory was
        // created without a features.yaml file yet.
        $logger = new ArrayLogger();
        $store = new FlagStore(null, $logger, 'new-host.example.com');

        foreach (FeatureFlag::cases() as $case) {
            $this->assertFalse(
                $store->isEnabled($case),
                "Missing features.yaml must leave `{$case->value}` disabled."
            );
            $this->assertFalse($store->isConfigured($case));
        }
        $this->assertSame(
            [],
            $logger->warnings(),
            'Missing features.yaml is not a misconfiguration; no warning.'
        );
    }
}
