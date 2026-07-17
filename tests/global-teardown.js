// @ts-check
'use strict';

/**
 * Playwright globalTeardown hook.
 *
 * Removes both test-account YAMLs unconditionally (rm -f semantics — safe
 * if the file is already gone, and ensures a crashed mid-run still leaves
 * the accounts directory clean on the next exit).
 *
 * Helpers validate the account argument against an allowlist before any
 * filesystem write, so this is restricted to the two sanctioned paths.
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const {
  TEST_USER,
  TEST_ADMIN,
  TEST_ORGANIZER,
  removeAccount,
} = require('./helpers/accounts');
const {
  removeLockedRoadmapItem,
  removeReleasableRoadmapItem,
  removeUnpromotedBugReport,
  removeDraftEvent,
  removeArchivedEvent,
  removeForeignEvent,
  removeRsvpEvent,
  removeCapacityEvent,
  removeInterestEvent,
  removePublicDemoEvents,
  clearEventSignups,
  clearEventImages,
} = require('./helpers/fixtures');
const { restoreEmailConfig } = require('./helpers/mailer');

// Grav auto-generates a per-environment `security.yaml` (salt) the first
// time a profile is accessed. The Sprint-4 feature-flag tests probe the
// public-demo and staging profiles via Host-header overrides, which
// triggers that write. The file is dev-only and leaks into `git status`
// if left behind; remove it on teardown so `make test` ends clean.
const GENERATED_ENV_SECURITY_FILES = [
  'config/www/user/env/public-demo.example.com/config/security.yaml',
  'config/www/user/env/staging.example.com/config/security.yaml',
];

module.exports = async function globalTeardown() {
  try {
    removeAccount(TEST_USER);
  } catch (err) {
    // Teardown should not mask the test outcome; log a generic message.
    console.warn(`globalTeardown: removeAccount(pw-test-user) failed: ${/** @type {any} */ (err).message}`);
  }
  try {
    removeAccount(TEST_ADMIN);
  } catch (err) {
    console.warn(`globalTeardown: removeAccount(pw-test-admin) failed: ${/** @type {any} */ (err).message}`);
  }
  try {
    removeAccount(TEST_ORGANIZER);
  } catch (err) {
    console.warn(`globalTeardown: removeAccount(pw-test-org) failed: ${/** @type {any} */ (err).message}`);
  }
  try { removeLockedRoadmapItem(); } catch (_) { /* non-fatal */ }
  try { removeReleasableRoadmapItem(); } catch (_) { /* non-fatal */ }
  try { removeUnpromotedBugReport(); } catch (_) { /* non-fatal */ }
  try { removeDraftEvent(); } catch (_) { /* non-fatal */ }
  try { removeArchivedEvent(); } catch (_) { /* non-fatal */ }
  try { removeForeignEvent(); } catch (_) { /* non-fatal */ }
  try { removeRsvpEvent(); } catch (_) { /* non-fatal */ }
  try { removeCapacityEvent(); } catch (_) { /* non-fatal */ }
  try { removeInterestEvent(); } catch (_) { /* non-fatal */ }
  try { removePublicDemoEvents(); } catch (_) { /* non-fatal */ }
  // Signups + uploaded images are gitignored runtime state — `git checkout`
  // won't restore them, so clear explicitly.
  try { clearEventSignups(); } catch (_) { /* non-fatal */ }
  try { clearEventImages(); } catch (_) { /* non-fatal */ }

  const repoRoot = path.resolve(__dirname, '..');
  for (const rel of GENERATED_ENV_SECURITY_FILES) {
    try { fs.rmSync(path.join(repoRoot, rel), { force: true }); } catch (_) { /* non-fatal */ }
  }

  // Automatic teardown of the Mailpit mailer override that global-setup may
  // have written. Unconditional + idempotent (a no-op when email.yaml is
  // already clean), and it clears the Grav cache as `abc`. This is what makes
  // the override impossible to leak past a normal run; the global-setup guard
  // catches the only remaining case — a run killed before this point.
  try { restoreEmailConfig(); } catch (_) { /* non-fatal */ }

  // Restore tracked files the suites mutate as a side effect, so the working
  // tree stays clean in `git status`:
  //   - flex-objects data: roadmap voting changes vote counts; bug-report tests
  //     append records.
  //   - the dev tier's features.yaml: the feature-flags cache-flip test flips a
  //     flag in it and restores it in afterAll, but this backstops a killed run.
  // `git checkout --` restores committed content; it's a no-op for an
  // already-clean file (e.g. the anonymous flex paths on a pure-anonymous run).
  try {
    execFileSync(
      'git',
      [
        'checkout',
        '--',
        'config/www/user/data/flex-objects',
        'config/www/user/env/dev.hackersbychoice.dk/config/features.yaml',
      ],
      { cwd: repoRoot, stdio: ['ignore', 'ignore', 'ignore'] },
    );
  } catch (_) { /* non-fatal — not a git checkout or nothing to restore */ }
};
