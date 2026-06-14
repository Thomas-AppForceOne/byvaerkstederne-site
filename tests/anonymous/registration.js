// @ts-check
'use strict';

/**
 * WI-6 — registration + activation coverage (success and failure paths).
 *
 * Exercises the real login + email plugin path. Forms are filled and submitted
 * through the browser so the session cookie and Grav forms CSRF nonce stay
 * coherent (an out-of-band POST is rejected as "form timed out"). Email-bearing
 * assertions read the captured activation message from the Mailpit sink
 * (WI-1/WI-6) and drive the token extracted from it — proving transport + token
 * usability.
 *
 * Gating (no silent passes):
 *   - The whole describe needs the `membership_signup` feature ON (the form is
 *     404/redirect otherwise). We probe GET /opret-medlemskab once; if not 200
 *     the suite skips with a reason naming the flag.
 *   - Mail-bearing tests additionally need a reachable Mailpit sink; they
 *     skip-with-reason when MAILPIT_URL is unset/unreachable.
 *
 * Created accounts use a unique pwtest* username per run (outside the
 * two-account allowlist) and are deleted in afterEach.
 */

const { test, expect } = require('@playwright/test');
const {
  uniqueSignup,
  submitRegistration,
  accountState,
  accountExists,
  removeSignupAccount,
} = require('../helpers/registration');
const {
  isMailSinkConfigured,
  mailSinkUrl,
  clearMail,
  waitForMail,
  extractLink,
} = require('../helpers/mail');

let signupEnabled = false;

/** Disable the theme's client-side submit guard so a bad value reaches the
 *  server (proving SERVER-side rejection, per WI-5/WI-7). */
async function disableClientValidation(page) {
  await page.evaluate(() => {
    const form = document.querySelector('.bv-register-card form');
    if (form) {
      const clone = form.cloneNode(true);
      form.parentNode?.replaceChild(clone, form);
    }
  });
}

test.describe('Registration & activation (WI-2/WI-6)', () => {
  /** @type {string[]} usernames created during the run, for teardown */
  const created = [];

  test.beforeAll(async ({ request }) => {
    const res = await request.get('/opret-medlemskab', { maxRedirects: 0 });
    signupEnabled = res.status() === 200;
  });

  test.beforeEach(() => {
    test.skip(
      !signupEnabled,
      'membership_signup feature is OFF (GET /opret-medlemskab not 200) — registration suite skipped',
    );
  });

  test.afterEach(() => {
    while (created.length) {
      const u = created.pop();
      if (u) removeSignupAccount(u);
    }
  });

  test('success: valid registration creates a DISABLED account', async ({ page }) => {
    const who = uniqueSignup('a');
    created.push(who.username);
    const { finalUrl } = await submitRegistration(page, who);
    // Success redirects to /.
    expect(finalUrl, 'successful registration redirects to /').toMatch(/\/$|127\.0\.0\.1:\d+\/?$/);
    expect(accountExists(who.username), 'account YAML should be created').toBe(true);
    expect(accountState(who.username), 'new account must be state: disabled (WI-2)').toBe('disabled');
  });

  test('success: registration shows the Danish activation notice, not "welcome"', async ({ page }) => {
    const who = uniqueSignup('b');
    created.push(who.username);
    await submitRegistration(page, who);
    // The flash renders on the / redirect target (WI-1 messages partial).
    const body = (await page.textContent('body')) || '';
    expect(body.toLowerCase(), 'Danish activation-pending flash present').toMatch(/aktiver|tjek din indbakke/);
    expect(body, 'previous English "welcome" copy gone').not.toMatch(/your account has been successfully created/i);
  });

  test('failure: missing/garbage CSRF nonce is rejected (no account created)', async ({ page }) => {
    const who = uniqueSignup('c');
    await page.goto('/opret-medlemskab');
    // Tamper the nonce field value in the DOM, then submit through the browser.
    await page.evaluate(() => {
      const n = document.querySelector('input[name="form-nonce"]');
      if (n) /** @type {HTMLInputElement} */ (n).value = 'deadbeefdeadbeefdeadbeefdeadbeef';
    });
    await disableClientValidation(page);
    await page.fill('input[name="data[fullname]"]', who.fullName);
    await page.fill('input[name="data[email]"]', who.email);
    await page.fill('input[name="data[username]"]', who.username);
    await page.fill('input[name="data[password1]"]', who.password);
    await page.fill('input[name="data[password2]"]', who.password);
    await Promise.all([
      page.waitForLoadState('networkidle'),
      page.click('button[type="submit"], input[type="submit"]'),
    ]);
    expect(accountExists(who.username), 'no account on bad nonce').toBe(false);
  });

  test('failure: weak password is rejected server-side (no account created)', async ({ page }) => {
    const who = { ...uniqueSignup('d'), password: 'short1' }; // 6 chars, no upper
    await page.goto('/opret-medlemskab');
    await disableClientValidation(page); // force the bad value to the server
    await page.fill('input[name="data[fullname]"]', who.fullName);
    await page.fill('input[name="data[email]"]', who.email);
    await page.fill('input[name="data[username]"]', who.username);
    await page.fill('input[name="data[password1]"]', who.password);
    await page.fill('input[name="data[password2]"]', who.password);
    await Promise.all([
      page.waitForLoadState('networkidle'),
      page.click('button[type="submit"], input[type="submit"]'),
    ]);
    expect(accountExists(who.username), 'weak password must not create an account (WI-5)').toBe(false);
  });

  test('failure: invalid username pattern is rejected server-side (no account created)', async ({
    page,
  }) => {
    await page.goto('/opret-medlemskab');
    await disableClientValidation(page);
    await page.fill('input[name="data[fullname]"]', 'Bad Name');
    await page.fill('input[name="data[email]"]', 'badname@example.invalid');
    await page.fill('input[name="data[username]"]', 'Has Spaces!'); // violates ^[a-z0-9_-]{3,16}$
    await page.fill('input[name="data[password1]"]', 'Abcdefg1');
    await page.fill('input[name="data[password2]"]', 'Abcdefg1');
    await Promise.all([
      page.waitForLoadState('networkidle'),
      page.click('button[type="submit"], input[type="submit"]'),
    ]);
    // Invalid username must not create an account file under that name. We
    // cannot read an arbitrary name with the strict helper, so assert the
    // form did not redirect to / (it re-rendered with an error).
    expect(page.url(), 'invalid username must keep us on the form').toContain('/opret-medlemskab');
  });

  test('failure: mismatched password confirmation is rejected (WI-7, no account)', async ({ page }) => {
    const who = uniqueSignup('e');
    await page.goto('/opret-medlemskab');
    await disableClientValidation(page);
    await page.fill('input[name="data[fullname]"]', who.fullName);
    await page.fill('input[name="data[email]"]', who.email);
    await page.fill('input[name="data[username]"]', who.username);
    await page.fill('input[name="data[password1]"]', who.password);
    await page.fill('input[name="data[password2]"]', 'Different9');
    await Promise.all([
      page.waitForLoadState('networkidle'),
      page.click('button[type="submit"], input[type="submit"]'),
    ]);
    expect(accountExists(who.username), 'mismatched passwords must not create an account').toBe(false);
  });

  test('failure: duplicate username is rejected', async ({ page }) => {
    const who = uniqueSignup('f');
    created.push(who.username);
    const first = await submitRegistration(page, who);
    expect(first.finalUrl, 'first registration succeeds (→ /)').toMatch(/\/$|127\.0\.0\.1:\d+\/?$/);
    expect(accountExists(who.username)).toBe(true);
    // Second registration with the same username, different email — must fail.
    await submitRegistration(page, { ...who, email: `dup-${who.email}` });
    expect(page.url(), 'duplicate username must re-render the form, not redirect to /').toContain(
      '/opret-medlemskab',
    );
  });

  // ── Email-bearing: activation token usability ─────────────────────────────
  test('activation: email captured with tier From, token enables the account', async ({ page }) => {
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — activation email test skipped`,
    );

    const who = uniqueSignup('g');
    created.push(who.username);

    await clearMail();
    await submitRegistration(page, who);
    expect(accountState(who.username)).toBe('disabled');

    // Exactly one message to the registrant, From the tier identity (WI-1).
    const msg = await waitForMail(who.email);
    const from = (msg.From && msg.From.Address) || '';
    expect(from, 'activation From must be the tier noreply identity').toBe('noreply@hackersbychoice.dk');
    expect(from, 'kontakt@ must never be the transactional From').not.toContain('kontakt@');

    // Negative-before-positive: the disabled account cannot reach /roadmap.
    const before = await page.request.get('/roadmap', { maxRedirects: 0 });
    expect(before.status(), 'disabled account must not reach /roadmap').not.toBe(200);

    // Extract the activation link from the captured email and drive it.
    const link = extractLink(msg, /\/activate_user\/[^\s"'<>)]+/);
    expect(link, 'activation link must be present in the captured email').not.toBeNull();
    await page.goto(/** @type {string} */ (link));
    expect(accountState(who.username), 'token must flip the account to enabled').toBe('enabled');
  });

  test('activation failure: a tampered token does NOT enable the account', async ({ page }) => {
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — tampered-token test skipped`,
    );

    const who = uniqueSignup('h');
    created.push(who.username);

    await clearMail();
    await submitRegistration(page, who);
    const msg = await waitForMail(who.email);
    const link = extractLink(msg, /\/activate_user\/[^\s"'<>)]+/);
    expect(link).not.toBeNull();

    // Mutate one hex character of the token.
    const bad = /** @type {string} */ (link).replace(/token:([a-f0-9]{31})[a-f0-9]/, 'token:$1f');
    expect(bad, 'tampered link must differ from the real one').not.toBe(link);
    await page.goto(bad);
    expect(accountState(who.username), 'tampered token must leave the account disabled').toBe('disabled');
  });
});
