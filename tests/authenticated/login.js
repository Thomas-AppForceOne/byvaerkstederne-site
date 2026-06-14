// @ts-check
'use strict';

/**
 * WI-6 area 4 — login coverage (success and failure paths).
 *
 *   - success: correct credentials on an ACTIVATED account log in and reach
 *     /roadmap.
 *   - failure: wrong password is refused (cannot reach /roadmap).
 *   - failure: repeated wrong-password attempts hit the rate limiter.
 *
 * Login is driven through the browser overlay form (like tests/helpers/auth.js)
 * so the session cookie and the CSRF nonce stay coherent — an out-of-band POST
 * is rejected by Grav as "form timed out".
 *
 * Needs the canonical pw-test-user (activated, enabled). Skipped-with-reason
 * when TEST_PASSWORD is absent (anonymous-only mode).
 */

const { test, expect } = require('@playwright/test');
const { execFileSync } = require('child_process');
const path = require('path');
const { hasUserPassword } = require('../helpers/auth');
const { TEST_USER } = require('../helpers/accounts');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

/**
 * Reset the login plugin's rate-limit state (stored in Grav's cache via
 * LoginCache). The rate-limit test deliberately trips the limiter; without a
 * reset its state would persist for the configured 10-minute window and lock
 * out the success-path login tests on a re-run. Clearing the cache is the
 * supported reset.
 */
function resetLoginRateLimit() {
  try {
    const { container } = discoverGravEnv(path.resolve(__dirname, '..', '..'));
    // The login plugin's RateLimiter persists in the FilesystemCache at
    // cache://login/ (Doctrine). `bin/grav clearcache` does NOT clear it, so
    // remove that dir directly to reset the IP-keyed attempt counters.
    execFileSync(
      'docker',
      ['exec', container, 'sh', '-c', 'rm -rf /app/www/public/cache/login/* /config/www/user/data/login 2>/dev/null; true'],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 15_000 },
    );
  } catch (_) {
    /* best-effort */
  }
}

/**
 * Fill + submit the overlay login form. Waits for the post-login redirect away
 * from /login (success) or settles on /login (failure). Returns the body after
 * submit so callers can assert on flash text.
 */
async function browserLogin(page, username, password) {
  await page.goto('/login');
  await page.evaluate(() => {
    const o = document.getElementById('bv-login-overlay');
    if (o) o.classList.add('is-open');
  });
  const form = page.locator('#bv-login-overlay form');
  await form.locator('[name="username"]').fill(username);
  await form.locator('[name="password"]').fill(password);
  await form.locator('[type="submit"]').click();
  // Success redirects away from /login; failure re-renders /login. Wait for
  // either, with a bounded timeout (don't throw on failure — callers assert).
  await page
    .waitForURL((url) => !url.pathname.includes('/login'), { timeout: 8000 })
    .catch(() => {});
  return (await page.content()) || '';
}

/** True if the current session can reach the member-only /roadmap. */
async function canReachRoadmap(page) {
  const r = await page.request.get('/roadmap', { maxRedirects: 0 });
  return r.status() === 200;
}

test.describe('Login (WI-6)', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — login suite skipped (anonymous-only mode)');

  // The rate-limit test below trips the limiter; reset it before the success
  // path so a previous run (or test ordering) can't lock us out.
  test.beforeEach(() => resetLoginRateLimit());

  // Run serially within the file so the rate-limit test's state is contained.
  test.describe.configure({ mode: 'serial' });

  test('success: activated account logs in and reaches /roadmap', async ({ page }) => {
    await browserLogin(page, TEST_USER.username, process.env.TEST_PASSWORD || '');
    expect(await canReachRoadmap(page), 'authenticated account reaches /roadmap').toBe(true);
  });

  test('failure: wrong password is refused', async ({ page }) => {
    await browserLogin(page, TEST_USER.username, 'WrongPassword9');
    expect(await canReachRoadmap(page), 'wrong password must not reach /roadmap').toBe(false);
  });

  test('failure: repeated wrong passwords hit the rate limiter', async ({ page }) => {
    // Use a throwaway username so we trip the per-username limiter without
    // locking out pw-test-user for any sibling/subsequent test.
    const victim = `pwratelimit${Math.random().toString(36).slice(2, 6)}`;
    let limited = false;
    // The limiter is 5 / 10 min; fire past the threshold and look for the
    // rate-limit message (Danish override or English fallback).
    for (let i = 0; i < 8; i++) {
      const body = await browserLogin(page, victim, `Nope${i}aaaa9`);
      if (/for mange|too many|tidsrum|attempts/i.test(body)) {
        limited = true;
        break;
      }
    }
    expect(limited, 'after the threshold the rate limiter must respond').toBe(true);
    // Reset so the limiter state doesn't bleed into other suites.
    resetLoginRateLimit();
  });
});
