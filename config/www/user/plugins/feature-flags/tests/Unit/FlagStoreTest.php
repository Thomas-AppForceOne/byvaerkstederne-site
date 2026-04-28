<?php
/**
 * Unit tests for FlagStore — the parser/resolver at the heart of the
 * feature-flags plugin. Covers every branch of the resolution table, every
 * malformed top-level shape, unknown and non-string keys, isConfigured
 * semantics, and the exact debug() shape. These tests are intentionally
 * granular: one behaviour per method (or labelled dataProvider row) so that
 * failures produce readable diffs.
 *
 * Prior sprints exercised much of this indirectly via PageGate / TwigHelpers
 * tests; this file makes the FlagStore contract explicit so no regression
 * can silently slip past the other suites' assertion shapes.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags\Tests\Unit;

use Grav\Plugin\FeatureFlags\FeatureFlag;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\Tests\Support\ArrayLogger;
use PHPUnit\Framework\TestCase;

final class FlagStoreTest extends TestCase
{
    // -------- Resolution table: missing key --------

    public function testMissingKeyIsEnabledFalseIsConfiguredFalseNoWarning(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore([], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::Roadmap));
        $this->assertFalse($store->isConfigured(FeatureFlag::Roadmap));
        $this->assertSame([], $logger->warnings(), 'Absent key must not warn.');
    }

    public function testNullEnabledIsEquivalentToEmpty(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(null, $logger);

        foreach (FeatureFlag::cases() as $case) {
            $this->assertFalse($store->isEnabled($case));
            $this->assertFalse($store->isConfigured($case));
        }
        $this->assertSame([], $logger->warnings());
    }

    // -------- Resolution table: exact-string "true" --------

    public function testExactStringTrueEnables(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['roadmap' => 'true'], $logger);

        $this->assertTrue($store->isEnabled(FeatureFlag::Roadmap));
        $this->assertTrue($store->isConfigured(FeatureFlag::Roadmap));
        $this->assertSame([], $logger->warnings());
    }

    // -------- Resolution table: exact-string "false" --------

    public function testExactStringFalseDisablesWithoutWarning(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['roadmap' => 'false'], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::Roadmap));
        $this->assertTrue($store->isConfigured(FeatureFlag::Roadmap));
        $this->assertSame([], $logger->warnings(), '"false" is a valid value; no warning.');
    }

    // -------- Resolution table: any other string --------

    /** @return array<string,array{0:mixed}> */
    public static function invalidStringValues(): array
    {
        return [
            'upper-TRUE'   => ['TRUE'],
            'yes'          => ['yes'],
            'one'          => ['1'],
            'zero'         => ['0'],
            'empty-string' => [''],
            'truthy'       => ['truthy'],
            'False-mixed'  => ['False'],
        ];
    }

    /** @dataProvider invalidStringValues */
    public function testInvalidStringValueFailsClosedWithExactlyOneWarning(mixed $value): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['roadmap' => $value], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::Roadmap));
        $this->assertTrue(
            $store->isConfigured(FeatureFlag::Roadmap),
            'Configured-but-disabled: key is present even when value is invalid.'
        );

        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertStringStartsWith(
            'Invalid value for feature flag',
            $warnings[0]['message']
        );
    }

    // -------- Resolution table: non-string scalar value --------

    /** @return array<string,array{0:mixed}> */
    public static function nonStringScalarValues(): array
    {
        return [
            'int-1'      => [1],
            'int-0'      => [0],
            'float'      => [1.5],
            'bool-true'  => [true],
            'bool-false' => [false],
            'null'       => [null],
        ];
    }

    /** @dataProvider nonStringScalarValues */
    public function testNonStringScalarValueFailsClosedWithExactlyOneWarning(mixed $value): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['roadmap' => $value], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::Roadmap));
        $this->assertTrue($store->isConfigured(FeatureFlag::Roadmap));
        $this->assertCount(1, $logger->warnings());
    }

    // -------- Resolution table: array value --------

    public function testArrayValueFailsClosedWithWarning(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['roadmap' => ['nested']], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::Roadmap));
        $this->assertTrue($store->isConfigured(FeatureFlag::Roadmap));
        $this->assertCount(1, $logger->warnings());
    }

    // -------- Malformed top-level shape --------

    /** @return array<string,array{0:mixed}> */
    public static function malformedTopLevelShapes(): array
    {
        return [
            'string'   => ['not-an-array'],
            'int'      => [42],
            'bool'     => [true],
            'float'    => [1.5],
        ];
    }

    /** @dataProvider malformedTopLevelShapes */
    public function testMalformedTopLevelFailsClosedForEveryFlag(mixed $raw): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore($raw, $logger);

        // Behavioural contract (preserved across enum-case additions):
        //   (a) every declared FeatureFlag case resolves to disabled and unconfigured,
        //   (b) getEnabledFlags() returns empty,
        //   (c) allFlags() contains one false-seeded entry per declared case,
        //       in FeatureFlag::cases() declaration order.
        foreach (FeatureFlag::cases() as $case) {
            $this->assertFalse($store->isEnabled($case));
            $this->assertFalse($store->isConfigured($case));
        }
        $this->assertSame([], $store->getEnabledFlags());

        $expectedAll = [];
        foreach (FeatureFlag::cases() as $case) {
            $expectedAll[$case->value] = false;
        }
        $this->assertSame($expectedAll, $store->allFlags());
        $this->assertCount(
            count(FeatureFlag::cases()),
            $store->allFlags(),
            'allFlags() must have exactly one entry per declared enum case.'
        );

        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertStringStartsWith(
            'features.enabled is not an array',
            $warnings[0]['message']
        );
        $ctx = $warnings[0]['context'];
        $this->assertArrayHasKey('raw_type', $ctx);
        $this->assertArrayHasKey('raw_value', $ctx);
        $this->assertArrayHasKey('environment', $ctx);
    }

    // -------- Unknown and non-string keys --------

    public function testUnknownKeyProducesWarningAndDoesNotAffectKnownKey(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(
            ['unknown_flag' => 'true', 'roadmap' => 'true'],
            $logger
        );

        $this->assertTrue($store->isEnabled(FeatureFlag::Roadmap));
        $debug = $store->debug();
        $this->assertNotContains('unknown_flag', $debug['configured']);
        $this->assertArrayNotHasKey('unknown_flag', $debug['all']);

        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertSame(
            'Unknown feature flag key in config; ignoring.',
            $warnings[0]['message']
        );
        $ctx = $warnings[0]['context'];
        $this->assertSame('unknown_flag', $ctx['flag']);
        $this->assertArrayHasKey('raw_value', $ctx);
        $this->assertArrayHasKey('environment', $ctx);
    }

    public function testNumericKeyIsSkippedWithWarning(): void
    {
        $logger = new ArrayLogger();
        // Numeric-indexed list entry (PHP autocasts numeric string keys to int).
        $store = new FlagStore([0 => 'true'], $logger);

        foreach (FeatureFlag::cases() as $case) {
            $this->assertFalse($store->isEnabled($case));
        }

        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertStringContainsString(
            'Feature flag key is not a string',
            $warnings[0]['message']
        );
    }

    public function testMixedUnknownNumericAndValidEachWarnedIndependently(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(
            [
                'unknown_flag'       => 'true',   // unknown -> warn
                0                    => 'true',   // numeric key -> warn
                'roadmap'            => 'true',   // valid -> resolves true
                'feature_suggestion' => 'TRUE',   // invalid value -> warn
            ],
            $logger
        );

        $this->assertTrue($store->isEnabled(FeatureFlag::Roadmap));
        $this->assertFalse($store->isEnabled(FeatureFlag::FeatureSuggestion));
        $this->assertTrue($store->isConfigured(FeatureFlag::FeatureSuggestion));

        $messages = array_column($logger->warnings(), 'message');
        $this->assertCount(3, $messages, 'Three defective entries -> three warnings.');
    }

    // -------- isConfigured semantics --------

    public function testIsConfiguredDistinguishesAbsentFromInvalid(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(
            ['roadmap' => 'TRUE'], // invalid value
            $logger
        );

        $this->assertTrue(
            $store->isConfigured(FeatureFlag::Roadmap),
            'Present-with-invalid must be configured=true.'
        );
        $this->assertFalse($store->isEnabled(FeatureFlag::Roadmap));

        $this->assertFalse(
            $store->isConfigured(FeatureFlag::FeatureSuggestion),
            'Absent key must be configured=false.'
        );
    }

    // -------- debug() shape --------

    public function testDebugShapeIsExactAndOrdered(): void
    {
        $store = new FlagStore([
            'roadmap'            => 'true',
            'feature_suggestion' => 'false',
            'bug_report'         => 'TRUE', // invalid but configured
            // community_footer_column absent
        ]);

        $debug = $store->debug();
        $this->assertSame(
            ['enabled', 'configured', 'all'],
            array_keys($debug),
            'debug() top-level keys must be exactly [enabled, configured, all] in order.'
        );

        // enabled: list<string>
        $this->assertSame(['roadmap'], $debug['enabled']);
        foreach ($debug['enabled'] as $i => $v) {
            $this->assertIsInt($i, 'enabled must be integer-indexed (a list).');
            $this->assertIsString($v);
        }

        // configured: list<string>
        $this->assertIsArray($debug['configured']);
        $this->assertSame(
            array_values($debug['configured']),
            $debug['configured'],
            'configured must be a list (integer-indexed, consecutive).'
        );
        sort($debug['configured']); // order-agnostic set check
        $expectedConfigured = ['bug_report', 'feature_suggestion', 'roadmap'];
        $this->assertSame($expectedConfigured, $debug['configured']);

        // Behavioural contract (preserved across enum-case additions):
        // debug()['all'] has exactly the key set and stable ordering of
        // FeatureFlag::cases(); the three configured keys above resolve
        // as set and every other declared case resolves to false.
        $expectedAll = [];
        foreach (FeatureFlag::cases() as $case) {
            $expectedAll[$case->value] = false;
        }
        $expectedAll['roadmap'] = true;
        // feature_suggestion and bug_report already seeded false above; explicit
        // assignment keeps the intent readable.
        $expectedAll['feature_suggestion'] = false;
        $expectedAll['bug_report']         = false;

        $this->assertSame(
            $expectedAll,
            $debug['all'],
            'debug()["all"] keys must match FeatureFlag::cases() exactly, in declaration order.'
        );
        $this->assertSame(
            array_map(static fn (FeatureFlag $c): string => $c->value, FeatureFlag::cases()),
            array_keys($debug['all']),
            'debug()["all"] key ordering must mirror FeatureFlag::cases().'
        );
    }

    // -------- Warning messages verbatim (logger-double sanity) --------

    public function testInvalidValueWarningMessageAndContextAreVerbatim(): void
    {
        $logger = new ArrayLogger();
        new FlagStore(['roadmap' => 'TRUE'], $logger, 'localhost');

        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertSame(
            'Invalid value for feature flag; must be exact string "true" or "false". Treating as disabled.',
            $warnings[0]['message']
        );
        $ctx = $warnings[0]['context'];
        $this->assertSame(
            ['flag', 'raw_value', 'raw_type', 'environment'],
            array_keys($ctx),
            'Context keys must be exactly {flag, raw_value, raw_type, environment}.'
        );
        $this->assertSame('roadmap', $ctx['flag']);
        $this->assertSame('TRUE', $ctx['raw_value']);
        $this->assertSame('string', $ctx['raw_type']);
        $this->assertSame('localhost', $ctx['environment']);
    }

    public function testUnknownKeyWarningContextShape(): void
    {
        $logger = new ArrayLogger();
        new FlagStore(['mystery_flag' => 'true'], $logger, 'staging.hackersbychoice.dk');

        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertSame(
            'Unknown feature flag key in config; ignoring.',
            $warnings[0]['message']
        );
        $ctx = $warnings[0]['context'];
        $this->assertSame(
            ['flag', 'raw_value', 'environment'],
            array_keys($ctx)
        );
        $this->assertSame('mystery_flag', $ctx['flag']);
        $this->assertSame('true', $ctx['raw_value']);
        $this->assertSame('staging.hackersbychoice.dk', $ctx['environment']);
    }

    public function testNonArrayTopLevelWarningContextShape(): void
    {
        $logger = new ArrayLogger();
        new FlagStore('not-an-array', $logger, 'localhost');

        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertSame(
            'features.enabled is not an array; ignoring all feature flag overrides.',
            $warnings[0]['message']
        );
        $ctx = $warnings[0]['context'];
        $this->assertSame(
            ['raw_type', 'raw_value', 'environment'],
            array_keys($ctx)
        );
        $this->assertSame('string', $ctx['raw_type']);
        $this->assertSame('not-an-array', $ctx['raw_value']);
        $this->assertSame('localhost', $ctx['environment']);
    }

    public function testEnabledFlagsReturnsEnumCases(): void
    {
        $store = new FlagStore([
            'roadmap'            => 'true',
            'feature_suggestion' => 'true',
        ]);

        $flags = $store->getEnabledFlags();
        $this->assertCount(2, $flags);
        foreach ($flags as $flag) {
            $this->assertInstanceOf(FeatureFlag::class, $flag);
        }
        $values = array_map(static fn (FeatureFlag $f): string => $f->value, $flags);
        $this->assertContains('roadmap', $values);
        $this->assertContains('feature_suggestion', $values);
    }

    public function testAllFlagsAlwaysMatchesDeclaredCases(): void
    {
        // Behavioural contract (preserved across enum-case additions):
        // allFlags() returns exactly one entry per declared FeatureFlag case,
        // in declaration order, with no extras — independent of which subset
        // of keys appeared in the raw config.
        $store = new FlagStore(['roadmap' => 'true']);
        $all = $store->allFlags();

        $expectedKeys = array_map(
            static fn (FeatureFlag $c): string => $c->value,
            FeatureFlag::cases()
        );
        $this->assertSame(
            $expectedKeys,
            array_keys($all),
            'allFlags() key set and order must match FeatureFlag::cases() exactly.'
        );
        $this->assertCount(
            count(FeatureFlag::cases()),
            $all,
            'allFlags() must have exactly one entry per declared enum case (no extras).'
        );

        // Only the single configured key flipped; everything else stays false.
        $this->assertTrue($all['roadmap']);
        foreach (FeatureFlag::cases() as $case) {
            if ($case->value === 'roadmap') {
                continue;
            }
            $this->assertFalse(
                $all[$case->value],
                "Unconfigured flag {$case->value} must be false."
            );
        }
    }
}
