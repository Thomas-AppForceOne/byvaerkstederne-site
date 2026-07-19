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
  TEST_ORGANIZER,
  hasUserPassword,
  hasAdminPassword,
  hasOrganizerPassword,
  ensureAccount,
} = require('./helpers/accounts');
const {
  ensureLockedRoadmapItem,
  ensureReleasableRoadmapItem,
  ensureUnpromotedBugReport,
  ensurePromotedBugReport,
  ensureDraftEvent,
  ensureArchivedEvent,
  ensureForeignEvent,
  ensureRsvpEvent,
  ensureCapacityEvent,
  ensureInterestEvent,
  ensureStaleEvent,
  removeStaleEvent,
  ensurePublicDemoEvents,
  clearEventSignups,
  clearEventImages,
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

  // Frontend event CRUD: the own-vs-other-owner authz suite hinges on a
  // seeded arrangør. Fail LOUD if the operator has credentials for the
  // ordinary accounts but not the organizer — a silently-unrunnable authz
  // suite is exactly the Sprint-5 failure mode (CLAUDE.md). A machine with
  // no credentials at all still runs anonymous-only, which is fine.
  if (hasUserPassword && !hasOrganizerPassword) {
    throw new Error(
      'globalSetup: TEST_PASSWORD is set but TEST_ORGANIZER_PASSWORD is not. ' +
      'Add TEST_ORGANIZER_PASSWORD=... to ~/.gan-secrets/workshop-site.env — ' +
      'without it the event-management authz suite cannot run.'
    );
  }

  if (hasUserPassword) {
    const password = process.env.TEST_PASSWORD || '';
    await ensureAccount(TEST_USER, password);
  }
  if (hasAdminPassword) {
    const password = process.env.TEST_ADMIN_PASSWORD || '';
    await ensureAccount(TEST_ADMIN, password);
  }
  if (hasOrganizerPassword) {
    const password = process.env.TEST_ORGANIZER_PASSWORD || '';
    await ensureAccount(TEST_ORGANIZER, password);
  }
  let seeded = false;
  // Forward-looking public demo events — seeded regardless of credentials so
  // the calendar is never empty (auto-archive hides the committed past seeds).
  // The anonymous + mobile calendar suites depend on this content.
  seeded = ensurePublicDemoEvents().seeded || seeded;
  if (hasUserPassword) {
    try { seeded = ensureLockedRoadmapItem().seeded || seeded; } catch (_) { /* non-fatal */ }
  }
  if (hasAdminPassword) {
    try { seeded = ensureReleasableRoadmapItem().seeded || seeded; } catch (_) { /* non-fatal */ }
    try { seeded = ensureUnpromotedBugReport().seeded || seeded; } catch (_) { /* non-fatal */ }
    try { seeded = ensurePromotedBugReport().seeded || seeded; } catch (_) { /* non-fatal */ }
  }
  if (hasOrganizerPassword) {
    // Event fixtures back the read-visibility, restore, and per-object authz
    // suites. These must NOT silently skip — surface seeding failures.
    seeded = ensureDraftEvent().seeded || seeded;
    seeded = ensureArchivedEvent().seeded || seeded;
    seeded = ensureForeignEvent().seeded || seeded;
    // Event RSVP fixtures back the signup/capacity/interest suites. Start from
    // a clean signup + image state so a prior crashed run can't leave a
    // capacity-1 event already full.
    seeded = ensureRsvpEvent().seeded || seeded;
    seeded = ensureCapacityEvent().seeded || seeded;
    seeded = ensureInterestEvent().seeded || seeded;
    // Auto-archive sweep target: remove any archived leftover from a prior run
    // first, so the sweep test always sees the archived false→true transition.
    removeStaleEvent();
    seeded = ensureStaleEvent().seeded || seeded;
    clearEventSignups();
    clearEventImages();
  }
  // Make the freshly-seeded flex fixtures visible to Grav's cached admin flex
  // index (appending YAML at runtime doesn't invalidate it). Without this the
  // admin roadmap edit page reads the seeded item as non-existent and never
  // renders the release_nonce, failing the admin smoke test non-deterministically.
  if (seeded) {
    clearGravCache();
  }
};
