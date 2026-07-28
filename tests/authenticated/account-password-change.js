// @ts-check
'use strict';

/**
 * Account self-service — change password
 * (account_self_service_specification.md §10).
 *
 *   - failures first (wrong current password, mismatched pair, policy
 *     violation) so the account's password is still known;
 *   - then the happy path: change succeeds, the OLD password stops working
 *     and the NEW one logs in.
 *
 * Destructive → runs on a disposable account, never the seeded ones.
 */

const { test, expect } = require('@playwright/test');
const path = require('path');
const { hasUserPassword } = require('../helpers/auth');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));
const {
  createDisposableAccount,
  removeDisposableAccount,
  loginAs,
  logout,
} = require('../helpers/self-service');

const { port: PORT } = discoverGravEnv(path.resolve(__dirname, '..', '..'));
const BASE = `http://127.0.0.1:${PORT}`;

const NEW_PASSWORD = 'Zyxwvut-Fixture-9'; // >=12 per system.pwd_regex, no blocklisted term

/**
 * Fill and submit the change-password form on /konto.
 * @param {import('@playwright/test').Page} page
 * @param {{current: string, new1: string, new2: string}} fields
 */
async function submitPasswordChange(page, fields) {
  await page.goto('/konto');
  await page.fill('#account-current-password', fields.current);
  await page.fill('#account-password1', fields.new1);
  await page.fill('#account-password2', fields.new2);
  await page.click('#password button[type="submit"]');
  await page.waitForURL(/\/konto/);
}

test.describe('account self-service: change password', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');
  test.describe.configure({ mode: 'serial' });

  /** @type {{username:string,email:string,fullName:string,password:string}} */
  let acct;

  test.beforeAll(() => {
    acct = createDisposableAccount({ tag: 'pw' });
  });

  test.afterAll(() => {
    if (acct) removeDisposableAccount(acct.username);
  });

  test('wrong current password is rejected', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await submitPasswordChange(page, { current: 'WrongPass1', new1: NEW_PASSWORD, new2: NEW_PASSWORD });
    await expect(page.locator('.bv-message--error')).toContainText('Forkert adgangskode');
  });

  test('mismatched new passwords are rejected', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await submitPasswordChange(page, { current: acct.password, new1: NEW_PASSWORD, new2: 'Different1' });
    await expect(page.locator('.bv-message--error')).toContainText('ikke ens');
  });

  test('a blocklisted new password is rejected', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    // Long enough for pwd_regex — only the blocklist can refuse it.
    await submitPasswordChange(page, {
      current: acct.password,
      new1: 'hundested-sommer',
      new2: 'hundested-sommer',
    });
    await expect(page.locator('.bv-message--error')).toContainText('for nemt at gætte');
  });

  test('policy-violating new password is rejected', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await submitPasswordChange(page, { current: acct.password, new1: 'weakpass', new2: 'weakpass' });
    await expect(page.locator('.bv-message--error')).toContainText('mindst 8 tegn');
  });

  test('happy path: old password stops working, new password logs in', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await submitPasswordChange(page, { current: acct.password, new1: NEW_PASSWORD, new2: NEW_PASSWORD });
    await expect(page.locator('.bv-message--success')).toContainText('Din adgangskode er ændret');

    await logout(page);

    // Old password refused…
    expect(await loginAs(page, { username: acct.username, password: acct.password })).toBe(false);
    // …new password accepted.
    expect(await loginAs(page, { username: acct.username, password: NEW_PASSWORD })).toBe(true);
  });

  test('a second device cannot re-auth with the OLD password after a change', async ({ page, browser }) => {
    // Regression guard for the session-epoch read hazard: device B's
    // session snapshot predates the password change made on device A —
    // re-auth must verify against the on-disk hash, never the snapshot.
    const xdAcct = createDisposableAccount({ tag: 'xd' });
    // >=12 per system.pwd_regex, and free of blocklisted terms — an earlier
    // 'Qwertyu…' fixture was correctly refused by the blocklist itself.
    const changed = 'Zzxxccvv-Fixture-7';
    const ctxB = await browser.newContext({ baseURL: BASE });
    try {
      // Device B logs in FIRST (its session snapshot holds the old hash)
      // and mints an email-change nonce while the form is rendered.
      const pageB = await ctxB.newPage();
      expect(await loginAs(pageB, xdAcct)).toBe(true);
      await pageB.goto('/konto');
      const nonceB = await pageB
        .locator('#email form[action="/konto/request-email-change"] input[name="account-nonce"]')
        .inputValue();

      // Device A changes the password.
      expect(await loginAs(page, xdAcct)).toBe(true);
      await submitPasswordChange(page, { current: xdAcct.password, new1: changed, new2: changed });
      await expect(page.locator('.bv-message--success')).toContainText('Din adgangskode er ændret');

      // Device B: re-auth with the OLD password must be refused…
      const oldResp = await pageB.request.post('/konto/request-email-change', {
        maxRedirects: 0,
        form: {
          'account-nonce': nonceB,
          new_email: `${xdAcct.username}-xd@example.invalid`,
          current_password: xdAcct.password,
        },
      });
      expect(oldResp.status()).toBe(403);

      // …and with the NEW password accepted from the same stale session.
      const newResp = await pageB.request.post('/konto/request-email-change', {
        maxRedirects: 0,
        form: {
          'account-nonce': nonceB,
          new_email: `${xdAcct.username}-xd@example.invalid`,
          current_password: changed,
        },
      });
      expect(newResp.status()).toBe(303);
    } finally {
      await ctxB.close();
      removeDisposableAccount(xdAcct.username);
    }
  });
});
