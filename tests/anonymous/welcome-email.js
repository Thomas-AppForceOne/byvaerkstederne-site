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
const fs = require('fs');
const path = require('path');
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

/**
 * site.author.email as configured for the origin under test (the base
 * profile — deployed tiers may override it per host). The welcome mail's
 * contact line must follow this value rather than a literal: a hardcoded
 * address points a tier's testers at the production mailbox.
 */
function configuredContactAddress() {
  const siteYaml = fs.readFileSync(
    path.resolve(__dirname, '..', '..', 'config/www/user/config/site.yaml'),
    'utf8',
  );
  const m = siteYaml.match(/author:\s*[\r\n]+(?:\s*\w+:[^\r\n]*[\r\n]+)*?\s*email:\s*'?([^'\s]+)'?/);
  if (!m) {
    throw new Error('welcome-email: could not read site.author.email from site.yaml');
  }
  return m[1];
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

    // Shared mail chrome: the footer under every mail is ours, not the email
    // plugin's stock "GetGrav.org" branding, and no translation key leaks
    // (Grav renders a missing translation as the key itself).
    expect(body, 'footer names the association').toContain('Byværkstederne · Nørregade 21');
    expect(body, 'contact line follows site.author.email, not a literal').toContain(
      configuredContactAddress(),
    );
    expect(body, 'plugin vendor branding must not ship to members').not.toMatch(/GetGrav\.org/i);
    expect(body, 'no untranslated key may leak into the mail').not.toMatch(
      /PLUGIN_(LOGIN|EMAIL)\./,
    );

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

/**
 * Single source of truth for the welcome copy.
 *
 * The rule, in one sentence: editing
 * themes/byvaerkstederne/templates/emails/login/welcome.html.twig must be
 * enough to change what EVERY tier sends. dev, test, staging and prod all
 * deploy that one file; no tier gets its own wording, and nothing else in the
 * repo may carry a welcome-mail body.
 *
 * This is not hypothetical. `scripts/send-test-welcome-emails.sh` used to send
 * the test tier a second, entirely different welcome mail — its own hardcoded
 * Danish body, its own subject ("Velkommen til Byværkstedernes website test"),
 * driven by a LaunchAgent on one operator's Mac. Two copies meant a correction
 * to the template silently missed the tier most likely to be read by someone
 * reviewing the copy. The script is gone; these assertions keep it gone.
 *
 * Pure-source checks — no container, no mail sink, no credentials — so they
 * run on every invocation rather than skipping with the delivery tests above.
 */
test.describe('Welcome email — single source of truth', () => {
  const REPO = path.resolve(__dirname, '..', '..');
  const TEMPLATE_REL =
    'config/www/user/themes/byvaerkstederne/templates/emails/login/welcome.html.twig';

  // A phrase from the mail's own body. Deliberately longer than it looks like
  // it needs to be: `Din konto er nu aktiv` alone is a PREFIX of the web flash
  // string USER_ACTIVATED_SUCCESSFULLY ("Din konto er nu aktiveret. Du kan
  // logge ind.") in user/languages/en.yaml, which is not mail copy at all.
  const COPY_MARKER = 'Din konto er nu aktiv, og du';

  /** Directories that are not sources: vendored code, build scratch, history. */
  const SKIP_DIRS = new Set([
    'node_modules',
    '.git',
    'vendor',
    'archive',
    'logs',
    // deploy/staging is gitignored deploy scratch — a generated mirror of
    // config/, so a hit there is the same file, not a second one.
    'staging',
    // The login plugin's stock template is the file our theme override
    // deliberately shadows. It must stay untouched and updatable.
    'plugins',
  ]);

  /** @param {string} dir @param {string[]} acc */
  function walk(dir, acc = []) {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return acc;
    }
    for (const e of entries) {
      const full = path.join(dir, e.name);
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name)) continue;
        walk(full, acc);
      } else if (e.isFile()) {
        acc.push(full);
      }
    }
    return acc;
  }

  test('the welcome copy lives in exactly one file', () => {
    const searched = [
      path.join(REPO, 'config/www/user'),
      path.join(REPO, 'scripts'),
      path.join(REPO, 'deploy'),
    ];

    const carriers = [];
    for (const root of searched) {
      for (const file of walk(root)) {
        let text;
        try {
          text = fs.readFileSync(file, 'utf8');
        } catch {
          continue; // binary or unreadable — cannot be mail copy
        }
        if (text.includes(COPY_MARKER)) carriers.push(path.relative(REPO, file));
      }
    }

    expect(
      carriers,
      'the welcome copy must exist in exactly one file — a second copy is how a tier ' +
        'starts sending stale wording after the template is corrected',
    ).toEqual([TEMPLATE_REL]);
  });

  test('only one welcome template exists outside the vendored plugin', () => {
    // Structural companion to the prose check above: a duplicate written from
    // scratch shares no phrasing, but it still has to live somewhere Twig can
    // resolve. The login plugin's own copy is excluded by SKIP_DIRS — that one
    // is the file our override deliberately shadows.
    const templates = walk(path.join(REPO, 'config/www/user'))
      .filter((f) => /emails[/\\]login[/\\]welcome\./.test(f))
      .map((f) => path.relative(REPO, f));

    expect(
      templates,
      'a second welcome template means the resolved one depends on load order',
    ).toEqual([TEMPLATE_REL]);
  });

  test('no script carries member-facing mail copy of its own', () => {
    // scripts/ is operator tooling. Danish prose addressed to a member means
    // someone is composing mail outside the template again — the exact shape
    // the retired welcome agent had.
    const offenders = walk(path.join(REPO, 'scripts'))
      .filter((file) => {
        let text;
        try {
          text = fs.readFileSync(file, 'utf8');
        } catch {
          return false;
        }
        return /Velkommen til/i.test(text);
      })
      .map((f) => path.relative(REPO, f));

    expect(
      offenders,
      'a script composing its own welcome mail bypasses the template every tier deploys',
    ).toEqual([]);
  });

  test('the template pins its own subject, so no English fallback can render', () => {
    const twig = fs.readFileSync(path.join(REPO, TEMPLATE_REL), 'utf8');
    // The login plugin's language file carries WELCOME_EMAIL_SUBJECT
    // ("Welcome to %s"). It is deliberately not overridden in the repo's
    // en.yaml, so the ONLY thing keeping the subject Danish is the template
    // setting it itself. Lose this line and every tier mails an English
    // subject with a Danish body.
    expect(twig, 'the template must set the subject itself').toMatch(/setSubject/);
    expect(twig, 'the subject must be the Danish one').toMatch(/Velkommen til/);
  });

  test('no tier overrides the welcome mail', () => {
    // Grav resolves per-tier config from user/env/<host>/. A welcome template
    // or a WELCOME_EMAIL_* language override placed there would give one tier
    // its own wording — silently, and only for that tier's members.
    const envRoot = path.join(REPO, 'config/www/user/env');
    const offenders = walk(envRoot)
      .filter((file) => {
        if (/welcome/i.test(path.basename(file))) return true;
        let text;
        try {
          text = fs.readFileSync(file, 'utf8');
        } catch {
          return false;
        }
        // A comment mentioning the mail is fine; an actual override is not.
        return /^\s*WELCOME_EMAIL_[A-Z_]*\s*:/m.test(text);
      })
      .map((f) => path.relative(REPO, f));

    expect(offenders, 'a per-tier welcome override defeats the single source').toEqual([]);
  });
});
