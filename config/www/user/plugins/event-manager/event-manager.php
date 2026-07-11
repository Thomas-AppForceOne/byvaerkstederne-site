<?php
/**
 * Event Manager Plugin for Byværkstederne
 *
 * Frontend event CRUD (frontend_event_crud_specification.md): lets members of
 * the `organizers` group create, read, update and soft-delete their own
 * events in the existing `begivenheder` Flex directory from the public site,
 * without admin-panel access.
 *
 * Handles:
 *  - Public event detail route            /begivenheder/<key>
 *  - Management dashboard                 /begivenheder/mine
 *  - Create / edit / delete form pages    /begivenheder/{opret,rediger,slet}
 *  - The mutating POST contract (§8.1): feature flag → method → authn →
 *    CSRF → capability → validation → per-object ownership → Flex mutation →
 *    audit → PRG redirect.
 *
 * Design notes:
 *  - Forms are RENDERED by the Form plugin (page-frontmatter forms through
 *    the stock forms/form.html.twig — CSRF nonce injection and house styling
 *    for free), but the POSTs are intercepted here in onPageInitialized at
 *    priority 5 — after the login plugin's access gate (priority 10), before
 *    the Form plugin's own processing (priority 0). Running the whole §8.1
 *    contract in one place is what makes the spec'd status codes (403 on bad
 *    CSRF, 400 on invalid input, 404 on unknown key) achievable; the Form
 *    plugin's onFormProcessed pipeline re-renders with HTTP 200 on nonce or
 *    validation failure, which the forced-browsing negative tests forbid.
 *  - Read denials on the detail route fall through to Grav's natural themed
 *    404 — byte-identical to a genuinely missing page, so an unpublished or
 *    archived event's existence never leaks (§8.2).
 *  - Mutations go through the Flex API (blueprint validation, supported
 *    write path) and the render cache is busted explicitly after every
 *    successful mutation — never relying on onFlexAfterSave/Delete firing
 *    frontend-side, which is unverified in Flex Objects 1.3.8 (§0/§8).
 */

namespace Grav\Plugin;

use Grav\Common\Grav;
use Grav\Common\Page\Interfaces\PageInterface;
use Grav\Common\Page\Page;
use Grav\Common\Plugin;
use Grav\Common\Utils;
use Grav\Framework\Psr7\Response;
use Grav\Plugin\EventManager\AuditLog;
use Grav\Plugin\EventManager\EventAuthorizer;
use Grav\Plugin\EventManager\EventRepository;
use Grav\Plugin\EventManager\EventValidator;
use Grav\Plugin\EventManager\FormDataProvider;
use Grav\Plugin\EventManager\ImageStore;
use Grav\Plugin\EventManager\SignupRepository;
use Grav\Plugin\FeatureFlags\FeatureFlag;
use Grav\Plugin\FeatureFlags\FlagStoreInterface;

class EventManagerPlugin extends Plugin
{
    private const ROUTE_BASE = '/begivenheder';

    /** Fixed management slugs under /begivenheder — never treated as object keys. */
    private const RESERVED_SLUGS = ['mine', 'opret', 'rediger', 'slet', 'tilmeld', 'upload', 'billede'];

    /** Object keys: legacy `event0NN` and new `ev_<hex>` both match. */
    private const KEY_PATTERN = '/^[A-Za-z0-9_-]{1,64}$/';

    private ?EventRepository $repository = null;

    /** Event data + key resolved for the current request (detail/edit/delete GET). */
    private ?array $currentEvent = null;
    private ?string $currentKey = null;

    public static function getSubscribedEvents(): array
    {
        return [
            'onPluginsInitialized' => ['onPluginsInitialized', 0],
        ];
    }

    public function __construct($name, Grav $grav, $config = null)
    {
        parent::__construct($name, $grav, $config);
        $this->registerAutoloader();
    }

    /**
     * PSR-4 autoloader for src/ — same self-contained pattern as the
     * feature-flags and site-version plugins (no composer step at deploy).
     */
    private function registerAutoloader(): void
    {
        static $registered = false;
        if ($registered) {
            return;
        }
        $registered = true;

        $prefix = 'Grav\\Plugin\\EventManager\\';
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
        if (!$this->config->get('plugins.event-manager.enabled')) {
            return;
        }
        if ($this->isAdmin()) {
            return;
        }

        $this->enable([
            // Route resolution: detail view, keyed edit/delete routes, and
            // form patching (blueprint-sourced options, prefill, hidden key).
            // Priority 1000: MUST run before the Form plugin's own
            // onPagesInitialized (priority 0), which snapshots each page's
            // form definition into Form objects — patches applied after that
            // snapshot never reach the rendered form.
            'onPagesInitialized' => ['onPagesInitialized', 1000],
            // Mutating-POST contract (§8.1). Priority 5: after the login
            // plugin's page-access gate (10) and the feature-flags page gate
            // (100000), before the Form plugin's own processing (0).
            'onPageInitialized' => ['onPageInitialized', 5],
            'onTwigInitialized' => ['onTwigInitialized', 0],
            'onTwigSiteVariables' => ['onTwigSiteVariables', 0],
        ]);
    }

    // -------------------------------------------------------------------------
    // Route resolution
    // -------------------------------------------------------------------------

    public function onPagesInitialized(): void
    {
        $path = $this->grav['uri']->path();
        if ($path !== self::ROUTE_BASE && !str_starts_with($path, self::ROUTE_BASE . '/')) {
            return;
        }

        $segments = array_values(array_filter(explode('/', $path), 'strlen'));
        $method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

        // Public image serving GET /begivenheder/billede/<key>/<file> (§5.3) —
        // streamed directly and terminated here.
        if (count($segments) === 4 && $segments[1] === 'billede') {
            $this->serveEventImage($segments[2], $segments[3]);
            return;
        }

        // /begivenheder itself has no page; the public event list lives on
        // the calendar page.
        if (count($segments) === 1) {
            $this->grav->redirect('/vaerkstedskalenderen', 302);
        }

        if (count($segments) === 2) {
            $slug = $segments[1];
            if (!in_array($slug, self::RESERVED_SLUGS, true)) {
                $this->resolveDetailRoute($slug);
                return;
            }
            if ($slug === 'mine') {
                $this->enforceManagementAccess('read');
                return;
            }
            if ($slug === 'opret') {
                $this->enforceManagementAccess('create');
                return;
            }
            if ($slug === 'tilmeld' || $slug === 'upload') {
                // The RSVP toggle (§3) and image upload (§5.2) are POST-only
                // and have no page of their own. Mount a virtual page so the
                // §8.1 contract handler in onPageInitialized reliably fires for
                // the POST; a bare GET is a dead end → back to the calendar.
                if ($method === 'POST') {
                    $this->mountVirtualRoute('event-rsvp.md');
                } else {
                    $this->grav->redirect('/vaerkstedskalenderen', 302);
                }
                return;
            }
            // A bare GET on the keyed form routes is meaningless — send the
            // visitor to the dashboard. POSTs pass through to the contract
            // handler (the form actions post here with a hidden key field).
            if (in_array($slug, ['rediger', 'slet'], true) && $method !== 'POST') {
                $this->grav->redirect(self::ROUTE_BASE . '/mine', 302);
            }
            return;
        }

        if (count($segments) === 3 && in_array($segments[1], ['rediger', 'slet'], true)) {
            $this->enforceManagementAccess($segments[1] === 'rediger' ? 'update' : 'delete');
            $this->resolveKeyedManagementRoute($segments[1], $segments[2]);
        }
    }

    /**
     * GET gate for the management pages (§6): the pages' `access:
     * site.login` frontmatter lets the login plugin handle anonymous
     * visitors (login form / redirect); an authenticated member WITHOUT the
     * events capability gets an explicit 403 here — page access frontmatter
     * alone cannot express "site.login AND admin.events.*" reliably, and
     * frontend gating must never be the only boundary anyway.
     */
    private function enforceManagementAccess(string $capability): void
    {
        if (!$this->featureEnabled()) {
            return; // the page's `feature:` gate serves the 404
        }
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorized) {
            return; // anonymous: login plugin's access gate takes over
        }
        if (!EventAuthorizer::hasCapability($user, $capability)) {
            $this->sendError(403, 'Du har ikke adgang til denne side.');
        }
    }

    /**
     * Route /begivenheder/<key>. The standalone public detail page has been
     * retired — event details are shown inline on the calendar (card
     * expansion), so any /begivenheder/<key> URL redirects to the calendar.
     * Redirecting every key uniformly (published, unpublished, unknown alike)
     * means no event's existence leaks via a distinct 404 (§8.2). Feature off
     * still falls through to the natural themed 404.
     */
    private function resolveDetailRoute(string $key): void
    {
        if (!$this->featureEnabled()) {
            return; // feature off → natural themed 404 (the page's `feature:` gate)
        }
        $this->grav->redirect('/vaerkstedskalenderen', 302);
    }

    /**
     * Keyed management routes /begivenheder/{rediger,slet}/<key>: dispatch
     * the underlying form page, resolve the object and enforce ownership for
     * authenticated viewers (anonymous visitors fall through to the login
     * plugin's access gate on the dispatched page). Form prefill, blueprint-
     * sourced select options and the hidden key are provided per request by
     * the pages' data-options@/data-default@ directives (FormDataProvider) —
     * the Form plugin caches form definitions with the pages index, so
     * runtime header patching never reaches the rendered form.
     */
    private function resolveKeyedManagementRoute(string $action, string $key): void
    {
        if (!$this->featureEnabled()) {
            return; // no page at this route → natural themed 404
        }
        if (!preg_match(self::KEY_PATTERN, $key)) {
            return;
        }

        /** @var \Grav\Common\Page\Pages $pages */
        $pages = $this->grav['pages'];
        $page = $pages->find(self::ROUTE_BASE . '/' . $action);
        if (!$page instanceof PageInterface) {
            return;
        }

        $user = $this->grav['user'] ?? null;
        if ($user && $user->authenticated && $user->authorized) {
            $event = $this->repository()->findArray($key);
            if ($event === null) {
                return; // natural 404
            }
            if (!EventAuthorizer::ownsOrSuper($user, $event['owner'] ?? null)) {
                $this->sendError(403, 'Du kan kun administrere dine egne begivenheder.');
            }
            $this->currentEvent = $event;
            $this->currentKey = $key;
        }
        // Anonymous: mount the page untouched; the login plugin's access
        // gate (site.login + admin.events.*) takes over on onPageInitialized.

        $grav = $this->grav;
        unset($grav['page']);
        $grav['page'] = static function () use ($page) {
            return $page;
        };
    }

    // -------------------------------------------------------------------------
    // Mutating-POST contract (§8.1)
    // -------------------------------------------------------------------------

    public function onPageInitialized(): void
    {
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
            return;
        }

        $action = $this->mutationActionForPath($this->grav['uri']->path());
        if ($action === null) {
            return;
        }

        // 1. Feature-flag gate — before any payload parsing. Belt to the
        //    page-level gate: a disabled feature never processes a POST. The
        //    CRUD actions gate on event_management; the RSVP toggle and the
        //    image upload (part of the details feature, §3/§5/§6) additionally
        //    require event_rsvp — either off ⇒ the same no-leak 404.
        $flagOk = in_array($action, ['rsvp', 'upload'], true)
            ? $this->rsvpFeatureEnabled()
            : $this->featureEnabled();
        if (!$flagOk) {
            $this->sendFlagDisabled404();
        }

        // 2. Method — POST, matched above.

        // 3. Authentication. The login plugin's access gate (priority 10)
        //    normally intercepts anonymous POSTs first; re-checked here so
        //    the contract never depends on page frontmatter.
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorized) {
            $this->sendError(401, 'Ikke autoriseret. Log ind for at fortsætte.');
        }

        // 4. CSRF. The full-page CRUD forms use the Form plugin's shared
        //    'form' nonce (injected by forms/form.html.twig). The RSVP button
        //    flips state without navigation, so it carries its own rotating
        //    'event-rsvp' nonce (minted fresh into every success response) —
        //    the roadmap-vote pattern.
        if ($action === 'rsvp') {
            $nonce = (string)($_POST['rsvp_nonce'] ?? '');
            if ($nonce === '' || !Utils::verifyNonce($nonce, 'event-rsvp')) {
                $this->sendError(403, 'Ugyldig sikkerhedstoken. Genindlæs siden og prøv igen.');
            }
        } else {
            $nonce = (string)($_POST['form-nonce'] ?? '');
            if ($nonce === '' || !Utils::verifyNonce($nonce, 'form')) {
                $this->sendError(403, 'Ugyldig sikkerhedstoken. Genindlæs siden og prøv igen.');
            }
        }

        // 5. Capability (admin.super passes explicitly — core authorize()
        //    has no super override outside the admin plugin). SKIPPED for
        //    rsvp: any activated member may sign up — site.login is the bar
        //    (§3), which step 3 already enforced. For upload, either the
        //    create or the update capability qualifies (§5.2) — the image may
        //    be added while composing a new event or editing an existing one.
        if ($action === 'upload') {
            if (!EventAuthorizer::hasCapability($user, 'create')
                && !EventAuthorizer::hasCapability($user, 'update')) {
                $this->sendError(403, 'Du har ikke rettigheder til at uploade billeder.');
            }
        } elseif ($action !== 'rsvp' && !EventAuthorizer::hasCapability($user, $action)) {
            $this->sendError(403, 'Du har ikke rettigheder til at administrere begivenheder.');
        }

        $data = $_POST['data'] ?? [];
        if (!is_array($data)) {
            $data = [];
        }

        switch ($action) {
            case 'create':
                $this->handleCreate($user, $data);
                break;
            case 'update':
                $this->handleUpdate($user, $data);
                break;
            case 'delete':
                $this->handleDelete($user, $data);
                break;
            case 'rsvp':
                $this->handleRsvp($user, $data);
                break;
            case 'upload':
                $this->handleUpload($user, $data);
                break;
        }
    }

    /** Map a request path to the §8.1 action (and capability suffix). */
    private function mutationActionForPath(string $path): ?string
    {
        if ($path === self::ROUTE_BASE . '/tilmeld') {
            return 'rsvp';
        }
        if ($path === self::ROUTE_BASE . '/upload') {
            return 'upload';
        }
        if ($path === self::ROUTE_BASE . '/opret') {
            return 'create';
        }
        if ($path === self::ROUTE_BASE . '/rediger' || str_starts_with($path, self::ROUTE_BASE . '/rediger/')) {
            return 'update';
        }
        if ($path === self::ROUTE_BASE . '/slet' || str_starts_with($path, self::ROUTE_BASE . '/slet/')) {
            return 'delete';
        }
        return null;
    }

    /** @param array<string,mixed> $data */
    private function handleCreate($user, array $data): void
    {
        // Honeypot: humans never see the field; a filled value is a bot.
        // (The Form plugin's own honeypot rejection is pre-empted by this
        // handler, so the check lives here.)
        if (!empty($data['website'])) {
            $this->sendError(400, 'Ugyldig formular.');
        }

        $values = $this->validateOr400($data, self::ROUTE_BASE . '/opret');

        // 8. Mutate — owner stamped once here, never client-settable. The
        //    arrangør self-publishes: the validated `published` value is
        //    honoured, no forced moderation state (§0/§8.1).
        $now = gmdate('Y-m-d\TH:i:s\Z');
        $values['owner'] = $user->username;
        $values['created_by'] = $user->username;
        $values['created_at'] = $now;
        $values['updated_by'] = $user->username;
        $values['updated_at'] = $now;
        $values['archived'] = false;

        // Adopt the create form's pre-generated key when it is well-formed and
        // still unused, so images uploaded before first save (§5.2/§6) land in
        // the folder the finished event actually uses; otherwise mint a fresh
        // collision-resistant one (mirrors the br_/rm_ convention).
        $key = $this->adoptOrGenerateKey($data);

        try {
            $key = $this->repository()->create($values, $key);
        } catch (\Throwable $e) {
            $this->sendError(500, 'Begivenheden kunne ikke gemmes. Prøv igen.');
        }

        // The create-form key has been consumed — the next new form gets a
        // fresh one.
        FormDataProvider::clearNewEventKey($this->grav);

        $this->auditLog()->append('create', $key, $user->username, ['after' => $this->auditSnapshot($values)]);
        $this->repository()->bustRenderCache();
        $this->redirectWithFlash('Begivenheden "' . $values['title'] . '" er oprettet.');
    }

    /** @param array<string,mixed> $data */
    private function handleUpdate($user, array $data): void
    {
        [$key, $object, $stored] = $this->resolveOwnedObjectOr40x($user, $data);

        $values = $this->validateOr400($data, self::ROUTE_BASE . '/rediger/' . $key);

        // Preserve identity and creation stamps from the STORED object —
        // client-submitted values for server-managed fields are ignored.
        $values['owner'] = (string)($stored['owner'] ?? '');
        $values['created_by'] = (string)($stored['created_by'] ?? '');
        $values['created_at'] = (string)($stored['created_at'] ?? '');
        $values['archived'] = !empty($stored['archived']);
        $values['updated_by'] = $user->username;
        $values['updated_at'] = gmdate('Y-m-d\TH:i:s\Z');

        try {
            $this->repository()->update($object, $values);
        } catch (\Throwable $e) {
            $this->sendError(500, 'Ændringerne kunne ikke gemmes. Prøv igen.');
        }

        $this->auditLog()->append('update', $key, $user->username, [
            'before' => $this->auditSnapshot($stored),
            'after' => $this->auditSnapshot($values),
        ]);
        $this->repository()->bustRenderCache();
        $this->redirectWithFlash('Begivenheden "' . $values['title'] . '" er opdateret.');
    }

    /** @param array<string,mixed> $data */
    private function handleDelete($user, array $data): void
    {
        [$key, $object, $stored] = $this->resolveOwnedObjectOr40x($user, $data);

        $mode = (string)($data['mode'] ?? 'archive');
        $now = gmdate('Y-m-d\TH:i:s\Z');

        if ($mode === 'hard') {
            // Hard delete is a rare, super-only escalation (§3/§4).
            if (!$user->authorize('admin.super')) {
                $this->sendError(403, 'Permanent sletning kræver administrator-rettigheder.');
            }
            try {
                $this->repository()->hardDelete($object);
            } catch (\Throwable $e) {
                $this->sendError(500, 'Begivenheden kunne ikke slettes. Prøv igen.');
            }
            // A permanently removed event leaves no orphaned signups or images.
            $this->signupRepository()->deleteFor($key);
            $this->imageStore()->deleteEventImages($key);
            $this->auditLog()->append('hard_delete', $key, $user->username, ['before' => $this->auditSnapshot($stored)]);
            $this->repository()->bustRenderCache();
            $this->redirectWithFlash('Begivenheden er slettet permanent.');
        }

        if ($mode === 'restore') {
            // Reverse of the soft archive — the owner's self-service undo.
            // `published` stays false; the event comes back as a draft.
            try {
                $this->repository()->update($object, [
                    'archived' => false,
                    'updated_by' => $user->username,
                    'updated_at' => $now,
                ]);
            } catch (\Throwable $e) {
                $this->sendError(500, 'Begivenheden kunne ikke gendannes. Prøv igen.');
            }
            $this->auditLog()->append('restore', $key, $user->username, []);
            $this->repository()->bustRenderCache();
            $this->redirectWithFlash('Begivenheden er gendannet som kladde.');
        }

        // Default: soft archive — retain the object, unpublish, hide from
        // all public views; reversible by the owner from the dashboard.
        try {
            $this->repository()->update($object, [
                'archived' => true,
                'published' => false,
                'updated_by' => $user->username,
                'updated_at' => $now,
            ]);
        } catch (\Throwable $e) {
            $this->sendError(500, 'Begivenheden kunne ikke arkiveres. Prøv igen.');
        }
        $this->auditLog()->append('archive', $key, $user->username, ['before' => $this->auditSnapshot($stored)]);
        $this->repository()->bustRenderCache();
        $this->redirectWithFlash('Begivenheden er arkiveret.');
    }

    /**
     * RSVP toggle (event_rsvp_specification.md §3). The shared gates (flag,
     * authn, CSRF) have already run; no capability is required. Order here:
     * event exists → published && !archived → date not past → toggle (with
     * capacity inside the store's lock for Tilmeld) → audit → respond.
     *
     * Every not-signup-able condition returns the same no-leak 404 as the
     * detail route (existence is not disclosed); a past event is 409; a full
     * Tilmeld event is 409 "Alle pladser er optaget".
     *
     * @param array<string,mixed> $data
     */
    private function handleRsvp($user, array $data): void
    {
        $key = trim((string)($data['key'] ?? ''));
        if ($key === '' || !preg_match(self::KEY_PATTERN, $key)) {
            $this->sendError(404, 'Begivenheden findes ikke.');
        }

        $event = $this->repository()->findArray($key);
        if ($event === null || empty($event['published']) || !empty($event['archived'])) {
            // Unknown, unpublished, or archived — indistinguishable from
            // missing, same posture as the detail route (§8.2).
            $this->sendError(404, 'Begivenheden findes ikke.');
        }

        if ($this->eventIsPast($event)) {
            $this->sendError(409, 'Tilmelding er lukket — begivenheden er afholdt.');
        }

        // Mode is stamped from the event's button_text (lowercased), so a
        // later organizer flip does not reinterpret existing signups (§2).
        $mode = strtolower(trim((string)($event['button_text'] ?? 'Tilmeld')));
        if ($mode !== SignupRepository::MODE_TILMELD && $mode !== 'interesseret') {
            $mode = SignupRepository::MODE_TILMELD;
        }

        // Capacity is enforced only for Tilmeld with a numeric capacity;
        // non-numeric/empty ⇒ unlimited (§0). Interesseret is never bounded.
        $capacity = null;
        if ($mode === SignupRepository::MODE_TILMELD) {
            $rawCap = trim((string)($event['capacity'] ?? ''));
            if (preg_match('/^\d+$/', $rawCap)) {
                $capacity = (int)$rawCap;
            }
        }

        $signups = $this->signupRepository();
        $result = $signups->toggle($key, (string)$user->username, $mode, $capacity);

        if ($result === SignupRepository::FULL) {
            $this->sendError(409, 'Alle pladser er optaget.');
        }

        $auditAction = $result === SignupRepository::SIGNED_UP ? 'signup' : 'withdraw';
        $this->auditLog()->append($auditAction, $key, (string)$user->username, ['mode' => $mode]);

        $count = $signups->countFor($key);
        $remaining = $capacity !== null
            ? max(0, $capacity - $signups->countFor($key, SignupRepository::MODE_TILMELD))
            : null;

        // AJAX button (Accept not text/html) gets JSON with a fresh rotating
        // nonce; a no-JS form submit (Accept: text/html) gets PRG-with-flash
        // back to the page it came from — mirrors validateOr400()'s split.
        if (!str_contains((string)($_SERVER['HTTP_ACCEPT'] ?? ''), 'text/html')) {
            $this->sendJson([
                'success' => true,
                'action' => $result,
                'count' => $count,
                'remaining' => $remaining,
                'new_nonce' => Utils::getNonce('event-rsvp'),
            ]);
        }

        $flash = $result === SignupRepository::SIGNED_UP
            ? ($mode === SignupRepository::MODE_TILMELD ? 'Du er nu tilmeldt.' : 'Du er nu noteret som interesseret.')
            : 'Din tilmelding er annulleret.';
        $this->grav['messages']->add($flash, 'success');
        $this->grav->redirect($this->safeReferer('/vaerkstedskalenderen'), 303);
        exit; // @phpstan-ignore-line — redirect() exits; belt for static analysis
    }

    /**
     * Image upload for the details editor (§5.2). The shared gates (flags,
     * authn, form-nonce CSRF, create|update capability) have already run.
     * Per-object rule: if the posted key resolves to an existing event, the
     * caller must own it (or be super); if it doesn't exist yet, a
     * capability-holder may upload against the pre-generated create-form key
     * (bounded by the per-event quota). Responds in TinyMCE's shape:
     * {location} on success.
     *
     * @param array<string,mixed> $data
     */
    private function handleUpload($user, array $data): void
    {
        $key = trim((string)($data['key'] ?? ''));
        if ($key === '' || !preg_match(self::KEY_PATTERN, $key)) {
            $this->sendError(400, 'Ugyldig begivenhedsnøgle.');
        }

        // Existing event → ownership required; not-yet-created key → allowed
        // for the capability-holder already verified in the shared gates.
        $event = $this->repository()->findArray($key);
        if ($event !== null && !EventAuthorizer::ownsOrSuper($user, $event['owner'] ?? null)) {
            $this->sendError(403, 'Du kan kun uploade billeder til dine egne begivenheder.');
        }

        $file = $_FILES['file'] ?? null;
        if (!is_array($file)) {
            $this->sendError(400, 'Ingen fil modtaget.');
        }

        $result = $this->imageStore()->store($key, $file);
        if (isset($result['error'])) {
            $this->sendError(400, $result['error']);
        }

        $this->auditLog()->append('image_upload', $key, (string)$user->username, ['file' => $result['file']]);
        // The serving URL is extensionless (see ImageStore) so the web server's
        // static-asset handler doesn't swallow it before Grav.
        $this->sendJson([
            'location' => self::ROUTE_BASE . '/billede/' . $key . '/' . ImageStore::hashOf($result['file']),
        ]);
    }

    /**
     * §8.1.6 — server-side validation, independent of any client checks.
     * Returns the validated value map or terminates with a 400 carrying
     * field-level Danish messages.
     *
     * @param array<string,mixed> $data
     * @return array<string,mixed>
     */
    private function validateOr400(array $data, string $formRoute): array
    {
        $validator = new EventValidator($this->repository()->fieldOptions('group'));
        $result = $validator->validate($data);
        if ($result['errors'] === []) {
            return $result['values'];
        }

        // A browser form POST (Accept: text/html) gets the friendly path —
        // §8.1.10's PRG-with-flash: back to the form with the field errors
        // flashed and the submitted values stashed for repopulation
        // (FormDataProvider consumes the stash on the next render). Every
        // other caller — the forced-browsing negative tests, scripts, APIs —
        // gets the contract's bare 400 with field-level JSON errors.
        if (str_contains((string)($_SERVER['HTTP_ACCEPT'] ?? ''), 'text/html')) {
            $messages = $this->grav['messages'];
            foreach ($result['errors'] as $message) {
                $messages->add($message, 'error');
            }
            FormDataProvider::stashOldInput($this->grav, $data);
            $this->grav->redirect($formRoute, 303);
        }

        $this->sendJson(['success' => false, 'errors' => $result['errors']], 400);
    }

    /**
     * §8.1.7 — per-object authorization for update/delete. The key is a
     * correlation value only: the object is re-resolved server-side and
     * ownership computed against the STORED owner. Missing owner ⇒
     * super-only. Unknown key ⇒ 404; not owned ⇒ 403.
     *
     * @param array<string,mixed> $data
     * @return array{0:string,1:object,2:array<string,mixed>}
     */
    private function resolveOwnedObjectOr40x($user, array $data): array
    {
        $key = trim((string)($data['key'] ?? ''));
        if ($key === '' || !preg_match(self::KEY_PATTERN, $key)) {
            $this->sendError(404, 'Begivenheden findes ikke.');
        }

        $object = $this->repository()->find($key);
        if ($object === null) {
            $this->sendError(404, 'Begivenheden findes ikke.');
        }

        $stored = $this->repository()->toArray($object);
        if (!EventAuthorizer::ownsOrSuper($user, $stored['owner'] ?? null)) {
            $this->sendError(403, 'Du kan kun administrere dine egne begivenheder.');
        }

        return [$key, $object, $stored];
    }

    /** Compact before/after snapshot for the audit trail — no free-text bodies. */
    private function auditSnapshot(array $values): array
    {
        return [
            'title' => (string)($values['title'] ?? ''),
            'event_date' => (string)($values['event_date'] ?? ''),
            'published' => !empty($values['published']),
            'archived' => !empty($values['archived']),
            'owner' => (string)($values['owner'] ?? ''),
        ];
    }

    /** §8.1.10 — PRG: flash + 303 redirect to the dashboard. */
    private function redirectWithFlash(string $message): never
    {
        $this->grav['messages']->add($message, 'success');
        $this->grav->redirect(self::ROUTE_BASE . '/mine', 303);
        exit; // @phpstan-ignore-line — redirect() exits; belt for static analysis
    }

    // -------------------------------------------------------------------------
    // Twig data injection
    // -------------------------------------------------------------------------

    /**
     * event_sort_key(date, time, group): the calendar's chronological sort
     * key — event date, then start time, then the house workshop order
     * (makerspace, krea, grønt, eventværkstedet; fælles/'alle' events after
     * those). Lives in PHP because legacy event_time strings are messy
     * ("18:00 — 20:00", "Fredag 17 - 20") and need a real regex to yield a
     * comparable HH:MM.
     */
    public function onTwigInitialized(): void
    {
        $twig = $this->grav['twig']->twig();
        $twig->addFunction(new \Twig\TwigFunction(
            'event_sort_key',
            static function ($date, $time, $group): string {
                $start = '99:99'; // untimed events sort after timed ones that day
                if (preg_match('/(\d{1,2})(?:[:.](\d{2}))?/', (string)$time, $m)) {
                    $start = str_pad($m[1], 2, '0', STR_PAD_LEFT) . ':' . ($m[2] ?? '00');
                }
                $rank = [
                    'makerspace' => 1,
                    'kreativ' => 2, 'krea' => 2,
                    'groenne' => 3, 'groent' => 3,
                    'kulturhus' => 4,
                    'alle' => 5,
                ][(string)$group] ?? 6;
                return sprintf('%s|%s|%d', (string)$date, $start, $rank);
            }
        ));

        // RSVP reads injected straight into the existing card/detail/dashboard
        // templates — no new read endpoints (§3). Arrow functions bind $this
        // so the closures reach the private repositories.
        $twig->addFunction(new \Twig\TwigFunction(
            'event_signup_info',
            fn (string $key): ?array => $this->signupInfo($key)
        ));
        $twig->addFunction(new \Twig\TwigFunction(
            'event_attendees',
            fn (string $key): ?array => $this->attendeeList($key)
        ));
    }

    /**
     * Public signup state for one event, or null when the event is not
     * signup-able (unknown, unpublished, archived, or the flag is off). The
     * data is public — counts and remaining seats are shown to everyone,
     * including anonymous visitors (§1.3).
     *
     * @return array{count:int, remaining:?int, is_full:bool, user_signed_up:bool, mode:string, is_past:bool}|null
     */
    private function signupInfo(string $key): ?array
    {
        if ($key === '' || !$this->rsvpFeatureEnabled()) {
            return null;
        }
        $event = $this->repository()->findArray($key);
        if ($event === null || empty($event['published']) || !empty($event['archived'])) {
            return null;
        }

        $mode = strtolower(trim((string)($event['button_text'] ?? 'Tilmeld')));
        if ($mode !== SignupRepository::MODE_TILMELD && $mode !== 'interesseret') {
            $mode = SignupRepository::MODE_TILMELD;
        }

        $rawCap = trim((string)($event['capacity'] ?? ''));
        $capacity = preg_match('/^\d+$/', $rawCap) ? (int)$rawCap : null;

        $signups = $this->signupRepository();
        $count = $signups->countFor($key);
        $remaining = ($mode === SignupRepository::MODE_TILMELD && $capacity !== null)
            ? max(0, $capacity - $signups->countFor($key, SignupRepository::MODE_TILMELD))
            : null;

        $user = $this->grav['user'] ?? null;
        $userSignedUp = $user && $user->authenticated && $user->authorized
            && $signups->isSignedUp($key, (string)$user->username);

        return [
            'count' => $count,
            'remaining' => $remaining,
            'is_full' => $remaining !== null && $remaining <= 0,
            'user_signed_up' => (bool)$userSignedUp,
            'mode' => $mode,
            'is_past' => $this->eventIsPast($event),
        ];
    }

    /**
     * Attendee list for the OWNER (or super) only — the ownership check lives
     * here in PHP so a template can never leak names by accident (§3). Returns
     * null for anyone else. Full names are resolved from Grav's accounts at
     * render time, never stored in the signup file (§2).
     *
     * @return list<array{username:string, fullname:string, mode:string, ts:string}>|null
     */
    private function attendeeList(string $key): ?array
    {
        if ($key === '' || !$this->rsvpFeatureEnabled()) {
            return null;
        }
        $event = $this->repository()->findArray($key);
        if ($event === null) {
            return null;
        }
        $user = $this->grav['user'] ?? null;
        if (!EventAuthorizer::ownsOrSuper($user, isset($event['owner']) ? (string)$event['owner'] : null)) {
            return null;
        }

        $rows = $this->signupRepository()->attendeesFor($key);
        foreach ($rows as &$row) {
            $row['fullname'] = $this->resolveFullName($row['username']);
        }
        unset($row);
        return $rows;
    }

    /** Best-effort full-name lookup via Grav's accounts; falls back to ''. */
    private function resolveFullName(string $username): string
    {
        try {
            $accounts = $this->grav['accounts'] ?? null;
            if ($accounts === null || !method_exists($accounts, 'load')) {
                return '';
            }
            $account = $accounts->load($username);
            if (!$account) {
                return '';
            }
            $name = '';
            if (method_exists($account, 'get')) {
                $name = (string)($account->get('fullname') ?? '');
            }
            if ($name === '' && isset($account->fullname)) {
                $name = (string)$account->fullname;
            }
            return $name;
        } catch (\Throwable $e) {
            return '';
        }
    }

    public function onTwigSiteVariables(): void
    {
        $page = $this->grav['page'] ?? null;
        if (!$page instanceof PageInterface) {
            return;
        }
        $template = $page->template();
        $twig = $this->grav['twig'];

        if (in_array($template, ['event_edit', 'event_delete'], true) && $this->currentEvent !== null) {
            $twig->twig_vars['em_event'] = $this->currentEvent;
            $twig->twig_vars['em_event_key'] = $this->currentKey;
        }

        // The inline card editor (event_create + event_edit) is a custom form,
        // not a Form-plugin form: inject its initial client state, computed from
        // the stored event (edit) and/or the stashed old input (repopulation
        // after a validation redirect). Create additionally gets the
        // pre-generated key (adopted by handleCreate so pre-save image uploads
        // land in the right folder).
        if ($template === 'event_create') {
            $twig->twig_vars['em_new_key'] = FormDataProvider::newEventKey();
            $twig->twig_vars['em_editor_state'] = FormDataProvider::editorState(null, FormDataProvider::allOldInput());
        } elseif ($template === 'event_edit' && $this->currentEvent !== null) {
            $twig->twig_vars['em_editor_state'] = FormDataProvider::editorState($this->currentEvent, FormDataProvider::allOldInput());
        }

        if ($template === 'event_dashboard') {
            $user = $this->grav['user'] ?? null;
            if ($user && $user->authenticated && $user->authorized) {
                $twig->twig_vars['em_events'] = $this->repository()->listFor($user);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private function repository(): EventRepository
    {
        if ($this->repository === null) {
            $this->repository = new EventRepository($this->grav);
        }
        return $this->repository;
    }

    private function auditLog(): AuditLog
    {
        return new AuditLog($this->grav);
    }

    /** Init a Page from a plugin-bundled markdown file (virtual route). */
    private function buildVirtualPage(string $file): ?PageInterface
    {
        $path = __DIR__ . '/pages/' . $file;
        if (!is_file($path)) {
            return null;
        }
        try {
            $page = new Page();
            $page->init(new \SplFileInfo($path));
            $page->slug(basename($this->grav['uri']->path()));
            return $page;
        } catch (\Throwable $e) {
            return null;
        }
    }

    /**
     * Container read of the FlagStore singleton — profile resolution stays
     * identical to the rest of the app. Fails open only if the feature-flags
     * plugin is missing/mis-registered (same posture as roadmap/bug-report).
     */
    private function featureEnabled(): bool
    {
        $store = $this->grav['feature_flags'] ?? null;
        if (!$store instanceof FlagStoreInterface) {
            return true;
        }
        return $store->isEnabled(FeatureFlag::EventManagement);
    }

    /**
     * RSVP gate: both event_rsvp AND event_management must be on (§3/§6).
     * Same fail-open-if-missing posture as featureEnabled().
     */
    private function rsvpFeatureEnabled(): bool
    {
        $store = $this->grav['feature_flags'] ?? null;
        if (!$store instanceof FlagStoreInterface) {
            return true;
        }
        return $store->isEnabled(FeatureFlag::EventRsvp)
            && $store->isEnabled(FeatureFlag::EventManagement);
    }

    /** The signup store, bound to user/data/flex-objects/event-signups.yaml. */
    private function signupRepository(): SignupRepository
    {
        $dir = $this->grav['locator']->findResource('user-data://flex-objects', true, true);
        if (!is_dir($dir)) {
            mkdir($dir, 0750, true);
        }
        return new SignupRepository($dir . '/event-signups.yaml');
    }

    /** The image store, bound to user/data/event-images/. */
    private function imageStore(): ImageStore
    {
        $dir = $this->grav['locator']->findResource('user-data://event-images', true, true);
        if (!is_dir($dir)) {
            mkdir($dir, 0750, true);
        }
        return new ImageStore($dir);
    }

    /**
     * Adopt the create form's pre-generated `ev_<hex>` key when it is
     * well-formed and not already an event (so pre-save image uploads keep
     * their folder); otherwise mint a fresh one.
     *
     * @param array<string,mixed> $data
     */
    private function adoptOrGenerateKey(array $data): string
    {
        $posted = trim((string)($data['key'] ?? ''));
        if ($posted !== ''
            && preg_match('/^ev_[a-f0-9]{16}$/', $posted)
            && $this->repository()->find($posted) === null) {
            return $posted;
        }
        return 'ev_' . bin2hex(random_bytes(8));
    }

    /**
     * Stream a stored event image (§5.3). Public — event details are public —
     * so no auth gate, but the feature flag still applies (off ⇒ natural 404)
     * and the key/filename are strictly validated (no traversal). Content-Type
     * is derived from magic bytes with X-Content-Type-Options: nosniff.
     */
    private function serveEventImage(string $key, string $file): void
    {
        if (!$this->rsvpFeatureEnabled()) {
            return; // natural themed 404 — no existence leak
        }
        $store = $this->imageStore();
        $path = $store->resolvePath($key, $file);
        if ($path === null) {
            return; // malformed or missing → natural 404
        }
        $mime = $store->detectMimeType($path);
        if ($mime === null || !in_array($mime, ImageStore::ALLOWED_MIME, true)) {
            return;
        }

        $response = new Response(
            200,
            [
                'Content-Type' => $mime,
                'Content-Length' => (string)filesize($path),
                'Cache-Control' => 'public, max-age=86400',
                'X-Content-Type-Options' => 'nosniff',
            ],
            (string)file_get_contents($path)
        );
        $this->grav->close($response);
    }

    /** True when the event's date is strictly before today in Europe/Copenhagen. */
    private function eventIsPast(array $event): bool
    {
        $date = trim((string)($event['event_date'] ?? ''));
        if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $date)) {
            return false; // unparseable date → don't block on it
        }
        $today = (new \DateTimeImmutable('now', new \DateTimeZone('Europe/Copenhagen')))->format('Y-m-d');
        return $date < $today;
    }

    /**
     * A same-origin local path from the Referer header, or $fallback. Guards
     * the no-JS PRG redirect against an open-redirect via a spoofed Referer.
     */
    private function safeReferer(string $fallback): string
    {
        $referer = (string)($_SERVER['HTTP_REFERER'] ?? '');
        if ($referer === '') {
            return $fallback;
        }
        $parts = parse_url($referer);
        if ($parts === false) {
            return $fallback;
        }
        $host = $parts['host'] ?? '';
        $selfHost = (string)($_SERVER['HTTP_HOST'] ?? '');
        if ($host !== '' && $host !== $selfHost) {
            return $fallback; // cross-origin referer — never redirect there
        }
        $path = $parts['path'] ?? '';
        if (!is_string($path) || !str_starts_with($path, '/')) {
            return $fallback;
        }
        return $path . (isset($parts['fragment']) ? '#' . $parts['fragment'] : '');
    }

    /**
     * Mount a plugin-bundled virtual page at the current route so a POST-only
     * endpoint (no page of its own) still fires onPageInitialized. The
     * contract handler terminates before render, so the page is never shown.
     */
    private function mountVirtualRoute(string $file): void
    {
        $page = $this->buildVirtualPage($file);
        if ($page === null) {
            return;
        }
        $grav = $this->grav;
        unset($grav['page']);
        $grav['page'] = static function () use ($page) {
            return $page;
        };
    }

    /**
     * Generic 404 leaking no feature name, route, or structure — identical
     * body to the roadmap/bug-report flag-disabled responses.
     */
    private function sendFlagDisabled404(): never
    {
        $response = new Response(
            404,
            ['Content-Type' => 'text/plain; charset=utf-8'],
            "Not Found\n"
        );
        $this->grav->close($response);
    }

    /** Error JSON + terminate — {"status":"error","data":{"error":msg}} (house shape). */
    private function sendError(int $status, string $message): never
    {
        $this->sendJson(['status' => 'error', 'data' => ['error' => $message]], $status);
    }

    private function sendJson(array $data, int $status = 200): never
    {
        $body = json_encode($data, JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR);
        $response = new Response($status, ['Content-Type' => 'application/json; charset=utf-8'], $body);
        $this->grav->close($response);
    }
}
