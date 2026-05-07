<?php
/**
 * Apex VERSION/BUILD reader — extracted from apex/index.php so the
 * Sprint-3 shell-level probe under tests/version/ can `require` just
 * this file and exercise the reader without rendering the full landing
 * page.
 *
 * Behaviour (preserved from the previous inline implementation in
 * apex/index.php — see specifications/semantic_versioning_specification.md
 * Sprint 2 "Robustness" section for the contract):
 *
 *   - readApexSiteVersion() returns ['version' => ?string, 'build' => ?string]
 *     from apex/VERSION and apex/BUILD respectively, validated against
 *     the same regex pair the Grav site-version plugin uses
 *     (VersionReader::VERSION_REGEX / BUILD_REGEX).
 *   - Missing / empty / regex-mismatched / unreadable files yield null
 *     for the corresponding key.
 *   - A single PHP-level error_log() warning per (path, reason) pair
 *     fires per request — sufficient for the "exactly once per request"
 *     requirement because the helper memoises in a static once it has
 *     produced a result.
 *   - Path construction is purely __DIR__ + literal segment; no user
 *     input flows into the filesystem path.
 *
 * declare(strict_types=1) is intentionally omitted here so this file is
 * safe to `require_once` from contexts that don't already use strict
 * types — the directive is file-scoped in PHP. apex/index.php sets it
 * for itself.
 *
 * Memoisation note: the static $cached inside readApexSiteVersion() is
 * function-scoped, so a fresh PHP process always re-reads. The probe
 * spawns one PHP child per fixture case, so the cache is effectively
 * disabled for testing — and unconditionally beneficial in the
 * production single-request lifetime.
 */

/** SemVer 2.0.0 uden build-metadata — build-tallet ligger separat i BUILD. */
if (!defined('APEX_VERSION_REGEX')) {
    define('APEX_VERSION_REGEX', '/^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$/');
}
/** Ikke-negativt heltal, op til seks cifre er rigeligt. */
if (!defined('APEX_BUILD_REGEX')) {
    define('APEX_BUILD_REGEX', '/^\d+$/');
}

if (!function_exists('readValidatedFile')) {
    /**
     * Læs én tekstfil og valider mod $regex. Returnerer null på manglende,
     * tom eller ikke-matchende fil. Logger nøjagtigt én advarsel pr. (sti,
     * årsag) for hele requestet via error_log().
     */
    function readValidatedFile(string $path, string $regex, string $label): ?string {
        static $logged = [];
        $logKey = $path . ':';

        if (!is_readable($path)) {
            $key = $logKey . 'missing';
            if (!isset($logged[$key])) {
                $logged[$key] = true;
                error_log("[apex-version] $label file " . apexShortenPath($path) . ': missing');
            }
            return null;
        }
        $raw = @file_get_contents($path);
        if ($raw === false) {
            $key = $logKey . 'unreadable';
            if (!isset($logged[$key])) {
                $logged[$key] = true;
                error_log("[apex-version] $label file " . apexShortenPath($path) . ': unreadable');
            }
            return null;
        }
        $trimmed = trim($raw);
        if ($trimmed === '') {
            $key = $logKey . 'empty';
            if (!isset($logged[$key])) {
                $logged[$key] = true;
                error_log("[apex-version] $label file " . apexShortenPath($path) . ': empty');
            }
            return null;
        }
        if (!preg_match($regex, $trimmed)) {
            $key = $logKey . 'regex_mismatch';
            if (!isset($logged[$key])) {
                $logged[$key] = true;
                error_log("[apex-version] $label file " . apexShortenPath($path) . ': regex_mismatch');
            }
            return null;
        }
        return $trimmed;
    }
}

if (!function_exists('apexShortenPath')) {
    /**
     * Trim absolutte stier ned til "apex/..."-segmentet, så fejllogning ikke
     * lækker operatorens $HOME eller container-layout.
     */
    function apexShortenPath(string $path): string {
        $pos = strpos($path, 'apex/');
        if ($pos !== false) {
            return substr($path, $pos);
        }
        return basename($path);
    }
}

if (!function_exists('readApexSiteVersion')) {
    /**
     * Læs apex' egne VERSION + BUILD ved request-tid (ikke fra version.json).
     * Returnerer { version: ?string, build: ?string }. Hver halvdel kan være
     * null individuelt.
     *
     * Memoiseres med static så templaten kan kalde funktionen flere gange
     * uden at re-logge. Stier konstrueres fra __DIR__ + literal — ingen user
     * input flyder ind i filsystemstien.
     *
     * @return array{version: ?string, build: ?string}
     */
    function readApexSiteVersion(): array {
        static $cached = null;
        if ($cached !== null) {
            return $cached;
        }
        $cached = [
            'version' => readValidatedFile(__DIR__ . '/VERSION', APEX_VERSION_REGEX, 'VERSION'),
            'build'   => readValidatedFile(__DIR__ . '/BUILD',   APEX_BUILD_REGEX,   'BUILD'),
        ];
        return $cached;
    }
}
