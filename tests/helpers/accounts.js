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

const ACCOUNTS_DIR_REL = path.join('config', 'www', 'user', 'accounts');
const REPO_ROOT = path.resolve(__dirname, '..', '..');

const USERNAME_PATTERN = /^[a-z0-9-]+$/;

const TEST_USER = Object.freeze({
  username: 'playwright-test-user',
  email: 'playwright-test-user@example.invalid',
  fullName: 'Playwright Test User',
  isAdmin: false,
});

const TEST_ADMIN = Object.freeze({
  username: 'playwright-test-admin',
  email: 'playwright-test-admin@example.invalid',
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
  if (fs.existsSync(yamlPath)) {
    return Promise.resolve({ created: false });
  }

  // Verify docker is reachable and the grav container is running before we
  // try to create the account. Failing here gives a clear, actionable error.
  assertDockerAndGravRunning();

  const args = [
    'exec', 'grav',
    'bin/plugin', 'login', 'new-user',
    '-u', a.username,
    '-p', password,
    '-e', a.email,
    '-N', a.fullName,
    '-P', 'g', // permissions: site (g)
    '-s', 'enabled',
  ];
  if (a.isAdmin) {
    args.push('-a', 'admin.super');
  }

  return new Promise((resolve, reject) => {
    execFile('docker', args, { timeout: 30_000 }, (err, stdout, stderr) => {
      if (err) {
        const scrub = (s) => (typeof s === 'string' ? s.split(password).join('***') : '');
        const msg = `accounts.ensureAccount(${a.username}) failed: ${scrub(err.message)} ${scrub(stderr)}`.trim();
        reject(new Error(msg));
        return;
      }
      // Do not log stdout — it could echo the supplied password back. Confirm
      // the YAML now exists; if not, surface a generic error.
      if (!fs.existsSync(yamlPath)) {
        reject(new Error(`accounts.ensureAccount(${a.username}) reported success but YAML was not created`));
        return;
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
  try {
    fs.rmSync(yamlPath, { force: true });
    return { removed: true };
  } catch (err) {
    // rm -f semantics: never throw on missing-file. Re-throw anything else.
    if (err && /** @type {any} */ (err).code === 'ENOENT') {
      return { removed: false };
    }
    throw new Error(`accounts.removeAccount(${a.username}) failed: ${/** @type {any} */ (err).message}`);
  }
}

/**
 * Verify Docker is installed/runnable and the `grav` container is up.
 * Throws with a precise, actionable error if not — never silently skips.
 */
function assertDockerAndGravRunning() {
  try {
    execFileSync('docker', ['version', '--format', '{{.Server.Version}}'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10_000,
    });
  } catch (err) {
    throw new Error(
      'Docker does not appear to be installed or running. Start Docker Desktop and try again. ' +
      'Test-account setup requires `docker exec grav ...`.'
    );
  }
  let output;
  try {
    output = execFileSync('docker', ['ps', '--filter', 'name=^grav$', '--format', '{{.Names}}'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10_000,
    }).toString().trim();
  } catch (err) {
    throw new Error('Docker is running but `docker ps` failed. Cannot verify the grav container.');
  }
  if (output !== 'grav') {
    throw new Error(
      'The `grav` Docker container is not running. Start it with `docker compose up -d` ' +
      'from the repo root, then re-run the test suite.'
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
