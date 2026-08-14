<?php
/**
 * ImageStore — validation + storage + serving for event-details images
 * (event_rsvp_specification.md §5.2/§5.3). The validation (magic-byte
 * sniffing, extension allowlist, size cap) is copied verbatim from the
 * bug-report plugin's proven upload path — deliberately copied, not
 * cross-imported, so the two plugins stay independent.
 *
 * Files land under user/data/event-images/<event-key>/<32-hex>.<ext> with a
 * per-folder .htaccess (exec-block + deny-all) and empty index.html, exactly
 * as bug-report does. A per-event quota bounds disk use. Serving is public
 * (event details are public) with a magic-byte-derived Content-Type and
 * X-Content-Type-Options: nosniff.
 *
 * Path-injectable (takes the resolved base directory) so the validation and
 * quota logic are unit-testable against a temp dir; the plugin resolves the
 * locator path and constructs it.
 */

declare(strict_types=1);

namespace Grav\Plugin\EventManager;

final class ImageStore
{
    /** Accepted image MIME types (validated via magic bytes, not Content-Type). */
    public const ALLOWED_MIME = ['image/jpeg', 'image/png', 'image/gif', 'image/webp'];

    /** Accepted filename extensions (belt to the magic-byte check). */
    public const ALLOWED_EXT = ['jpg', 'jpeg', 'png', 'gif', 'webp'];

    public const MAX_BYTES = 5 * 1024 * 1024; // 5 MB
    public const MAX_PER_EVENT = 10;

    /** Stored extension derived from the sniffed MIME (never the user's name). */
    private const EXT_FOR_MIME = [
        'image/jpeg' => 'jpg',
        'image/png' => 'png',
        'image/gif' => 'gif',
        'image/webp' => 'webp',
    ];

    /** Keys are `ev_<hex>` or legacy `event0NN` — the same shape the plugin uses. */
    private const KEY_PATTERN = '/^[A-Za-z0-9_-]{1,64}$/';

    /**
     * The serving URL carries the extensionless 32-hex hash — an extension in
     * the path would be intercepted by the web server's static-asset handler
     * and never reach Grav (bug-report's endpoint is extensionless for the
     * same reason). The stored file keeps its real extension on disk.
     */
    private const HASH_PATTERN = '/^[0-9a-f]{32}$/';

    private string $baseDir;

    /** @var callable(string,string):bool moves the uploaded temp file into place */
    private $mover;

    /**
     * @param string        $baseDir resolved user/data/event-images path
     * @param callable|null  $mover  override the file move (tests pass `rename`,
     *                               since move_uploaded_file only accepts real
     *                               HTTP uploads); defaults to move_uploaded_file
     */
    public function __construct(string $baseDir, ?callable $mover = null)
    {
        $this->baseDir = rtrim($baseDir, '/');
        $this->mover = $mover ?? 'move_uploaded_file';
    }

    /**
     * Validate and persist an uploaded image for an event.
     *
     * @param array<string,mixed> $file a $_FILES entry
     * @return array{file:string}|array{error:string}
     */
    public function store(string $eventKey, array $file): array
    {
        if (!preg_match(self::KEY_PATTERN, $eventKey)) {
            return ['error' => 'Ugyldig begivenhedsnøgle.'];
        }
        $error = $this->validate($file);
        if ($error !== null) {
            return ['error' => $error];
        }

        $dir = $this->eventDir($eventKey);
        if ($this->countFor($eventKey) >= self::MAX_PER_EVENT) {
            return ['error' => 'Maks. ' . self::MAX_PER_EVENT . ' billeder pr. begivenhed.'];
        }
        if (!$this->ensureDir($dir)) {
            return ['error' => 'Serverfejl: kan ikke oprette billedmappe.'];
        }

        $mime = $this->detectMimeType((string)$file['tmp_name']);
        $ext = self::EXT_FOR_MIME[$mime] ?? 'bin';
        $name = bin2hex(random_bytes(16)) . '.' . $ext;
        $dest = $dir . '/' . $name;

        if (!($this->mover)((string)$file['tmp_name'], $dest)) {
            return ['error' => 'Serverfejl: kan ikke gemme billedet.'];
        }
        return ['file' => $name];
    }

    /**
     * Validate a $_FILES entry — returns a Danish error message or null when
     * the file is an acceptable image.
     *
     * @param array<string,mixed> $file
     */
    public function validate(array $file): ?string
    {
        $code = $file['error'] ?? UPLOAD_ERR_NO_FILE;
        if ($code !== UPLOAD_ERR_OK) {
            return match ($code) {
                UPLOAD_ERR_INI_SIZE, UPLOAD_ERR_FORM_SIZE => 'Billedet er for stort (maks. 5 MB).',
                UPLOAD_ERR_PARTIAL => 'Billedet blev kun delvist uploadet.',
                UPLOAD_ERR_NO_FILE => 'Ingen fil modtaget.',
                default => 'Upload-fejl. Prøv igen.',
            };
        }
        if ((int)($file['size'] ?? 0) > self::MAX_BYTES) {
            return 'Billedet er for stort (maks. 5 MB).';
        }

        $tmp = (string)($file['tmp_name'] ?? '');
        $mime = $tmp !== '' ? $this->detectMimeType($tmp) : null;
        if ($mime === null || !in_array($mime, self::ALLOWED_MIME, true)) {
            return 'Ugyldig filtype. Kun JPEG, PNG, GIF og WebP er tilladt.';
        }
        $ext = strtolower(pathinfo((string)($file['name'] ?? ''), PATHINFO_EXTENSION));
        if (!in_array($ext, self::ALLOWED_EXT, true)) {
            return 'Ugyldig filtype. Kun JPEG, PNG, GIF og WebP er tilladt.';
        }
        return null;
    }

    /** Detect the actual MIME type from magic bytes (bug-report's logic). */
    public function detectMimeType(string $filePath): ?string
    {
        $handle = @fopen($filePath, 'rb');
        if (!$handle) {
            return null;
        }
        $bytes = fread($handle, 12);
        fclose($handle);
        if ($bytes === false || strlen($bytes) < 3) {
            return null;
        }
        if (substr($bytes, 0, 3) === "\xFF\xD8\xFF") {
            return 'image/jpeg';
        }
        if (substr($bytes, 0, 8) === "\x89PNG\r\n\x1a\n") {
            return 'image/png';
        }
        if (substr($bytes, 0, 6) === 'GIF87a' || substr($bytes, 0, 6) === 'GIF89a') {
            return 'image/gif';
        }
        if (substr($bytes, 0, 4) === 'RIFF' && substr($bytes, 8, 4) === 'WEBP') {
            return 'image/webp';
        }
        return null;
    }

    /** Number of stored image files for an event (excludes .htaccess/index.html). */
    public function countFor(string $eventKey): int
    {
        $dir = $this->eventDir($eventKey);
        if (!is_dir($dir)) {
            return 0;
        }
        $n = 0;
        foreach (glob($dir . '/*') ?: [] as $f) {
            if (is_file($f) && preg_match('/\.(jpg|jpeg|png|gif|webp)$/i', $f)) {
                $n++;
            }
        }
        return $n;
    }

    /**
     * Resolve an extensionless 32-hex hash to the stored file's absolute path
     * for serving, or null when the key/hash is malformed or no matching file
     * exists. The strict hash regex plus basename() make path traversal
     * impossible; the extension is recovered by probing the allowlist.
     */
    public function resolvePath(string $eventKey, string $hash): ?string
    {
        if (!preg_match(self::KEY_PATTERN, $eventKey)) {
            return null;
        }
        $hash = basename($hash);
        if (!preg_match(self::HASH_PATTERN, $hash)) {
            return null;
        }
        $dir = $this->eventDir($eventKey);
        foreach (self::ALLOWED_EXT as $ext) {
            $path = $dir . '/' . $hash . '.' . $ext;
            if (is_file($path)) {
                return $path;
            }
        }
        return null;
    }

    /** The extensionless hash of a stored filename, for building a serving URL. */
    public static function hashOf(string $storedFile): string
    {
        return pathinfo($storedFile, PATHINFO_FILENAME);
    }

    /** Remove an event's whole image folder (used by hard delete). */
    public function deleteEventImages(string $eventKey): void
    {
        if (!preg_match(self::KEY_PATTERN, $eventKey)) {
            return;
        }
        $dir = $this->eventDir($eventKey);
        if (!is_dir($dir)) {
            return;
        }
        foreach (glob($dir . '/*') ?: [] as $f) {
            if (is_file($f)) {
                @unlink($f);
            }
        }
        @unlink($dir . '/.htaccess');
        @unlink($dir . '/index.html');
        @rmdir($dir);
    }

    // -------------------------------------------------------------------------
    // Internals
    // -------------------------------------------------------------------------

    private function eventDir(string $eventKey): string
    {
        return $this->baseDir . '/' . $eventKey;
    }

    /**
     * Create the event's image folder with the same execution-block +
     * deny-all .htaccess and empty index.html bug-report writes.
     */
    private function ensureDir(string $dir): bool
    {
        if (is_dir($dir)) {
            return true;
        }
        if (!mkdir($dir, 0750, true) && !is_dir($dir)) {
            return false;
        }
        file_put_contents(
            $dir . '/.htaccess',
            "Options -Indexes\n"
            . "php_flag engine off\n"
            . "<FilesMatch \".*\">\n"
            . "  Order Deny,Allow\n"
            . "  Deny from all\n"
            . "</FilesMatch>\n"
        );
        file_put_contents($dir . '/index.html', '');
        return true;
    }
}
