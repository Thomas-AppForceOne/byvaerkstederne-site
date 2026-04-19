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

        $this->assertFalse($store->isEnabled(FeatureFlag::CheckoutV2));
        $this->assertFalse($store->isConfigured(FeatureFlag::CheckoutV2));
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
        $store = new FlagStore(['checkout_v2' => 'true'], $logger);

        $this->assertTrue($store->isEnabled(FeatureFlag::CheckoutV2));
        $this->assertTrue($store->isConfigured(FeatureFlag::CheckoutV2));
        $this->assertSame([], $logger->warnings());
    }

    // -------- Resolution table: exact-string "false" --------

    public function testExactStringFalseDisablesWithoutWarning(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['checkout_v2' => 'false'], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::CheckoutV2));
        $this->assertTrue($store->isConfigured(FeatureFlag::CheckoutV2));
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
        $store = new FlagStore(['checkout_v2' => $value], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::CheckoutV2));
        $this->assertTrue(
            $store->isConfigured(FeatureFlag::CheckoutV2),
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
        $store = new FlagStore(['checkout_v2' => $value], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::CheckoutV2));
        $this->assertTrue($store->isConfigured(FeatureFlag::CheckoutV2));
        $this->assertCount(1, $logger->warnings());
    }

    // -------- Resolution table: array value --------

    public function testArrayValueFailsClosedWithWarning(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['checkout_v2' => ['nested']], $logger);

        $this->assertFalse($store->isEnabled(FeatureFlag::CheckoutV2));
        $this->assertTrue($store->isConfigured(FeatureFlag::CheckoutV2));
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

        foreach (FeatureFlag::cases() as $case) {
            $this->assertFalse($store->isEnabled($case));
            $this->assertFalse($store->isConfigured($case));
        }
        $this->assertSame([], $store->getEnabledFlags());
        $this->assertSame(
            [
                'checkout_v2'        => false,
                'pricing_experiment' => false,
                'promo_banner'       => false,
                'partner_portal'     => false,
            ],
            $store->allFlags()
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
            ['unknown_flag' => 'true', 'checkout_v2' => 'true'],
            $logger
        );

        $this->assertTrue($store->isEnabled(FeatureFlag::CheckoutV2));
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
                'unknown_flag' => 'true',   // unknown -> warn
                0              => 'true',   // numeric key -> warn
                'checkout_v2'  => 'true',   // valid -> resolves true
                'promo_banner' => 'TRUE',   // invalid value -> warn
            ],
            $logger
        );

        $this->assertTrue($store->isEnabled(FeatureFlag::CheckoutV2));
        $this->assertFalse($store->isEnabled(FeatureFlag::PromoBanner));
        $this->assertTrue($store->isConfigured(FeatureFlag::PromoBanner));

        $messages = array_column($logger->warnings(), 'message');
        $this->assertCount(3, $messages, 'Three defective entries -> three warnings.');
    }

    // -------- isConfigured semantics --------

    public function testIsConfiguredDistinguishesAbsentFromInvalid(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(
            ['checkout_v2' => 'TRUE'], // invalid value
            $logger
        );

        $this->assertTrue(
            $store->isConfigured(FeatureFlag::CheckoutV2),
            'Present-with-invalid must be configured=true.'
        );
        $this->assertFalse($store->isEnabled(FeatureFlag::CheckoutV2));

        $this->assertFalse(
            $store->isConfigured(FeatureFlag::PromoBanner),
            'Absent key must be configured=false.'
        );
    }

    // -------- debug() shape --------

    public function testDebugShapeIsExactAndOrdered(): void
    {
        $store = new FlagStore([
            'checkout_v2'        => 'true',
            'promo_banner'       => 'false',
            'partner_portal'     => 'TRUE', // invalid but configured
            // pricing_experiment absent
        ]);

        $debug = $store->debug();
        $this->assertSame(
            ['enabled', 'configured', 'all'],
            array_keys($debug),
            'debug() top-level keys must be exactly [enabled, configured, all] in order.'
        );

        // enabled: list<string>
        $this->assertSame(['checkout_v2'], $debug['enabled']);
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
        $expectedConfigured = ['checkout_v2', 'partner_portal', 'promo_banner'];
        $this->assertSame($expectedConfigured, $debug['configured']);

        // all: array<string,bool> with exactly the four declared keys.
        $this->assertSame(
            [
                'checkout_v2'        => true,
                'pricing_experiment' => false,
                'promo_banner'       => false,
                'partner_portal'     => false,
            ],
            $debug['all']
        );
    }

    // -------- Warning messages verbatim (logger-double sanity) --------

    public function testInvalidValueWarningMessageAndContextAreVerbatim(): void
    {
        $logger = new ArrayLogger();
        new FlagStore(['checkout_v2' => 'TRUE'], $logger, 'localhost');

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
        $this->assertSame('checkout_v2', $ctx['flag']);
        $this->assertSame('TRUE', $ctx['raw_value']);
        $this->assertSame('string', $ctx['raw_type']);
        $this->assertSame('localhost', $ctx['environment']);
    }

    public function testUnknownKeyWarningContextShape(): void
    {
        $logger = new ArrayLogger();
        new FlagStore(['mystery_flag' => 'true'], $logger, 'staging.example.com');

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
        $this->assertSame('staging.example.com', $ctx['environment']);
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
            'checkout_v2'  => 'true',
            'promo_banner' => 'true',
        ]);

        $flags = $store->getEnabledFlags();
        $this->assertCount(2, $flags);
        foreach ($flags as $flag) {
            $this->assertInstanceOf(FeatureFlag::class, $flag);
        }
        $values = array_map(static fn (FeatureFlag $f): string => $f->value, $flags);
        $this->assertContains('checkout_v2', $values);
        $this->assertContains('promo_banner', $values);
    }

    public function testAllFlagsAlwaysHasFourDeclaredKeys(): void
    {
        $store = new FlagStore(['checkout_v2' => 'true']);
        $all = $store->allFlags();
        $this->assertSame(
            ['checkout_v2', 'pricing_experiment', 'promo_banner', 'partner_portal'],
            array_keys($all)
        );
        $this->assertTrue($all['checkout_v2']);
        $this->assertFalse($all['pricing_experiment']);
    }
}
