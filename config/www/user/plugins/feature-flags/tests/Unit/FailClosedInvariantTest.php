<?php
/**
 * Fail-closed invariant regression suite.
 *
 * The single most important correctness property of this plugin is that no
 * malformed, unknown, disabled, or missing input can flip a feature flag to
 * `true`, render a gated page, or let a flagged-disabled entry leak through
 * the collection filter. This test class consolidates that invariant into
 * an explicit, labelled matrix across the three subsystems (FlagStore,
 * TwigHelpers, PageGate + CollectionFilter).
 *
 * Every assertion here is negative: "X MUST NOT cause a flag to resolve
 * true / MUST NOT allow render / MUST NOT pass filter." If a future change
 * accidentally loosens any fail-closed branch, one of these rows will go
 * red before the functional tests do.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags\Tests\Unit;

use Grav\Plugin\FeatureFlags\CollectionFilter;
use Grav\Plugin\FeatureFlags\FeatureFlag;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\PageGate;
use Grav\Plugin\FeatureFlags\Tests\Support\ArrayLogger;
use Grav\Plugin\FeatureFlags\TwigHelpers;
use PHPUnit\Framework\TestCase;

final class FailClosedInvariantTest extends TestCase
{
    // -------- FlagStore invariant rows --------

    /** @return array<string,array{0:mixed}> */
    public static function flagStoreMalformedInputs(): array
    {
        return [
            'enabled=string'             => ['not-an-array'],
            'enabled=null'               => [null],
            'enabled=int'                => [42],
            'enabled=float'              => [1.5],
            'enabled=bool-true'          => [true],
            'enabled=bool-false'         => [false],
            'enabled=empty-array'        => [[]],
            'value=TRUE-upper'           => [['checkout_v2' => 'TRUE']],
            'value=1-string'             => [['checkout_v2' => '1']],
            'value=int-1'                => [['checkout_v2' => 1]],
            'value=bool-true'            => [['checkout_v2' => true]],
            'value=null'                 => [['checkout_v2' => null]],
            'value=array'                => [['checkout_v2' => ['true']]],
            'key=numeric'                => [[0 => 'true']],
            'key=unknown'                => [['mystery' => 'true']],
            'value=empty-string'         => [['checkout_v2' => '']],
            'value=yes'                  => [['checkout_v2' => 'yes']],
        ];
    }

    /** @dataProvider flagStoreMalformedInputs */
    public function testFlagStoreNeverResolvesTrueForMalformedInput(mixed $raw): void
    {
        $store = new FlagStore($raw);
        foreach (FeatureFlag::cases() as $case) {
            $this->assertFalse(
                $store->isEnabled($case),
                "Malformed input must never cause {$case->value} to resolve true."
            );
        }
    }

    // -------- TwigHelpers invariant rows --------

    /** @return array<string,array{0:mixed}> */
    public static function twigHelperBadArgs(): array
    {
        return [
            'unknown-string' => ['not_a_flag'],
            'empty-string'   => [''],
            'null'           => [null],
            'int'            => [42],
            'float'          => [1.5],
            'bool-true'      => [true],
            'bool-false'     => [false],
            'array'          => [['checkout_v2']],
            'object'         => [new \stdClass()],
        ];
    }

    /** @dataProvider twigHelperBadArgs */
    public function testTwigFeatureEnabledNeverReturnsTrueForBadArg(mixed $arg): void
    {
        $logger = new ArrayLogger();
        // Every flag intentionally enabled at the store level — so the only
        // way featureEnabled($arg) could return true is if the helper let
        // the bad arg through. Fail-closed means it must not.
        $store = new FlagStore([
            'checkout_v2'        => 'true',
            'pricing_experiment' => 'true',
            'promo_banner'       => 'true',
            'partner_portal'     => 'true',
        ], $logger);
        $helpers = new TwigHelpers($store, $logger);

        $this->assertFalse($helpers->featureEnabled($arg));
    }

    // -------- PageGate invariant rows --------

    /** @return array<string,array{0:mixed}> */
    public static function pageGateBadHeaders(): array
    {
        return [
            'feature-unknown'        => [['feature' => 'not_a_flag']],
            'feature-empty'          => [['feature' => '']],
            'feature-int'            => [['feature' => 42]],
            'feature-bool'           => [['feature' => true]],
            'feature-array'          => [['feature' => ['checkout_v2']]],
            'feature-object'         => [['feature' => new \stdClass()]],
            'feature-known-disabled' => [['feature' => 'checkout_v2']],
        ];
    }

    /** @dataProvider pageGateBadHeaders */
    public function testPageGateNeverRendersForBadOrDisabled(array $header): void
    {
        $gate = new PageGate(new FlagStore([]), new ArrayLogger(), 'localhost');
        $this->assertSame(
            PageGate::NOT_FOUND,
            $gate->decide($header, '/route'),
            'Bad or disabled feature header must decide NOT_FOUND.'
        );
    }

    // -------- CollectionFilter invariant rows --------

    /** @return array<string,array{0:mixed}> */
    public static function collectionBadEntries(): array
    {
        return [
            'unknown-name'  => [['header' => ['feature' => 'not_a_flag']]],
            'empty-string'  => [['header' => ['feature' => '']]],
            'non-string'    => [['header' => ['feature' => 42]]],
            'array-value'   => [['header' => ['feature' => ['x']]]],
            'disabled-name' => [['header' => ['feature' => 'partner_portal']]],
        ];
    }

    /** @dataProvider collectionBadEntries */
    public function testCollectionFilterStripsBadOrDisabled(array $entry): void
    {
        $logger = new ArrayLogger();
        $gate = new PageGate(new FlagStore([], $logger), $logger, 'localhost');
        $filter = new CollectionFilter($gate);

        $out = $filter->filter([$entry]);
        $this->assertSame([], $out, 'Bad or disabled entry must be stripped.');
    }
}
