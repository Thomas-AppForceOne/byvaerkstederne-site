<?php
/**
 * Unit tests for CollectionFilter — the helper that strips feature-gated-
 * disabled entries from an iterable. Covers every entry shape the Sprint 3
 * criteria enumerate (no-header, enabled, disabled, unknown, non-string,
 * nested header object) and asserts input-order preservation.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags\Tests\Unit;

use Grav\Plugin\FeatureFlags\CollectionFilter;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\PageGate;
use Grav\Plugin\FeatureFlags\Tests\Support\ArrayLogger;
use PHPUnit\Framework\TestCase;

final class CollectionFilterTest extends TestCase
{
    private function makeFilter(array $enabled = [], ?ArrayLogger $logger = null): CollectionFilter
    {
        $logger ??= new ArrayLogger();
        $store = new FlagStore($enabled, $logger);
        $logger->records = [];
        $gate = new PageGate($store, $logger);
        return new CollectionFilter($gate);
    }

    public function testNoFeatureHeaderPassesThrough(): void
    {
        $filter = $this->makeFilter();
        $input = [
            ['header' => ['title' => 'A']],
            ['header' => ['title' => 'B']],
        ];
        $this->assertSame($input, $filter->filter($input));
    }

    public function testEnabledFlagPassesThroughAndPreservesOrder(): void
    {
        $filter = $this->makeFilter(['roadmap' => 'true']);
        $a = ['id' => 'a', 'header' => ['feature' => 'roadmap']];
        $b = ['id' => 'b', 'header' => ['title' => 'plain']];
        $c = ['id' => 'c', 'header' => ['feature' => 'roadmap']];

        $out = $filter->filter([$a, $b, $c]);
        $this->assertCount(3, $out);
        $this->assertSame(['a', 'b', 'c'], array_column($out, 'id'));
    }

    public function testDisabledFlagIsStripped(): void
    {
        $filter = $this->makeFilter();
        $out = $filter->filter([
            ['id' => 'a', 'header' => ['feature' => 'roadmap']],
            ['id' => 'b', 'header' => []],
        ]);
        $this->assertSame(['b'], array_column($out, 'id'));
    }

    public function testUnknownEnumNameIsStripped(): void
    {
        $filter = $this->makeFilter();
        $out = $filter->filter([
            ['id' => 'a', 'header' => ['feature' => 'not_a_flag']],
            ['id' => 'b', 'header' => ['feature' => 'roadmap']],
            ['id' => 'c', 'header' => []],
        ]);
        // Both flag-carrying entries are disabled; only 'c' passes.
        $this->assertSame(['c'], array_column($out, 'id'));
    }

    /** @return array<string,array{0:mixed}> */
    public static function nonStringValues(): array
    {
        return [
            'array' => [['roadmap']],
            'int'   => [42],
            'bool'  => [true],
            'object' => [new \stdClass()],
        ];
    }

    /** @dataProvider nonStringValues */
    public function testNonStringFeatureValueIsStripped(mixed $badValue): void
    {
        $filter = $this->makeFilter(['roadmap' => 'true']);
        $out = $filter->filter([
            ['id' => 'bad', 'header' => ['feature' => $badValue]],
            ['id' => 'good', 'header' => ['feature' => 'roadmap']],
        ]);
        $this->assertSame(['good'], array_column($out, 'id'));
    }

    public function testEmptyStringFeatureValueIsStripped(): void
    {
        $filter = $this->makeFilter();
        $out = $filter->filter([
            ['id' => 'empty', 'header' => ['feature' => '']],
            ['id' => 'plain', 'header' => []],
        ]);
        $this->assertSame(['plain'], array_column($out, 'id'));
    }

    public function testGravLikePageObjectIsHandled(): void
    {
        $filter = $this->makeFilter(['feature_suggestion' => 'true']);

        $disabled = new class {
            public function header(): object { return (object) ['feature' => 'roadmap']; }
            public function route(): string { return '/disabled'; }
        };
        $enabled = new class {
            public function header(): object { return (object) ['feature' => 'feature_suggestion']; }
            public function route(): string { return '/enabled'; }
        };
        $plain = new class {
            public function header(): object { return (object) ['title' => 'plain']; }
            public function route(): string { return '/plain'; }
        };

        $out = $filter->filter([$disabled, $enabled, $plain]);
        $this->assertCount(2, $out);
        $this->assertSame($enabled, $out[0]);
        $this->assertSame($plain, $out[1]);
    }

    public function testFlatRowWithTopLevelFeatureKey(): void
    {
        // Some Grav collection shapes (e.g. arrays from config-backed
        // menus) put `feature` at the top level rather than inside a
        // `header` sub-array. The filter must handle both.
        $filter = $this->makeFilter(['feature_suggestion' => 'true']);
        $out = $filter->filter([
            ['title' => 'A', 'feature' => 'roadmap'],
            ['title' => 'B', 'feature' => 'feature_suggestion'],
            ['title' => 'C'],
        ]);
        $this->assertSame(['B', 'C'], array_column($out, 'title'));
    }

    public function testShouldShowSingleEntryApi(): void
    {
        $filter = $this->makeFilter(['roadmap' => 'true']);
        $this->assertTrue($filter->shouldShow(['header' => ['feature' => 'roadmap']]));
        $this->assertFalse($filter->shouldShow(['header' => ['feature' => 'feature_suggestion']]));
        $this->assertTrue($filter->shouldShow(['header' => []]));
    }

    public function testAcceptsGenerator(): void
    {
        $filter = $this->makeFilter();
        $gen = (function (): \Generator {
            yield ['id' => 1, 'header' => []];
            yield ['id' => 2, 'header' => ['feature' => 'roadmap']];
            yield ['id' => 3, 'header' => []];
        })();

        $out = $filter->filter($gen);
        $this->assertSame([1, 3], array_column($out, 'id'));
    }
}
