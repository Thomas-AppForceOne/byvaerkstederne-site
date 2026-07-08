// @ts-check
'use strict';

/**
 * Account self-service — access request (arrangør)
 * (account_self_service_specification.md §8/§10).
 *
 *   - requesting shows the pending state and produces the admin email
 *     (recipient resolves per-tier: plugins.email.to, fallback
 *     site.author.email — the test asserts against the fallback since the
 *     Mailpit override sets no `to`);
 *   - a duplicate open request is refused (direct POST — the form is
 *     hidden while a request is open);
 *   - cancelling stamps the cooldown; an immediate re-request is refused;
 *   - an unrequestable role is refused;
 *   - once the group is granted (container-side YAML patch — simulating the
 *     manual super action), the state derives to granted and the marker is
 *     lazily cleared.
 *
 * Destructive → each test runs on its own disposable account (self-
 * contained, so retries never inherit half-consumed state or nonces from
 * a previous worker).
 */

const { test, expect } = require('@playwright/test');
const { hasUserPassword } = require('../helpers/auth');
const {
  isMailSinkConfigured,
  mailSinkUrl,
  clearMail,
  waitForMail,
} = require('../helpers/mail');
const {
  createDisposableAccount,
  removeDisposableAccount,
  readAccountYaml,
  grantGroups,
  loginAs,
} = require('../helpers/self-service');

// Committed fallback admin recipient (site.author.email in site.yaml) — the
// test-mode email.yaml sets no plugins.email.to.
const ADMIN_FALLBACK = 'kontakt@byvaerkstederne.dk';

/**
 * Mint the request-form nonce for the CURRENT session (the form must still
 * be rendered — i.e. no open request yet).
 */
async function mintRequestNonce(page) {
  await page.goto('/konto');
  return page
    .locator('#roles form[action="/konto/request-access"] input[name="account-nonce"]')
    .inputValue();
}

/** Submit the access-request form on /konto through the UI. */
async function submitAccessRequest(page, motivation) {
  await page.goto('/konto');
  await page.selectOption('#account-access-role', 'organizers');
  if (motivation) {
    await page.fill('#account-access-motivation', motivation);
  }
  await page.click('#roles form[action="/konto/request-access"] button[type="submit"]');
  await page.waitForURL(/\/konto/);
}

test.describe('account self-service: access request', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');

  test('request shows pending state, notifies admins; duplicate is refused', async ({ page }) => {
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    const acct = createDisposableAccount({ tag: 'ar' });
    try {
      await clearMail();
      expect(await loginAs(page, acct)).toBe(true);
      const nonce = await mintRequestNonce(page);

      await submitAccessRequest(page, 'Jeg vil gerne arrangere træworkshops.');
      await expect(page.locator('.bv-message--success')).toContainText('afventer godkendelse');
      await expect(page.locator('[data-pending="access"]')).toContainText('Arrangør');
      expect(readAccountYaml(acct.username)).toContain('access_request');

      const msg = await waitForMail(ADMIN_FALLBACK);
      expect(JSON.stringify(msg)).toContain(acct.username);

      // Duplicate open request: the form is hidden now, so forced browsing
      // is the only route — refused with 400.
      const resp = await page.request.post('/konto/request-access', {
        maxRedirects: 0,
        form: { 'account-nonce': nonce, role: 'organizers', motivation: '' },
      });
      expect(resp.status()).toBe(400);
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('cancel clears the request; immediate re-request hits the cooldown', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'ac' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      const nonce = await mintRequestNonce(page);
      await submitAccessRequest(page, '');

      await page.goto('/konto');
      await page.click('#roles form[action="/konto/cancel-access-request"] button[type="submit"]');
      await page.waitForURL(/\/konto/);
      await expect(page.locator('.bv-message--success')).toContainText('fortrudt');

      const yaml = readAccountYaml(acct.username);
      expect(yaml).not.toContain('access_request:');
      expect(yaml).toContain('access_request_cleared_at');

      // Cooldown (24h default) blocks the immediate re-request.
      const resp = await page.request.post('/konto/request-access', {
        maxRedirects: 0,
        form: { 'account-nonce': nonce, role: 'organizers', motivation: '' },
      });
      expect(resp.status()).toBe(429);
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('an unrequestable role is refused', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'au' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      const nonce = await mintRequestNonce(page);
      const resp = await page.request.post('/konto/request-access', {
        maxRedirects: 0,
        form: { 'account-nonce': nonce, role: 'admins', motivation: '' },
      });
      expect(resp.status()).toBe(400);
      expect(readAccountYaml(acct.username)).not.toContain('access_request');
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('granting the group derives to granted and clears the marker', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'gr' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      await submitAccessRequest(page, '');
      expect(readAccountYaml(acct.username)).toContain('access_request');

      // The manual super action: the group lands on the account YAML.
      grantGroups(acct.username, ['organizers']);

      await page.goto('/konto');
      // Granted: role chip visible, pending state gone…
      await expect(page.locator('.bv-account-roles__item', { hasText: 'Arrangør' })).toBeVisible();
      expect(await page.locator('[data-pending="access"]').count()).toBe(0);
      // …and the stale marker was lazily cleared from the YAML (§4.2).
      expect(readAccountYaml(acct.username)).not.toContain('access_request:');
    } finally {
      removeDisposableAccount(acct.username);
    }
  });
});
