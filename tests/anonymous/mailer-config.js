// @ts-check
'use strict';

/**
 * The committed base mailer config must never be the test override.
 *
 * WHY THIS FILE EXISTS
 * --------------------
 * tests/global-setup.js repoints user/config/plugins/email.yaml at the Mailpit
 * sink for the duration of a run, and global-teardown.js restores it with
 * `git checkout`. Two guards already cover that dance — but both compare the
 * WORKING TREE against git:
 *
 *   * assertEmailConfigCleanOrThrow() aborts a run that starts with the file
 *     already modified (i.e. a previous run was killed before teardown), and
 *   * restoreEmailConfig() puts the committed content back afterwards.
 *
 * Neither can see the failure that actually happened. On 2026-08-14 the
 * override was COMMITTED — swept into commit c7a5770, an unrelated scheduler
 * feature — replacing 43 lines of credential-free defaults with the 9-line
 * Mailpit form. From that moment the working tree matched git, so nothing was
 * "dirty", every guard passed, and `server: mailpit / port: 1025` shipped to
 * staging and production in every release for four days.
 *
 * It was not the active transport there: the per-tier env email.yaml overrides
 * it on each canonical host. It was the FALLBACK — what any Host without its
 * own env mailer resolves, such as production's bare apex. The intended
 * fallback is no transport at all, which fails closed; `mailpit` is a hostname
 * that does not resolve outside the test compose network, which fails
 * confusingly.
 *
 * So this file asserts the property the other guards cannot: what is COMMITTED
 * is the credential-free form. It reads via `git show HEAD:<path>` rather than
 * from disk on purpose — during a Mailpit-backed run the working tree is
 * legitimately the override, and a disk read would fail every local run.
 *
 * Pure source: no container, no sink, no credentials. Runs always.
 */

const { test, expect } = require('@playwright/test');
const path = require('path');
const { execFileSync } = require('child_process');

const REPO = path.resolve(__dirname, '..', '..');
const EMAIL_REL = 'config/www/user/config/plugins/email.yaml';

/** The committed content of a repo file, independent of the working tree. */
function committed(rel) {
  return execFileSync('git', ['show', `HEAD:${rel}`], {
    cwd: REPO,
    encoding: 'utf8',
    maxBuffer: 10 * 1024 * 1024,
  });
}

test.describe('Base mailer config (committed form)', () => {
  test('the Mailpit override is not what is committed', () => {
    const yaml = committed(EMAIL_REL);
    // The marker global-setup writes, kept greppable for exactly this reason
    // (tests/helpers/mailer.js: MAILPIT_MARKER).
    expect(
      yaml,
      `${EMAIL_REL} is the TEST-ONLY Mailpit override. It was committed — restore the ` +
        'credential-free form (git show c7a5770^:' +
        EMAIL_REL +
        ') before this ships to a tier again.',
    ).not.toMatch(/TEST-ONLY Mailpit override/);
  });

  test('the committed base declares no SMTP host or port', () => {
    const yaml = committed(EMAIL_REL);
    // The transport is per-tier by design: the env email.yaml under
    // user/env/<host>/config/plugins/ supplies server/port/user/password.
    // A host literal here becomes the fallback for every unprofiled Host,
    // which is precisely how `mailpit` reached production.
    expect(yaml, 'the base config must declare no SMTP server').not.toMatch(
      /^\s*server:\s*\S/m,
    );
    expect(yaml, 'the base config must declare no SMTP port').not.toMatch(/^\s*port:\s*\d/m);
  });

  test('the committed base carries no credentials', () => {
    const yaml = committed(EMAIL_REL);
    // user/password belong in the gitignored per-tier file. A non-empty value
    // here would be a secret in git history, which no revert can undo.
    //
    // The negative lookahead exempts an explicitly EMPTY value (`user: ''`):
    // that is a declaration of "no credential", not a leaked one. Without it
    // this assertion fires on the Mailpit override for the wrong reason —
    // that form is caught by the marker check above, on its own merits.
    expect(yaml, 'no SMTP username in the committed base').not.toMatch(
      /^\s*user:\s*(?!['"]{2}\s*$)\S/m,
    );
    expect(yaml, 'no SMTP password in the committed base').not.toMatch(
      /^\s*password:\s*(?!['"]{2}\s*$)\S/m,
    );
  });

  test('the committed base keeps the non-prod From identity', () => {
    const yaml = committed(EMAIL_REL);
    // Restoring the file must not overshoot into stripping what it is FOR.
    // dev/test/staging inherit this From; prod overrides it per tier.
    expect(yaml, 'the non-prod From identity must survive').toMatch(
      /^from:\s*'noreply@hackersbychoice\.dk'/m,
    );
    expect(yaml, 'the transport engine must survive').toMatch(/^\s*engine:\s*smtp/m);
  });
});
