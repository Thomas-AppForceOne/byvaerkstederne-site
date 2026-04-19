<?php
/**
 * Feature Flags Plugin for Byværkstederne
 *
 * Scope after Sprint 2: typed FeatureFlag enum + FlagStore parser/resolver +
 * structured warning logs + Twig helpers (feature_enabled, enabled_features).
 * Page gating and collection filter arrive in Sprint 3.
 *
 * Loads merged Grav config from `features.enabled` and exposes a resolver
 * registered on the Grav container as `feature_flags`. Exposes two Twig
 * functions on the Grav Twig environment for template-level gating.
 */

namespace Grav\Plugin;

use Grav\Common\Grav;
use Grav\Common\Plugin;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\FlagStoreInterface;
use Grav\Plugin\FeatureFlags\TwigHelpers;
use Psr\Log\LoggerInterface;
use Twig\TwigFunction;

class FeatureFlagsPlugin extends Plugin
{
    /**
     * Subscribe early so later plugins and themes can fetch the resolver.
     *
     * Priority 1100 ensures the service is available before roadmap (1000)
     * and other plugins that may begin to gate behavior behind flags.
     */
    public static function getSubscribedEvents(): array
    {
        return [
            'onPluginsInitialized' => ['onPluginsInitialized', 1100],
            // Twig registration happens after onPluginsInitialized has put
            // `feature_flags` on the container (priority 1100 above), so
            // the helper always sees a resolved FlagStore. Default Twig
            // priority (0) is fine — onTwigInitialized always fires after
            // onPluginsInitialized in Grav's boot order.
            'onTwigInitialized'    => ['onTwigInitialized', 0],
        ];
    }

    /**
     * Register a lightweight PSR-4 autoloader for this plugin's src/ tree.
     *
     * Note: we do NOT expose a public `autoload()` method. Grav's
     * Plugins::init() calls `$plugin->autoload()` only if `method_exists()`
     * returns true. Because shipping a full vendor/ tree is heavy for a
     * plugin with four classes, we register our own spl_autoload_register
     * instead. This keeps the plugin self-contained with no composer
     * install step required at deploy time.
     */
    public function __construct($name, Grav $grav, $config = null)
    {
        parent::__construct($name, $grav, $config);
        $this->registerAutoloader();
    }

    private function registerAutoloader(): void
    {
        static $registered = false;
        if ($registered) {
            return;
        }
        $registered = true;

        $prefix = 'Grav\\Plugin\\FeatureFlags\\';
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
        if (!$this->config->get('plugins.feature-flags.enabled')) {
            return;
        }

        // Register the FlagStore as a singleton on the Grav container.
        // Using a Pimple closure so the store is built lazily the first
        // time something asks for it — keeps plugin boot cheap and means
        // a broken config only surfaces when a flag is actually queried.
        $this->grav['feature_flags'] = function () {
            return $this->buildFlagStore();
        };
    }

    /**
     * Register feature_enabled() and enabled_features() on the Twig
     * environment. Both helpers delegate to a TwigHelpers shim that
     * handles string->enum conversion and the fail-closed contract.
     *
     * is_safe: neither helper emits HTML; they return bool / array<string>.
     * The template is expected to escape the string values itself if it
     * interpolates them. We do NOT mark anything as safe here — keeping
     * Twig's autoescape defense on by default.
     */
    public function onTwigInitialized(): void
    {
        if (!$this->config->get('plugins.feature-flags.enabled')) {
            return;
        }

        $twig = $this->grav['twig']->twig();

        $helpers = $this->buildTwigHelpers();

        $twig->addFunction(new TwigFunction(
            'feature_enabled',
            // Closure keeps the helper instance encapsulated; Twig will
            // pass the raw template argument (mixed) straight through.
            static function (mixed $name) use ($helpers): bool {
                return $helpers->featureEnabled($name);
            }
        ));

        $twig->addFunction(new TwigFunction(
            'enabled_features',
            static function () use ($helpers): array {
                return $helpers->enabledFeatures();
            }
        ));
    }

    private function buildTwigHelpers(): TwigHelpers
    {
        // Fetch (or lazily build) the FlagStore via the container. If for
        // any reason the store is missing, fall back to a dummy store that
        // resolves everything to false — preserving fail-closed on error
        // pages where plugin init may have been partial.
        $store = null;
        if (isset($this->grav['feature_flags'])) {
            $candidate = $this->grav['feature_flags'];
            if ($candidate instanceof FlagStoreInterface) {
                $store = $candidate;
            }
        }
        if ($store === null) {
            // Empty array -> every flag resolves false.
            $store = new FlagStore([], $this->resolveLogger(), $this->resolveEnvironment());
        }

        return new TwigHelpers($store, $this->resolveLogger(), $this->resolveEnvironment());
    }

    private function resolveLogger(): ?LoggerInterface
    {
        if (!isset($this->grav['log'])) {
            return null;
        }
        $candidate = $this->grav['log'];
        return $candidate instanceof LoggerInterface ? $candidate : null;
    }

    private function buildFlagStore(): FlagStoreInterface
    {
        $rawEnabled = $this->grav['config']->get('features.enabled', []);
        return new FlagStore($rawEnabled, $this->resolveLogger(), $this->resolveEnvironment());
    }

    private function resolveEnvironment(): ?string
    {
        // Grav stores the active environment on the Uri; fall back to the
        // server's HTTP_HOST if not yet resolved.
        try {
            if (isset($this->grav['uri'])) {
                $host = $this->grav['uri']->host();
                if (is_string($host) && $host !== '') {
                    return $host;
                }
            }
        } catch (\Throwable $e) {
            // Intentionally swallow — environment is diagnostic only.
        }
        $host = $_SERVER['HTTP_HOST'] ?? null;
        return is_string($host) && $host !== '' ? $host : null;
    }
}
