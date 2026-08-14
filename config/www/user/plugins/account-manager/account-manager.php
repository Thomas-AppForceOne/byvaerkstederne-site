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

use Grav\Common\Data\ValidationException;
use Grav\Common\File\CompiledYamlFile;
use Grav\Common\Grav;
use Grav\Common\Page\Interfaces\PageInterface;
use Grav\Common\Page\Page;
use Grav\Common\Plugin;
use Grav\Common\User\Interfaces\UserInterface;
use Grav\Common\Utils;
use Grav\Framework\Psr7\Response;
use Grav\Plugin\AccountManager\AccountAuditLog;
use Grav\Plugin\AccountManager\AccountEmail;
use Grav\Plugin\AccountManager\AccountStore;
use Grav\Plugin\AccountManager\AccountValidator;
use Grav\Plugin\AccountManager\PasswordPolicy;
use Grav\Plugin\FeatureFlags\FeatureFlag;
use Grav\Plugin\FeatureFlags\FlagStoreInterface;
use RocketTheme\Toolbox\Event\Event;

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
        'request-email-change' => ['nonce' => 'account-email-change', 'reauth' => true, 'section' => 'email'],
        'resend-email-change' => ['nonce' => 'account-email-resend', 'reauth' => false, 'section' => 'email'],
        'cancel-email-change' => ['nonce' => 'account-email-cancel', 'reauth' => false, 'section' => 'email'],
        'request-access' => ['nonce' => 'account-access-request', 'reauth' => false, 'section' => 'roles'],
        'cancel-access-request' => ['nonce' => 'account-access-cancel', 'reauth' => false, 'section' => 'roles'],
        'request-deletion' => ['nonce' => 'account-deletion', 'reauth' => true, 'section' => 'delete'],
    ];

    /** GET route segment for the email-change confirmation link (token+user Grav params). */
    private const CONFIRM_EMAIL_PATH = self::ROUTE_BASE . '/confirm-email-change';

    /** Mail-link base for the admin approve/reject/switch-account routes. */
    private const ACCESS_REQUEST_BASE = self::ROUTE_BASE . '/access-request/';

    /**
     * The wrong-account page's only action: end the current session and come
     * back through login. POST-only and nonce-gated, so that opening a mail
     * link can never terminate a member's session on its own — a plain GET
     * side effect here would let any page force-log-out any visitor with an
     * <img src="…/approve?token=…">.
     */
    private const ACCESS_REQUEST_SWITCH_PATH = self::ACCESS_REQUEST_BASE . 'switch-account';
    private const ACCESS_REQUEST_SWITCH_NONCE = 'account-access-switch';

    /** The §6 neutral response — identical for available and occupied targets. */
    private const EMAIL_CHANGE_NEUTRAL_FLASH = 'Hvis adressen kan bruges, har vi sendt en bekræftelse til den nye adresse.';

    /** The §6 generic confirm-link failure — identical for every failure cause. */
    private const CONFIRM_FAILURE_FLASH = 'Linket er ugyldigt eller udløbet.';

    private ?AccountStore $store = null;

    /** @var array<string,mixed>|null view model for access-request-result.html.twig */
    private ?array $accessRequestResult = null;

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

        // Always enable onPageInitialized to handle admin access-request endpoints
        // (GET/POST on /konto/access-request/*, returning early); disable
        // other hooks in admin mode.
        $this->enable([
            'onPageInitialized' => ['onPageInitialized', 5],
        ]);

        // Admin mode only gets the access-request endpoint hook; skip the rest.
        if ($this->isAdmin()) {
            return;
        }

        // Member-facing hooks (disabled in admin mode).
        $this->enable([
            // Mutating-POST contract (§4.3). Priority 5: after the login
            // plugin's page-access gate (10) and the feature-flags page gate
            // (100000), before the Form plugin's own processing (0).
            'onTwigTemplatePaths' => ['onTwigTemplatePaths', 0],
            'onTwigSiteVariables' => ['onTwigSiteVariables', 0],
            // Reinstatement-on-login (§2.8). Priority 0: after the login
            // plugin's own userLogin (10) has placed the user in the session.
            // Deliberately NOT flag-gated: were the flag turned off while
            // deletion markers exist, a gated hook would strand members in an
            // unrecoverable pending-deletion state while the purge job still
            // deletes them. With the flag off on a clean tier this is an
            // exact no-op (no marker can be created).
            'onUserLogin' => ['onUserLogin', 0],
            // Daily §7 purge job (fired by `bin/grav scheduler` under cron;
            // see deploy/SCHEDULER.md). Unflagged like the login hook: a
            // member who consented to deletion must be deleted on schedule.
            'onSchedulerInitialized' => ['onSchedulerInitialized', 0],
            // Password blocklist on the REGISTRATION form. Unflagged: the
            // rule is about credential quality, not about a feature — and a
            // tier with the self-service flag off still registers members.
            'onFormValidationProcessed' => ['onFormValidationProcessed', 0],
        ]);
    }

    /**
     * Reject a blocklisted password on the registration form.
     *
     * The forms plugin fires this inside its own try block, so a
     * ValidationException here surfaces as a normal Danish field error rather
     * than a 500 — and it lands on the SAME submission as the length rule
     * from system.pwd_regex, which the plugin has already applied.
     *
     * Registration is the only form handled here; the /konto password change
     * calls PasswordPolicy directly (handleChangePassword), and Grav's own
     * password-RESET form never reaches the forms plugin at all — that gap is
     * documented on PasswordPolicy.
     */
    public function onFormValidationProcessed(Event $event): void
    {
        $form = $event['form'] ?? null;
        if ($form === null || !method_exists($form, 'value')) {
            return;
        }
        $name = method_exists($form, 'getName') ? (string)$form->getName() : '';
        if ($name !== 'registration') {
            return;
        }

        $password = (string)($form->value('password1') ?? '');
        if ($password === '') {
            return;
        }

        $policy = new PasswordPolicy($this->grav);
        if ($policy->blockedTerm($password) === null) {
            return;
        }

        // The forms plugin's catch assigns the exception's message to the
        // form (Form::$message), so throwing IS how a listener reports the
        // rejection — Form::setError() is protected and not ours to call.
        throw new ValidationException($policy->rejectionMessage());
    }

    // -------------------------------------------------------------------------
    // Mutating-POST contract (§4.3)
    // -------------------------------------------------------------------------

    /** Register the plugin's templates/ dir (transactional email twigs). */
    public function onTwigTemplatePaths(): void
    {
        $this->grav['twig']->twig_paths[] = __DIR__ . '/templates';
    }

    public function onPageInitialized(): void
    {
        // Request hygiene FIRST — before any dispatch decision, so every
        // account read later in this request (ours or another plugin's)
        // reflects the on-disk file, not the session's snapshot.
        $this->freeStaleSessionAccountInstance();

        $method = $_SERVER['REQUEST_METHOD'] ?? '';

        // The email-change confirmation link (§4.3 #2) — the token is the
        // credential; no session is required.
        if ($method === 'GET' && $this->grav['uri']->path() === self::CONFIRM_EMAIL_PATH) {
            if (!$this->featureEnabled()) {
                $this->sendFlagDisabled404();
            }
            $this->handleConfirmEmailChange();
        }

        // Admin approval/rejection of access requests — token in query string,
        // admin auth required. GET is accepted because the admin mail embeds
        // plain links (activation-link precedent); the handler already reads
        // both $_POST and $_GET. Lives under /konto/ (NOT /admin/) because
        // the Grav admin panel owns /admin/* on every tier and swallows the
        // request before this hook ever runs.
        if (($method === 'POST' || $method === 'GET') && str_starts_with($this->grav['uri']->path(), '/konto/access-request/')) {
            $this->handleAdminAccessRequest();
            return;
        }

        if ($method !== 'POST') {
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

        // 5. Throttle the mail-sending endpoints (§6) BEFORE re-auth: every
        //    POST burns the per-IP + per-account budget, so both mail
        //    bombing and password guessing through this surface are bounded.
        if ($action === 'request-email-change' || $action === 'resend-email-change') {
            $this->throttleEmailChange($user->username, $spec['section']);
        }

        // 6. Re-auth (current password) for the sensitive endpoints —
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
            case 'request-email-change':
                $this->handleRequestEmailChange($user);
                break;
            case 'resend-email-change':
                $this->handleResendEmailChange($user);
                break;
            case 'cancel-email-change':
                $this->handleCancelEmailChange($user);
                break;
            case 'request-access':
                $this->handleRequestAccess($user);
                break;
            case 'cancel-access-request':
                $this->handleCancelAccessRequest($user);
                break;
            case 'request-deletion':
                $this->handleRequestDeletion($user);
                break;
        }
    }

    /**
     * Session-epoch read repair. In an authenticated request, the static
     * per-path CompiledYamlFile registry can hold the member's account file
     * pre-populated with the SESSION's snapshot instead of disk content —
     * observed as a backdated token expiry being served with its original
     * value while file_get_contents() of the same path returned the fresh
     * bytes. free() unregisters the poisoned instance, so every subsequent
     * $grav['accounts']->load() in this request builds a fresh instance
     * from disk. AccountStore::read() keeps its own free-and-reload as a
     * second belt for its security checks.
     *
     * Deliberately avoids $grav['accounts']->load() itself (the source
     * guard in tests/anonymous/account-access.js confines that call to
     * AccountStore) and never lets hygiene break a request.
     */
    private function freeStaleSessionAccountInstance(): void
    {
        try {
            $user = $this->grav['user'] ?? null;
            $username = $user && $user->authenticated ? (string)$user->username : '';
            if ($username === '') {
                return;
            }
            $path = $this->grav['locator']->findResource('account://' . $username . YAML_EXT);
            if (is_string($path)) {
                CompiledYamlFile::instance($path)->free();
            }
        } catch (\Throwable $e) {
            error_log('account-manager session-instance hygiene failed: ' . $e->getMessage());
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

        // The rule system.pwd_regex cannot express: a guessable-word blocklist.
        // Checked after the regex so the member gets the length message first
        // when both apply.
        $policy = new PasswordPolicy($this->grav);
        if ($policy->blockedTerm($password) !== null) {
            $this->failWith(400, [$policy->rejectionMessage()], 'password');
        }

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
    // Email change (§6) — verify-new-address-first
    // -------------------------------------------------------------------------

    private function handleRequestEmailChange(UserInterface $user): void
    {
        $result = AccountValidator::email((string)($_POST['new_email'] ?? ''));
        if ($result['errors'] !== []) {
            $this->failWith(400, $result['errors'], 'email');
        }
        $newAddress = $result['value'];
        $account = $this->store()->read($user->username);
        if ($account === null) {
            $this->failWith(500, ['Noget gik galt. Prøv igen.'], 'email');
        }

        // Requesting one's own current address is a no-op behind the same
        // neutral response — nothing observable to distinguish.
        if (strcasecmp($newAddress, (string)$account->email) === 0) {
            $this->auditLog()->append('request_email_change', $user->username);
            $this->redirectWithFlash(self::EMAIL_CHANGE_NEUTRAL_FLASH, 'email');
        }

        // No-enumeration branch (§6): an occupied address gets the identical
        // neutral flash; its existing owner receives an informational mail
        // instead of a confirmation link. No pending state is written.
        $existing = $this->grav['accounts']->find($newAddress, ['email']);
        if ($existing && $existing->exists() && $existing->username !== $user->username) {
            try {
                $this->accountEmail()->sendEmailChangeOccupied($newAddress);
            } catch (\Throwable $e) {
                error_log('account-manager occupied-address mail failed: ' . $e->getMessage());
            }
            $this->auditLog()->append('request_email_change', $user->username);
            $this->redirectWithFlash(self::EMAIL_CHANGE_NEUTRAL_FLASH, 'email');
        }

        // Token: random 256-bit, stored only as a hash, expiring, single-use,
        // invalidated by any newer request (this write overwrites).
        $token = bin2hex(random_bytes(32));
        $ttlHours = (int)$this->config->get('plugins.account-manager.email_change.token_ttl_hours', 24);
        $pending = [
            'address' => $newAddress,
            'token_hash' => hash('sha256', $token),
            'expires_at' => gmdate('Y-m-d\TH:i:s\Z', time() + $ttlHours * 3600),
        ];

        try {
            $this->store()->mutate($user->username, static function (UserInterface $acct) use ($pending): void {
                $acct->set('pending_email', $pending);
            });
        } catch (\Throwable $e) {
            error_log('account-manager request_email_change failed: ' . $e->getMessage());
            $this->failWith(500, ['Noget gik galt. Prøv igen.'], 'email');
        }

        try {
            $this->accountEmail()->sendEmailChangeConfirm($account, $newAddress, $token, $ttlHours);
            $this->accountEmail()->sendEmailChangeNotice($account);
        } catch (\Throwable $e) {
            // The pending state is stored — the member can resend. The UI
            // response stays neutral (no-enumeration).
            error_log('account-manager email-change mail failed: ' . $e->getMessage());
        }

        $this->auditLog()->append('request_email_change', $user->username);
        $this->redirectWithFlash(self::EMAIL_CHANGE_NEUTRAL_FLASH, 'email');
    }

    /** GET /konto/confirm-email-change/token:<t>/user:<u> — token is the credential. */
    private function handleConfirmEmailChange(): void
    {
        $uri = $this->grav['uri'];
        $token = (string)$uri->param('token');
        $username = (string)$uri->param('user');

        $account = ($username !== '' && preg_match('/^[a-z0-9_-]{1,32}$/', $username))
            ? $this->store()->read($username)
            : null;
        $pending = $account?->get('pending_email');

        $valid = is_array($pending)
            && $token !== ''
            && !empty($pending['token_hash'])
            && hash_equals((string)$pending['token_hash'], hash('sha256', $token))
            && !empty($pending['expires_at'])
            && strtotime((string)$pending['expires_at']) >= time();

        if (!$valid) {
            // One generic failure for every cause — unknown user, no pending
            // change, wrong/reused token, expired token (§6).
            $this->confirmRedirect(self::CONFIRM_FAILURE_FLASH, 'error');
        }

        $oldAddress = (string)$account->email;
        $newAddress = (string)$pending['address'];

        try {
            $this->store()->mutate($username, static function (UserInterface $acct) use ($newAddress): void {
                $acct->set('email', $newAddress);
                $acct->undef('pending_email'); // single-use: consumed here
            });
        } catch (\Throwable $e) {
            error_log('account-manager confirm_email_change failed: ' . $e->getMessage());
            $this->confirmRedirect(self::CONFIRM_FAILURE_FLASH, 'error');
        }

        // Keep a live session for the same member coherent.
        $sessionUser = $this->grav['user'] ?? null;
        if ($sessionUser && $sessionUser->authenticated && $sessionUser->username === $username) {
            $sessionUser->set('email', $newAddress);
        }

        try {
            $this->accountEmail()->sendEmailChangeComplete($oldAddress, $this->store()->read($username));
        } catch (\Throwable $e) {
            error_log('account-manager email-change completion mail failed: ' . $e->getMessage());
        }

        $this->auditLog()->append('confirm_email_change', $username);
        $this->confirmRedirect('Din e-mailadresse er opdateret.', 'success');
    }

    private function handleResendEmailChange(UserInterface $user): void
    {
        $account = $this->store()->read($user->username);
        $pending = $account?->get('pending_email');
        if (!is_array($pending) || empty($pending['address'])) {
            $this->failWith(400, ['Der er ingen afventende e-mailændring.'], 'email');
        }

        // Re-mint: a fresh token + expiry replaces (and invalidates) the old.
        $token = bin2hex(random_bytes(32));
        $ttlHours = (int)$this->config->get('plugins.account-manager.email_change.token_ttl_hours', 24);
        $pending['token_hash'] = hash('sha256', $token);
        $pending['expires_at'] = gmdate('Y-m-d\TH:i:s\Z', time() + $ttlHours * 3600);

        try {
            $this->store()->mutate($user->username, static function (UserInterface $acct) use ($pending): void {
                $acct->set('pending_email', $pending);
            });
            $this->accountEmail()->sendEmailChangeConfirm($account, (string)$pending['address'], $token, $ttlHours);
        } catch (\Throwable $e) {
            error_log('account-manager resend_email_change failed: ' . $e->getMessage());
            $this->failWith(500, ['Noget gik galt. Prøv igen.'], 'email');
        }

        $this->auditLog()->append('resend_email_change', $user->username);
        $this->redirectWithFlash('Vi har sendt et nyt bekræftelseslink.', 'email');
    }

    private function handleCancelEmailChange(UserInterface $user): void
    {
        try {
            $this->store()->mutate($user->username, static function (UserInterface $acct): void {
                $acct->undef('pending_email');
            });
        } catch (\Throwable $e) {
            error_log('account-manager cancel_email_change failed: ' . $e->getMessage());
            $this->failWith(500, ['Noget gik galt. Prøv igen.'], 'email');
        }

        $this->auditLog()->append('cancel_email_change', $user->username);
        $this->redirectWithFlash('E-mailændringen er annulleret.', 'email');
    }

    /**
     * §6 throttle — reuses the login plugin's rate-limiter primitives (the
     * registration-throttle pattern; that plugin itself is untouched).
     * Every POST registers against BOTH buckets before the check, so the
     * budget bounds mail volume and password guessing alike.
     */
    private function throttleEmailChange(string $username, string $section): void
    {
        $login = $this->grav['login'] ?? null;
        if ($login === null) {
            return; // login plugin is a declared dependency; defensive only
        }

        $cfg = (array)$this->config->get('plugins.account-manager.email_change', []);
        $ipKey = $login->getIpKey();

        $ipLimiter = $login->getRateLimiter(
            'account_email_change_ip',
            (int)($cfg['ip_max'] ?? 10),
            (int)($cfg['ip_interval'] ?? 60)
        );
        $ipLimiter->registerRateLimitedAction($ipKey, 'ip');

        $userLimiter = $login->getRateLimiter(
            'account_email_change_user',
            (int)($cfg['account_max'] ?? 5),
            (int)($cfg['account_interval'] ?? 60)
        );
        $userLimiter->registerRateLimitedAction($username, 'username');

        if ($ipLimiter->isRateLimited($ipKey, 'ip') || $userLimiter->isRateLimited($username, 'username')) {
            $this->failWith(429, ['For mange forsøg. Prøv igen senere.'], $section);
        }
    }

    /**
     * PRG for the confirm-link GET: back to /konto for a live session,
     * otherwise to the login page (where the flash renders in the card).
     */
    private function confirmRedirect(string $message, string $scope): never
    {
        $this->grav['messages']->add($message, $scope);
        $user = $this->grav['user'] ?? null;
        $target = ($user && $user->authenticated && $user->authorized)
            ? self::ROUTE_BASE . '#email'
            : '/login';
        $this->grav->redirect($target, 303);
        exit; // @phpstan-ignore-line — redirect() exits; belt for static analysis
    }

    /**
     * Register the daily purge job with Grav's scheduler (§4.1). The
     * scheduler itself is cron-driven (`bin/grav scheduler` every 15 min —
     * deploy/SCHEDULER.md); PurgeService is idempotent, so granularity is
     * irrelevant. `bin/plugin account-manager purge-deleted` wraps the same
     * service for tests and manual runs.
     *
     * @param \RocketTheme\Toolbox\Event\Event $event
     */
    public function onSchedulerInitialized($event): void
    {
        $scheduler = $event['scheduler'];
        $job = $scheduler->addFunction(
            'Grav\\Plugin\\AccountManager\\PurgeService::runScheduled',
            [],
            'account-manager-purge'
        );
        $job->at('0 3 * * *');

        // Privilege-escalation watch (site-side backstop). Runs in-process
        // under `bin/grav scheduler`, so it inherits whatever environment the
        // cron entry resolved — which is why that entry MUST carry
        // `--env <tier-host>`, or the alert is composed and delivered
        // nowhere. See deploy/SCHEDULER.md.
        $watch = $scheduler->addFunction(
            'Grav\\Plugin\\AccountManager\\SuperWatch::runScheduled',
            [],
            'account-manager-super-watch'
        );
        $watch->at('*/30 * * * *');
    }

    // -------------------------------------------------------------------------
    // Deletion lifecycle (§2.8/§7) — soft delete, 30-day regret window
    // -------------------------------------------------------------------------

    private function handleRequestDeletion(UserInterface $user): void
    {
        // Explicit confirmation on top of re-auth (§4.3) — validated
        // server-side, the checkbox is never the boundary.
        if ((string)($_POST['confirm_deletion'] ?? '') !== '1') {
            $this->failWith(400, ['Du skal bekræfte, at kontoen slettes endeligt efter fristen.'], 'delete');
        }

        $username = (string)$user->username;
        $windowDays = (int)$this->config->get('plugins.account-manager.deletion.window_days', 30);
        $hardDeleteDate = $this->danishDate(time() + $windowDays * 86400);

        try {
            $this->store()->mutate($username, static function (UserInterface $acct): void {
                $acct->set('deletion_requested_at', gmdate('Y-m-d\TH:i:s\Z'));
            });
        } catch (\Throwable $e) {
            error_log('account-manager request_deletion failed: ' . $e->getMessage());
            $this->failWith(500, ['Noget gik galt. Prøv igen.'], 'delete');
        }

        $this->auditLog()->append('request_deletion', $username);

        // Member email with the exact hard-delete date and the reinstatement
        // rule — sent while the account address is still current.
        try {
            $account = $this->store()->read($username);
            if ($account !== null) {
                $this->accountEmail()->sendDeletionRequested($account, $hardDeleteDate, $windowDays);
            }
        } catch (\Throwable $e) {
            error_log('account-manager deletion-requested mail failed: ' . $e->getMessage());
        }

        // The member was just PROMISED a hard-delete date; without a wired
        // cron that promise is silently broken (retention past the stated
        // date). Fail loud the moment the obligation becomes concrete.
        $this->warnIfSchedulerUnwired($hardDeleteDate);

        // Terminate the session AND every remember-me token (§2.8). The
        // login plugin's own logout handler only cleans triplets when the
        // remember-me cookie authenticates, so the explicit clean comes
        // first; logout() then fires onUserLogout (cookie cleared, session
        // invalidated and restarted).
        $login = $this->grav['login'];
        try {
            $login->rememberMe()->getStorage()->cleanAllTriplets($username);
        } catch (\Throwable $e) {
            error_log('account-manager remember-me invalidation failed: ' . $e->getMessage());
        }
        $login->logout(['remember_me' => true]);

        // Flash lands in the FRESH session created by the logout handler.
        $this->grav['messages']->add(
            "Din konto er markeret til sletning. Den slettes endeligt den {$hardDeleteDate} — log ind inden da for at fortryde.",
            'success'
        );
        $this->grav->redirect('/', 303);
        exit; // @phpstan-ignore-line — redirect() exits; belt for static analysis
    }

    /**
     * Deletion promises require the cron-driven scheduler. If its heartbeat
     * (user/data/scheduler/last_run.txt, touched on every `bin/grav
     * scheduler` tick) is missing or older than 26 h, the tier's cron is
     * effectively unwired: log AND alert the admins — the one failure mode
     * of the unflagged purge design that code can catch is "flag turned on
     * without the operational wiring".
     */
    private function warnIfSchedulerUnwired(string $hardDeleteDate): void
    {
        try {
            $dir = $this->grav['locator']->findResource('user-data://scheduler');
            $heartbeat = is_string($dir) ? $dir . '/last_run.txt' : null;
            if ($heartbeat !== null && is_file($heartbeat) && time() - (int)filemtime($heartbeat) < 26 * 3600) {
                return; // scheduler ticked within the last cron day — wired
            }
            error_log(
                'account-manager: a deletion was requested but the Grav scheduler has no recent heartbeat — '
                . 'the promised hard delete will NOT run until cron is wired (deploy/SCHEDULER.md).'
            );
            $this->accountEmail()->sendOpsAlert(
                'Sletteanmodning uden aktiv planlægger',
                "Et medlem har anmodet om sletning af sin konto (lovet slettedato: {$hardDeleteDate}), "
                . 'men Grav-planlæggeren har ikke kørt inden for det seneste døgn på denne server. '
                . 'Sletningen sker IKKE, før cron-linjen er sat op — se deploy/SCHEDULER.md.'
            );
        } catch (\Throwable $e) {
            error_log('account-manager scheduler-heartbeat warning failed: ' . $e->getMessage());
        }
    }

    /**
     * Reinstatement (§2.8): a successful login inside the window clears the
     * deletion marker — the whole regret mechanism. Fired by the login
     * plugin's event chain; receives the freshly authenticated user.
     *
     * @param \RocketTheme\Toolbox\Event\Event $event
     */
    public function onUserLogin($event): void
    {
        $user = $event['user'] ?? null;
        if (!$user instanceof UserInterface) {
            return;
        }
        $marker = (string)($user->get('deletion_requested_at') ?? '');
        if ($marker === '') {
            return;
        }
        $username = (string)$user->username;

        try {
            $this->store()->mutate($username, static function (UserInterface $acct): void {
                $acct->undef('deletion_requested_at');
            });
        } catch (\Throwable $e) {
            error_log('account-manager reinstatement failed: ' . $e->getMessage());
            return;
        }

        // Keep the live session object coherent with the account file.
        $user->undef('deletion_requested_at');

        $this->auditLog()->append('reinstate', $username);

        try {
            $account = $this->store()->read($username);
            if ($account !== null) {
                $this->accountEmail()->sendAccountReinstated($account);
            }
        } catch (\Throwable $e) {
            error_log('account-manager reinstatement mail failed: ' . $e->getMessage());
        }

        $this->grav['messages']->add('Din konto er genaktiveret. Sletningen er fortrudt.', 'success');
    }

    // -------------------------------------------------------------------------
    // Access request (§8) — request-only; granting stays a manual super action
    // -------------------------------------------------------------------------

    private function handleRequestAccess(UserInterface $user): void
    {
        $role = (string)($_POST['role'] ?? '');
        $requestable = (array)$this->config->get('plugins.account-manager.access_request.requestable_roles', []);
        if (!in_array($role, $requestable, true)) {
            $this->failWith(400, ['Rollen kan ikke anmodes.'], 'roles');
        }

        $motivation = AccountValidator::motivation(
            (string)($_POST['motivation'] ?? ''),
            (int)$this->config->get('plugins.account-manager.access_request.motivation_max_length', 500)
        );
        if ($motivation['errors'] !== []) {
            $this->failWith(400, $motivation['errors'], 'roles');
        }

        $account = $this->store()->read($user->username);
        if ($account === null) {
            $this->failWith(500, ['Noget gik galt. Prøv igen.'], 'roles');
        }

        $groups = (array)($account->get('groups') ?? []);
        if (in_array($role, $groups, true)) {
            $this->failWith(400, ['Du har allerede denne rolle.'], 'roles');
        }
        if (is_array($account->get('access_request'))) {
            $this->failWith(400, ['Du har allerede en åben anmodning.'], 'roles');
        }

        // Cooldown after clearing (§8 / design note D5): the cancel endpoint
        // stamps access_request_cleared_at; re-requests wait it out.
        $clearedAt = (string)($account->get('access_request_cleared_at') ?? '');
        $cooldownHours = (int)$this->config->get('plugins.account-manager.access_request.cooldown_hours', 24);
        if ($clearedAt !== '' && strtotime($clearedAt) + $cooldownHours * 3600 > time()) {
            $this->failWith(429, ['Vent venligst, før du anmoder igen.'], 'roles');
        }

        // Generate approval token (128-bit random, stored as SHA-256 hash)
        $token = bin2hex(random_bytes(16));
        $tokenHash = hash('sha256', $token, false);
        $tokenExpiresAt = gmdate('Y-m-d\TH:i:s\Z', time() + 24 * 3600);

        $request = [
            'role' => $role,
            'motivation' => $motivation['value'],
            'requested_at' => gmdate('Y-m-d\TH:i:s\Z'),
            'token_hash' => $tokenHash,
            'token_expires_at' => $tokenExpiresAt,
        ];

        try {
            $this->store()->mutate($user->username, static function (UserInterface $acct) use ($request): void {
                $acct->set('access_request', $request);
                $acct->undef('access_request_cleared_at');
            });
        } catch (\Throwable $e) {
            error_log('account-manager request_access failed: ' . $e->getMessage());
            $this->failWith(500, ['Anmodningen kunne ikke gemmes. Prøv igen.'], 'roles');
        }

        $notified = true;
        try {
            $roleLabel = (string)($this->config->get("groups.{$role}.readableName") ?: $role);
            $this->accountEmail()->sendAccessRequestAdmin($account, $role, $roleLabel, $motivation['value'], $token);
        } catch (\Throwable $e) {
            // The request is stored and visible on /konto either way.
            $notified = false;
            error_log('account-manager access-request admin mail failed: ' . $e->getMessage());
        }

        $this->auditLog()->append('request_access', $user->username, ['role' => $role]);

        if (!$notified) {
            // Say so rather than claiming a notification that never left.
            // The member is pointed at the association's public contact
            // address — a mailbox for visitors, deliberately NOT a delivery
            // fallback for operator mail: whoever reads it is not
            // necessarily a super and cannot act on the request. They can
            // pass it on, and a super then has the log to work from.
            $contact = (string)$this->config->get('site.author.email', '');
            $this->redirectWithFlash(
                'Din anmodning er gemt, men vi kunne ikke give administratorerne besked automatisk.'
                . ($contact !== '' ? ' Skriv til ' . $contact . ', så bliver den taget op manuelt.' : ''),
                'roles',
                'warning'
            );
        }

        $this->redirectWithFlash('Din anmodning er sendt og afventer godkendelse.', 'roles');
    }

    private function handleCancelAccessRequest(UserInterface $user): void
    {
        $account = $this->store()->read($user->username);
        if ($account === null || !is_array($account->get('access_request'))) {
            $this->failWith(400, ['Der er ingen åben anmodning.'], 'roles');
        }

        try {
            $this->store()->mutate($user->username, static function (UserInterface $acct): void {
                $acct->undef('access_request');
                $acct->set('access_request_cleared_at', gmdate('Y-m-d\TH:i:s\Z'));
            });
        } catch (\Throwable $e) {
            error_log('account-manager cancel_access_request failed: ' . $e->getMessage());
            $this->failWith(500, ['Noget gik galt. Prøv igen.'], 'roles');
        }

        $this->auditLog()->append('cancel_access_request', $user->username);
        $this->redirectWithFlash('Anmodningen er fortrudt.', 'roles');
    }

    /**
     * Admin approval/rejection of access requests via email token links.
     * Paths: /konto/access-request/approve or /konto/access-request/reject
     */
    private function handleAdminAccessRequest(): void
    {
        $user = $this->grav['user'] ?? null;
        if (!$user || !$user->authenticated || !$user->authorized) {
            // A mail-link GET from a logged-out admin: route through the site
            // login and come straight back — the login plugin honors
            // session->redirect_after_login, so the approval completes
            // automatically after authentication. POSTs keep the hard 403.
            if (strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? '')) === 'GET') {
                $uri = $this->grav['uri'];
                $query = (string)$uri->query();
                $this->grav['session']->redirect_after_login =
                    $uri->path() . ($query !== '' ? '?' . $query : '');
                $this->grav->redirectLangSafe('/login', 302);
            }
            $this->sendError(403, 'Ikke autoriseret.');
        }

        // Account switch, posted from the wrong-account page below. Handled
        // BEFORE the admin check on purpose: the whole point is that the
        // current session belongs to someone who fails that check.
        if (strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? '')) === 'POST'
            && $this->grav['uri']->path() === self::ACCESS_REQUEST_SWITCH_PATH) {
            $this->handleAccessRequestSwitchAccount();
        }

        // Superuser check: an account with admin.super access qualifies
        // directly; the 'admin' group is an alternative for delegated
        // approvers. (groups.yaml defines no 'admin' group today, so the
        // group-only check locked out every real super.)
        $groups = (array)($user->get('groups') ?? []);
        if (!$user->authorize('admin.super') && !in_array('admin', $groups, true)) {
            // A mail link opened in a browser that happens to be logged in as
            // a member: render the themed wrong-account page, which offers to
            // switch accounts and resume this exact approval. sendError()
            // answers JSON — right for the AJAX endpoints, but as a mail-link
            // response it put a raw JSON blob on screen. Non-GET keeps the
            // hard 403; only a human following a link gets the page.
            if (strtoupper((string)($_SERVER['REQUEST_METHOD'] ?? '')) === 'GET') {
                $this->renderAccessRequestWrongAccount($user);
                return;
            }
            $this->sendError(403, 'Administratortilladelse påkrævet.');
        }

        $path = $this->grav['uri']->path();
        $token = (string)($_POST['token'] ?? $_GET['token'] ?? '');
        $username = (string)($_POST['username'] ?? $_GET['username'] ?? '');

        // Validate token + dispatch. Every failure exits the do-block with a
        // null outcome and renders the NEUTRAL result page — identical for
        // unknown user, bad token, expired token, and already-processed
        // request, so a super cannot probe which of them it was. Success
        // renders the fact sheet (the viewer is an authenticated super; the
        // data is what the admin needs to recognise the applicant).
        $outcome = null;
        $request = null;
        do {
            if ($token === '' || $username === '') {
                break;
            }

            $account = $this->store()->read($username);
            if ($account === null) {
                break;
            }
            $request = is_array($account->get('access_request')) ? (array)$account->get('access_request') : null;
            if ($request === null || !isset($request['token_hash'])) {
                break;
            }

            // Token validation: hash-compare and expiry check
            $storedHash = (string)($request['token_hash'] ?? '');
            $expiresAt = (string)($request['token_expires_at'] ?? '');
            $tokenHash = hash('sha256', $token, false);
            if (!hash_equals($storedHash, $tokenHash)) {
                break;
            }
            if ($expiresAt !== '' && strtotime($expiresAt) < time()) {
                break;
            }

            if (str_ends_with($path, '/approve')) {
                if ($this->approveAccessRequest($username, $request, $user)) {
                    $outcome = 'approved';
                }
            } elseif (str_ends_with($path, '/reject')) {
                if ($this->rejectAccessRequest($username, $request, $user)) {
                    $outcome = 'rejected';
                }
            }
        } while (false);

        $this->renderAccessRequestResult($outcome, $outcome !== null ? $username : null, $request);
    }

    /**
     * End the current session and route back through login to the approval
     * link that was clicked. Posted from the wrong-account page; nonce-gated.
     */
    private function handleAccessRequestSwitchAccount(): void
    {
        $nonce = (string)($_POST['account-nonce'] ?? '');
        if ($nonce === '' || !Utils::verifyNonce($nonce, self::ACCESS_REQUEST_SWITCH_NONCE)) {
            $this->sendError(403, 'Sikkerhedstjekket fejlede. Åbn linket fra mailen igen.');
        }

        // The resume target comes from the session, stashed when the
        // wrong-account page rendered — never from the POST body. Two things
        // fall out of that: the page needs no hidden token/username fields,
        // so it discloses nothing about the applicant to a viewer who just
        // failed the admin check; and there is no submitted URL to turn into
        // an open redirect. Read it BEFORE the logout wipes the session.
        $session = $this->grav['session'];
        $target = (string)($session->access_request_resume ?? '');
        if ($target === '' || !str_starts_with($target, self::ACCESS_REQUEST_BASE)) {
            $target = self::ROUTE_BASE;
        }

        // Order matters. The login plugin's userLogout() ends with
        // $session->invalidate()->start(), so anything stashed BEFORE the
        // logout is wiped with the session. remember_me clears the cookie in
        // the same step — without it the redirect to /login can silently
        // re-authenticate the very session we just ended, and the admin never
        // gets a login form.
        $this->grav['login']->logout(['remember_me' => true]);
        $this->grav['session']->redirect_after_login = $target;
        $this->grav->redirectLangSafe('/login', 302);
    }

    private function approveAccessRequest(string $username, array $request, UserInterface $admin): bool
    {
        $role = (string)($request['role'] ?? '');
        if ($role === '') {
            return false;
        }

        try {
            $this->store()->mutate($username, static function (UserInterface $acct) use ($role): void {
                $groups = (array)($acct->get('groups') ?? []);
                if (!in_array($role, $groups, true)) {
                    $groups[] = $role;
                    $acct->set('groups', $groups);
                }
                $acct->undef('access_request');
            });
        } catch (\Throwable $e) {
            error_log('account-manager approve_access_request failed: ' . $e->getMessage());
            return false;
        }

        $this->auditLog()->append('approve_access_request', (string)$admin->username, [
            'target_username' => $username,
            'role' => $role,
        ]);

        // Notify the applicant. Mail failure must never undo the grant —
        // same swallow-and-log posture as the admin notification.
        try {
            $account = $this->store()->read($username);
            if ($account !== null) {
                $roleLabel = (string)($this->config->get("groups.{$role}.readableName") ?: $role);
                $this->accountEmail()->sendAccessRequestApproved($account, $role, $roleLabel);
            }
        } catch (\Throwable $e) {
            error_log('account-manager access-request approved mail failed: ' . $e->getMessage());
        }

        return true;
    }

    private function rejectAccessRequest(string $username, array $request, UserInterface $admin): bool
    {
        try {
            $this->store()->mutate($username, static function (UserInterface $acct): void {
                $acct->undef('access_request');
                $acct->set('access_request_cleared_at', gmdate('Y-m-d\TH:i:s\Z'));
            });
        } catch (\Throwable $e) {
            error_log('account-manager reject_access_request failed: ' . $e->getMessage());
            return false;
        }

        $this->auditLog()->append('reject_access_request', (string)$admin->username, [
            'target_username' => $username,
        ]);

        // Notify the applicant — swallow-and-log like the approval mail.
        try {
            $account = $this->store()->read($username);
            if ($account !== null) {
                $role = (string)($request['role'] ?? '');
                $roleLabel = (string)($this->config->get("groups.{$role}.readableName") ?: $role);
                $this->accountEmail()->sendAccessRequestRejected($account, $role, $roleLabel);
            }
        } catch (\Throwable $e) {
            error_log('account-manager access-request rejected mail failed: ' . $e->getMessage());
        }

        return true;
    }

    /**
     * Swap the current page for the themed result page and let Grav's normal
     * rendering finish the request (login-plugin unauthorized-page pattern).
     * Null outcome = the neutral no-details card with a 404 status; success
     * carries the applicant fact sheet for the template.
     *
     * @param array<string,mixed>|null $request the access_request as it was
     *   BEFORE the mutation cleared it (motivation, requested_at, role).
     */
    private function renderAccessRequestResult(?string $outcome, ?string $username, ?array $request): void
    {
        $viewModel = ['outcome' => $outcome, 'applicant' => null, 'request' => null];

        if ($outcome !== null && $username !== null) {
            // Re-read AFTER the mutation so the roles list reflects the grant.
            $account = $this->store()->read($username);
            $groups = $account !== null ? (array)($account->get('groups') ?? []) : [];
            $roleLabels = [];
            foreach ($groups as $group) {
                $roleLabels[] = (string)($this->config->get("groups.{$group}.readableName") ?: $group);
            }
            $requestedRole = (string)($request['role'] ?? '');
            $viewModel['applicant'] = [
                'username' => $username,
                'fullname' => $account !== null ? (string)($account->get('fullname') ?? '') : '',
                'email' => $account !== null ? (string)($account->get('email') ?? '') : '',
                'state' => $account !== null ? (string)($account->get('state') ?? '') : '',
                'roles' => $roleLabels,
            ];
            $viewModel['request'] = [
                'role_label' => (string)($this->config->get("groups.{$requestedRole}.readableName") ?: $requestedRole),
                'motivation' => (string)($request['motivation'] ?? ''),
                'requested_at' => (string)($request['requested_at'] ?? ''),
            ];
        }

        $this->accessRequestResult = $viewModel;

        $title = $outcome === 'approved' ? 'Anmodning godkendt'
            : ($outcome === 'rejected' ? 'Anmodning afvist' : 'Anmodning');
        $this->renderAccessRequestPage($title, $outcome === null ? 404 : null);
    }

    /**
     * Themed page for a mail link opened in a browser signed in as someone
     * who cannot approve. Carries NO applicant data by design — the viewer
     * just failed the admin check, so the page states only who they are
     * signed in as and how to continue. The token and applicant username are
     * read back off the URL the viewer already holds, so putting them in the
     * form leaks nothing they did not arrive with.
     */
    private function renderAccessRequestWrongAccount(UserInterface $user): void
    {
        $uri = $this->grav['uri'];
        $path = $uri->path();
        $query = (string)$uri->query();

        // Stash the link to resume after the switch. Session-scoped, so the
        // page itself can stay free of the token and the applicant's name.
        $this->grav['session']->access_request_resume =
            $path . ($query !== '' ? '?' . $query : '');

        $this->accessRequestResult = [
            'outcome' => 'wrong_account',
            'applicant' => null,
            'request' => null,
            'current_user' => [
                'username' => (string)($user->get('username') ?? ''),
                'fullname' => (string)($user->get('fullname') ?? ''),
            ],
            'action' => str_ends_with($path, '/reject') ? 'reject' : 'approve',
            'switch_path' => self::ACCESS_REQUEST_SWITCH_PATH,
            'switch_nonce' => Utils::getNonce(self::ACCESS_REQUEST_SWITCH_NONCE),
        ];

        $this->renderAccessRequestPage('Forkert konto', 403);
    }

    /** Substitute the themed result page for this request. */
    private function renderAccessRequestPage(string $title, ?int $status): void
    {
        $page = new Page();
        $page->init(new \SplFileInfo('plugin://account-manager/pages/access-request-result.md'));
        // PagesProcessor discards a non-routable page AFTER onPageInitialized
        // and serves the themed 404 instead - the page must be routable.
        $page->routable(true);
        $route = $this->grav['uri']->path();
        $page->route($route);
        $page->slug(basename($route));
        $header = $page->header();
        $header->title = $title;
        if ($status !== null) {
            $header->http_response_code = $status;
        }
        $page->title($title);

        /** @var \Grav\Common\Page\Pages $pages */
        $pages = $this->grav['pages'];
        $pages->addPage($page, $route);

        unset($this->grav['page']);
        $this->grav['page'] = $page;
    }

    // -------------------------------------------------------------------------
    // Twig view model
    // -------------------------------------------------------------------------

    public function onTwigSiteVariables(): void
    {
        $page = $this->grav['page'] ?? null;
        if (!$page instanceof PageInterface) {
            return;
        }
        if ($page->template() === 'access-request-result' && $this->accessRequestResult !== null) {
            $this->grav['twig']->twig_vars['ar_result'] = $this->accessRequestResult;
            return;
        }
        if ($page->template() !== 'account') {
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

        // Derived access-request state (§4.2): membership of the group IS the
        // granted state — a leftover request marker is cleared lazily on the
        // next /konto load (no cooldown stamp; the grant closed it).
        $request = $account->get('access_request');
        $groups = (array)($account->get('groups') ?? []);
        if (is_array($request) && in_array($request['role'] ?? '', $groups, true)) {
            try {
                $this->store()->mutate($user->username, static function (UserInterface $acct): void {
                    $acct->undef('access_request');
                });
                $account = $this->store()->read($user->username) ?? $account;
            } catch (\Throwable $e) {
                error_log('account-manager granted-request cleanup failed: ' . $e->getMessage());
            }
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
    private function redirectWithFlash(string $message, string $section, string $type = 'success'): never
    {
        $this->grav['messages']->add($message, $type);
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

    private function accountEmail(): AccountEmail
    {
        return new AccountEmail($this->grav);
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
