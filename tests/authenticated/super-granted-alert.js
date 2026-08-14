// @ts-check
'use strict';

/**
 * Privilege-escalation alert: every super-admin is told when an account is
 * granted super.
 *
 * Granting super hands over every member's record, and the grant happens with
 * server tooling (deploy/manage-super.sh) — outside the site, where no page
 * shows it and no member notices. Two things make that accountable, and both
 * are asserted here:
 *
 *   1. an entry in the same audit log the in-app rights changes write to
 *      (covered by tests/deploy/unit-manage-super.sh, which exercises the
 *      YAML+audit helper directly), and
 *   2. this mail, so the people who could act on an unexpected escalation
 *      hear about it rather than finding it in a log afterwards.
 *
 * The CLI under test is what the shell tool invokes after the rights change
 * lands. It is deliberately a separate step: the YAML edit must not depend on
 * a working mailer, and a mail failure must never leave a half-applied grant.
 */

const { test, expect } = require('@playwright/test');
const { hasUserPassword } = require('../helpers/auth');
const {
  isMailSinkConfigured,
  mailSinkUrl,
  clearMail,
  waitForMail,
  expectNoMail,
} = require('../helpers/mail');
const { TEST_ADMIN, hasAdminPassword, ensureAccount } = require('../helpers/accounts');
const {
  createDisposableAccount,
  removeDisposableAccount,
  runNotifySuperGrantedCli,
} = require('../helpers/self-service');

test.describe('super-admin grant alert', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');

  test.beforeAll(async () => {
    if (hasAdminPassword) {
      await ensureAccount(TEST_ADMIN, process.env.TEST_ADMIN_PASSWORD);
    }
  });

  test('every super-admin is mailed when an account is granted super', async () => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — no super-admin to alert');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    const promoted = createDisposableAccount({ tag: 'sg' });
    try {
      await clearMail();
      const run = runNotifySuperGrantedCli({ user: promoted.username, actor: 'taa@laptop' });
      expect(run.status, `CLI failed: ${run.stderr || run.stdout}`).toBe(0);

      const msg = await waitForMail(TEST_ADMIN.email);
      const body = `${msg.Text || ''}\n${msg.HTML || ''}`;

      expect(msg.Subject, 'subject names the promoted account').toMatch(/^Ny super-admin på /);
      expect(msg.Subject).toContain(promoted.username);
      // Who, and by whom — an alert that omits the actor cannot be acted on.
      expect(body, 'the promoted account is named').toContain(promoted.username);
      expect(body, 'the operator who did it is named').toContain('taa@laptop');
      expect(body, 'the alert points at the audit log').toContain('account-audit.jsonl');
      expect(body, 'the alert says what to do if unexpected').toMatch(/Var det ikke ventet/);
      expect(body, 'no untranslated key leaks').not.toMatch(/PLUGIN_(LOGIN|EMAIL)\./);
    } finally {
      removeDisposableAccount(promoted.username);
    }
  });

  test('failure: an unsafe username is refused and nothing is mailed', async () => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — no super-admin to alert');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    await clearMail();
    // A username carrying shell/path metacharacters must never reach a send:
    // the alert names the account in the mail, and the CLI is invoked over
    // SSH from the tier tool.
    const run = runNotifySuperGrantedCli({ user: 'no;rm -rf /', actor: 'taa@laptop' });
    expect(run.status, 'the CLI rejects an unsafe username').not.toBe(0);
    expect(
      await expectNoMail(TEST_ADMIN.email),
      'a refused alert sends nothing at all',
    ).toBe(true);
  });
});
