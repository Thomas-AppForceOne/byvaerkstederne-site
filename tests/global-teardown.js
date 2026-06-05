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
const {
  TEST_USER,
  TEST_ADMIN,
  removeAccount,
} = require('./helpers/accounts');
const {
  removeLockedRoadmapItem,
  removeReleasableRoadmapItem,
  removeUnpromotedBugReport,
} = require('./helpers/fixtures');

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
  try { removeLockedRoadmapItem(); } catch (_) { /* non-fatal */ }
  try { removeReleasableRoadmapItem(); } catch (_) { /* non-fatal */ }
  try { removeUnpromotedBugReport(); } catch (_) { /* non-fatal */ }

  const repoRoot = path.resolve(__dirname, '..');
  for (const rel of GENERATED_ENV_SECURITY_FILES) {
    try { fs.rmSync(path.join(repoRoot, rel), { force: true }); } catch (_) { /* non-fatal */ }
  }
};
