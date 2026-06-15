// @ts-check
'use strict';

/**
 * Registration helpers (WI-6).
 *
 * The self-service signup tests create arbitrary, per-run usernames that fall
 * OUTSIDE the two-account allowlist in helpers/accounts.js, so they cannot use
 * ensureAccount/removeAccount. These helpers:
 *   - submit the registration form with a fresh nonce via the page's request
 *     context (so CSRF passes),
 *   - delete the created account YAML directly inside the worktree's Grav
 *     container (tests never touch account files other than the ones they
 *     create), and
 *   - read the account state YAML to assert state: disabled / enabled.
 *
 * Usernames are validated against a strict pattern and a mandatory `pwtest`
 * prefix before any docker exec, so a test can never delete an arbitrary
 * account file.
 */

const { execFileSync } = require('child_process');
const path = require('path');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

const REPO_ROOT = path.resolve(__dirname, '..', '..');

// Signup test usernames MUST match this — a strict subset of the username
// policy (^[a-z0-9_-]{3,16}$) AND a mandatory prefix so cleanup can never
// target a real account.
const SIGNUP_USERNAME = /^pwtest[a-z0-9]{1,8}$/;

let _container = null;
function gravContainer() {
  if (_container) return _container;
  ({ container: _container } = discoverGravEnv(REPO_ROOT));
  return _container;
}

function assertSignupUsername(username) {
  if (typeof username !== 'string' || !SIGNUP_USERNAME.test(username)) {
    throw new Error(`registration: signup username '${username}' must match ${SIGNUP_USERNAME}`);
  }
}

/** Unique-per-run signup identity so reruns don't collide with the dup guard. */
function uniqueSignup(tag = '') {
  const rand = Math.random().toString(36).slice(2, 6);
  const username = `pwtest${tag}${rand}`.slice(0, 16);
  assertSignupUsername(username);
  return {
    username,
    email: `${username}@example.invalid`,
    fullName: 'PW Signup Tester',
    password: 'Abcdefg1',
  };
}

/**
 * Submit the registration form by FILLING AND SUBMITTING the real browser
 * form. Submitting through the page (not page.request.post) keeps the session
 * cookie and the Grav forms CSRF nonce coherent — an out-of-band POST mints a
 * nonce in one session and submits it in another, which Grav rejects as
 * "form has timed out". Returns the final URL after submission so callers can
 * tell a success redirect (→ /) from a re-rendered form (stays on the page).
 *
 * @param {import('@playwright/test').Page} page
 * @param {{username:string,email:string,fullName:string,password:string,
 *          password2?:string}} fields
 * @returns {Promise<{finalUrl: string, body: string}>}
 */
async function submitRegistration(page, fields) {
  await page.goto('/opret-medlemskab');
  // Confirm the form is present (signup enabled) before filling.
  const nonceField = page.locator('input[name="form-nonce"]');
  if ((await nonceField.count()) === 0) {
    throw new Error('submitRegistration: registration form not present (is signup enabled?)');
  }
  await page.fill('input[name="data[fullname]"]', fields.fullName);
  await page.fill('input[name="data[email]"]', fields.email);
  await page.fill('input[name="data[username]"]', fields.username);
  await page.fill('input[name="data[password1]"]', fields.password);
  await page.fill('input[name="data[password2]"]', fields.password2 ?? fields.password);
  await Promise.all([
    page.waitForLoadState('networkidle'),
    page.click('button[type="submit"], input[type="submit"]'),
  ]);
  return { finalUrl: page.url(), body: (await page.content()) || '' };
}

/** Read an account's `state:` from its YAML inside the container. null if absent. */
function accountState(username) {
  assertSignupUsername(username);
  try {
    const out = execFileSync(
      'docker',
      ['exec', gravContainer(), 'sh', '-c', `grep -E '^state:' /config/www/user/accounts/${username}.yaml 2>/dev/null || true`],
      { encoding: 'utf8' },
    );
    const m = out.match(/^state:\s*(\S+)/m);
    return m ? m[1] : null;
  } catch (_) {
    return null;
  }
}

/** True if the account YAML exists in the container. */
function accountExists(username) {
  assertSignupUsername(username);
  try {
    execFileSync(
      'docker',
      ['exec', gravContainer(), 'test', '-f', `/config/www/user/accounts/${username}.yaml`],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
    return true;
  } catch (_) {
    return false;
  }
}

/** Delete a signup test account's YAML (idempotent, container-side). */
function removeSignupAccount(username) {
  assertSignupUsername(username);
  try {
    execFileSync(
      'docker',
      ['exec', gravContainer(), 'rm', '-f', `/config/www/user/accounts/${username}.yaml`],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );
  } catch (_) {
    /* best-effort teardown */
  }
}

module.exports = {
  SIGNUP_USERNAME,
  uniqueSignup,
  submitRegistration,
  accountState,
  accountExists,
  removeSignupAccount,
};
