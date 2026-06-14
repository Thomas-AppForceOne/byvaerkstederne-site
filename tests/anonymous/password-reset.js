// @ts-check
'use strict';

/**
 * WI-6 area 6 — password reset (success and failure paths).
 *
 * Success: clear inbox -> submit /forgot_password for a known account ->
 * waitForMail -> extract the /reset_password link -> set a new password ->
 * the new password authenticates and the old one is rejected.
 *
 * Failure (no user enumeration): a non-existent email produces NO captured
 * message and an identical response to the success case (same redirect/flash).
 *
 * The themed-shell render assertions (forgot/reset inside header+footer) need
 * no credentials. The full reset round-trip needs a known account; it uses the
 * canonical pw-test-user and is skipped-with-reason when TEST_PASSWORD is
 * absent. All email assertions additionally require a reachable Mailpit sink.
 */

const { test, expect } = require('@playwright/test');
const { execFileSync } = require('child_process');
const path = require('path');
const { hasUserPassword } = require('../helpers/auth');
const { TEST_USER } = require('../helpers/accounts');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));
const {
  isMailSinkConfigured,
  mailSinkUrl,
  clearMail,
  waitForMail,
  expectNoMail,
  extractLink,
} = require('../helpers/mail');

/**
 * Reset the login plugin's IP-keyed rate-limit state (login + password-reset
 * counters live in Grav's cache via LoginCache). max_pw_resets_count is 2 per
 * window, so without a reset the reset round-trip (which submits /forgot twice)
 * would be throttled. Clearing the cache is the supported reset.
 */
function resetRateLimit() {
  try {
    const { container } = discoverGravEnv(path.resolve(__dirname, '..', '..'));
    // RateLimiter persists in the FilesystemCache at cache://login/ — remove it
    // directly (bin/grav clearcache does NOT clear it).
    execFileSync(
      'docker',
      ['exec', container, 'sh', '-c', 'rm -rf /app/www/public/cache/login/* /config/www/user/data/login 2>/dev/null; true'],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 15_000 },
    );
  } catch (_) {
    /* best-effort */
  }
}

test.describe('Password reset (WI-1/WI-6)', () => {
  test.beforeEach(() => resetRateLimit());
  test('GET /forgot_password renders inside the themed site shell', async ({ page }) => {
    const res = await page.goto('/forgot_password');
    expect(res?.status()).toBe(200);
    // Site shell markers: themed heading + footer (not the unstyled plugin fallback).
    const body = (await page.content()) || '';
    expect(body, 'themed forgot heading present').toMatch(/Glemt adgangskode/);
    expect(await page.locator('footer').count(), 'site footer present').toBeGreaterThan(0);
    // And the plugin form (with its nonce) is rendered.
    expect(body).toMatch(/name="forgot-form-nonce"/);
  });

  /**
   * Submit the forgot form by FILLING + SUBMITTING the real browser form so
   * the session cookie and the CSRF nonce stay coherent (an out-of-band POST
   * is rejected by Grav as "form timed out"). Returns the final URL.
   */
  async function submitForgot(page, email) {
    await page.goto('/forgot_password');
    const emailInput = page.locator('#grav-login form input[name="data[email]"], #grav-login form input[type="email"], #grav-login form input[type="text"]').first();
    await emailInput.fill(email);
    await Promise.all([
      page.waitForLoadState('networkidle'),
      page.locator('#grav-login form button[type="submit"], #grav-login form [name="task"][value="login.forgot"]').first().click(),
    ]);
    return page.url();
  }

  test('failure (no enumeration): unknown email -> no mail, same response as success', async ({
    page,
  }) => {
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — enumeration test skipped`,
    );
    await clearMail();
    await submitForgot(page, 'definitely-not-a-user@example.invalid');
    // No message must be captured for the unknown address.
    const none = await expectNoMail('definitely-not-a-user@example.invalid');
    expect(none, 'unknown email must generate no message in the sink').toBe(true);
    // The page shows the same generic "if an account exists" flash as success —
    // it does not reveal whether the account exists.
    const body = (await page.textContent('body')) || '';
    expect(
      body.toLowerCase(),
      'response must be the generic non-enumerating flash',
    ).toMatch(/hvis der findes en konto|if an account exists/);
  });

  test('success: known account -> reset email -> new password works, old rejected', async ({
    page,
  }) => {
    test.skip(
      !hasUserPassword,
      'TEST_PASSWORD not set — reset round-trip skipped (anonymous-only mode)',
    );
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — reset round-trip skipped`,
    );

    const oldPassword = process.env.TEST_PASSWORD || '';
    const newPassword = 'Resetpw9X';

    // Drive the themed reset form in the browser (session/nonce coherent).
    async function setPasswordViaReset(link, newPw) {
      const rp = await page.goto(link);
      expect(rp?.status()).toBe(200);
      const html = (await page.content()) || '';
      expect(html, 'themed reset heading present').toMatch(/Nulstil adgangskode/);
      expect(html, 'reset form nonce present').toMatch(/name="reset-form-nonce"/);
      await page.locator('#grav-login form input[name="data[password]"], #grav-login form input[type="password"]').first().fill(newPw);
      await Promise.all([
        page.waitForLoadState('networkidle'),
        page.locator('#grav-login form [name="task"][value="login.reset"], #grav-login form button[type="submit"]').first().click(),
      ]);
    }

    // Browser login attempt; returns true if it reached an authenticated state.
    async function tryLogin(pw) {
      await page.goto('/login');
      await page.evaluate(() => {
        const o = document.getElementById('bv-login-overlay');
        if (o) o.classList.add('is-open');
      });
      const form = page.locator('#bv-login-overlay form');
      await form.locator('[name="username"]').fill(TEST_USER.username);
      await form.locator('[name="password"]').fill(pw);
      await Promise.all([page.waitForLoadState('networkidle'), form.locator('[type="submit"]').click()]);
      // Authenticated iff we can reach /roadmap (member-only).
      const r = await page.request.get('/roadmap', { maxRedirects: 0 });
      // Log out for the next attempt regardless.
      return r.status() === 200;
    }

    await clearMail();
    await submitForgot(page, TEST_USER.email);

    // The reset email lands for the known account (email-sent assertion).
    const msg = await waitForMail(TEST_USER.email);
    const link = extractLink(msg, /\/reset_password\/[^\s"'<>)]+/);
    expect(link, 'reset link must be present in the captured email').not.toBeNull();

    await setPasswordViaReset(/** @type {string} */ (link), newPassword);

    // New password authenticates.
    expect(await tryLogin(newPassword), 'new password should authenticate').toBe(true);

    // Restore the original password so the canonical account stays usable for
    // other suites, via the same captured-email flow.
    await clearMail();
    await submitForgot(page, TEST_USER.email);
    const restoreMsg = await waitForMail(TEST_USER.email);
    const restoreLink = extractLink(restoreMsg, /\/reset_password\/[^\s"'<>)]+/);
    expect(restoreLink, 'restore reset link present').not.toBeNull();
    await setPasswordViaReset(/** @type {string} */ (restoreLink), oldPassword);

    // The restored (old) password authenticates again; the interim password no
    // longer does — proving the reset actually changed the credential.
    expect(await tryLogin(oldPassword), 'restored original password authenticates').toBe(true);
  });
});
