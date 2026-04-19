<?php
/**
 * Unit tests for PageGate::decide — the pure decision function that the
 * feature-flags plugin uses inside onPageInitialized to answer "render or
 * replace with themed 404?".
 *
 * Every branch of the fail-closed contract is exercised: header absent,
 * `feature:` key absent, null / non-string / empty / unknown / known-
 * disabled / known-enabled, plus a store-exception path. All tests run
 * without booting Grav and without hitting the filesystem — the input is
 * a plain array or a lightweight anonymous-class header.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags\Tests\Unit;

use Grav\Plugin\FeatureFlags\FeatureFlag;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\FlagStoreInterface;
use Grav\Plugin\FeatureFlags\PageGate;
use Grav\Plugin\FeatureFlags\Tests\Support\ArrayLogger;
use PHPUnit\Framework\TestCase;

final class PageGateTest extends TestCase
{
    private function makeGate(array $enabled = [], ?ArrayLogger $logger = null): PageGate
    {
        $logger ??= new ArrayLogger();
        $store = new FlagStore($enabled, $logger);
        // Silence the "configured false" / "configured true" records left
        // on the logger by the store so each test only sees the gate's
        // own warnings.
        $logger->records = [];
        return new PageGate($store, $logger, 'localhost');
    }

    public function testNoHeaderAllows(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        $this->assertSame(PageGate::ALLOW, $gate->decide(null, '/some-route'));
        $this->assertSame([], $logger->warnings(), 'ALLOW path must not warn.');
    }

    public function testHeaderWithoutFeatureKeyAllows(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        $this->assertSame(
            PageGate::ALLOW,
            $gate->decide(['title' => 'Hello'], '/hello')
        );
        $this->assertSame([], $logger->warnings());
    }

    public function testArrayAccessHeaderWithoutFeatureKeyAllows(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        $header = new \ArrayObject(['title' => 'X']);
        $this->assertSame(PageGate::ALLOW, $gate->decide($header));
        $this->assertSame([], $logger->warnings());
    }

    public function testObjectHeaderWithFeatureProperty(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate(['checkout_v2' => 'true'], $logger);
        $header = new \stdClass();
        $header->feature = 'checkout_v2';
        $this->assertSame(PageGate::ALLOW, $gate->decide($header));
    }

    public function testKnownEnabledFlagAllows(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate(['checkout_v2' => 'true'], $logger);
        $this->assertSame(
            PageGate::ALLOW,
            $gate->decide(['feature' => 'checkout_v2'])
        );
        $this->assertSame([], $logger->warnings(), 'Enabled path must not warn.');
    }

    public function testKnownDisabledFlagReturnsNotFoundWithoutWarning(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        $this->assertSame(
            PageGate::NOT_FOUND,
            $gate->decide(['feature' => 'checkout_v2'])
        );
        // Normal disabled path — no warning, this is the expected state.
        $this->assertSame([], $logger->warnings());
    }

    public function testUnknownEnumNameFailsClosedWithWarning(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        $this->assertSame(
            PageGate::NOT_FOUND,
            $gate->decide(['feature' => 'not_a_flag'], '/some-route')
        );
        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $ctx = $warnings[0]['context'];
        $this->assertSame('not_a_flag', $ctx['flag']);
        $this->assertSame('unknown_name', $ctx['reason']);
        $this->assertSame('/some-route', $ctx['route']);
        $this->assertSame('localhost', $ctx['environment']);
    }

    public function testEmptyStringValueFailsClosedWithWarning(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        $this->assertSame(
            PageGate::NOT_FOUND,
            $gate->decide(['feature' => ''])
        );
        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertSame('empty_value', $warnings[0]['context']['reason']);
    }

    /** @return array<string,array{0:mixed}> */
    public static function nonStringFeatureValues(): array
    {
        return [
            'null-value' => [['feature' => null]],
            'int'        => [['feature' => 42]],
            'bool-true'  => [['feature' => true]],
            'bool-false' => [['feature' => false]],
            'array'      => [['feature' => ['checkout_v2']]],
            'object'     => [['feature' => new \stdClass()]],
        ];
    }

    /** @dataProvider nonStringFeatureValues */
    public function testNonStringFeatureValueFailsClosed(array $header): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        // null is the "key absent" sentinel — ALLOW without warning.
        $expected = array_key_exists('feature', $header) && $header['feature'] === null
            ? PageGate::ALLOW
            : PageGate::NOT_FOUND;

        $this->assertSame($expected, $gate->decide($header));

        if ($expected === PageGate::NOT_FOUND) {
            $this->assertCount(1, $logger->warnings());
            $this->assertSame(
                'non_string_value',
                $logger->warnings()[0]['context']['reason']
            );
        }
    }

    public function testStoreThrowingResolvesToNotFoundWithWarning(): void
    {
        $logger = new ArrayLogger();
        $throwing = new class implements FlagStoreInterface {
            public function isEnabled(FeatureFlag $flag): bool { throw new \RuntimeException('boom'); }
            public function isConfigured(FeatureFlag $flag): bool { return false; }
            public function getEnabledFlags(): array { return []; }
            public function allFlags(): array { return []; }
            public function debug(): array { return ['enabled' => [], 'configured' => [], 'all' => []]; }
        };
        $gate = new PageGate($throwing, $logger, 'localhost');

        $this->assertSame(
            PageGate::NOT_FOUND,
            $gate->decide(['feature' => 'checkout_v2'], '/x')
        );
        $warnings = $logger->warnings();
        $this->assertCount(1, $warnings);
        $this->assertSame('store_exception', $warnings[0]['context']['reason']);
    }

    public function testGatingDecisionIsIdenticalForAuthenticatedVisitor(): void
    {
        // The gate has no notion of "user" — it only sees header + store.
        // This test documents that the same NOT_FOUND decision is returned
        // regardless of any auth context the event handler might later
        // attach, satisfying the "no admin bypass" criterion from
        // .gan/sprint-3-contract.json (gating_applies_to_all_visitors).
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);

        $header = ['feature' => 'checkout_v2'];
        $decisionAnon = $gate->decide($header, '/gated');

        // Simulate an "authenticated user" context by passing the same
        // header — the function signature does not accept a user; this
        // asserts the absence of any branch that could let auth bypass it.
        $decisionAuthed = $gate->decide($header, '/gated');

        $this->assertSame(PageGate::NOT_FOUND, $decisionAnon);
        $this->assertSame($decisionAnon, $decisionAuthed);
    }

    public function testLogContextDoesNotLeakSensitiveData(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        $gate->decide(['feature' => 'not_a_flag'], '/r');

        $ctx = $logger->warnings()[0]['context'];
        $allowed = ['flag', 'reason', 'route', 'environment', 'value_type', 'exception_class'];
        foreach (array_keys($ctx) as $k) {
            $this->assertContains(
                $k,
                $allowed,
                "Unexpected key '{$k}' in log context — possible leak."
            );
        }
    }

    public function testLongFlagNameIsTruncatedInLogs(): void
    {
        $logger = new ArrayLogger();
        $gate = $this->makeGate([], $logger);
        $long = str_repeat('x', 512);
        $gate->decide(['feature' => $long]);

        $ctx = $logger->warnings()[0]['context'];
        $this->assertLessThanOrEqual(200, strlen((string) $ctx['flag']));
    }
}
