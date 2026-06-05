<?php
/**
 * VersionReader — pure-PHP reader for VERSION + BUILD files.
 *
 * Lives under the site-version plugin namespace but contains no Grav
 * dependencies, so it can be unit-exercised without booting the CMS
 * (used by the Sprint 3 shell-level probe). The Grav plugin wires in
 * Grav's logger; the apex copy (apex/site_version.php) reuses the same
 * regex contract and per-instance memoisation pattern via PHP's
 * error_log() instead of Grav's monolog channel.
 *
 * Contract — see specifications/semantic_versioning_specification.md
 * (Sprint 2):
 *
 *   - VERSION must match /^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$/ after
 *     trimming surrounding whitespace. Build metadata (`+...`) is
 *     deliberately rejected here — the build number lives in BUILD.
 *   - BUILD must match /^\d+$/ after trimming.
 *   - Missing files, empty files, files failing the regex all yield
 *     null for the corresponding key. Callers render `ukendt` in the
 *     template; the helper itself never produces user-facing copy.
 *   - Failures log exactly once per (path, reason) pair within the
 *     lifetime of a reader instance — sufficient for the "exactly once
 *     per request" requirement because the plugin builds one reader
 *     per onTwigInitialized.
 */

declare(strict_types=1);

namespace Grav\Plugin\SiteVersion;

use Psr\Log\LoggerInterface;

final class VersionReader
{
    /** Regex for the VERSION file — SemVer 2.0.0 sans build metadata. */
    public const VERSION_REGEX = '/^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$/';

    /** Regex for the BUILD file — non-negative integer. */
    public const BUILD_REGEX = '/^\d+$/';

    private string $versionPath;
    private string $buildPath;
    private ?LoggerInterface $logger;
    private string $logChannel;

    /**
     * Per-instance dedup of warning log lines. Keyed by "<path>:<reason>"
     * so two distinct failure modes for the same file each surface once.
     *
     * @var array<string, true>
     */
    private array $logged = [];

    /**
     * Memoised result of read(), so multiple Twig calls in one request
     * reuse the same struct (and don't re-log).
     *
     * @var array{version: ?string, build: ?string}|null
     */
    private ?array $cached = null;

    public function __construct(
        string $versionPath,
        string $buildPath,
        ?LoggerInterface $logger = null,
        string $logChannel = 'site-version'
    ) {
        $this->versionPath = $versionPath;
        $this->buildPath = $buildPath;
        $this->logger = $logger;
        $this->logChannel = $logChannel;
    }

    /**
     * Read both files and return a normalised struct. Either or both
     * keys may be null if the corresponding source is missing/invalid.
     *
     * @return array{version: ?string, build: ?string}
     */
    public function read(): array
    {
        if ($this->cached !== null) {
            return $this->cached;
        }
        $this->cached = [
            'version' => $this->readField($this->versionPath, self::VERSION_REGEX, 'VERSION'),
            'build'   => $this->readField($this->buildPath,   self::BUILD_REGEX,   'BUILD'),
        ];
        return $this->cached;
    }

    /**
     * Read a single field from $path, validating against $regex. The
     * $label is used only for log messages (e.g. "VERSION", "BUILD").
     */
    private function readField(string $path, string $regex, string $label): ?string
    {
        if (!is_readable($path)) {
            $this->logOnce($path, $label, 'missing');
            return null;
        }

        // file_get_contents → false on read error (treat as missing).
        $raw = @file_get_contents($path);
        if ($raw === false) {
            $this->logOnce($path, $label, 'unreadable');
            return null;
        }

        $trimmed = trim($raw);
        if ($trimmed === '') {
            $this->logOnce($path, $label, 'empty');
            return null;
        }

        if (!preg_match($regex, $trimmed)) {
            // Don't log the value itself — it could be operator-pasted
            // junk we don't want to surface. The reason ("regex
            // mismatch") plus the file path is enough to debug.
            $this->logOnce($path, $label, 'regex_mismatch');
            return null;
        }

        return $trimmed;
    }

    /**
     * Log a structured warning once per (path, reason) pair.
     *
     * The path is reported relative to the project/grav root rather than
     * absolute, so logs don't leak the operator's home directory or
     * container internals.
     */
    private function logOnce(string $path, string $label, string $reason): void
    {
        $key = $path . ':' . $reason;
        if (isset($this->logged[$key])) {
            return;
        }
        $this->logged[$key] = true;

        if ($this->logger === null) {
            return;
        }

        $this->logger->warning(
            sprintf(
                '[%s] %s file %s: %s',
                $this->logChannel,
                $label,
                $this->shortenPath($path),
                $reason
            ),
            [
                'channel' => $this->logChannel,
                'field'   => $label,
                'reason'  => $reason,
                'file'    => $this->shortenPath($path),
            ]
        );
    }

    /**
     * Reduce an absolute filesystem path to its trailing
     * "config/www/..." or "apex/..." segment when possible. Avoids
     * leaking operator $HOME or container layout into log messages.
     */
    private function shortenPath(string $path): string
    {
        foreach (['config/www/', 'apex/'] as $marker) {
            $pos = strpos($path, $marker);
            if ($pos !== false) {
                return substr($path, $pos);
            }
        }
        // Last-resort: emit only the basename so we still say something
        // useful without surfacing the surrounding directories.
        return basename($path);
    }
}
