// @ts-check
'use strict';

/**
 * Registration anti-abuse — honeypot field (success + failure paths).
 *
 * The registration form carries a hidden `website` field of type `honeypot`
 * (register.md), visually hidden via .form-honeybear (register.html.twig).
 * Humans never see or fill it; bots fill every field. The forms plugin rejects
 * any submission where a honeypot-type field is non-empty
 * (form.php onFormValidationProcessed → ValidationException), so no account is
 * created and no activation email is sent.
 *
 * Gating: the whole describe needs `membership_signup` ON (the form is
 * 404/redirect otherwise) — same probe-and-skip-with-reason as the WI-6 suite.
 * Created accounts use a unique pwtest* username and are removed in afterEach.
 */

const { test, expect } = require('@playwright/test');
const { uniqueSignup, accountExists, removeSignupAccount } = require('../helpers/registration');

let signupEnabled = false;

/**
 * Fill and submit the registration form through the browser (keeps the CSRF
 * nonce coherent). When `honeypotValue` is set, populate the hidden honeypot
 * field directly via the DOM — exactly what a bot that fills every field does.
 *
 * @param {import('@playwright/test').Page} page
 * @param {{username:string,email:string,fullName:string,password:string}} who
 * @param {string|null} honeypotValue
 */
async function submitWithHoneypot(page, who, honeypotValue) {
  await page.goto('/opret-medlemskab');
  const nonce = page.locator('input[name="form-nonce"]');
  if ((await nonce.count()) === 0) {
    throw new Error('registration form not present (is signup enabled?)');
  }
  await page.fill('input[name="data[fullname]"]', who.fullName);
  await page.fill('input[name="data[email]"]', who.email);
  await page.fill('input[name="data[username]"]', who.username);
  await page.fill('input[name="data[password1]"]', who.password);
  await page.fill('input[name="data[password2]"]', who.password);
  if (honeypotValue !== null) {
    // The honeypot is CSS-hidden, so set its value directly (page.fill refuses
    // a non-visible element). This is the bot behaviour the field detects.
    await page.evaluate((val) => {
      const el = /** @type {HTMLInputElement|null} */ (
        document.querySelector('input[name="data[website]"]')
      );
      if (el) el.value = val;
    }, honeypotValue);
  }
  await Promise.all([
    page.waitForLoadState('networkidle'),
    page.click('button[type="submit"], input[type="submit"]'),
  ]);
}

test.describe('Registration honeypot (anti-spam)', () => {
  /** @type {string[]} */
  const created = [];

  test.beforeAll(async ({ request }) => {
    const res = await request.get('/opret-medlemskab', { maxRedirects: 0 });
    signupEnabled = res.status() === 200;
  });

  test.beforeEach(() => {
    // Precondition skip (feature flag), not a regression mask — mirrors the
    // WI-6 suite's probe.
    test.skip(!signupEnabled, 'membership_signup is off (GET /opret-medlemskab != 200)');
  });

  test.afterEach(() => {
    while (created.length) removeSignupAccount(created.pop());
  });

  test('the honeypot field is present and rendered hidden', async ({ page }) => {
    await page.goto('/opret-medlemskab');
    const hp = page.locator('input[name="data[website]"]');
    await expect(hp).toHaveCount(1);
    // Hidden from humans: off-screen via .form-honeybear, not user-visible.
    await expect(hp).toBeHidden();
  });

  test('FAILURE: a filled honeypot is rejected and creates no account', async ({ page }) => {
    const who = uniqueSignup('hp');
    created.push(who.username); // teardown even if (wrongly) created
    await submitWithHoneypot(page, who, 'http://spam.example');

    // Rejected by the forms plugin: no account, and not redirected to "/".
    expect(accountExists(who.username)).toBe(false);
    expect(page.url()).toContain('/opret-medlemskab');
  });

  test('SUCCESS: an empty honeypot lets a valid registration through', async ({ page }) => {
    const who = uniqueSignup('ok');
    created.push(who.username);
    await submitWithHoneypot(page, who, null);

    // The honeypot guard does not interfere with a real signup: the account is
    // created (disabled, pending email verification — WI-2).
    expect(accountExists(who.username)).toBe(true);
  });
});
