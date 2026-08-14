// @ts-check
'use strict';

/**
 * Privilege-escalation watch — the site detects a new super-admin no matter
 * how it was created.
 *
 * The alert fired by deploy/manage-super.sh only covers the tidy path. This
 * covers the others: the test promotes an account by writing the rights
 * straight into its YAML — exactly what a hand edit over SSH, a restored
 * backup or an unknown future script would leave behind — and asserts the
 * site notices on its own.
 *
 * Three properties, each with a way to fail:
 *   - a first run RECORDS the baseline and alerts about nobody (alerting on
 *     every existing super would teach the reader to ignore the mail);
 *   - a super appearing afterwards is alerted AND audited;
 *   - a second run over unchanged state is silent (no repeat alert), which
 *     is what makes a 30-minute schedule liveable.
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
  runWatchSupersCli,
  resetSuperBaseline,
  makeAccountSuper,
} = require('../helpers/self-service');

test.describe('super-admin watch (site-side detection)', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');

  test.beforeAll(async () => {
    if (hasAdminPassword) {
      await ensureAccount(TEST_ADMIN, process.env.TEST_ADMIN_PASSWORD);
    }
  });

  test('a super promoted outside the tooling is detected, alerted and audited', async () => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — no super-admin to alert');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );

    const sneaky = createDisposableAccount({ tag: 'sw' });
    try {
      // 1. First run: baseline only, nobody alerted.
      resetSuperBaseline();
      await clearMail();
      const first = runWatchSupersCli();
      expect(first.status, first.stderr || first.stdout).toBe(0);
      expect(first.stdout).toMatch(/baseline recorded/);
      expect(
        await expectNoMail(TEST_ADMIN.email),
        'a first run must not alert about accounts that were already supers',
      ).toBe(true);

      // 2. Promote OUTSIDE the tooling — a raw YAML edit, like a hand edit
      //    over SSH or a restored backup would leave.
      makeAccountSuper(sneaky.username);
      await clearMail();
      const second = runWatchSupersCli();
      expect(second.status, second.stderr || second.stdout).toBe(0);
      expect(second.stdout, 'the CLI names the account it found').toContain(sneaky.username);

      const msg = await waitForMail(TEST_ADMIN.email);
      const body = `${msg.Text || ''}\n${msg.HTML || ''}`;
      expect(msg.Subject).toMatch(/^Ny super-admin på /);
      expect(body, 'the alert names the account').toContain(sneaky.username);
      expect(body, 'the alert says the site found it, not who did it').toMatch(/opdaget af sitet/);

      // 3. Unchanged state stays silent — otherwise a 30-minute schedule
      //    would mail the same thing 48 times a day and be filtered away.
      await clearMail();
      const third = runWatchSupersCli();
      expect(third.status).toBe(0);
      expect(third.stdout).toMatch(/unchanged/);
      expect(
        await expectNoMail(TEST_ADMIN.email),
        'an unchanged run must not re-alert',
      ).toBe(true);
    } finally {
      removeDisposableAccount(sneaky.username);
      resetSuperBaseline();
    }
  });

  test('dry-run reports without alerting, auditing or moving the baseline', async () => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — no super-admin to alert');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );

    const sneaky = createDisposableAccount({ tag: 'wd' });
    try {
      resetSuperBaseline();
      expect(runWatchSupersCli().status).toBe(0); // baseline
      makeAccountSuper(sneaky.username);

      await clearMail();
      const dry = runWatchSupersCli({ dryRun: true });
      expect(dry.status).toBe(0);
      expect(dry.stdout).toContain(sneaky.username);
      expect(
        await expectNoMail(TEST_ADMIN.email),
        'a dry run must not send anything',
      ).toBe(true);

      // The baseline must NOT have moved: the next real run still has the
      // detection to report. A dry run that silently consumed the finding
      // would be worse than no dry run at all.
      await clearMail();
      const real = runWatchSupersCli();
      expect(real.status).toBe(0);
      expect(real.stdout, 'the real run still reports what the dry run saw').toContain(
        sneaky.username,
      );
      const msg = await waitForMail(TEST_ADMIN.email);
      expect(msg.Subject).toMatch(/^Ny super-admin på /);
    } finally {
      removeDisposableAccount(sneaky.username);
      resetSuperBaseline();
    }
  });
});
