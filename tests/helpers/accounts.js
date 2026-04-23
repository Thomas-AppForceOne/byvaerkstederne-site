// @ts-check
'use strict';

/**
 * Canonical Playwright test-account definitions and account lifecycle helpers.
 *
 * Provides:
 *   - TEST_USER / TEST_ADMIN frozen account descriptors
 *   - hasUserPassword / hasAdminPassword booleans driven by env vars
 *   - ensureAccount(account, password): idempotent shell-out via
 *     `docker exec grav bin/plugin login new-user ...`
 *   - removeAccount(account): rm -f on the account YAML under
 *     config/www/user/accounts/
 *
 * Security invariants:
 *   - Only the two canonical usernames are accepted; helpers reject any other
 *     account input before invoking docker or the filesystem.
 *   - Passwords are passed via execFile arguments (no shell), never echoed,
 *     never logged.
 *   - File operations target only the two sanctioned YAML paths; no
 *     readdir/glob ever runs against the accounts directory.
 */

const { execFile, execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

const ACCOUNTS_DIR_REL = path.join('config', 'www', 'user', 'accounts');
const REPO_ROOT = path.resolve(__dirname, '..', '..');

// Resolve the Grav container for this worktree (not a stray 'grav').
// Cached per-process; assertDockerAndGravRunning below still validates
// that the container is actually up before any write operation.
let _cachedContainer = null;
function gravContainer() {
  if (_cachedContainer) return _cachedContainer;
  const { container } = discoverGravEnv(REPO_ROOT);
  _cachedContainer = container;
  return container;
}

const USERNAME_PATTERN = /^[a-z0-9-]+$/;

const TEST_USER = Object.freeze({
  username: 'pw-test-user',
  email: 'pw-test-user@example.invalid',
  fullName: 'Playwright Test User',
  isAdmin: false,
});

const TEST_ADMIN = Object.freeze({
  username: 'pw-test-admin',
  email: 'pw-test-admin@example.invalid',
  fullName: 'Playwright Test Admin',
  isAdmin: true,
});

const ALLOWED_USERNAMES = Object.freeze([TEST_USER.username, TEST_ADMIN.username]);

const hasUserPassword = Boolean(process.env.TEST_PASSWORD);
const hasAdminPassword = Boolean(process.env.TEST_ADMIN_PASSWORD);

/**
 * Validate an account argument before any shell-out or filesystem call.
 * Throws with a non-sensitive message; never includes the password.
 *
 * @param {unknown} account
 * @returns {{username: string, email: string, fullName: string, isAdmin: boolean}}
 */
function validateAccount(account) {
  if (!account || typeof account !== 'object') {
    throw new Error('accounts: account argument must be a frozen account descriptor');
  }
  const a = /** @type {any} */ (account);
  const { username, email, fullName, isAdmin } = a;
  if (typeof username !== 'string' || !USERNAME_PATTERN.test(username)) {
    throw new Error('accounts: username must match /^[a-z0-9-]+$/');
  }
  if (!ALLOWED_USERNAMES.includes(username)) {
    throw new Error(`accounts: username '${username}' is not a sanctioned test account`);
  }
  if (typeof email !== 'string' || !email.endsWith('@example.invalid')) {
    throw new Error('accounts: email must use the @example.invalid domain');
  }
  if (typeof fullName !== 'string' || fullName.length === 0) {
    throw new Error('accounts: fullName must be a non-empty string');
  }
  return { username, email, fullName, isAdmin: Boolean(isAdmin) };
}

/**
 * Resolve the absolute YAML path for a validated account.
 * @param {{username: string}} account
 */
function accountYamlPath(account) {
  // username already validated against allowlist; no traversal possible.
  return path.join(REPO_ROOT, ACCOUNTS_DIR_REL, `${account.username}.yaml`);
}

/**
 * Idempotently ensure a Grav account exists.
 *
 * If the account YAML already exists on disk we return without invoking
 * docker — this is the crash-recovery / second-run path.
 *
 * Otherwise we shell out to `docker exec grav bin/plugin login new-user`
 * via execFile (no shell interpolation). The password is supplied as an
 * argument and is not logged. stdout/stderr are buffered and only surfaced
 * (with the password scrubbed) on non-zero exit.
 *
 * @param {object} account
 * @param {string} password
 * @returns {Promise<{created: boolean}>}
 */
function ensureAccount(account, password) {
  const a = validateAccount(account);
  if (typeof password !== 'string' || password.length === 0) {
    throw new Error(`accounts: password for ${a.username} must be a non-empty string`);
  }

  const yamlPath = accountYamlPath(a);
  if (accountExistsInContainer(a) || fs.existsSync(yamlPath)) {
    return Promise.resolve({ created: false });
  }

  // Verify docker is reachable and the grav container is running before we
  // try to create the account. Failing here gives a clear, actionable error.
  assertDockerAndGravRunning();

  const args = [
    'exec', '-w', '/app/www/public', gravContainer(),
    'bin/plugin', 'login', 'new-user',
    '-u', a.username,
    '-p', password,
    '-e', a.email,
    '-N', a.fullName,
    '-l', 'en',
    '-t', 'Test User',
    '-P', a.isAdmin ? 'b' : 's', // permissions: both (admin+site) or site-only
    '-s', 'enabled',
  ];

  return new Promise((resolve, reject) => {
    execFile('docker', args, { timeout: 30_000 }, (err, stdout, stderr) => {
      if (err) {
        const scrub = (s) => (typeof s === 'string' ? s.split(password).join('***') : '');
        const msg = `accounts.ensureAccount(${a.username}) failed: ${scrub(err.message)} ${scrub(stderr)}`.trim();
        reject(new Error(msg));
        return;
      }
      // Do not log stdout — it could echo the supplied password back. Confirm
      // the YAML now exists inside the container (authoritative) or on the
      // host-mounted path; if neither, surface a generic error.
      if (!accountExistsInContainer(a) && !fs.existsSync(yamlPath)) {
        reject(new Error(`accounts.ensureAccount(${a.username}) reported success but YAML was not created`));
        return;
      }
      if (a.isAdmin) {
        try {
          grantAdminSuperInContainer(a);
        } catch (patchErr) {
          reject(new Error(`accounts.ensureAccount(${a.username}) created but failed to grant admin.super: ${/** @type {any} */ (patchErr).message}`));
          return;
        }
      }
      resolve({ created: true });
    });
  });
}

/**
 * Idempotently remove a test account YAML. Safe to call when the file is
 * already gone — `rm -f` semantics.
 *
 * @param {object} account
 * @returns {{removed: boolean}}
 */
function removeAccount(account) {
  const a = validateAccount(account);
  const yamlPath = accountYamlPath(a);
  let removed = false;
  try {
    if (fs.existsSync(yamlPath)) {
      fs.rmSync(yamlPath, { force: true });
      removed = true;
    }
  } catch (err) {
    if (!(err && /** @type {any} */ (err).code === 'ENOENT')) {
      throw new Error(`accounts.removeAccount(${a.username}) failed: ${/** @type {any} */ (err).message}`);
    }
  }
  // Also attempt in-container removal so worktree-run tests clean up the real
  // mount path. Idempotent; either location is acceptable.
  if (removeAccountInContainer(a)) {
    removed = true;
  }
  return { removed };
}

/**
 * Verify Docker is installed/runnable and the `grav` container is up.
 * Throws with a precise, actionable error if not — never silently skips.
 */
/**
 * Check whether an account YAML exists inside the running Grav container.
 * This is authoritative when the host-side mount doesn't match the cwd we're
 * running from (e.g. Playwright tests executed from a git worktree while
 * docker compose was started from the main checkout).
 *
 * @param {{username: string}} account
 */
function accountExistsInContainer(account) {
  try {
    execFileSync(
      'docker',
      ['exec', gravContainer(), 'test', '-f', `/config/www/user/accounts/${account.username}.yaml`],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 10_000 }
    );
    return true;
  } catch {
    return false;
  }
}

/**
 * Remove an account YAML from inside the container. Used by removeAccount as a
 * fallback when the host-side path isn't writable from the current cwd.
 *
 * @param {{username: string}} account
 */
function removeAccountInContainer(account) {
  try {
    execFileSync(
      'docker',
      ['exec', gravContainer(), 'rm', '-f', `/config/www/user/accounts/${account.username}.yaml`],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 10_000 }
    );
    return true;
  } catch {
    return false;
  }
}

/**
 * Ensure an admin account's YAML has `access.admin.super: true`.
 * The bin/plugin login new-user command sets admin.login / site.login via -P b
 * but never grants super; admin smoke tests require super to hit approve flows.
 *
 * @param {{username: string}} account
 */
function grantAdminSuperInContainer(account) {
  const yamlPath = `/config/www/user/accounts/${account.username}.yaml`;
  // Idempotent: replace or append. Using sh -c is safe because username is
  // already allowlist-validated (/^[a-z0-9-]+$/).
  const script = [
    `set -e`,
    `if grep -q '^\\s*super:' "${yamlPath}"; then`,
    `  sed -i 's/^\\(\\s*super:\\s*\\).*/\\1true/' "${yamlPath}"`,
    `else`,
    `  awk '1; /^\\s*admin:\\s*$/ && !d { print "    super: true"; d=1 }' "${yamlPath}" > "${yamlPath}.tmp" && mv "${yamlPath}.tmp" "${yamlPath}"`,
    `fi`,
  ].join('\n');
  execFileSync('docker', ['exec', gravContainer(), 'sh', '-c', script], {
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 10_000,
  });
}

function assertDockerAndGravRunning() {
  try {
    execFileSync('docker', ['version', '--format', '{{.Server.Version}}'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10_000,
    });
  } catch (err) {
    throw new Error(
      'Docker does not appear to be installed or running. Start Docker Desktop and try again. ' +
      'Test-account setup requires `docker exec` against the worktree\'s Grav container.'
    );
  }
  // Resolve the worktree's container via the shared chain. discoverGravEnv
  // throws loud if the container isn't running, which is exactly what we
  // want — no silent fallback to a stray 'grav' container from some other
  // checkout.
  try {
    gravContainer();
  } catch (err) {
    throw new Error(
      `Cannot set up test accounts: ${err.message}`
    );
  }
}

module.exports = {
  TEST_USER,
  TEST_ADMIN,
  hasUserPassword,
  hasAdminPassword,
  ensureAccount,
  removeAccount,
  // Exported for tests / callers that need to assert on the path; never used
  // to construct a path from untrusted input.
  accountYamlPath,
};
