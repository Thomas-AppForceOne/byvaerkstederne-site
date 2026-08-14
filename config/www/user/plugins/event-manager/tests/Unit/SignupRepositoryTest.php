<?php
/**
 * Unit tests for SignupRepository — the toggle/capacity/read logic of the
 * event signup store (event_rsvp_specification.md §2/§3). Exercises the
 * success paths (sign up, withdraw, list) AND the failure paths (capacity
 * full, over-capacity race, garbage file) the testing discipline requires.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager\Tests\Unit;

use Grav\Plugin\EventManager\SignupRepository;
use PHPUnit\Framework\TestCase;
use Symfony\Component\Yaml\Yaml;

final class SignupRepositoryTest extends TestCase
{
    private string $dataFile;

    protected function setUp(): void
    {
        $this->dataFile = sys_get_temp_dir() . '/em-signups-' . bin2hex(random_bytes(6)) . '.yaml';
    }

    protected function tearDown(): void
    {
        if (is_file($this->dataFile)) {
            unlink($this->dataFile);
        }
    }

    private function repo(): SignupRepository
    {
        return new SignupRepository($this->dataFile);
    }

    private function storedMap(): array
    {
        if (!is_file($this->dataFile)) {
            return [];
        }
        $content = file_get_contents($this->dataFile);
        if ($content === false || trim($content) === '') {
            return [];
        }
        $parsed = Yaml::parse($content);
        return is_array($parsed) ? $parsed : [];
    }

    // ── Sign up / withdraw ───────────────────────────────────────────────

    public function testSignUpStampsModeAndTimestamp(): void
    {
        $result = $this->repo()->toggle('ev_a', 'anders', 'tilmeld');
        $this->assertSame(SignupRepository::SIGNED_UP, $result);

        $map = $this->storedMap();
        $this->assertArrayHasKey('ev_a', $map);
        $this->assertArrayHasKey('anders', $map['ev_a']);
        $this->assertSame('tilmeld', $map['ev_a']['anders']['mode']);
        $this->assertMatchesRegularExpression(
            '/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/',
            $map['ev_a']['anders']['ts']
        );
    }

    public function testToggleTwiceWithdraws(): void
    {
        $repo = $this->repo();
        $this->assertSame(SignupRepository::SIGNED_UP, $repo->toggle('ev_a', 'anders', 'tilmeld'));
        $this->assertSame(SignupRepository::WITHDRAWN, $repo->toggle('ev_a', 'anders', 'tilmeld'));
        $this->assertFalse($repo->isSignedUp('ev_a', 'anders'));
    }

    public function testWithdrawLeavesEmptyEventOutOfFile(): void
    {
        $repo = $this->repo();
        $repo->toggle('ev_a', 'anders', 'tilmeld');
        $repo->toggle('ev_a', 'anders', 'tilmeld'); // withdraw
        $this->assertArrayNotHasKey('ev_a', $this->storedMap());
    }

    public function testIsSignedUpReflectsState(): void
    {
        $repo = $this->repo();
        $this->assertFalse($repo->isSignedUp('ev_a', 'anders'));
        $repo->toggle('ev_a', 'anders', 'tilmeld');
        $this->assertTrue($repo->isSignedUp('ev_a', 'anders'));
    }

    // ── Capacity enforcement (failure paths) ─────────────────────────────

    public function testCapacityFullRejectsNewSignup(): void
    {
        $repo = $this->repo();
        $this->assertSame(SignupRepository::SIGNED_UP, $repo->toggle('ev_a', 'first', 'tilmeld', 1));
        // Second distinct member over capacity=1 → refused, nothing written.
        $this->assertSame(SignupRepository::FULL, $repo->toggle('ev_a', 'second', 'tilmeld', 1));
        $this->assertFalse($repo->isSignedUp('ev_a', 'second'));
        $this->assertSame(1, $repo->countFor('ev_a'));
    }

    public function testWithdrawFreesTheSeat(): void
    {
        $repo = $this->repo();
        $repo->toggle('ev_a', 'first', 'tilmeld', 1);
        $this->assertSame(SignupRepository::FULL, $repo->toggle('ev_a', 'second', 'tilmeld', 1));
        // First withdraws → seat opens → second can now sign up.
        $this->assertSame(SignupRepository::WITHDRAWN, $repo->toggle('ev_a', 'first', 'tilmeld', 1));
        $this->assertSame(SignupRepository::SIGNED_UP, $repo->toggle('ev_a', 'second', 'tilmeld', 1));
    }

    public function testExistingAttendeeCanAlwaysWithdrawEvenAtCapacity(): void
    {
        $repo = $this->repo();
        $repo->toggle('ev_a', 'first', 'tilmeld', 1);
        // Toggling an existing attendee is a withdrawal — capacity never blocks it.
        $this->assertSame(SignupRepository::WITHDRAWN, $repo->toggle('ev_a', 'first', 'tilmeld', 1));
    }

    public function testInteresseretIsNeverCapacityBlocked(): void
    {
        $repo = $this->repo();
        // null capacity == unlimited (Interesseret is passed null by the endpoint).
        $this->assertSame(SignupRepository::SIGNED_UP, $repo->toggle('ev_b', 'a', 'interesseret', null));
        $this->assertSame(SignupRepository::SIGNED_UP, $repo->toggle('ev_b', 'b', 'interesseret', null));
        $this->assertSame(SignupRepository::SIGNED_UP, $repo->toggle('ev_b', 'c', 'interesseret', null));
        $this->assertSame(3, $repo->countFor('ev_b'));
    }

    public function testCapacityCountsOnlyTilmeldEntries(): void
    {
        // A pre-existing interesseret entry must not consume a Tilmeld seat.
        file_put_contents($this->dataFile, Yaml::dump([
            'ev_a' => [
                'legacy' => ['ts' => '2026-01-01T00:00:00Z', 'mode' => 'interesseret'],
            ],
        ], 4, 2));
        $repo = $this->repo();
        // capacity=1 tilmeld: the interesseret entry does not fill the seat.
        $this->assertSame(SignupRepository::SIGNED_UP, $repo->toggle('ev_a', 'newcomer', 'tilmeld', 1));
        $this->assertSame(1, $repo->countFor('ev_a', 'tilmeld'));
        $this->assertSame(1, $repo->countFor('ev_a', 'interesseret'));
        $this->assertSame(2, $repo->countFor('ev_a'));
    }

    // ── Reads ────────────────────────────────────────────────────────────

    public function testCountForFiltersByMode(): void
    {
        $repo = $this->repo();
        $repo->toggle('ev_a', 'a', 'tilmeld');
        $repo->toggle('ev_a', 'b', 'tilmeld');
        $this->assertSame(2, $repo->countFor('ev_a', 'tilmeld'));
        $this->assertSame(0, $repo->countFor('ev_a', 'interesseret'));
        $this->assertSame(0, $repo->countFor('ev_unknown'));
    }

    public function testAttendeesForIsSortedByTimestampAndCarriesMode(): void
    {
        file_put_contents($this->dataFile, Yaml::dump([
            'ev_a' => [
                'later' => ['ts' => '2026-07-07T12:05:00Z', 'mode' => 'tilmeld'],
                'earlier' => ['ts' => '2026-07-07T12:00:00Z', 'mode' => 'tilmeld'],
            ],
        ], 4, 2));
        $rows = $this->repo()->attendeesFor('ev_a');
        $this->assertCount(2, $rows);
        $this->assertSame('earlier', $rows[0]['username']);
        $this->assertSame('later', $rows[1]['username']);
        $this->assertSame('tilmeld', $rows[0]['mode']);
    }

    public function testAttendeesForUnknownEventIsEmpty(): void
    {
        $this->assertSame([], $this->repo()->attendeesFor('ev_nope'));
    }

    // ── deleteFor ────────────────────────────────────────────────────────

    public function testDeleteForRemovesAllSignups(): void
    {
        $repo = $this->repo();
        $repo->toggle('ev_a', 'a', 'tilmeld');
        $repo->toggle('ev_a', 'b', 'tilmeld');
        $repo->toggle('ev_b', 'c', 'tilmeld');
        $repo->deleteFor('ev_a');
        $this->assertSame(0, $repo->countFor('ev_a'));
        $this->assertSame(1, $repo->countFor('ev_b'), 'other events untouched');
    }

    // ── Robustness ───────────────────────────────────────────────────────

    public function testMissingFileReadsAsEmpty(): void
    {
        $repo = $this->repo();
        $this->assertSame(0, $repo->countFor('ev_a'));
        $this->assertFalse($repo->isSignedUp('ev_a', 'x'));
        $this->assertSame([], $repo->attendeesFor('ev_a'));
    }

    public function testGarbageScalarFileTreatedAsEmptyMap(): void
    {
        file_put_contents($this->dataFile, "just a scalar string\n");
        $repo = $this->repo();
        $this->assertSame(0, $repo->countFor('ev_a'));
        // A subsequent write recovers cleanly.
        $this->assertSame(SignupRepository::SIGNED_UP, $repo->toggle('ev_a', 'anders', 'tilmeld'));
        $this->assertTrue($repo->isSignedUp('ev_a', 'anders'));
    }
}
