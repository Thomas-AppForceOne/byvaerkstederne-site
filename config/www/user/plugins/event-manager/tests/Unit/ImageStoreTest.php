<?php
/**
 * Unit tests for ImageStore — the event-image validation/storage/serving
 * logic (event_rsvp_specification.md §5.2/§5.3). Covers magic-byte detection,
 * the rejection paths (oversize, wrong type, fake extension), the per-event
 * quota, path-traversal safety, and the full store path (via a test double
 * that substitutes a plain rename for the real HTTP upload move).
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager\Tests\Unit;

use Grav\Plugin\EventManager\ImageStore;
use PHPUnit\Framework\TestCase;

final class ImageStoreTest extends TestCase
{
    private string $baseDir;

    protected function setUp(): void
    {
        $this->baseDir = sys_get_temp_dir() . '/em-images-' . bin2hex(random_bytes(6));
        mkdir($this->baseDir, 0750, true);
    }

    protected function tearDown(): void
    {
        $this->rrmdir($this->baseDir);
    }

    private function rrmdir(string $dir): void
    {
        if (!is_dir($dir)) {
            return;
        }
        foreach (scandir($dir) ?: [] as $e) {
            if ($e === '.' || $e === '..') {
                continue;
            }
            $p = $dir . '/' . $e;
            is_dir($p) ? $this->rrmdir($p) : @unlink($p);
        }
        @rmdir($dir);
    }

    private const PNG = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0d";
    private const JPEG = "\xFF\xD8\xFF\xE0\x00\x10JFIF";
    private const GIF = "GIF89a\x01\x00\x01\x00";
    private const WEBP = "RIFF\x1a\x00\x00\x00WEBPVP8 ";

    private function tmpFile(string $bytes): string
    {
        $p = tempnam(sys_get_temp_dir(), 'emimg');
        file_put_contents($p, $bytes);
        return $p;
    }

    /** @return array<string,mixed> */
    private function fileEntry(string $bytes, string $name, ?int $size = null): array
    {
        $tmp = $this->tmpFile($bytes);
        return [
            'tmp_name' => $tmp,
            'name' => $name,
            'size' => $size ?? strlen($bytes),
            'error' => UPLOAD_ERR_OK,
        ];
    }

    private function store(): ImageStore
    {
        // rename() stands in for move_uploaded_file(), which only accepts real
        // HTTP uploads.
        return new ImageStore($this->baseDir, 'rename');
    }

    // ── Magic-byte detection ─────────────────────────────────────────────

    public function testDetectsEachImageType(): void
    {
        $s = $this->store();
        $this->assertSame('image/png', $s->detectMimeType($this->tmpFile(self::PNG)));
        $this->assertSame('image/jpeg', $s->detectMimeType($this->tmpFile(self::JPEG)));
        $this->assertSame('image/gif', $s->detectMimeType($this->tmpFile(self::GIF)));
        $this->assertSame('image/webp', $s->detectMimeType($this->tmpFile(self::WEBP)));
    }

    public function testDetectsNonImageAsNull(): void
    {
        $this->assertNull($this->store()->detectMimeType($this->tmpFile('just plain text, not an image')));
    }

    // ── Validation (rejection paths) ─────────────────────────────────────

    public function testRejectsOversize(): void
    {
        $file = $this->fileEntry(self::PNG, 'big.png', ImageStore::MAX_BYTES + 1);
        $this->assertStringContainsString('5 MB', (string)$this->store()->validate($file));
    }

    public function testRejectsFakeExtensionByMagicBytes(): void
    {
        // Text content with an image extension → magic-byte check fails.
        $file = $this->fileEntry('#!/bin/sh\nrm -rf', 'evil.png');
        $this->assertNotNull($this->store()->validate($file));
    }

    public function testRejectsImageBytesWithDisallowedExtension(): void
    {
        // Real PNG bytes but a .txt name → extension allowlist fails.
        $file = $this->fileEntry(self::PNG, 'note.txt');
        $this->assertNotNull($this->store()->validate($file));
    }

    public function testRejectsUploadErrorCode(): void
    {
        $file = ['tmp_name' => '', 'name' => 'x.png', 'size' => 0, 'error' => UPLOAD_ERR_INI_SIZE];
        $this->assertStringContainsString('5 MB', (string)$this->store()->validate($file));
    }

    public function testAcceptsValidPng(): void
    {
        $this->assertNull($this->store()->validate($this->fileEntry(self::PNG, 'ok.png')));
    }

    // ── Store + quota ────────────────────────────────────────────────────

    public function testStoreWritesFileAndHardeningFiles(): void
    {
        $res = $this->store()->store('ev_abc123', $this->fileEntry(self::PNG, 'ok.png'));
        $this->assertArrayHasKey('file', $res);
        $this->assertMatchesRegularExpression('/^[0-9a-f]{32}\.png$/', $res['file']);
        $dir = $this->baseDir . '/ev_abc123';
        $this->assertFileExists($dir . '/' . $res['file']);
        $this->assertFileExists($dir . '/.htaccess');
        $this->assertFileExists($dir . '/index.html');
        $this->assertStringContainsString('Deny from all', file_get_contents($dir . '/.htaccess'));
        $this->assertSame(1, $this->store()->countFor('ev_abc123'));
    }

    public function testStoredExtensionDerivesFromMagicBytesNotName(): void
    {
        // JPEG bytes uploaded as a .png name → stored as .jpg (sniffed type wins).
        $res = $this->store()->store('ev_abc123', $this->fileEntry(self::JPEG, 'mislabelled.png'));
        $this->assertArrayHasKey('file', $res);
        $this->assertStringEndsWith('.jpg', $res['file']);
    }

    public function testQuotaBlocksTheEleventhImage(): void
    {
        $s = $this->store();
        for ($i = 0; $i < ImageStore::MAX_PER_EVENT; $i++) {
            $this->assertArrayHasKey('file', $s->store('ev_full', $this->fileEntry(self::PNG, 'x.png')));
        }
        $res = $s->store('ev_full', $this->fileEntry(self::PNG, 'x.png'));
        $this->assertArrayHasKey('error', $res);
        $this->assertStringContainsString('Maks. 10', $res['error']);
        $this->assertSame(ImageStore::MAX_PER_EVENT, $s->countFor('ev_full'));
    }

    public function testStoreRejectsMalformedKey(): void
    {
        $res = $this->store()->store('../../etc', $this->fileEntry(self::PNG, 'x.png'));
        $this->assertArrayHasKey('error', $res);
    }

    // ── Serving path resolution (traversal safety) ───────────────────────

    public function testResolvePathAcceptsValidStoredFile(): void
    {
        $res = $this->store()->store('ev_abc123', $this->fileEntry(self::PNG, 'ok.png'));
        // The serving URL carries the extensionless hash; resolvePath recovers
        // the on-disk file (with extension).
        $path = $this->store()->resolvePath('ev_abc123', ImageStore::hashOf($res['file']));
        $this->assertNotNull($path);
        $this->assertFileExists($path);
        $this->assertStringEndsWith('.png', $path);
    }

    public function testResolvePathRejectsTraversalAndBadNames(): void
    {
        $s = $this->store();
        $this->assertNull($s->resolvePath('ev_abc123', '../../../etc/passwd'));
        $this->assertNull($s->resolvePath('ev_abc123', 'nothex'));        // not hex
        $this->assertNull($s->resolvePath('ev_abc123', 'abc.png'));       // has an extension
        $this->assertNull($s->resolvePath('../evil', str_repeat('a', 32)));
        // Well-formed hash but no such file → null (not an error, just absent).
        $this->assertNull($s->resolvePath('ev_abc123', str_repeat('a', 32)));
    }

    // ── Delete ───────────────────────────────────────────────────────────

    public function testDeleteEventImagesRemovesTheFolder(): void
    {
        $s = $this->store();
        $s->store('ev_gone', $this->fileEntry(self::PNG, 'x.png'));
        $this->assertDirectoryExists($this->baseDir . '/ev_gone');
        $s->deleteEventImages('ev_gone');
        $this->assertDirectoryDoesNotExist($this->baseDir . '/ev_gone');
    }
}
