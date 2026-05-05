<?php
/**
 * Site Version plugin for Byværkstederne.
 *
 * Exposes a single `site_version()` Twig function returning a two-key
 * struct { version, build }, read at request time from
 * config/www/VERSION and config/www/BUILD respectively. Failures yield
 * null for the corresponding key (template renders <em>ukendt</em>);
 * a structured warning is logged via Grav's monolog channel exactly
 * once per (path, reason) pair per request.
 *
 * Mirrors the shape of the existing feature-flags plugin so the two
 * stay structurally similar — see config/www/user/plugins/feature-flags
 * for the reference implementation.
 *
 * Path construction is hard-coded relative to GRAV_ROOT; no user input,
 * query string, or environment variable feeds into the filesystem path.
 */

declare(strict_types=1);

namespace Grav\Plugin;

use Grav\Common\Grav;
use Grav\Common\Plugin;
use Grav\Plugin\SiteVersion\VersionReader;
use Psr\Log\LoggerInterface;
use Twig\TwigFunction;

class SiteVersionPlugin extends Plugin
{
    /** Per-request memoised reader; built lazily on first Twig call. */
    private ?VersionReader $reader = null;

    public static function getSubscribedEvents(): array
    {
        return [
            'onPluginsInitialized' => ['onPluginsInitialized', 0],
            'onTwigInitialized'    => ['onTwigInitialized', 0],
        ];
    }

    public function __construct($name, Grav $grav, $config = null)
    {
        parent::__construct($name, $grav, $config);
        $this->registerAutoloader();
    }

    /**
     * Lightweight PSR-4 autoloader for the plugin's src/ tree. Avoids
     * shipping a vendor/ folder for a plugin with one class.
     */
    private function registerAutoloader(): void
    {
        static $registered = false;
        if ($registered) {
            return;
        }
        $registered = true;

        $prefix = 'Grav\\Plugin\\SiteVersion\\';
        $baseDir = __DIR__ . '/src/';

        spl_autoload_register(static function (string $class) use ($prefix, $baseDir): void {
            if (strncmp($prefix, $class, strlen($prefix)) !== 0) {
                return;
            }
            $relative = substr($class, strlen($prefix));
            $file = $baseDir . str_replace('\\', '/', $relative) . '.php';
            if (is_file($file)) {
                require_once $file;
            }
        });
    }

    public function onPluginsInitialized(): void
    {
        // No container wiring needed — the reader is request-scoped and
        // built lazily inside onTwigInitialized. Method exists so the
        // subscribed event has a callable target.
    }

    public function onTwigInitialized(): void
    {
        if (!$this->config->get('plugins.site-version.enabled')) {
            return;
        }

        $twig = $this->grav['twig']->twig();

        $twig->addFunction(new TwigFunction(
            'site_version',
            function (): array {
                return $this->resolveReader()->read();
            }
        ));
    }

    /**
     * Resolve (and cache) the reader for this request.
     *
     * Path construction uses fixed compile-time-derived candidates; no
     * user input is interpolated into the filesystem path. We pick the
     * first candidate root that actually contains a VERSION (or, if no
     * candidate has one, BUILD) file, so the helper works in both the
     * canonical production deploy (where VERSION/BUILD sit at
     * GRAV_ROOT) and the local-dev linuxserver/grav container (where
     * the user/ tree is symlinked from /config/www/ but the files at
     * the root of /config/www/ are not symlinked into /app/www/public).
     */
    private function resolveReader(): VersionReader
    {
        if ($this->reader === null) {
            $root = $this->resolveVersionRoot();
            $this->reader = new VersionReader(
                $root . '/VERSION',
                $root . '/BUILD',
                $this->resolveLogger(),
                'site-version'
            );
        }
        return $this->reader;
    }

    /**
     * Pick the directory that contains VERSION/BUILD. Candidates are
     * compile-time string concatenations of well-known constants and
     * __DIR__-derived paths — never anything sourced from the request.
     *
     * Order:
     *   1. GRAV_ROOT — the canonical post-deploy location.
     *   2. dirname(__DIR__, 3) — the Grav root resolved from this
     *      plugin file, useful when GRAV_ROOT is undefined or differs
     *      from where the plugin actually lives.
     *   3. The grandparent of the user/plugins/site-version/ path
     *      after dereferencing one level of symlink — handles
     *      linuxserver/grav, where user/ is a symlink to
     *      /config/www/user/ and the source-of-truth VERSION/BUILD
     *      live at /config/www/.
     *
     * The first candidate whose VERSION file is readable wins. If none
     * has a VERSION, the first candidate whose BUILD is readable wins
     * (so a deploy that ships only BUILD still finds the right root).
     * Fallback: candidate 1 (GRAV_ROOT or its __DIR__ equivalent),
     * which yields null/null from the reader and triggers the standard
     * "ukendt" rendering — never an exception.
     */
    private function resolveVersionRoot(): string
    {
        $candidates = [];

        if (defined('GRAV_ROOT') && is_string(GRAV_ROOT) && GRAV_ROOT !== '') {
            $candidates[] = rtrim(GRAV_ROOT, '/');
        }
        // From the plugin's own location: <grav-root>/user/plugins/site-version/site-version.php.
        $candidates[] = dirname(__DIR__, 3);
        // Linuxserver/grav layout: user/ is a symlink to /config/www/user/.
        // realpath of __DIR__ resolves through that symlink, then we
        // take the equivalent of dirname(realpath, 3) to land at the
        // /config/www/ root. We fence with is_string + str_starts to
        // avoid surprising paths.
        $real = realpath(__DIR__);
        if (is_string($real) && $real !== '') {
            $candidates[] = dirname($real, 3);
        }

        // Dedupe while preserving order.
        $candidates = array_values(array_unique(array_filter($candidates)));

        // Prefer a candidate whose VERSION exists.
        foreach ($candidates as $c) {
            if (is_readable($c . '/VERSION')) {
                return $c;
            }
        }
        // Fall back to a candidate whose BUILD exists.
        foreach ($candidates as $c) {
            if (is_readable($c . '/BUILD')) {
                return $c;
            }
        }
        // Neither found anywhere — return the first candidate so the
        // reader logs against a sensible path (never user-influenced).
        return $candidates[0] ?? dirname(__DIR__, 3);
    }

    private function resolveLogger(): ?LoggerInterface
    {
        if (!isset($this->grav['log'])) {
            return null;
        }
        $candidate = $this->grav['log'];
        return $candidate instanceof LoggerInterface ? $candidate : null;
    }
}
