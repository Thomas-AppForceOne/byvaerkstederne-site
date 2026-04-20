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
};
