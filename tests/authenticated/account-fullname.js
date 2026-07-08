// @ts-check
'use strict';

/**
 * Account self-service — change display name
 * (account_self_service_specification.md §10).
 *
 *   - success: the new name lands in the account YAML AND the header chip;
 *   - failure: markup in the name is refused; over-length input is refused
 *     server-side (posted out-of-band because the input's maxlength clips
 *     browser input); a tampered nonce is a 403.
 *
 * Destructive → runs on a disposable account, never the seeded ones.
 */

const { test, expect } = require('@playwright/test');
const { hasUserPassword } = require('../helpers/auth');
const {
  createDisposableAccount,
  removeDisposableAccount,
  readAccountYaml,
  loginAs,
} = require('../helpers/self-service');

test.describe('account self-service: change fullname', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');
  test.describe.configure({ mode: 'serial' });

  /** @type {{username:string,email:string,fullName:string,password:string}} */
  let acct;

  test.beforeAll(() => {
    acct = createDisposableAccount({ tag: 'fn' });
  });

  test.afterAll(() => {
    if (acct) removeDisposableAccount(acct.username);
  });

  test('renders the account card with the name form', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await page.goto('/konto');
    await expect(page.locator('.bv-auth-card')).toBeVisible();
    await expect(page.locator('#account-fullname-input')).toHaveValue(acct.fullName);
  });

  test('happy path: name change lands in YAML and header chip', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await page.goto('/konto');
    await page.fill('#account-fullname-input', 'Nyt Navn Tester');
    await page.click('#name button[type="submit"]');
    await page.waitForURL(/\/konto/);

    await expect(page.locator('.bv-message--success')).toContainText('Dit navn er opdateret');
    await expect(page.locator('.bv-nav__user')).toContainText('Nyt Navn Tester');
    expect(readAccountYaml(acct.username)).toMatch(/fullname:.*Nyt Navn Tester/);
  });

  test('markup in the name is refused', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await page.goto('/konto');
    await page.fill('#account-fullname-input', '<b>Ondsindet</b>');
    await page.click('#name button[type="submit"]');
    await page.waitForURL(/\/konto/);

    await expect(page.locator('.bv-message--error')).toContainText('Navnet må ikke indeholde');
    expect(readAccountYaml(acct.username)).not.toMatch(/Ondsindet/);
  });

  test('over-length name is refused server-side', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await page.goto('/konto');
    // The browser input clips at maxlength=80, so exercise the server rule
    // out-of-band with the page's own minted nonce (same session + UA).
    const nonce = await page.locator('#name input[name="account-nonce"]').inputValue();
    const resp = await page.request.post('/konto/change-fullname', {
      form: { 'account-nonce': nonce, fullname: 'x'.repeat(81) },
    });
    expect(resp.status()).toBe(400);
    expect(readAccountYaml(acct.username)).not.toMatch(/xxxxxxxxxx/);
  });

  test('tampered nonce is a 403', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    const resp = await page.request.post('/konto/change-fullname', {
      form: { 'account-nonce': 'tampered-nonce-value', fullname: 'Nonce Tester' },
    });
    expect(resp.status()).toBe(403);
    expect(readAccountYaml(acct.username)).not.toMatch(/Nonce Tester/);
  });
});
