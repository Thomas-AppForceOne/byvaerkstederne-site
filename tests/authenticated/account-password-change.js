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
const { hasUserPassword } = require('../helpers/auth');
const {
  createDisposableAccount,
  removeDisposableAccount,
  loginAs,
  logout,
} = require('../helpers/self-service');

const NEW_PASSWORD = 'Zyxwvut9';

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
});
