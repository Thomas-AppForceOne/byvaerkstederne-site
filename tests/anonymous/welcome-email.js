// @ts-check
'use strict';

/**
 * Welcome email — success and failure paths.
 *
 * The welcome mail is sent by the login plugin from its ACTIVATION handler
 * (login.php: handleUserActivation), not at registration: with
 * send_activation_email on, the registration branch sends the activation mail
 * and skips the welcome one entirely. So the guarantee under test is
 * "activating the account produces the Danish welcome mail, and nothing short
 * of activation does".
 *
 * Two invariants beyond delivery, both of which have silent failure modes:
 *
 *   1. CONTENT SOURCE. The copy lives in the THEME override
 *      themes/byvaerkstederne/templates/emails/login/welcome.html.twig, which
 *      shadows the login plugin's stock template. If a plugin update renames
 *      the template key, our override stops being resolved and members get the
 *      stock English "Account Created" mail — delivery still succeeds, so only
 *      a content assertion catches it.
 *   2. FEATURE-FLAG DISCIPLINE. The mail may only describe surfaces that are
 *      released or in active testing (calendar, event creation, login, account
 *      self-service). Advertising a flag-gated surface (roadmap, feature
 *      suggestions, bug reports, vedtægter, referater, presse) sends new
 *      members looking for something they cannot reach.
 *
 * Gating mirrors registration.js: the describe needs the signup form reachable,
 * and mail-bearing tests need the Mailpit sink. Both skip WITH A REASON rather
 * than pass silently.
 */

const { test, expect } = require('@playwright/test');
const {
  uniqueSignup,
  submitRegistration,
  accountState,
  removeSignupAccount,
} = require('../helpers/registration');
const {
  isMailSinkConfigured,
  mailSinkUrl,
  clearMail,
  searchMail,
  getMessage,
  waitForMail,
  extractLink,
} = require('../helpers/mail');

let signupEnabled = false;

/** Subject shape: 'Velkommen til ' ~ site_name (site.title). */
const WELCOME_SUBJECT = /^Velkommen til /;

/** Captured messages to `to` whose subject is the welcome mail's, newest first. */
async function welcomeSummaries(to) {
  const all = await searchMail(to);
  return all.filter((m) => WELCOME_SUBJECT.test(String(m.Subject || '')));
}

/**
 * Poll until the welcome mail lands, then return it in full. Throws on
 * timeout — a missing welcome mail is a failed assertion, never a silent pass.
 */
async function waitForWelcome(to, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const hits = await welcomeSummaries(to);
    if (hits.length > 0) return getMessage(hits[0].ID);
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(
    `waitForWelcome: no "Velkommen til …" message to ${to} within ${timeoutMs}ms — ` +
      'is send_welcome_email on and the activation handler reaching the mailer?',
  );
}

/** True when NO welcome mail arrives for `to` within the settle window. */
async function noWelcomeWithin(to, settleMs = 3000) {
  const deadline = Date.now() + settleMs;
  while (Date.now() < deadline) {
    if ((await welcomeSummaries(to)).length > 0) return false;
    await new Promise((r) => setTimeout(r, 400));
  }
  return (await welcomeSummaries(to)).length === 0;
}

/** Text + HTML parts joined, for content assertions. */
function bodyOf(msg) {
  return `${msg.Text || ''}\n${msg.HTML || ''}`;
}

test.describe('Welcome email (post-activation)', () => {
  /** @type {string[]} usernames created during the run, for teardown */
  const created = [];

  test.beforeAll(async ({ request }) => {
    const res = await request.get('/opret-medlemskab', { maxRedirects: 0 });
    signupEnabled = res.status() === 200;
  });

  test.beforeEach(async () => {
    test.skip(
      !signupEnabled,
      'membership_signup feature is OFF (GET /opret-medlemskab not 200) — welcome-mail suite skipped',
    );
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — welcome-mail suite skipped`,
    );
  });

  test.afterEach(() => {
    while (created.length) {
      const u = created.pop();
      if (u) removeSignupAccount(u);
    }
  });

  test('success: activation sends the Danish welcome mail with calendar + account guidance', async ({
    page,
  }) => {
    const who = uniqueSignup('w');
    created.push(who.username);

    await clearMail();
    await submitRegistration(page, who);
    expect(accountState(who.username), 'registration must leave the account disabled').toBe(
      'disabled',
    );

    // Negative before positive: registration alone must NOT send the welcome
    // mail — the copy says "din konto er nu aktiv", which is only true after
    // the activation link has been used.
    expect(
      await noWelcomeWithin(who.email),
      'no welcome mail may be sent while the account is still disabled',
    ).toBe(true);

    // Drive the activation link out of the captured activation mail.
    const activation = await waitForMail(who.email);
    const link = extractLink(activation, /\/activate_user\/[^\s"'<>)]+/);
    expect(link, 'activation link must be present in the captured email').not.toBeNull();
    await page.goto(/** @type {string} */ (link));
    expect(accountState(who.username), 'activation must enable the account').toBe('enabled');

    const welcome = await waitForWelcome(who.email);
    const body = bodyOf(welcome);

    // Transport identity — same tier noreply as every other transactional mail.
    const from = (welcome.From && welcome.From.Address) || '';
    expect(from, 'welcome From must be the tier noreply identity').toBe(
      'noreply@hackersbychoice.dk',
    );

    // Content source: our theme override, not the plugin's stock template.
    expect(welcome.Subject, 'subject comes from the theme override').toMatch(WELCOME_SUBJECT);
    expect(body, 'stock English welcome copy must not resurface').not.toMatch(
      /account has been successfully created/i,
    );
    expect(body, 'greeting addresses the member by full name').toContain(who.fullName);

    // The surfaces the mail promises, in the words the UI actually uses.
    expect(body, 'calendar section present').toContain('Værkstedskalenderen');
    expect(body, 'capacity signup button named as the UI names it').toContain('Deltag');
    expect(body, 'drop-in button named as the UI names it').toContain('Interesseret');
    expect(body, 'personal calendar filter named').toContain('Mine aktiviteter');
    expect(body, 'account self-service section present').toContain('Min konto');
    expect(body, 'organiser path present').toContain('arrangør');
    for (const slug of [
      '/vaerksteder/makerspace',
      '/vaerksteder/krea-cafe',
      '/vaerksteder/groent-byvaerksted',
      '/vaerksteder/eventvaerkstedet',
      '/vaerkstedskalenderen',
      '/konto',
    ]) {
      expect(body, `links to ${slug}`).toContain(slug);
    }

    // Links must be absolute: mail clients render a root-relative href as
    // file:///… — the exact dead-link failure site_host exists to prevent.
    const hrefs = [...String(welcome.HTML || '').matchAll(/href="([^"]+)"/g)].map((m) => m[1]);
    expect(hrefs.length, 'the HTML part must carry links').toBeGreaterThan(0);
    for (const href of hrefs) {
      expect(href, `href must be absolute or mailto:, got ${href}`).toMatch(/^(https?:\/\/|mailto:)/);
    }
  });

  test('content rule: the welcome mail advertises no flag-gated surface', async ({ page }) => {
    const who = uniqueSignup('x');
    created.push(who.username);

    await clearMail();
    await submitRegistration(page, who);
    const activation = await waitForMail(who.email);
    const link = extractLink(activation, /\/activate_user\/[^\s"'<>)]+/);
    expect(link).not.toBeNull();
    await page.goto(/** @type {string} */ (link));

    const body = bodyOf(await waitForWelcome(who.email));

    // Each of these is behind a feature flag that is OFF on the deployed
    // tiers. Naming one in the welcome mail points a brand-new member at a
    // page or affordance they cannot reach. Remove the mention, or ship the
    // feature first — do not relax this test.
    for (const forbidden of [
      /roadmap/i,
      /rapport[eé]r fejl/i,
      /forsl[aå] feature/i,
      /vedt[æa]gter/i,
      /referater/i,
      /nyhedsbrev/i,
      /\/presse/i,
    ]) {
      expect(body, `unreleased surface named in the welcome mail: ${forbidden}`).not.toMatch(
        forbidden,
      );
    }
  });

  test('failure: a tampered activation token sends no welcome mail', async ({ page }) => {
    const who = uniqueSignup('y');
    created.push(who.username);

    await clearMail();
    await submitRegistration(page, who);
    const activation = await waitForMail(who.email);
    const link = extractLink(activation, /\/activate_user\/[^\s"'<>)]+/);
    expect(link).not.toBeNull();

    // Mutate the token's last hex character (f->e, else ->f) so the replacement
    // can never coincide with the original.
    const bad = /** @type {string} */ (link).replace(
      /(token:[a-f0-9]{31})([a-f0-9])/,
      (_m, prefix, last) => prefix + (last === 'f' ? 'e' : 'f'),
    );
    expect(bad, 'tampered link must differ from the real one').not.toBe(link);
    await page.goto(bad);

    expect(accountState(who.username), 'tampered token must leave the account disabled').toBe(
      'disabled',
    );
    expect(
      await noWelcomeWithin(who.email),
      'a rejected activation must not send the welcome mail',
    ).toBe(true);
  });
});
