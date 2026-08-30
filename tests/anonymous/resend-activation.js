/**
 * `bin/plugin account-manager resend-activation` — the operator's way to
 * re-send a registration activation email.
 *
 * WHY THIS COMMAND EXISTS
 * -----------------------
 * Grav's login plugin sends the activation mail once, during registration,
 * and never again. A member whose mail was filtered, lost or expired left an
 * operator with two bad options: activate the account by hand, skipping the
 * address verification the mail exists to provide, or delete it so they could
 * register a second time. Found on production 2026-08-29.
 *
 * WHAT THIS FILE PINS
 * -------------------
 * The two ways the command can be worse than useless, both of which were hit
 * while building it:
 *
 *   1. Sending mail with no reachable transport. The send fails AFTER
 *      Login::sendActivationEmail() has already minted a fresh token and
 *      saved the user — so a failed send silently kills the member's existing
 *      link. Hence the pre-flight guards and --dry-run.
 *
 *   2. Sending a mail whose link is a bare path. Utils::url() yields
 *      `/activate_user/token:…` outside a request; only
 *      `plugins.login.site_host` makes it absolute. A relative link in an
 *      email is unclickable, and the send looks like a success.
 */

const { test, expect } = require('@playwright/test');
const {
  createDisposableAccount,
  removeDisposableAccount,
  readAccountYaml,
  runResendActivationCli,
  setPendingActivation,
} = require('../helpers/self-service');
const { isMailSinkConfigured, clearMail, waitForMail, mailSinkUrl } = require('../helpers/mail');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// plugins.login.site_host is what turns the activation route into an absolute
// URL. Every tier pins it in its env login.yaml; the local container has no
// env dir, so the base config leaves it unset and the command correctly
// refuses to send an unclickable link.
//
// The tests that exercise a real send therefore have to supply it — the same
// thing globalSetup does when it repoints email.yaml at Mailpit. The value
// cannot be hardcoded: grav-up.sh assigns a port per checkout, so it is
// derived from the baseURL Playwright resolved.
const BASE_LOGIN_YAML = path.join(__dirname, '..', '..', 'config', 'www', 'user', 'config', 'plugins', 'login.yaml');

function clearGravCache() {
  const { discoverGravEnv } = require('../../scripts/discover-grav-port.js');
  execFileSync('docker', [
    'exec', '-u', 'abc', '-w', '/app/www/public',
    discoverGravEnv('.').container, 'bin/grav', 'clearcache',
  ], { stdio: ['ignore', 'pipe', 'pipe'], timeout: 60_000 });
}

test.describe('resend-activation CLI', () => {
  let restoreLoginYaml = null;

  test.beforeAll(async ({}, testInfo) => {
    const baseURL = testInfo.project.use.baseURL;
    const existed = fs.existsSync(BASE_LOGIN_YAML);
    const original = existed ? fs.readFileSync(BASE_LOGIN_YAML, 'utf8') : null;
    restoreLoginYaml = () => {
      if (original === null) {
        if (fs.existsSync(BASE_LOGIN_YAML)) fs.unlinkSync(BASE_LOGIN_YAML);
      } else {
        fs.writeFileSync(BASE_LOGIN_YAML, original, 'utf8');
      }
      clearGravCache();
    };
    fs.writeFileSync(
      BASE_LOGIN_YAML,
      `${original ?? ''}\nsite_host: '${baseURL}'\n`,
      'utf8',
    );
    clearGravCache();
  });

  test.afterAll(() => {
    // The file must never stay modified — a dirty local config is how the
    // next suite run picks up state nobody committed.
    if (restoreLoginYaml) restoreLoginYaml();
  });

  test('an unknown account is refused', async () => {
    const res = runResendActivationCli({ user: 'does-not-exist-anywhere' });
    expect(res.status, 'must exit non-zero').not.toBe(0);
    expect(res.stdout + res.stderr).toMatch(/No account/i);
  });

  test('an already-enabled account is refused, and points at the alternative', async () => {
    const acct = createDisposableAccount({ tag: 'ra1' });
    try {
      const res = runResendActivationCli({ user: acct.username });
      expect(res.status, 'must exit non-zero').not.toBe(0);
      const out = res.stdout + res.stderr;
      expect(out).toMatch(/already enabled/i);
      // A refusal that does not say what to do instead sends the operator
      // looking for a workaround — which is how accounts get activated by
      // hand, skipping verification.
      expect(out).toMatch(/reset-password/i);
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('--dry-run reports the transport and changes nothing', async () => {
    const acct = createDisposableAccount({ tag: 'ra2' });
    try {
      const planted = setPendingActivation(acct.username);
      const before = readAccountYaml(acct.username);
      expect(before, 'fixture must carry the planted token').toContain(planted);

      const res = runResendActivationCli({ user: acct.username, dryRun: true });
      expect(res.status, `dry-run should succeed: ${res.stderr}`).toBe(0);
      const out = res.stdout;
      expect(out, 'must name the account').toContain(acct.username);
      expect(out, 'must report the transport so --env can be confirmed').toMatch(/transport\s*:/);
      expect(out, 'must report the link host').toMatch(/link host\s*:/);
      expect(out).toMatch(/dry-run/i);

      // The whole point: no token rotation, so the member's existing link
      // still works after an operator inspects the situation.
      expect(
        readAccountYaml(acct.username),
        'dry-run must not rotate the activation token',
      ).toContain(planted);
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('a real run rotates the token and delivers a clickable, working link', async () => {
    test.skip(!(await isMailSinkConfigured()), `Mailpit not reachable at ${mailSinkUrl()}`);

    const acct = createDisposableAccount({ tag: 'ra3' });
    try {
      const planted = setPendingActivation(acct.username);
      await clearMail();

      const res = runResendActivationCli({ user: acct.username });
      expect(res.status, `send should succeed: ${res.stderr}`).toBe(0);
      expect(res.stdout).toMatch(/Sent\./);
      // The operator must be told the old link is dead — they may have just
      // been on the phone telling the member to use it.
      expect(res.stdout).toMatch(/stopped working/i);

      expect(
        readAccountYaml(acct.username),
        'a real run must mint a fresh token',
      ).not.toContain(planted);

      const msg = await waitForMail(acct.email);
      expect(msg, 'an activation mail must arrive').toBeTruthy();

      const body = (msg.HTML || '') + (msg.Text || '');
      const link = (body.match(/https?:\/\/[^\s"'<>]*activate_user[^\s"'<>]*/) || [])[0];
      // Absolute, not `/activate_user/...`. A bare path is unclickable in a
      // mail client, and the send reports success either way.
      expect(link, 'the activation link must be absolute').toBeTruthy();
      expect(link).toMatch(/^https?:\/\//);
      expect(link).toContain(acct.username);
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('the freshly sent link actually activates the account', async ({ request }) => {
    test.skip(!(await isMailSinkConfigured()), `Mailpit not reachable at ${mailSinkUrl()}`);

    const acct = createDisposableAccount({ tag: 'ra4' });
    try {
      setPendingActivation(acct.username);
      await clearMail();
      expect(runResendActivationCli({ user: acct.username }).status).toBe(0);

      const msg = await waitForMail(acct.email);
      const body = (msg.HTML || '') + (msg.Text || '');
      const link = (body.match(/https?:\/\/[^\s"'<>]*activate_user[^\s"'<>]*/) || [])[0];
      expect(link).toBeTruthy();

      // End to end: a mail that arrives with a link nobody can act on is the
      // failure mode this whole command exists to avoid.
      const resp = await request.get(link, { maxRedirects: 5 });
      expect(resp.status()).toBe(200);
      expect(readAccountYaml(acct.username)).toMatch(/^state:\s*enabled/m);
    } finally {
      removeDisposableAccount(acct.username);
    }
  });
});
