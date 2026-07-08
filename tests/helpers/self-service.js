// @ts-check
'use strict';

/**
 * Account self-service helpers (account_self_service_specification.md §10).
 *
 * Destructive flows (name/password/email changes, deletion, purge) must never
 * touch the shared seeded accounts (pw-test-user / pw-test-org /
 * pw-test-admin) — every such spec creates a DISPOSABLE account here instead.
 * Disposable usernames reuse the registration helpers' strict `pwtest` prefix
 * rule, so cleanup can never target a real account.
 *
 * Container-side helpers (create / read / edit account YAML) go through the
 * worktree's own Grav container via the shared discovery chain — never a
 * stray container from another checkout.
 */

const { execFileSync } = require('child_process');
const path = require('path');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));
const { SIGNUP_USERNAME, removeSignupAccount } = require('./registration');

const REPO_ROOT = path.resolve(__dirname, '..', '..');

// Meets system.pwd_regex (≥8 chars, upper + lower + digit).
const DISPOSABLE_PASSWORD = 'Abcdefg1';

let _container = null;
function gravContainer() {
  if (_container) return _container;
  ({ container: _container } = discoverGravEnv(REPO_ROOT));
  return _container;
}

function assertDisposableUsername(username) {
  if (typeof username !== 'string' || !SIGNUP_USERNAME.test(username)) {
    throw new Error(`self-service: username '${username}' must match ${SIGNUP_USERNAME}`);
  }
}

/**
 * Create a fresh, enabled, site-only account for one destructive spec.
 * Returns the credentials; callers MUST removeDisposableAccount() in
 * afterAll (global-teardown does not know about these).
 *
 * @param {{tag?: string, groups?: string[], fullName?: string}} [options]
 * @returns {{username: string, email: string, fullName: string, password: string}}
 */
function createDisposableAccount({ tag = '', groups = [], fullName = 'PW SelfService Tester' } = {}) {
  const rand = Math.random().toString(36).slice(2, 6);
  const username = `pwtest${tag}${rand}`.slice(0, 16);
  assertDisposableUsername(username);
  const email = `${username}@example.invalid`;

  execFileSync(
    'docker',
    [
      // -u abc: root-created account files break Grav's web-user writes.
      'exec', '-u', 'abc', '-w', '/app/www/public', gravContainer(),
      'bin/plugin', 'login', 'new-user',
      '-u', username,
      '-p', DISPOSABLE_PASSWORD,
      '-e', email,
      '-N', fullName,
      '-l', 'en',
      '-t', 'Test User',
      '-P', 's',
      '-s', 'enabled',
    ],
    { stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000 },
  );

  if (groups.length > 0) {
    grantGroups(username, groups);
  }

  return { username, email, fullName, password: DISPOSABLE_PASSWORD };
}

/**
 * Idempotently append a `groups:` list to a disposable account's YAML —
 * used to simulate the manual admin grant (the plugin itself never writes
 * groups).
 *
 * @param {string} username
 * @param {string[]} groups
 */
function grantGroups(username, groups) {
  assertDisposableUsername(username);
  for (const g of groups) {
    if (!/^[a-z0-9_-]+$/.test(g)) {
      throw new Error(`self-service: group name '${g}' is not a valid identifier`);
    }
  }
  const yamlPath = `/config/www/user/accounts/${username}.yaml`;
  const lines = ['groups:', ...groups.map((g) => `  - ${g}`)].join('\\n');
  const script = [
    'set -e',
    `if ! grep -q '^groups:' "${yamlPath}"; then`,
    `  printf '${lines}\\n' >> "${yamlPath}"`,
    'fi',
  ].join('\n');
  execFileSync('docker', ['exec', '-u', 'abc', gravContainer(), 'sh', '-c', script], {
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 10_000,
  });
  bustCompiledFileCache();
}

/** Remove a disposable account (idempotent; strict-prefix validated). */
function removeDisposableAccount(username) {
  removeSignupAccount(username);
}

/**
 * Read a disposable account's raw YAML from the container. Returns null
 * when the file is gone (e.g. after purge).
 *
 * @param {string} username
 * @returns {string|null}
 */
function readAccountYaml(username) {
  assertDisposableUsername(username);
  try {
    return execFileSync(
      'docker',
      ['exec', gravContainer(), 'cat', `/config/www/user/accounts/${username}.yaml`],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 10_000 },
    );
  } catch (_) {
    return null;
  }
}

/**
 * Grav serves account YAML through a compiled-file cache (PHP files under
 * cache/compiled/files/) that is doubly sticky for out-of-band edits:
 * mtime invalidation has one-second granularity, and the web process's
 * OPcache re-serves the compiled include for up to opcache.revalidate_freq
 * (2s, PHP default) without re-stat'ing. Every container-side YAML edit
 * therefore busts the compiled files AND waits out the OPcache window —
 * otherwise a request landing within ~2s of the edit still sees the stale
 * account (observed: a backdated token expiry being honoured as valid).
 */
function bustCompiledFileCache() {
  execFileSync(
    'docker',
    ['exec', '-u', 'abc', gravContainer(), 'sh', '-c',
      'rm -rf /app/www/public/cache/compiled/files/* 2>/dev/null; sleep 3; true'],
    { stdio: ['ignore', 'pipe', 'pipe'], timeout: 20_000 },
  );
}

/**
 * Backdate a pending email change's expiry so the confirm link is expired
 * (single-file sed inside the container; the account YAML's only
 * `expires_at` key lives under pending_email).
 *
 * @param {string} username
 */
function backdatePendingEmail(username) {
  assertDisposableUsername(username);
  const yamlPath = `/config/www/user/accounts/${username}.yaml`;
  // Same-inode rewrite (read → truncate-write), NOT `sed -i`: sed's
  // tmp+rename swaps the inode, and the long-running php-fpm worker kept
  // serving the OLD inode's content through the macOS bind-mount cache —
  // the backdate was observably ignored. POSIX classes (BusyBox sed).
  const script = [
    'set -e',
    `content="$(sed "s/^\\([[:space:]]*expires_at:[[:space:]]*\\).*/\\1'2020-01-01T00:00:00Z'/" "${yamlPath}")"`,
    `printf '%s\\n' "$content" > "${yamlPath}"`,
  ].join('\n');
  execFileSync('docker', ['exec', '-u', 'abc', gravContainer(), 'sh', '-c', script], {
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 10_000,
  });
  bustCompiledFileCache();
}

/**
 * Reset the account-manager email-change rate limiter (login-plugin
 * FilesystemCache under cache/login/ — NOT cleared by `bin/grav
 * clearcache`, same as the login-attempt limiter in login.js).
 */
function resetEmailChangeThrottle() {
  try {
    execFileSync(
      'docker',
      ['exec', gravContainer(), 'sh', '-c',
        'rm -rf /app/www/public/cache/login/account_email_change_ip /app/www/public/cache/login/account_email_change_user 2>/dev/null; true'],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 15_000 },
    );
  } catch (_) {
    /* best-effort */
  }
}

/**
 * Log in through the site overlay form (same flow as helpers/auth.js, but
 * for arbitrary disposable credentials). Returns true when the session is
 * authenticated afterwards — false lets callers assert failed logins
 * without try/catch.
 *
 * @param {import('@playwright/test').Page} page
 * @param {{username: string, password: string}} account
 * @param {{rememberMe?: boolean}} [options]
 * @returns {Promise<boolean>}
 */
async function loginAs(page, { username, password }, { rememberMe = false } = {}) {
  await page.goto('/login');
  await page.evaluate(() => {
    const overlay = document.getElementById('bv-login-overlay');
    if (overlay) overlay.classList.add('is-open');
  });
  const form = page.locator('#bv-login-overlay form');
  await form.locator('[name="username"]').fill(username);
  await form.locator('[name="password"]').fill(password);
  if (rememberMe) {
    await form.locator('[name="rememberme"]').check();
  }
  await form.locator('[type="submit"]').click();
  // Success redirects away from /login; failure re-renders with a flash.
  await Promise.race([
    page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 8_000 }).catch(() => {}),
    page.locator('.bv-message').first().waitFor({ state: 'visible', timeout: 8_000 }).catch(() => {}),
  ]);
  return (await page.locator('.bv-nav__user').count()) > 0;
}

/** Log out via the header link (desktop viewport). */
async function logout(page) {
  await page.locator('.bv-nav__links a', { hasText: 'Log ud' }).click();
  await page.waitForLoadState('networkidle');
}

/**
 * True while a remember-me token file exists for the account
 * (user/data/rememberme/<sha1(username)>.yaml — the login plugin's
 * TokenStorage layout).
 *
 * @param {string} username
 * @returns {boolean}
 */
function rememberMeFileExists(username) {
  assertDisposableUsername(username);
  const hash = require('crypto').createHash('sha1').update(username).digest('hex');
  try {
    execFileSync(
      'docker',
      ['exec', gravContainer(), 'test', '-f', `/config/www/user/data/rememberme/${hash}.yaml`],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 10_000 },
    );
    return true;
  } catch (_) {
    return false;
  }
}

module.exports = {
  DISPOSABLE_PASSWORD,
  createDisposableAccount,
  grantGroups,
  removeDisposableAccount,
  readAccountYaml,
  backdatePendingEmail,
  bustCompiledFileCache,
  resetEmailChangeThrottle,
  loginAs,
  logout,
  rememberMeFileExists,
};
