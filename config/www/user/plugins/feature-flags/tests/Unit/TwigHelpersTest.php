<?php
/**
 * Unit tests for the TwigHelpers shim. These exercise the string->enum
 * conversion layer directly — no Twig, no Grav. They cover every branch of
 * the fail-closed contract that the Sprint 2 criteria call out.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags\Tests\Unit;

use Grav\Plugin\FeatureFlags\FeatureFlag;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\TwigHelpers;
use Grav\Plugin\FeatureFlags\Tests\Support\ArrayLogger;
use PHPUnit\Framework\TestCase;

final class TwigHelpersTest extends TestCase
{
    public function testKnownFlagTrueDelegatesToStoreIsEnabled(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['promo_banner' => 'true'], $logger);
        $helpers = new TwigHelpers($store, $logger);

        $this->assertTrue($helpers->featureEnabled('promo_banner'));
        $this->assertSame([], $logger->warnings(), 'Known enabled flag must not log a warning.');
    }

    public function testKnownFlagFalseReturnsFalseAndDoesNotWarn(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(['promo_banner' => 'false'], $logger);
        // Drop the store-side "configured false" records so we only see
        // warnings produced by the helper itself.
        $logger->records = [];

        $helpers = new TwigHelpers($store, $logger);

        $this->assertFalse($helpers->featureEnabled('promo_banner'));
        $this->assertSame([], $logger->warnings());
    }

    public function testAbsentFlagReturnsFalseAndDoesNotWarn(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore([], $logger);
        $helpers = new TwigHelpers($store, $logger);

        $this->assertFalse($helpers->featureEnabled('promo_banner'));
        $this->assertSame([], $logger->warnings());
    }

    public function testUnknownNameReturnsFalseAndLogsExactlyOneWarning(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore([], $logger);
        $helpers = new TwigHelpers($store, $logger);

        $this->assertFalse($helpers->featureEnabled('not_a_real_flag'));

        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings, 'Exactly one warning for the unknown-name case.');
        $this->assertSame('Unknown feature flag.', $warnings[0]['message']);
        $this->assertSame('not_a_real_flag', $warnings[0]['context']['flag'] ?? null);
    }

    public function testEmptyStringReturnsFalseAndWarns(): void
    {
        $logger = new ArrayLogger();
        $helpers = new TwigHelpers(new FlagStore([], $logger), $logger);

        $this->assertFalse($helpers->featureEnabled(''));
        $this->assertCount(1, $logger->warnings());
        $this->assertSame('Unknown feature flag.', $logger->warnings()[0]['message']);
    }

    /** @return array<string,array{0: mixed}> */
    public static function nonStringProvider(): array
    {
        return [
            'null'    => [null],
            'int'     => [42],
            'float'   => [1.5],
            'bool'    => [true],
            'array'   => [['foo']],
            'object'  => [new \stdClass()],
        ];
    }

    /** @dataProvider nonStringProvider */
    public function testNonStringArgumentReturnsFalseAndWarns(mixed $arg): void
    {
        $logger = new ArrayLogger();
        $helpers = new TwigHelpers(new FlagStore([], $logger), $logger);

        $this->assertFalse($helpers->featureEnabled($arg));
        $this->assertCount(1, $logger->warnings());
    }

    public function testLogMessageDoesNotLeakLongRawStrings(): void
    {
        $logger = new ArrayLogger();
        $helpers = new TwigHelpers(new FlagStore([], $logger), $logger);

        $long = str_repeat('x', 512);
        $this->assertFalse($helpers->featureEnabled($long));
        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        // The raw string is truncated before landing in context['flag'].
        $this->assertLessThanOrEqual(200, strlen((string) $warnings[0]['context']['flag']));
    }

    public function testEnabledFeaturesReturnsStringArrayNotEnumCases(): void
    {
        $logger = new ArrayLogger();
        $store = new FlagStore(
            ['promo_banner' => 'true', 'partner_portal' => 'true'],
            $logger
        );
        $helpers = new TwigHelpers($store, $logger);

        $result = $helpers->enabledFeatures();
        $this->assertIsArray($result);
        foreach ($result as $item) {
            $this->assertIsString($item, 'enabled_features() must return strings, not enum instances.');
        }
        $this->assertContains(FeatureFlag::PromoBanner->value, $result);
        $this->assertContains(FeatureFlag::PartnerPortal->value, $result);
        $this->assertCount(2, $result);
    }

    public function testEnabledFeaturesEmptyByDefault(): void
    {
        $logger = new ArrayLogger();
        $helpers = new TwigHelpers(new FlagStore([], $logger), $logger);
        $this->assertSame([], $helpers->enabledFeatures());
    }

    public function testWarningContextContainsEnvironmentButNoSensitiveData(): void
    {
        $logger = new ArrayLogger();
        $helpers = new TwigHelpers(new FlagStore([], $logger), $logger, 'staging.example.com');

        $helpers->featureEnabled('not_a_real_flag');
        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $ctx = $warnings[0]['context'];
        $this->assertSame('staging.example.com', $ctx['environment'] ?? null);
        // No forbidden keys — the PSR-3 context map is the only place we
        // might accidentally leak; assert on a small allow-list.
        $allowedKeys = ['flag', 'reason', 'environment', 'arg_type'];
        foreach (array_keys($ctx) as $k) {
            $this->assertContains(
                $k,
                $allowedKeys,
                "Unexpected context key '{$k}' in warning log; possible data leak."
            );
        }
    }

    public function testFailClosedWhenStoreThrows(): void
    {
        $logger = new ArrayLogger();
        $throwingStore = new class implements \Grav\Plugin\FeatureFlags\FlagStoreInterface {
            public function isEnabled(FeatureFlag $flag): bool { throw new \RuntimeException('boom'); }
            public function isConfigured(FeatureFlag $flag): bool { return false; }
            public function getEnabledFlags(): array { throw new \RuntimeException('boom'); }
            public function allFlags(): array { return []; }
            public function debug(): array { return ['enabled' => [], 'configured' => [], 'all' => []]; }
        };

        $helpers = new TwigHelpers($throwingStore, $logger);
        $this->assertFalse($helpers->featureEnabled('promo_banner'));
        $this->assertSame([], $helpers->enabledFeatures());
    }
}
