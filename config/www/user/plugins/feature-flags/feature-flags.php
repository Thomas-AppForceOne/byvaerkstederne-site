<?php
/**
 * Feature Flags Plugin for Byværkstederne
 *
 * Sprint 1 scope: typed FeatureFlag enum + FlagStore parser/resolver +
 * structured warning logs. No Twig helpers, no page gating, no collection
 * filter yet — those arrive in later sprints.
 *
 * Loads merged Grav config from `features.enabled` and exposes a resolver
 * registered on the Grav container as `feature_flags`.
 */

namespace Grav\Plugin;

use Grav\Common\Grav;
use Grav\Common\Plugin;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\FlagStoreInterface;
use Psr\Log\LoggerInterface;

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

    private function buildFlagStore(): FlagStoreInterface
    {
        $rawEnabled = $this->grav['config']->get('features.enabled', []);

        /** @var LoggerInterface|null $logger */
        $logger = null;
        if (isset($this->grav['log'])) {
            $candidate = $this->grav['log'];
            if ($candidate instanceof LoggerInterface) {
                $logger = $candidate;
            }
        }

        $environment = $this->resolveEnvironment();

        return new FlagStore($rawEnabled, $logger, $environment);
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
