<?php
/**
 * Account Manager Plugin for Byværkstederne
 *
 * Account self-service (account_self_service_specification.md): gives a
 * logged-in member a /konto page carrying every user-centric operation —
 * change email (verify-new-address-first), change password, edit display
 * name, see current roles, request access rights, and delete the account
 * (soft delete → 30-day regret window → scheduled hard delete).
 *
 * Handles:
 *  - The mutating POST contract on /konto/<action> (§4.3): feature flag →
 *    method → authn → CSRF → re-auth (where marked) → validation →
 *    mutation → audit → PRG redirect.
 *  - The account view model for account.html.twig (never exposes token
 *    material — only the pending address and expiry).
 *
 * Design notes:
 *  - Mirrors the event-manager plugin's contract skeleton: POSTs are
 *    intercepted in onPageInitialized at priority 5 — after the login
 *    plugin's page-access gate (priority 10) and the feature-flags page
 *    gate (100000). The /konto/<action> subpaths carry no pages, so a
 *    non-POST request to them falls through to Grav's natural themed 404.
 *  - Boundary rule (spec §3): NO login/email plugin PHP is modified. The
 *    plugin only consumes their public services ($grav['accounts'],
 *    $grav['login'], $grav['Email']) and Grav events.
 *  - Account writes go through AccountStore, which serializes every
 *    read-modify-write under a plugin-wide advisory lock and saves via the
 *    supported $grav['accounts'] API (never raw YAML rewrites).
 */

namespace Grav\Plugin;

use Grav\Common\Grav;
use Grav\Common\Page\Interfaces\PageInterface;
use Grav\Common\Plugin;
use Grav\Common\User\Interfaces\UserInterface;
use Grav\Common\Utils;
use Grav\Framework\Psr7\Response;
use Grav\Plugin\AccountManager\AccountAuditLog;
use Grav\Plugin\AccountManager\AccountStore;
use Grav\Plugin\AccountManager\AccountValidator;
use Grav\Plugin\FeatureFlags\FeatureFlag;
use Grav\Plugin\FeatureFlags\FlagStoreInterface;

class AccountManagerPlugin extends Plugin
{
    private const ROUTE_BASE = '/konto';

    /**
     * The mutating POST endpoints (spec §4.3), keyed by the path segment
     * under /konto/. Every entry runs the full contract order:
     *
     *   flag → POST → authn → CSRF (per-action nonce) → re-auth (where
     *   marked) → validate → mutate → audit → PRG back to /konto#section.
     *
     * Per-action nonce strings follow the roadmap plugin's precedent: a
     * nonce minted for one form is not valid on another endpoint. There is
     * NO single-use nonce blacklist — Utils::verifyNonce() is the sole
     * CSRF gate (see decisions/ADR-001 and the CLAUDE.md vote-nonce
     * gotcha).
     */
    private const POST_ACTIONS = [
        'change-fullname' => ['nonce' => 'account-fullname', 'reauth' => false, 'section' => 'name'],
        'change-password' => ['nonce' => 'account-password', 'reauth' => true, 'section' => 'password'],
    ];

    private ?AccountStore $store = null;

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
     * event-manager and feature-flags plugins (no composer step at deploy).
     */
    private function registerAutoloader(): void
    {
        static $registered = false;
        if ($registered) {
            return;
        }
        $registered = true;

        $prefix = 'Grav\\Plugin\\AccountManager\\';
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
        if (!$this->config->get('plugins.account-manager.enabled')) {
            return;
        }
        if ($this->isAdmin()) {
            return;
        }

        $this->enable([
            // Mutating-POST contract (§4.3). Priority 5: after the login
            // plugin's page-access gate (10) and the feature-flags page gate
            // (100000), before the Form plugin's own processing (0).
            'onPageInitialized' => ['onPageInitialized', 5],
            'onTwigSiteVariables' => ['onTwigSiteVariables', 0],
        ]);
    }

    // -------------------------------------------------------------------------
    // Mutating-POST contract (§4.3)
    // -------------------------------------------------------------------------

    public function onPageInitialized(): void
    {
        if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
            return;
        }

        $action = $this->postActionForPath($this->grav['uri']->path());
        if ($action === null) {
            return;
        }
        $spec = self::POST_ACTIONS[$action];

        // 1. Feature-flag gate — before any payload parsing. A disabled
        //    feature never processes a POST and never reveals it exists.
        if (!$this->featureEnabled()) {
            $this->sendFlagDisabled404();
        }

        // 2. Method — POST, matched above.

        // 3. Authentication. The /konto/<action> subpaths carry no pages, so
        //    no page-access frontmatter applies — this check IS the boundary.
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorized) {
            $this->sendError(401, 'Ikke autoriseret. Log ind for at administrere din konto.');
        }

        // 4. CSRF — per-action nonce (house gotcha: nonces bind to the
        //    User-Agent, so the minting page and the POST must share one).
        $nonce = (string)($_POST['account-nonce'] ?? '');
        if ($nonce === '' || !Utils::verifyNonce($nonce, $spec['nonce'])) {
            $this->sendError(403, 'Ugyldig sikkerhedstoken. Genindlæs siden og prøv igen.');
        }

        // 5. Re-auth (current password) for the sensitive endpoints —
        //    verified against a FRESHLY LOADED account, never the session
        //    object, so a stale session can never satisfy re-auth.
        if ($spec['reauth']) {
            $this->requireCurrentPassword($user->username, $spec['section']);
        }

        switch ($action) {
            case 'change-fullname':
                $this->handleChangeFullname($user);
                break;
            case 'change-password':
                $this->handleChangePassword($user);
                break;
        }
    }

    /** Map a request path to a §4.3 POST action segment. */
    private function postActionForPath(string $path): ?string
    {
        if (!str_starts_with($path, self::ROUTE_BASE . '/')) {
            return null;
        }
        $segment = substr($path, strlen(self::ROUTE_BASE) + 1);
        return array_key_exists($segment, self::POST_ACTIONS) ? $segment : null;
    }

    // -------------------------------------------------------------------------
    // Handlers
    // -------------------------------------------------------------------------

    private function handleChangeFullname(UserInterface $user): void
    {
        $result = AccountValidator::fullname(
            (string)($_POST['fullname'] ?? ''),
            (int)$this->config->get('plugins.account-manager.fullname.max_length', 80)
        );
        if ($result['errors'] !== []) {
            $this->failWith(400, $result['errors'], 'name');
        }
        $fullname = $result['value'];

        try {
            $this->store()->mutate($user->username, static function (UserInterface $account) use ($fullname): void {
                $account->set('fullname', $fullname);
            });
        } catch (\Throwable $e) {
            error_log('account-manager change_fullname failed: ' . $e->getMessage());
            $this->failWith(500, ['Navnet kunne ikke gemmes. Prøv igen.'], 'name');
        }

        // Refresh the live session user so the header chip reflects the new
        // name on the very next render (the session object is otherwise a
        // stale copy of the account file).
        $user->set('fullname', $fullname);

        $this->auditLog()->append('change_fullname', $user->username);
        $this->redirectWithFlash('Dit navn er opdateret.', 'name');
    }

    private function handleChangePassword(UserInterface $user): void
    {
        $result = AccountValidator::password(
            (string)($_POST['password1'] ?? ''),
            (string)($_POST['password2'] ?? ''),
            (string)$this->config->get('system.pwd_regex', '')
        );
        if ($result['errors'] !== []) {
            $this->failWith(400, $result['errors'], 'password');
        }
        $password = $result['value'];

        try {
            $this->store()->mutate($user->username, static function (UserInterface $account) use ($password): void {
                // save() hashes `password` into `hashed_password` and strips
                // the plaintext — the same supported path the login plugin's
                // own reset flow uses.
                $account->set('password', $password);
            });
        } catch (\Throwable $e) {
            error_log('account-manager change_password failed: ' . $e->getMessage());
            $this->failWith(500, ['Adgangskoden kunne ikke gemmes. Prøv igen.'], 'password');
        }

        $this->auditLog()->append('change_password', $user->username);
        $this->redirectWithFlash('Din adgangskode er ændret.', 'password');
    }

    // -------------------------------------------------------------------------
    // Twig view model
    // -------------------------------------------------------------------------

    public function onTwigSiteVariables(): void
    {
        $page = $this->grav['page'] ?? null;
        if (!$page instanceof PageInterface || $page->template() !== 'account') {
            return;
        }
        if (!$this->featureEnabled()) {
            return;
        }
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorized) {
            return;
        }

        $account = $this->store()->read($user->username);
        if ($account === null) {
            return;
        }

        $this->grav['twig']->twig_vars['am_account'] = $this->buildViewModel($account);
    }

    /**
     * The template's read model. Token material (hashes) never leaves the
     * account file — only the pending address and its expiry are exposed.
     *
     * @return array<string,mixed>
     */
    private function buildViewModel(UserInterface $account): array
    {
        $groups = (array)($account->get('groups') ?? []);

        // Baseline "Medlem" plus each group's readableName (spec §2.6).
        $roles = ['Medlem'];
        foreach ($groups as $group) {
            $roles[] = (string)($this->config->get("groups.{$group}.readableName") ?: $group);
        }

        $pending = $account->get('pending_email');
        $pendingEmail = null;
        if (is_array($pending) && !empty($pending['address'])) {
            $pendingEmail = [
                'address' => (string)$pending['address'],
                'expires_at' => (string)($pending['expires_at'] ?? ''),
            ];
        }

        // Derived access-request state (spec §4.2): member in the group ⇒
        // granted; `access_request` present ⇒ pending; else none.
        $accessRequest = null;
        $request = $account->get('access_request');
        if (is_array($request) && !empty($request['role']) && !in_array($request['role'], $groups, true)) {
            $accessRequest = [
                'role' => (string)$request['role'],
                'role_label' => (string)($this->config->get('groups.' . $request['role'] . '.readableName') ?: $request['role']),
                'requested_at' => (string)($request['requested_at'] ?? ''),
            ];
        }

        $requestable = [];
        foreach ((array)$this->config->get('plugins.account-manager.access_request.requestable_roles', []) as $role) {
            if (!in_array($role, $groups, true)) {
                $requestable[$role] = (string)($this->config->get("groups.{$role}.readableName") ?: $role);
            }
        }

        $windowDays = (int)$this->config->get('plugins.account-manager.deletion.window_days', 30);

        return [
            'username' => (string)$account->get('username', ''),
            'fullname' => (string)$account->get('fullname', ''),
            'email' => (string)$account->get('email', ''),
            'roles' => $roles,
            'pending_email' => $pendingEmail,
            'access_request' => $accessRequest,
            'requestable_roles' => $requestable,
            'deletion_window_days' => $windowDays,
            'hard_delete_preview' => $this->danishDate(time() + $windowDays * 86400),
        ];
    }

    /** "7. august 2026" — Danish long date without relying on intl locales. */
    private function danishDate(int $timestamp): string
    {
        static $months = [
            1 => 'januar', 'februar', 'marts', 'april', 'maj', 'juni',
            'juli', 'august', 'september', 'oktober', 'november', 'december',
        ];
        $day = (int)gmdate('j', $timestamp);
        $month = $months[(int)gmdate('n', $timestamp)];
        $year = gmdate('Y', $timestamp);
        return "{$day}. {$month} {$year}";
    }

    // -------------------------------------------------------------------------
    // Contract helpers
    // -------------------------------------------------------------------------

    /**
     * §4.3 re-auth step: the submitted current password must verify against
     * a freshly loaded account. UserTrait::authenticate() is timing-safe and
     * side-effect free for hashed-password accounts.
     */
    private function requireCurrentPassword(string $username, string $section): void
    {
        $account = $this->store()->read($username);
        $submitted = (string)($_POST['current_password'] ?? '');
        if ($account === null || $submitted === '' || !$account->authenticate($submitted)) {
            $this->failWith(403, ['Forkert adgangskode.'], $section);
        }
    }

    /**
     * Failure split (event-manager precedent): a browser form POST gets the
     * friendly PRG path — errors flashed, 303 back to the section; every
     * other caller gets the contract's bare status with JSON errors.
     *
     * @param list<string> $messages
     */
    private function failWith(int $status, array $messages, string $section): never
    {
        if (str_contains((string)($_SERVER['HTTP_ACCEPT'] ?? ''), 'text/html')) {
            $flash = $this->grav['messages'];
            foreach ($messages as $message) {
                $flash->add($message, 'error');
            }
            $this->grav->redirect(self::ROUTE_BASE . '#' . $section, 303);
        }
        $this->sendJson(['status' => 'error', 'data' => ['errors' => $messages]], $status);
    }

    /** §4.3 PRG: flash + 303 redirect back to the /konto section. */
    private function redirectWithFlash(string $message, string $section): never
    {
        $this->grav['messages']->add($message, 'success');
        $this->grav->redirect(self::ROUTE_BASE . '#' . $section, 303);
        exit; // @phpstan-ignore-line — redirect() exits; belt for static analysis
    }

    private function store(): AccountStore
    {
        if ($this->store === null) {
            $this->store = new AccountStore($this->grav);
        }
        return $this->store;
    }

    private function auditLog(): AccountAuditLog
    {
        return new AccountAuditLog($this->grav);
    }

    /**
     * Container read of the FlagStore singleton — profile resolution stays
     * identical to the rest of the app. Fails open only if the feature-flags
     * plugin is missing/mis-registered (same posture as event-manager).
     */
    private function featureEnabled(): bool
    {
        $store = $this->grav['feature_flags'] ?? null;
        if (!$store instanceof FlagStoreInterface) {
            return true;
        }
        return $store->isEnabled(FeatureFlag::AccountSelfService);
    }

    /**
     * Generic 404 leaking no feature name, route, or structure — identical
     * body to the event-manager/roadmap flag-disabled responses.
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

    /** Error JSON + terminate — {"status":"error","data":{...}} (house shape). */
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
