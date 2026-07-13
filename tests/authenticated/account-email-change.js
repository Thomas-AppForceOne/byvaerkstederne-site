// @ts-check
'use strict';

/**
 * Account self-service — email change, verify-new-address-first
 * (account_self_service_specification.md §6/§10).
 *
 *   - happy path round-trip: request → notice to the OLD address + confirm
 *     link to the NEW address (mail layer) → confirm → YAML email swapped →
 *     completion notice to the old address;
 *   - token reuse and expired tokens rejected with the one generic flash;
 *   - wrong re-auth password rejected, no mail sent;
 *   - occupied target: byte-identical neutral flash, informational mail to
 *     the existing owner, no pending state written;
 *   - resend re-mints (the first link dies); cancel clears the pending state;
 *   - the request throttle kicks in after the per-account budget.
 *
 * Mail-layer assertions need the Mailpit sink (scripts/mailpit-up.sh) —
 * each test skips-with-reason when it is unreachable. Destructive → runs on
 * a disposable account; the occupied probe uses the seeded pw-test-org's
 * ADDRESS only (its account is never mutated).
 */

const { test, expect } = require('@playwright/test');
const { hasUserPassword } = require('../helpers/auth');
const { TEST_ORGANIZER } = require('../helpers/accounts');
const {
  isMailSinkConfigured,
  mailSinkUrl,
  clearMail,
  waitForMail,
  expectNoMail,
  extractLink,
} = require('../helpers/mail');
const {
  createDisposableAccount,
  removeDisposableAccount,
  readAccountYaml,
  backdatePendingEmail,
  resetEmailChangeThrottle,
  loginAs,
} = require('../helpers/self-service');

const CONFIRM_LINK = /\/konto\/confirm-email-change\/[^\s"'<>)\]]+/;
const NEUTRAL_FLASH = 'Hvis adressen kan bruges';

/** Fill + submit the request-email-change form on /konto. */
async function submitEmailChange(page, { newEmail, currentPassword }) {
  await page.goto('/konto');
  await page.fill('#account-new-email', newEmail);
  await page.fill('#account-email-password', currentPassword);
  await page.click('#email form[action="/konto/request-email-change"] button[type="submit"]');
  await page.waitForURL(/\/konto/);
}

test.describe('account self-service: email change', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');
  test.describe.configure({ mode: 'serial' });

  /** @type {{username:string,email:string,fullName:string,password:string}} */
  let acct;

  test.beforeAll(() => {
    acct = createDisposableAccount({ tag: 'em' });
  });

  test.beforeEach(async () => {
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertions unavailable`,
    );
    resetEmailChangeThrottle();
    await clearMail();
  });

  test.afterAll(() => {
    resetEmailChangeThrottle();
    if (acct) removeDisposableAccount(acct.username);
  });

  test('happy path: request → mails to both addresses → confirm → swap → completion notice', async ({ page }) => {
    const newEmail = `${acct.username}-ny@example.invalid`;
    expect(await loginAs(page, acct)).toBe(true);
    await submitEmailChange(page, { newEmail, currentPassword: acct.password });
    await expect(page.locator('.bv-message--success')).toContainText(NEUTRAL_FLASH);

    // Old address gets the heads-up; new address gets the confirm link.
    await waitForMail(acct.email);
    const confirmMsg = await waitForMail(newEmail);
    const link = extractLink(confirmMsg, CONFIRM_LINK);
    expect(link).toBeTruthy();

    // Pending state visible on /konto (address + resend/cancel affordances).
    await page.goto('/konto');
    await expect(page.locator('[data-pending="email"]')).toContainText(newEmail);

    await clearMail();
    await page.goto(link);
    await expect(page.locator('.bv-message--success')).toContainText('Din e-mailadresse er opdateret');

    const yaml = readAccountYaml(acct.username);
    expect(yaml).toContain(`email: ${newEmail}`);
    expect(yaml).not.toContain('pending_email');

    // Completion notice lands at the OLD address (hijack visibility).
    await waitForMail(acct.email);
    acct.email = newEmail; // subsequent tests use the swapped address
  });

  test('token reuse is rejected with the generic flash', async ({ page }) => {
    const newEmail = `${acct.username}-genbrug@example.invalid`;
    expect(await loginAs(page, acct)).toBe(true);
    await submitEmailChange(page, { newEmail, currentPassword: acct.password });
    const link = extractLink(await waitForMail(newEmail), CONFIRM_LINK);

    await page.goto(link);
    await expect(page.locator('.bv-message--success')).toContainText('Din e-mailadresse er opdateret');
    acct.email = newEmail;

    // Second use: pending_email is consumed → one generic failure.
    await page.goto(link);
    await expect(page.locator('.bv-message--error')).toContainText('Linket er ugyldigt eller udløbet');
  });

  test('expired token is rejected with the generic flash', async ({ page }) => {
    const newEmail = `${acct.username}-udloeb@example.invalid`;
    expect(await loginAs(page, acct)).toBe(true);
    await submitEmailChange(page, { newEmail, currentPassword: acct.password });
    const link = extractLink(await waitForMail(newEmail), CONFIRM_LINK);

    backdatePendingEmail(acct.username);
    await page.goto(link);
    await expect(page.locator('.bv-message--error')).toContainText('Linket er ugyldigt eller udløbet');
    expect(readAccountYaml(acct.username)).not.toContain(`email: ${newEmail}`);
  });

  test('wrong re-auth password is rejected and sends no mail', async ({ page }) => {
    const newEmail = `${acct.username}-afvist@example.invalid`;
    expect(await loginAs(page, acct)).toBe(true);
    await submitEmailChange(page, { newEmail, currentPassword: 'WrongPass1' });

    await expect(page.locator('.bv-message--error')).toContainText('Forkert adgangskode');
    expect(await expectNoMail(newEmail)).toBe(true);
  });

  test('occupied target: identical neutral flash, info mail to owner, no pending state', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    await submitEmailChange(page, { newEmail: TEST_ORGANIZER.email, currentPassword: acct.password });

    // Byte-identical UI response to the available-address case (§6).
    await expect(page.locator('.bv-message--success')).toContainText(NEUTRAL_FLASH);
    // The existing owner is informed instead of receiving a confirm link.
    const msg = await waitForMail(TEST_ORGANIZER.email);
    expect(JSON.stringify(msg)).not.toMatch(CONFIRM_LINK);
    // No pending change was stored FOR THE OCCUPIED ADDRESS (an earlier
    // test's rejected-expiry pending may legitimately still sit on the
    // account — it must not have been touched).
    expect(readAccountYaml(acct.username)).not.toContain(TEST_ORGANIZER.email);
  });

  test('resend re-mints the token — the first link is dead, the new one works', async ({ page }) => {
    const newEmail = `${acct.username}-igen@example.invalid`;
    expect(await loginAs(page, acct)).toBe(true);
    await submitEmailChange(page, { newEmail, currentPassword: acct.password });
    const firstLink = extractLink(await waitForMail(newEmail), CONFIRM_LINK);

    await clearMail();
    await page.goto('/konto');
    await page.click('#email form[action="/konto/resend-email-change"] button[type="submit"]');
    await page.waitForURL(/\/konto/);
    await expect(page.locator('.bv-message--success')).toContainText('nyt bekræftelseslink');
    const secondLink = extractLink(await waitForMail(newEmail), CONFIRM_LINK);
    expect(secondLink).not.toBe(firstLink);

    await page.goto(firstLink);
    await expect(page.locator('.bv-message--error')).toContainText('Linket er ugyldigt eller udløbet');

    await page.goto(secondLink);
    await expect(page.locator('.bv-message--success')).toContainText('Din e-mailadresse er opdateret');
    acct.email = newEmail;
  });

  test('cancel clears the pending change', async ({ page }) => {
    const newEmail = `${acct.username}-fortryd@example.invalid`;
    expect(await loginAs(page, acct)).toBe(true);
    await submitEmailChange(page, { newEmail, currentPassword: acct.password });
    expect(readAccountYaml(acct.username)).toContain('pending_email');

    await page.goto('/konto');
    await page.click('#email form[action="/konto/cancel-email-change"] button[type="submit"]');
    await page.waitForURL(/\/konto/);
    await expect(page.locator('.bv-message--success')).toContainText('annulleret');
    expect(readAccountYaml(acct.username)).not.toContain('pending_email');
    expect(await page.locator('[data-pending="email"]').count()).toBe(0);
  });

  test('the per-account request throttle kicks in', async ({ page }) => {
    expect(await loginAs(page, acct)).toBe(true);
    // Drive the endpoint directly (page.request shares session + UA, so the
    // page-minted nonce verifies): every POST counts against the budget
    // (account_max: 5), so requests 1-5 succeed with the PRG 303 and the
    // 6th is refused with 429.
    await page.goto('/konto');
    const nonce = await page
      .locator('#email form[action="/konto/request-email-change"] input[name="account-nonce"]')
      .inputValue();
    for (let i = 1; i <= 6; i += 1) {
      const resp = await page.request.post('/konto/request-email-change', {
        maxRedirects: 0,
        form: {
          'account-nonce': nonce,
          new_email: `${acct.username}-t${i}@example.invalid`,
          current_password: acct.password,
        },
      });
      expect(resp.status(), `request #${i}`).toBe(i <= 5 ? 303 : 429);
    }
  });
});
