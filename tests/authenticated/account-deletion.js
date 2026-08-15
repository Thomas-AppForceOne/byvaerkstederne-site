// @ts-check
'use strict';

/**
 * Account self-service — deletion request + reinstatement
 * (account_self_service_specification.md §2.8/§10).
 *
 *   - requesting deletion (re-auth + explicit confirmation) logs the member
 *     out, invalidates remember-me tokens, stamps deletion_requested_at,
 *     and emails the member the hard-delete date;
 *   - /konto is unreachable afterwards (logged out → login redirect);
 *   - logging in again inside the window reinstates: marker gone,
 *     "genaktiveret" flash, reinstatement email;
 *   - negatives: missing confirmation checkbox, wrong re-auth password,
 *     tampered nonce — each leaves no marker.
 *
 * Destructive → disposable accounts. The hard-delete side of the lifecycle
 * (purge + anonymization) is covered by account-purge.js.
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
  setDeletionMarker,
  withLocalhostFlagOff,
  loginAs,
  rememberMeFileExists,
} = require('../helpers/self-service');

/** Fill + submit the delete-account form on /konto. */
async function submitDeletion(page, { password, confirm = true } = {}) {
  await page.goto('/konto');
  await page.fill('#account-delete-password', password);
  if (confirm) {
    await page.check('#delete input[name="confirm_deletion"]');
  }
  await page.click('#delete button[type="submit"]');
  await page.waitForLoadState('networkidle');
}

test.describe('account self-service: deletion request + reinstatement', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');

  test('request logs out, invalidates remember-me, stamps the marker; login reinstates', async ({ page }) => {
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertions unavailable`,
    );
    const acct = createDisposableAccount({ tag: 'de' });
    try {
      await clearMail();
      // Log in WITH remember-me so a token file exists to invalidate.
      expect(await loginAs(page, acct, { rememberMe: true })).toBe(true);
      expect(rememberMeFileExists(acct.username)).toBe(true);

      await submitDeletion(page, { password: acct.password });

      // Logged out on the front page with the consequence flash.
      await expect(page).toHaveURL(/\/$/);
      await expect(page.locator('.bv-message--success')).toContainText('markeret til sletning');
      expect(await page.locator('.bv-nav__user').count()).toBe(0);

      // Marker stamped, remember-me tokens gone, member informed by mail.
      expect(readAccountYaml(acct.username)).toContain('deletion_requested_at');
      expect(rememberMeFileExists(acct.username)).toBe(false);
      const msg = await waitForMail(acct.email);
      expect(JSON.stringify(msg)).toContain('slettes');

      // /konto is unreachable — the member is anonymous now.
      await page.goto('/konto');
      await expect(page).toHaveURL(/\/login/);

      // Reinstatement: signing in again clears the marker (§2.8).
      await clearMail();
      expect(await loginAs(page, acct)).toBe(true);
      // The login plugin's own "successfully logged in" flash renders next
      // to the reinstatement one — filter for ours.
      await expect(
        page.locator('.bv-message--success', { hasText: 'genaktiveret' }),
      ).toBeVisible();
      expect(readAccountYaml(acct.username)).not.toContain('deletion_requested_at');
      await waitForMail(acct.email); // reinstatement notice
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('missing confirmation checkbox is refused; no marker is stamped', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'dc' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      // The checkbox is `required` client-side; exercise the server rule
      // out-of-band with the page-minted nonce.
      await page.goto('/konto');
      const nonce = await page
        .locator('#delete input[name="account-nonce"]')
        .inputValue();
      const resp = await page.request.post('/konto/request-deletion', {
        maxRedirects: 0,
        form: { 'account-nonce': nonce, current_password: acct.password },
      });
      expect(resp.status()).toBe(400);
      expect(readAccountYaml(acct.username)).not.toContain('deletion_requested_at');
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('wrong re-auth password is refused; no marker is stamped', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'dw' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      await submitDeletion(page, { password: 'WrongPass1' });
      await expect(page.locator('.bv-message--error')).toContainText('Forkert adgangskode');
      // Still logged in — the request never went through.
      await expect(page.locator('.bv-nav__user')).toBeVisible();
      expect(readAccountYaml(acct.username)).not.toContain('deletion_requested_at');
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('reinstatement still works with the flag OFF (unflagged by design)', async ({ page }) => {
    // Load-bearing test for the design decision: gating the login hook on
    // the flag would strand pending-deletion members while the purge still
    // deletes them. A future "cleanup" that adds the flag check must fail
    // here.
    const acct = createDisposableAccount({ tag: 'df' });
    const restoreFlag = withLocalhostFlagOff('account_self_service');
    try {
      // Marker inside the window (as if requested while the flag was on).
      setDeletionMarker(acct.username, new Date().toISOString().replace(/\.\d+Z$/, 'Z'));

      expect(await loginAs(page, acct)).toBe(true);
      await expect(
        page.locator('.bv-message--success', { hasText: 'genaktiveret' }),
      ).toBeVisible();
      expect(readAccountYaml(acct.username)).not.toContain('deletion_requested_at');
    } finally {
      restoreFlag();
      removeDisposableAccount(acct.username);
    }
  });

  test('tampered nonce is a 403; no marker is stamped', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'dn' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      const resp = await page.request.post('/konto/request-deletion', {
        maxRedirects: 0,
        form: {
          'account-nonce': 'tampered-nonce-value',
          current_password: acct.password,
          confirm_deletion: '1',
        },
      });
      expect(resp.status()).toBe(403);
      expect(readAccountYaml(acct.username)).not.toContain('deletion_requested_at');
    } finally {
      removeDisposableAccount(acct.username);
    }
  });
});
