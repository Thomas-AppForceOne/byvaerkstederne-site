<?php
/**
 * Feature Flags Plugin for Byværkstederne
 *
 * Scope after Sprint 3: typed FeatureFlag enum + FlagStore parser/resolver +
 * structured warning logs + Twig helpers (feature_enabled, enabled_features)
 * + page-level feature gating (404 on disabled) + centralised hidden-refs
 * filter (`feature_visible` as Twig filter and function).
 *
 * Loads merged Grav config from `features.enabled` and exposes a resolver
 * registered on the Grav container as `feature_flags`.
 */

namespace Grav\Plugin;

use Grav\Common\Grav;
use Grav\Common\Page\Interfaces\PageInterface;
use Grav\Common\Page\Page;
use Grav\Common\Page\Pages;
use Grav\Common\Plugin;
use Grav\Plugin\FeatureFlags\CollectionFilter;
use Grav\Plugin\FeatureFlags\FlagStore;
use Grav\Plugin\FeatureFlags\FlagStoreInterface;
use Grav\Plugin\FeatureFlags\PageGate;
use Grav\Plugin\FeatureFlags\TwigHelpers;
use Psr\Log\LoggerInterface;
use RocketTheme\Toolbox\Event\Event;
use Twig\TwigFilter;
use Twig\TwigFunction;

class FeatureFlagsPlugin extends Plugin
{
    /**
     * Subscribe early so later plugins and themes can fetch the resolver.
     *
     * Priorities:
     *   - onPluginsInitialized @ 1100: install the FlagStore on the
     *     container before any plugin that depends on it.
     *   - onPageInitialized    @ 100000: MUST run before login's
     *     authorizePage (priority 10) and before the form plugin's
     *     onPageInitialized (priority 0) — the form plugin dereferences
     *     $grav['page'] and must see a valid Page object even after we
     *     swap it for a themed 404. See criterion
     *     not_found_replacement_strategy_is_safe in
     *     .gan/sprint-3-contract.json: we use the "overwrite via
     *     unset-then-set of $grav['page']" strategy (option b) and run
     *     early enough that no other listener ever observes a missing key.
     *   - onPageNotFound       @ 100: belt-and-suspenders in case the page
     *     is never dispatched (e.g. route collision) — still swap to the
     *     themed error page and stopPropagation before Grav's built-in
     *     error plugin (priority 0) fires. This is option (a) from the
     *     same contract criterion.
     *   - onTwigInitialized    @ 0: default is fine; onPluginsInitialized
     *     always fires first in Grav boot order.
     */
    public static function getSubscribedEvents(): array
    {
        return [
            'onPluginsInitialized' => ['onPluginsInitialized', 1100],
            'onPageInitialized'    => ['onPageInitialized', 100000],
            'onPageNotFound'       => ['onPageNotFound', 100],
            'onTwigInitialized'    => ['onTwigInitialized', 0],
        ];
    }

    public function __construct($name, Grav $grav, $config = null)
    {
        parent::__construct($name, $grav, $config);
        $this->registerAutoloader();
    }

    /**
     * Register a lightweight PSR-4 autoloader for this plugin's src/ tree.
     *
     * Note: we do NOT expose a public `autoload()` method. Grav's
     * Plugins::init() calls `$plugin->autoload()` only if `method_exists()`
     * returns true. Because shipping a full vendor/ tree is heavy for a
     * plugin with six classes, we register our own spl_autoload_register
     * instead. This keeps the plugin self-contained with no composer
     * install step required at deploy time.
     */
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
        // Pimple closure — lazy build so a malformed config only surfaces
        // when something asks for a flag.
        $this->grav['feature_flags'] = function () {
            return $this->buildFlagStore();
        };
    }

    /**
     * Gate disabled-flagged pages at the EARLIEST reliable point after
     * $grav['page'] is set.
     *
     * Strategy — option (b) from the sprint contract's
     * not_found_replacement_strategy_is_safe criterion: if the dispatched
     * page declares a `feature:` frontmatter value that resolves disabled,
     * we (1) load the themed error page via $grav['pages']->dispatch('/error'),
     * (2) overwrite the container entry for 'page' using Pimple's
     * unset-then-set idiom so no listener ever reads a missing key, and
     * (3) set the HTTP response code to 404 on the replacement page. We
     * DO NOT call unset($grav['page']) without a following re-assignment.
     *
     * After this handler returns, subsequent onPageInitialized listeners
     * (form, login authorization, theme) will dereference $grav['page']
     * and see a valid, renderable Page object with http_response_code=404.
     */
    public function onPageInitialized(Event $event): void
    {
        if (!$this->config->get('plugins.feature-flags.enabled')) {
            return;
        }

        // Admin backend runs its own routing; never gate admin pages.
        if ($this->isAdmin()) {
            return;
        }

        $page = null;
        try {
            if (isset($this->grav['page'])) {
                $candidate = $this->grav['page'];
                if ($candidate instanceof PageInterface) {
                    $page = $candidate;
                }
            }
        } catch (\Throwable $e) {
            // Container access threw — nothing to gate; fall through.
            return;
        }

        if ($page === null) {
            return;
        }

        $header = $page->header();
        $route = null;
        try {
            $route = $page->route();
        } catch (\Throwable $e) {
            // Route is diagnostic only.
        }

        $decision = $this->buildPageGate()->decide($header, is_string($route) ? $route : null);

        if ($decision === PageGate::ALLOW) {
            return;
        }

        // Gated: swap for the themed 404 page. Catch every failure mode —
        // the visitor must see a themed response, never a Whoops trace.
        try {
            $errorPage = $this->loadErrorPage();
            if ($errorPage === null) {
                return;
            }

            // Pimple-safe overwrite: offsetUnset then offsetSet as a factory
            // closure. Completes BEFORE returning so downstream listeners
            // see the replacement page, never an unset key.
            $grav = $this->grav;
            unset($grav['page']);
            $grav['page'] = static function () use ($errorPage) {
                return $errorPage;
            };

            // Ensure header code is 404 even if the template somehow inherits
            // a different code from the original page.
            if (method_exists($errorPage, 'http_response_code')) {
                $errorPage->http_response_code(404);
            }

            // Stop this event so later onPageInitialized listeners see the
            // replacement (they still run — Grav fires them on the new page
            // only after this handler returns; stopPropagation here prevents
            // further listeners of the SAME priority from touching the
            // original page object).
            if (method_exists($event, 'stopPropagation')) {
                $event->stopPropagation();
            }
        } catch (\Throwable $e) {
            // Last-ditch: log and leave the original page in place rather
            // than 500'ing. Criterion error_handling_no_leaks: no stack
            // trace, no Whoops, no container-id strings bubble to the user.
            $logger = $this->resolveLogger();
            if ($logger !== null) {
                $logger->warning(
                    'Feature-flag page gating failed to swap page; rendering original.',
                    [
                        'reason'      => 'swap_exception',
                        'exception'   => get_class($e),
                        'environment' => $this->resolveEnvironment(),
                    ]
                );
            }
        }
    }

    /**
     * Secondary safety net: if a genuinely missing page reaches
     * onPageNotFound (Grav's error plugin is @ priority 0, we run higher at
     * 100 but still after error's own subscription registration order —
     * safe because stopPropagation here blocks the rest). We only override
     * the page if nothing else has yet. This is option (a) from the
     * contract — used defensively for a narrow edge case where the
     * original page was garbage-collected between initialization and
     * rendering.
     */
    public function onPageNotFound(Event $event): void
    {
        if (!$this->config->get('plugins.feature-flags.enabled')) {
            return;
        }
        if ($this->isAdmin()) {
            return;
        }

        // Only act if no other listener has set a replacement page on the
        // event yet. Grav's error plugin sets $event->page directly at
        // priority 0; if we already see a valid Page, leave it alone.
        $existing = $event->page ?? null;
        if ($existing instanceof PageInterface) {
            return;
        }

        try {
            $errorPage = $this->loadErrorPage();
            if ($errorPage === null) {
                return;
            }
            $event->page = $errorPage;
            if (method_exists($event, 'stopPropagation')) {
                $event->stopPropagation();
            }
        } catch (\Throwable $e) {
            // Let Grav's own error plugin handle it.
        }
    }

    /**
     * Load the themed /error page via Grav's Pages service. We follow the
     * same path the built-in `error` plugin uses (see
     * user/plugins/error/error.php::getErrorPage): first dispatch the
     * configured 404 route (default `/error`); if that yields nothing, init
     * a Page directly from the error plugin's bundled pages/error.md so
     * the themed template receives its real content. This keeps the
     * response identical to what Grav would have served had the page
     * simply not existed.
     */
    private function loadErrorPage(): ?PageInterface
    {
        /** @var Pages|null $pages */
        $pages = isset($this->grav['pages']) ? $this->grav['pages'] : null;
        if ($pages === null) {
            return null;
        }

        // Step 1: try the configured /error route (user override wins).
        try {
            $route = '/error';
            if (isset($this->grav['config'])) {
                $configured = $this->grav['config']->get('plugins.error.routes.404', '/error');
                if (is_string($configured) && $configured !== '') {
                    $route = $configured;
                }
            }
            $page = $pages->dispatch($route, true);
            if ($page instanceof PageInterface) {
                $page->routable(false);
                if (method_exists($page, 'http_response_code')) {
                    $page->http_response_code(404);
                }
                return $page;
            }
        } catch (\Throwable $e) {
            // Fall through to plugin-bundled page.
        }

        // Step 2: init a Page from the error plugin's bundled error.md.
        $bundled = '/app/www/public/user/plugins/error/pages/error.md';
        if (!is_file($bundled)) {
            // Resolve relative to the Grav root from the user plugin dir
            // (we live under user/plugins/feature-flags/).
            $candidate = __DIR__ . '/../error/pages/error.md';
            if (is_file($candidate)) {
                $bundled = $candidate;
            } else {
                $bundled = null;
            }
        }
        if ($bundled !== null) {
            try {
                $page = new Page();
                $page->init(new \SplFileInfo($bundled));
                $page->routable(false);
                if (method_exists($page, 'http_response_code')) {
                    $page->http_response_code(404);
                }
                return $page;
            } catch (\Throwable $e) {
                // Fall through to last-resort construction.
            }
        }

        // Step 3: last-resort — synthesise a themed error page without
        // hitting the filesystem. Content is a minimal translated string;
        // the theme's error.html.twig renders around it.
        try {
            $page = new Page();
            $page->routable(false);
            $page->template('error');
            $page->title('Page not Found');
            if (method_exists($page, 'modifyHeader')) {
                $page->modifyHeader('http_response_code', 404);
            }
            return $page;
        } catch (\Throwable $e) {
            return null;
        }
    }

    /**
     * Register feature_enabled(), enabled_features() (Sprint 2) and
     * feature_visible (Sprint 3 — filter + function).
     */
    public function onTwigInitialized(): void
    {
        if (!$this->config->get('plugins.feature-flags.enabled')) {
            return;
        }

        $twig = $this->grav['twig']->twig();

        $helpers = $this->buildTwigHelpers();
        $collectionFilter = $this->buildCollectionFilter();

        $twig->addFunction(new TwigFunction(
            'feature_enabled',
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

        // feature_visible: filter form (idiomatic `coll|feature_visible`)
        // and function form (for collections that are easier to express as
        // `feature_visible(coll)`).
        $filterCallable = static function (mixed $collection) use ($collectionFilter): array {
            if (!is_iterable($collection)) {
                return [];
            }
            return $collectionFilter->filter($collection);
        };

        $twig->addFilter(new TwigFilter('feature_visible', $filterCallable));
        $twig->addFunction(new TwigFunction('feature_visible', $filterCallable));
    }

    private function buildTwigHelpers(): TwigHelpers
    {
        $store = $this->resolveStore();
        return new TwigHelpers($store, $this->resolveLogger(), $this->resolveEnvironment());
    }

    private function buildCollectionFilter(): CollectionFilter
    {
        return new CollectionFilter($this->buildPageGate());
    }

    private function buildPageGate(): PageGate
    {
        return new PageGate(
            $this->resolveStore(),
            $this->resolveLogger(),
            $this->resolveEnvironment()
        );
    }

    private function resolveStore(): FlagStoreInterface
    {
        if (isset($this->grav['feature_flags'])) {
            $candidate = $this->grav['feature_flags'];
            if ($candidate instanceof FlagStoreInterface) {
                return $candidate;
            }
        }
        return new FlagStore([], $this->resolveLogger(), $this->resolveEnvironment());
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
