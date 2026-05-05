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
     * Path construction uses GRAV_ROOT — a Grav-defined constant — and
     * fixed string literals. No user input is interpolated.
     */
    private function resolveReader(): VersionReader
    {
        if ($this->reader === null) {
            $root = $this->resolveGravRoot();
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
     * The Grav root contains config/www/VERSION and config/www/BUILD.
     * `GRAV_ROOT` is the canonical constant; fall back to `__DIR__`
     * walked back to the plugin's grandparent if the constant is
     * unavailable (defensive — in practice it's always defined when a
     * plugin runs).
     */
    private function resolveGravRoot(): string
    {
        if (defined('GRAV_ROOT') && is_string(GRAV_ROOT) && GRAV_ROOT !== '') {
            return rtrim(GRAV_ROOT, '/');
        }
        // Fallback: this file is at <root>/user/plugins/site-version/site-version.php.
        return dirname(__DIR__, 3);
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
