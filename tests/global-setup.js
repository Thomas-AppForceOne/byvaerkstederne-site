// @ts-check
'use strict';

/**
 * Playwright globalSetup hook.
 *
 * Idempotently provisions the canonical test accounts when their respective
 * password env vars are set. Fails fast with an actionable error if Docker
 * or the `grav` container isn't reachable — never silently skips.
 *
 * Secrets discipline: passwords are read from the environment and passed to
 * helpers without ever being printed, logged, or interpolated into a
 * thrown error message.
 */

const {
  TEST_USER,
  TEST_ADMIN,
  hasUserPassword,
  hasAdminPassword,
  ensureAccount,
} = require('./helpers/accounts');
const {
  ensureLockedRoadmapItem,
  ensureReleasableRoadmapItem,
  ensureUnpromotedBugReport,
  clearGravCache,
} = require('./helpers/fixtures');
const { isMailSinkConfigured, mailSinkUrl } = require('./helpers/mail');
const { assertEmailConfigCleanOrThrow, applyMailpitOverride } = require('./helpers/mailer');

module.exports = async function globalSetup() {
  // FIRST: refuse to run if a prior crashed run left the Mailpit email.yaml
  // override in the working tree (see helpers/mailer.js). This is the
  // catastrophic guard — committing that override would break a real tier's
  // mailer, so we abort the whole run rather than risk it.
  assertEmailConfigCleanOrThrow();

  // When the Mailpit sink is reachable, repoint the mailer at it for the
  // duration of this run so the email-bearing auth flows actually send.
  // global-teardown restores email.yaml unconditionally. When Mailpit is down
  // we leave the committed (non-sending) config and those specs skip-with-reason.
  if (await isMailSinkConfigured()) {
    applyMailpitOverride();
    // eslint-disable-next-line no-console
    console.log(`globalSetup: Mailpit reachable at ${mailSinkUrl()} — email.yaml repointed at mailpit:1025 for this run.`);
  }

  if (hasUserPassword) {
    const password = process.env.TEST_PASSWORD || '';
    await ensureAccount(TEST_USER, password);
  }
  if (hasAdminPassword) {
    const password = process.env.TEST_ADMIN_PASSWORD || '';
    await ensureAccount(TEST_ADMIN, password);
  }
  let seeded = false;
  if (hasUserPassword) {
    try { seeded = ensureLockedRoadmapItem().seeded || seeded; } catch (_) { /* non-fatal */ }
  }
  if (hasAdminPassword) {
    try { seeded = ensureReleasableRoadmapItem().seeded || seeded; } catch (_) { /* non-fatal */ }
    try { seeded = ensureUnpromotedBugReport().seeded || seeded; } catch (_) { /* non-fatal */ }
  }
  // Make the freshly-seeded flex fixtures visible to Grav's cached admin flex
  // index (appending YAML at runtime doesn't invalidate it). Without this the
  // admin roadmap edit page reads the seeded item as non-existent and never
  // renders the release_nonce, failing the admin smoke test non-deterministically.
  if (seeded) {
    clearGravCache();
  }
};
