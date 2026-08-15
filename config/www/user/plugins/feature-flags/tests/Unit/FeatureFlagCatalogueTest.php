<?php
/**
 * Sprint 1 rollout-catalogue coverage.
 *
 * These tests pin down three properties the rollout spec depends on:
 *
 *   1. Every flag named in the rollout catalogue is a declared FeatureFlag
 *      enum case.
 *   2. The `dev.hackersbychoice.dk` profile enables every catalogue flag
 *      (the all-on tier; also catches "new enum case forgot the dev
 *      profile line"). The other tier profiles (test/staging/prod) are
 *      OPERATIONAL state — flags there are flipped to preview unreleased
 *      or temporary features and are deliberately NOT pinned by tests;
 *      only their payload SHAPE (declared flags, strict strings, no
 *      secrets) is enforced. The always-off profile the browser suites
 *      rely on is the dedicated `flags-off.invalid` fixture.
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
        'newsletter_signup',
        'event_highlight',
        'press_page',
        'minutes_archive',
        'press_assets_download',
        'press_stats',
        'contact_page',
        'statutes_page',
        'privacy_policy',
        'event_rsvp',
        'workshop_project_blueprints',
        'workshop_workday_signup',
        'gear_donation',
        'social_media_links',
        'makerspace_meeting_link',
        'account_self_service',
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

    /**
     * Every flag that has been retired, and why. A retired flag must not come
     * back as an enum case or a catalogue entry, and no per-tier features.yaml
     * may still declare it — a dangling key warns at runtime as an "unknown
     * feature flag" on every request.
     *
     * Two ways a flag earns retirement:
     *
     *   GATED NOTHING — the flag existed but no page, template or handler
     *   ever consulted it, so the explicit false-list in the prod profile
     *   advertised a kill switch for a feature that did not exist.
     *
     *   GRADUATED — the feature shipped to every tier and the flag stopped
     *   being a decision. The gate came out of the code with the flag.
     *
     * @return array<string,array{0:string,1:string}>
     */
    public static function retiredFlags(): array
    {
        return [
            // WI-1 (outstanding-spec-cleanup): the four /vaerksteder/* pages
            // carried no `feature:` key.
            'workshop_detail_pages'      => ['workshop_detail_pages', 'gated nothing'],
            // Featured calendar module (_03.featured) was never built.
            'workshop_calendar_featured' => ['workshop_calendar_featured', 'gated nothing'],
            // Kulturhus + MobilePay surfaces were never built either.
            'kulturhus_program'          => ['kulturhus_program', 'gated nothing'],
            'kulturhus_volunteer'        => ['kulturhus_volunteer', 'gated nothing'],
            'donation_mobilepay'         => ['donation_mobilepay', 'gated nothing'],
            // Live on all four tiers since v1.3.0.
            'workshop_calendar'          => ['workshop_calendar', 'graduated'],
            'workshop_calendar_filters'  => ['workshop_calendar_filters', 'graduated'],
            'event_management'           => ['event_management', 'graduated'],
        ];
    }

    /**
     * @dataProvider retiredFlags
     */
    public function testRetiredFlagStaysRetired(string $flag, string $reason): void
    {
        $this->assertNull(
            FeatureFlag::tryFrom($flag),
            "`{$flag}` was retired ({$reason}) — it must not be a valid enum case again."
        );
        $this->assertNotContains($flag, self::CATALOGUE);

        foreach (['dev.hackersbychoice.dk', 'test.hackersbychoice.dk', 'staging.hackersbychoice.dk', 'www.byvaerkstederne.dk'] as $host) {
            $enabled = self::loadProfileYaml($host);
            if (is_array($enabled)) {
                $this->assertArrayNotHasKey(
                    $flag,
                    $enabled,
                    "{$host} features.yaml must not declare the retired `{$flag}` flag."
                );
            }
        }
    }

    // -------- (2) Profile resolution --------

    public function testDevProfileEnablesAllCatalogueFlags(): void
    {
        // dev is the all-on tier (the "internal" profile) — this test also
        // catches "new enum case forgot its dev profile line". The other
        // tier profiles (test/staging/prod) are operational state and are
        // deliberately NOT pinned: flags there flip to preview unreleased
        // features without code changes. Only their payload shape is
        // enforced (the metadata-only tests below).
        $enabled = self::loadProfileYaml('dev.hackersbychoice.dk');
        $this->assertIsArray($enabled, 'dev.hackersbychoice.dk features.yaml must parse to an array.');

        $logger = new ArrayLogger();
        $store = new FlagStore($enabled, $logger, 'dev.hackersbychoice.dk');

        $enabledCount = 0;
        $total = count(self::CATALOGUE);
        foreach (self::CATALOGUE as $flagValue) {
            $case = FeatureFlag::from($flagValue);
            $this->assertTrue(
                $store->isEnabled($case),
                "Dev (internal) profile must enable `{$flagValue}` ({$total}/{$total} rule)."
            );
            $enabledCount++;
        }
        $this->assertSame($total, $enabledCount, "Dev must flip exactly {$total} catalogue flags on.");

        // Zero warnings — a warning would mean a malformed value or an unknown
        // key (e.g. a flag left in the YAML after its enum case was removed).
        $this->assertSame(
            [],
            $logger->warnings(),
            'Dev profile must load cleanly with zero FlagStore warnings.'
        );
    }

    /**
     * The all-off FIXTURE profile the browser suites rely on must actually
     * be all-off — this is the only profile with a pinned flag state
     * besides dev, and it is never deployed.
     */
    public function testFlagsOffFixtureProfileDisablesEverything(): void
    {
        $enabled = self::loadProfileYaml('flags-off.invalid');
        $this->assertTrue(
            $enabled === null || $enabled === [],
            'flags-off.invalid features.yaml must declare an empty enabled map — its entire purpose.'
        );

        $logger = new ArrayLogger();
        $store = new FlagStore($enabled, $logger, 'flags-off.invalid');

        foreach (self::CATALOGUE as $flagValue) {
            $case = FeatureFlag::from($flagValue);
            $this->assertFalse($store->isEnabled($case));
            $this->assertFalse($store->isConfigured($case));
        }

        $this->assertSame([], $logger->warnings(), 'Empty enabled map must not warn.');
    }

    /**
     * Staging is production's rehearsal — both governance headers say so, and
     * the staging one spells out the direction: it flips a flag "at the same
     * time (or earlier, never later)" than prod. So anything enabled in
     * production must also be enabled on staging.
     *
     * This is a RELATION between the two files, not a pinned state: which
     * features are live stays operational state (see
     * testDevProfileEnablesAllCatalogueFlags). What it catches is the
     * half-done rollout — prod flipped, staging forgotten — after which
     * staging silently stops showing reviewers what production shows.
     */
    public function testStagingIsNeverBehindProd(): void
    {
        $prod = self::loadProfileYaml('www.byvaerkstederne.dk');
        $staging = self::loadProfileYaml('staging.hackersbychoice.dk');
        $this->assertIsArray($prod, 'prod features.yaml must parse to an array.');
        $this->assertIsArray($staging, 'staging features.yaml must parse to an array.');

        $behind = [];
        foreach ($prod as $flag => $value) {
            if ($value === 'true' && ($staging[$flag] ?? 'false') !== 'true') {
                $behind[] = $flag;
            }
        }

        $this->assertSame(
            [],
            $behind,
            'Enabled on prod but not on staging: ' . implode(', ', $behind)
            . ' — flip the same flag on staging.hackersbychoice.dk (staging never lags prod).'
        );
    }

    public function testTestTierYamlPayloadIsFlagMetadataOnly(): void
    {
        $this->assertFlagPayloadIsMetadataOnly('test.hackersbychoice.dk');
    }

    public function testStagingYamlPayloadIsFlagMetadataOnly(): void
    {
        $this->assertFlagPayloadIsMetadataOnly('staging.hackersbychoice.dk');
    }

    public function testProdYamlPayloadIsFlagMetadataOnly(): void
    {
        $this->assertFlagPayloadIsMetadataOnly('www.byvaerkstederne.dk');
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
            'event_highlight=bool-true'       => ['event_highlight', true],
            'newsletter_signup=yes'           => ['newsletter_signup', 'yes'],
            'press_stats=null'                => ['press_stats', null],
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
