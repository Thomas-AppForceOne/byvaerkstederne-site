<?php
/**
 * In-memory PSR-3 logger for tests. Captures every call for assertions.
 *
 * Pure userland — no Monolog dependency so tests can run in any PHP 8.1+
 * environment with just phpunit installed.
 */

declare(strict_types=1);

namespace Grav\Plugin\FeatureFlags\Tests\Support;

use Psr\Log\AbstractLogger;

final class ArrayLogger extends AbstractLogger
{
    /** @var list<array{level: mixed, message: string, context: array<string,mixed>}> */
    public array $records = [];

    public function log($level, $message, array $context = []): void
    {
        $this->records[] = [
            'level'   => $level,
            'message' => (string) $message,
            'context' => $context,
        ];
    }

    /** @return list<array{level: mixed, message: string, context: array<string,mixed>}> */
    public function warnings(): array
    {
        return array_values(array_filter(
            $this->records,
            static fn (array $r): bool => $r['level'] === 'warning' || $r['level'] === \Psr\Log\LogLevel::WARNING
        ));
    }
}
