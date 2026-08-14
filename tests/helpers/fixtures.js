// @ts-check
'use strict';

/**
 * Deterministic test fixtures for Playwright runs.
 *
 * Seeds data the suite cannot create through public endpoints, so tests don't
 * skip themselves with "no locked item found" or similar. All fixture keys are
 * prefixed `rm_fixture_` or `br_fixture_` so teardown can remove them with a
 * single allowlist check and no risk of touching real data.
 *
 * The fixtures are appended to the live Grav flex-objects YAML files via
 * `docker exec grav sh -c "cat >> file"`. Grav re-reads these files on every
 * request, so no cache clear is needed for them to surface.
 */

const { execFileSync } = require('child_process');
const path = require('path');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

// Resolve once; throw loud if the worktree's container isn't running.
let _cachedContainer = null;
function gravContainer() {
  if (_cachedContainer) return _cachedContainer;
  _cachedContainer = discoverGravEnv(path.resolve(__dirname, '..', '..')).container;
  return _cachedContainer;
}

const LOCKED_ROADMAP_ITEM_ID = 'rm_fixture_locked';
const RELEASABLE_ROADMAP_ITEM_ID = 'rm_fixture_releasable';
const UNPROMOTED_BUG_REPORT_ID = 'br_fixture_unpromoted';
const PROMOTED_BUG_REPORT_ID = 'br_fixture_promoted';
const DRAFT_EVENT_ID = 'ev_fixture_draft';
const ARCHIVED_EVENT_ID = 'ev_fixture_archived';
const FOREIGN_EVENT_ID = 'ev_fixture_foreign';
// Event RSVP fixtures (future-dated so the past-event guard never trips).
const RSVP_EVENT_ID = 'ev_fixture_rsvp';
const CAPACITY_EVENT_ID = 'ev_fixture_capacity';
const INTEREST_EVENT_ID = 'ev_fixture_interest';
// Stale event (past-dated, archived: false) — the auto-archive sweep's target.
// Seeded fresh each run (teardown removes it) so the sweep test always
// exercises the false→true transition rather than finding it pre-archived.
const STALE_EVENT_ID = 'ev_fixture_stale';
const LOCKED_ROADMAP_YAML_PATH = '/config/www/user/data/flex-objects/roadmap-items.yaml';
const BUG_REPORTS_YAML_PATH = '/config/www/user/data/flex-objects/bug-reports.yaml';
const EVENTS_YAML_PATH = '/config/www/user/data/flex-objects/begivenheder.yaml';
const SIGNUPS_YAML_PATH = '/config/www/user/data/flex-objects/event-signups.yaml';
const EVENT_AUDIT_PATH = '/config/www/user/data/flex-objects/events-audit.jsonl';
const EVENT_IMAGES_DIR = '/config/www/user/data/event-images';

// Leading newline is intentionally omitted: the target files already end in
// a newline, so `cat >>` produces a clean break. Leaving a blank line in
// would survive sed removal (the blank is outside the /key/,/[a-z]/ range)
// and dirty the working tree on teardown.
const LOCKED_FIXTURE_YAML = `${LOCKED_ROADMAP_ITEM_ID}:
  published: true
  type: bug
  priority: middel
  status: under_implementation
  title: '[FIXTURE] Locked item for Playwright tests'
  description: 'Seeded by tests/helpers/fixtures.js so locked-state tests have data.'
  expected: 'Seeded item; do not edit.'
  steps:
    - 'Fixture step'
  page_url: /
  submitter_username: pw-test-user
  source_report_id: ''
  source_suggestion_id: ''
  timestamp: '2026-04-20T00:00:00Z'
  vote_count: 0
  votes: {  }
  vote_history: {  }
  votes_released: false
  display_id: '#FIX1'
`;

const RELEASABLE_FIXTURE_YAML = `${RELEASABLE_ROADMAP_ITEM_ID}:
  published: true
  type: bug
  priority: middel
  status: klar_til_implementation
  title: '[FIXTURE] Releasable item for Playwright admin smoke'
  description: 'Seeded so admin release-votes test has a valid target.'
  expected: 'Seeded item; do not edit.'
  steps:
    - 'Fixture step'
  page_url: /
  submitter_username: pw-test-user
  source_report_id: ''
  source_suggestion_id: ''
  timestamp: '2026-04-20T00:00:00Z'
  vote_count: 1
  votes:
    pw-fixture-voter: 1
  vote_history: {  }
  votes_released: false
  display_id: '#FIX2'
`;

const UNPROMOTED_BUG_YAML = `${UNPROMOTED_BUG_REPORT_ID}:
  username: pw-test-user
  timestamp: '2026-04-20T00:00:00Z'
  page_url: /
  browser_os: 'Playwright fixture'
  description: 'Seeded unpromoted bug-report so admin promote_nonce is available.'
  expected: 'Seeded item; do not edit.'
  steps: []
  image_path: null
  promoted: false
  promoted_item_id: null
  title: '[FIXTURE] Unpromoted for admin smoke'
`;

// Already-promoted report — the promote endpoint must 409 on it. Replaces the
// pre-flex-data-out-of-git reliance on the legacy br_promoted_login_mobile
// record, which no longer exists on a fresh (empty-store) container.
const PROMOTED_BUG_YAML = `${PROMOTED_BUG_REPORT_ID}:
  username: pw-test-user
  timestamp: '2026-04-20T00:00:00Z'
  page_url: /
  browser_os: 'Playwright fixture'
  description: 'Seeded promoted bug-report so the promote endpoint 409 path has a target.'
  expected: 'Seeded item; do not edit.'
  steps: []
  image_path: null
  promoted: true
  promoted_item_id: rm_fixture_locked
  title: '[FIXTURE] Promoted for admin 409 smoke'
`;

// Event fixtures (frontend event CRUD). The draft and archived events are
// owned by pw-test-org (read-visibility + restore tests); the foreign
// event is owned by a name that matches no test account, so organizer
// mutations against it must 403 (per-object authz negative tests).
const DRAFT_EVENT_YAML = `${DRAFT_EVENT_ID}:
  published: false
  title: '[FIXTURE] Draft event for Playwright tests'
  description: 'Seeded by tests/helpers/fixtures.js; do not edit.'
  group: makerspace
  badge: 'Makerspace & Reparation'
  event_date: '2030-01-15'
  event_time: '10:00 - 12:00'
  location: 'Makerspace lokalet'
  capacity: ''
  event_type: ''
  button_text: ''
  button_url: ''
  button_style: primary
  featured: false
  featured_tag: ''
  owner: pw-test-org
  created_by: pw-test-org
  created_at: '2026-06-01T00:00:00Z'
  updated_by: pw-test-org
  updated_at: '2026-06-01T00:00:00Z'
  archived: false
`;

const ARCHIVED_EVENT_YAML = `${ARCHIVED_EVENT_ID}:
  published: false
  title: '[FIXTURE] Archived event for Playwright tests'
  description: 'Seeded by tests/helpers/fixtures.js; do not edit.'
  group: krea
  badge: 'Krea Café'
  event_date: '2030-02-15'
  event_time: '10:00 - 12:00'
  location: 'Krea lokalet'
  capacity: ''
  event_type: ''
  button_text: ''
  button_url: ''
  button_style: secondary
  featured: false
  featured_tag: ''
  owner: pw-test-org
  created_by: pw-test-org
  created_at: '2026-06-01T00:00:00Z'
  updated_by: pw-test-org
  updated_at: '2026-06-01T00:00:00Z'
  archived: true
`;

const FOREIGN_EVENT_YAML = `${FOREIGN_EVENT_ID}:
  published: true
  title: '[FIXTURE] Foreign-owned event for Playwright tests'
  description: 'Seeded by tests/helpers/fixtures.js; do not edit.'
  group: kulturhus
  badge: 'Eventværkstedet'
  event_date: '2030-03-15'
  event_time: '10:00 - 12:00'
  location: 'Eventværkstedet'
  capacity: ''
  event_type: ''
  button_text: ''
  button_url: ''
  button_style: tertiary
  featured: false
  featured_tag: ''
  owner: some-other-organizer
  created_by: some-other-organizer
  created_at: '2026-06-01T00:00:00Z'
  updated_by: some-other-organizer
  updated_at: '2026-06-01T00:00:00Z'
  archived: false
`;

// Event RSVP fixtures. All future-dated (past-event guard never trips), owned
// by pw-test-org so the attendee-list authz tests have an owner. The Tilmeld
// events drive signup/withdraw + capacity; the Interesseret event drives the
// never-capacity-blocked path.
const RSVP_EVENT_YAML = `${RSVP_EVENT_ID}:
  published: true
  title: '[FIXTURE] RSVP Tilmeld event for Playwright tests'
  description: 'Seeded by tests/helpers/fixtures.js; do not edit.'
  group: makerspace
  badge: 'Makerspace & Reparation'
  event_date: '2030-05-15'
  event_time: '10:00 - 12:00'
  location: 'Makerspace lokalet'
  capacity: ''
  event_type: ''
  button_text: 'Tilmeld'
  button_url: ''
  button_style: primary
  featured: false
  featured_tag: ''
  owner: pw-test-org
  created_by: pw-test-org
  created_at: '2026-06-01T00:00:00Z'
  updated_by: pw-test-org
  updated_at: '2026-06-01T00:00:00Z'
  archived: false
  details_html: '<p>Medbring dit eget projekt — vi har værktøj og loddekolber klar.</p>'
`;

const CAPACITY_EVENT_YAML = `${CAPACITY_EVENT_ID}:
  published: true
  title: '[FIXTURE] Capacity-1 Tilmeld event for Playwright tests'
  description: 'Seeded by tests/helpers/fixtures.js; do not edit.'
  group: makerspace
  badge: 'Makerspace & Reparation'
  event_date: '2030-05-16'
  event_time: '10:00 - 12:00'
  location: 'Makerspace lokalet'
  capacity: '1'
  event_type: ''
  button_text: 'Tilmeld'
  button_url: ''
  button_style: primary
  featured: false
  featured_tag: ''
  owner: pw-test-org
  created_by: pw-test-org
  created_at: '2026-06-01T00:00:00Z'
  updated_by: pw-test-org
  updated_at: '2026-06-01T00:00:00Z'
  archived: false
  details_html: ''
`;

const INTEREST_EVENT_YAML = `${INTEREST_EVENT_ID}:
  published: true
  title: '[FIXTURE] Interesseret event for Playwright tests'
  description: 'Seeded by tests/helpers/fixtures.js; do not edit.'
  group: krea
  badge: 'Krea Café'
  event_date: '2030-05-17'
  event_time: '10:00 - 12:00'
  location: 'Krea lokalet'
  capacity: '1'
  event_type: ''
  button_text: 'Interesseret'
  button_url: ''
  button_style: tertiary
  featured: false
  featured_tag: ''
  owner: pw-test-org
  created_by: pw-test-org
  created_at: '2026-06-01T00:00:00Z'
  updated_by: pw-test-org
  updated_at: '2026-06-01T00:00:00Z'
  archived: false
  details_html: '<p>Kom og vær kreativ i Krea Café — kaffe på kanden.</p>'
`;

// Published, ran long ago, not yet archived — the dashboard sweep must flip
// archived to true. The date is static: it only ever needs to stay in the past.
// group MUST be a blueprint-valid stored value (alle/makerspace/kreativ/
// groenne/kulturhus — NOT the filter IDs krea/groent): the sweep saves through
// blueprint validation, and an invalid group makes the save throw, silently
// aborting the entire sweep.
const STALE_EVENT_YAML = `${STALE_EVENT_ID}:
  published: true
  title: '[FIXTURE] Stale event for auto-archive sweep tests'
  description: 'Seeded by tests/helpers/fixtures.js; do not edit.'
  group: groenne
  badge: 'Grønt BYværksted'
  event_date: '2026-01-10'
  event_time: '10:00 - 12:00'
  location: 'Grønt BYværksted'
  capacity: ''
  event_type: ''
  button_text: 'Tilmeld'
  button_url: ''
  button_style: primary
  featured: false
  featured_tag: ''
  owner: pw-test-org
  created_by: pw-test-org
  created_at: '2026-01-01T00:00:00Z'
  updated_by: pw-test-org
  updated_at: '2026-01-01T00:00:00Z'
  archived: false
`;

function ensureRsvpEvent() {
  return appendIfMissing(EVENTS_YAML_PATH, RSVP_EVENT_ID, RSVP_EVENT_YAML);
}

function ensureStaleEvent() {
  return appendIfMissing(EVENTS_YAML_PATH, STALE_EVENT_ID, STALE_EVENT_YAML);
}

function removeStaleEvent() {
  return removeFixture(EVENTS_YAML_PATH, STALE_EVENT_ID);
}

function ensureCapacityEvent() {
  return appendIfMissing(EVENTS_YAML_PATH, CAPACITY_EVENT_ID, CAPACITY_EVENT_YAML);
}

function ensureInterestEvent() {
  return appendIfMissing(EVENTS_YAML_PATH, INTEREST_EVENT_ID, INTEREST_EVENT_YAML);
}

function removeRsvpEvent() {
  return removeFixture(EVENTS_YAML_PATH, RSVP_EVENT_ID);
}

function removeCapacityEvent() {
  return removeFixture(EVENTS_YAML_PATH, CAPACITY_EVENT_ID);
}

function removeInterestEvent() {
  return removeFixture(EVENTS_YAML_PATH, INTEREST_EVENT_ID);
}

// Public demo events — seeded UNCONDITIONALLY (no credentials needed) so the
// calendar always carries forward-looking, detail-bearing content. Without
// them, the auto-archive rule (events that ran >1 day ago are hidden) plus
// details-gated card expansion would leave the anonymous/mobile calendar
// suites with nothing to assert on a credential-less machine. Dates are
// computed at seed time so they never age into staleness. Groups span
// makerspace + krea + kulturhus to cover the calendar filter tests; groent is
// intentionally left empty (the green filter's "no events" assumption).
const DEMO_EVENTS = [
  { key: 'ev_demo_makerspace', group: 'makerspace', style: 'secondary', badge: 'Makerspace & Reparation', title: '[DEMO] Åbent makerspace', days: 30 },
  { key: 'ev_demo_krea', group: 'krea', style: 'tertiary', badge: 'Krea Café', title: '[DEMO] Krea Café', days: 33 },
  { key: 'ev_demo_kulturhus', group: 'kulturhus', style: 'kulturhus', badge: 'Eventværkstedet', title: '[DEMO] Eventværkstedet', days: 37 },
];

function futureDateString(daysAhead) {
  const d = new Date();
  d.setDate(d.getDate() + daysAhead);
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function demoEventYaml(e) {
  return `${e.key}:
  published: true
  title: '${e.title}'
  description: 'Seeded by tests/helpers/fixtures.js; do not edit.'
  group: ${e.group}
  badge: '${e.badge}'
  event_date: '${futureDateString(e.days)}'
  event_time: '10:00 - 12:00'
  location: 'Store Rum'
  button_style: ${e.style}
  button_text: 'Tilmeld'
  featured: false
  archived: false
  details_html: '<p>Kom forbi og vær med — alle er velkomne.</p>'
`;
}

function ensurePublicDemoEvents() {
  let seeded = false;
  for (const e of DEMO_EVENTS) {
    seeded = appendIfMissing(EVENTS_YAML_PATH, e.key, demoEventYaml(e)).seeded || seeded;
  }
  return { seeded };
}

function removePublicDemoEvents() {
  for (const e of DEMO_EVENTS) {
    removeFixture(EVENTS_YAML_PATH, e.key);
  }
}

/**
 * Remove the whole event-signups store (runtime, gitignored). Resets every
 * RSVP test to zero signups; safe if the file is already absent.
 */
function clearEventSignups() {
  try {
    execFileSync('docker', ['exec', '-u', 'abc', gravContainer(), 'sh', '-c', `rm -f ${SIGNUPS_YAML_PATH}`], {
      stdio: ['ignore', 'ignore', 'ignore'],
      timeout: 10_000,
    });
  } catch (_) { /* non-fatal */ }
}

/**
 * Remove all uploaded event images (runtime, gitignored). Uses find -delete
 * (not rm -rf) so it degrades safely if the directory is missing.
 */
function clearEventImages() {
  try {
    execFileSync('docker', ['exec', '-u', 'abc', gravContainer(), 'sh', '-c',
      `find ${EVENT_IMAGES_DIR} -mindepth 1 -delete 2>/dev/null || true`], {
      stdio: ['ignore', 'ignore', 'ignore'],
      timeout: 10_000,
    });
  } catch (_) { /* non-fatal */ }
}

/** True when the event-manager audit log contains a line matching the pattern. */
function eventAuditContains(pattern) {
  try {
    execFileSync('docker', ['exec', gravContainer(), 'grep', '-qE', pattern, EVENT_AUDIT_PATH], {
      stdio: ['ignore', 'ignore', 'ignore'],
      timeout: 10_000,
    });
    return true;
  } catch {
    return false;
  }
}

function ensureDraftEvent() {
  return appendIfMissing(EVENTS_YAML_PATH, DRAFT_EVENT_ID, DRAFT_EVENT_YAML);
}

function ensureArchivedEvent() {
  return appendIfMissing(EVENTS_YAML_PATH, ARCHIVED_EVENT_ID, ARCHIVED_EVENT_YAML);
}

function ensureForeignEvent() {
  return appendIfMissing(EVENTS_YAML_PATH, FOREIGN_EVENT_ID, FOREIGN_EVENT_YAML);
}

function removeDraftEvent() {
  return removeFixture(EVENTS_YAML_PATH, DRAFT_EVENT_ID);
}

function removeArchivedEvent() {
  return removeFixture(EVENTS_YAML_PATH, ARCHIVED_EVENT_ID);
}

function removeForeignEvent() {
  return removeFixture(EVENTS_YAML_PATH, FOREIGN_EVENT_ID);
}

/**
 * Remove an event created DURING a test run by its server-assigned key.
 * Key shape is strictly validated (`ev_<hex>`) before it reaches sed — the
 * legacy `event0NN` seeds and fixtures can never match.
 *
 * @param {string} key
 */
function removeEventByKey(key) {
  if (!/^ev_[0-9a-f]{8,32}$/.test(key)) {
    throw new Error(`fixtures.removeEventByKey: '${key}' is not a test-created event key`);
  }
  return removeFixture(EVENTS_YAML_PATH, key);
}

/**
 * Ensure the locked-roadmap fixture is present. Idempotent: if the key is
 * already there we leave it alone.
 */
function ensureLockedRoadmapItem() {
  return appendIfMissing(LOCKED_ROADMAP_YAML_PATH, LOCKED_ROADMAP_ITEM_ID, LOCKED_FIXTURE_YAML);
}

function ensureReleasableRoadmapItem() {
  return appendIfMissing(LOCKED_ROADMAP_YAML_PATH, RELEASABLE_ROADMAP_ITEM_ID, RELEASABLE_FIXTURE_YAML);
}

function ensureUnpromotedBugReport() {
  return appendIfMissing(BUG_REPORTS_YAML_PATH, UNPROMOTED_BUG_REPORT_ID, UNPROMOTED_BUG_YAML);
}

function ensurePromotedBugReport() {
  return appendIfMissing(BUG_REPORTS_YAML_PATH, PROMOTED_BUG_REPORT_ID, PROMOTED_BUG_YAML);
}

function appendIfMissing(path, key, yaml) {
  if (yamlContains(path, `^${key}:`)) return { seeded: false };
  execFileSync(
    'docker',
    ['exec', '-i', '-u', 'abc', gravContainer(), 'sh', '-c', `cat >> ${path}`],
    { input: yaml, stdio: ['pipe', 'pipe', 'pipe'], timeout: 10_000 }
  );
  return { seeded: true };
}

/**
 * Clear Grav's cache so freshly-seeded fixtures become visible everywhere.
 *
 * Appending a row to a flex-objects YAML at runtime does NOT invalidate Grav's
 * compiled flex index. The front-end re-reads the file, but the ADMIN
 * flex-objects view serves the cached index — so an item seeded after the cache
 * warmed reads back as `object.exists == false` (e.g. the admin roadmap edit
 * page then never renders the release_nonce, failing the admin smoke test).
 * Clearing the cache once after seeding makes the seed visible to every read
 * path. `-w /app/www/public` is mandatory (the image's default WORKDIR lacks
 * bin/grav); `clearcache` is the single-word form (no hyphen); `-u abc` is
 * mandatory too — as root it recreates cache dirs the web user can't write,
 * which 500s the whole site on the next request.
 */
function clearGravCache() {
  try {
    execFileSync('docker', ['exec', '-u', 'abc', '-w', '/app/www/public', gravContainer(), 'bin/grav', 'clearcache'], {
      stdio: ['ignore', 'ignore', 'ignore'],
      timeout: 30_000,
    });
  } catch (_) { /* non-fatal */ }
}

/**
 * Remove the locked-roadmap fixture. Safe to call when the entry is gone.
 * Uses sed with the fixture key allowlisted — never accepts untrusted input.
 */
function removeLockedRoadmapItem() {
  return removeFixture(LOCKED_ROADMAP_YAML_PATH, LOCKED_ROADMAP_ITEM_ID);
}

function removeReleasableRoadmapItem() {
  return removeFixture(LOCKED_ROADMAP_YAML_PATH, RELEASABLE_ROADMAP_ITEM_ID);
}

function removeUnpromotedBugReport() {
  return removeFixture(BUG_REPORTS_YAML_PATH, UNPROMOTED_BUG_REPORT_ID);
}

function removePromotedBugReport() {
  return removeFixture(BUG_REPORTS_YAML_PATH, PROMOTED_BUG_REPORT_ID);
}

function removeFixture(path, key) {
  // Delete the fixture block (header line + its indented body). The fixture
  // key is a compile-time constant, so there's no interpolation from
  // untrusted input.
  const script = `sed -i '/^${key}:$/,/^[a-zA-Z_]/{ /^${key}:$/d; /^[a-zA-Z_]/!d; }' ${path}`;
  try {
    // -u abc: sed -i rewrites the YAML; as root it leaves a root-owned file.
    execFileSync('docker', ['exec', '-u', 'abc', gravContainer(), 'sh', '-c', script], {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10_000,
    });
    return { removed: true };
  } catch {
    return { removed: false };
  }
}

function yamlContains(path, pattern) {
  try {
    execFileSync('docker', ['exec', gravContainer(), 'grep', '-qE', pattern, path], {
      stdio: ['ignore', 'pipe', 'pipe'],
      timeout: 10_000,
    });
    return true;
  } catch {
    return false;
  }
}

module.exports = {
  LOCKED_ROADMAP_ITEM_ID,
  RELEASABLE_ROADMAP_ITEM_ID,
  UNPROMOTED_BUG_REPORT_ID,
  DRAFT_EVENT_ID,
  ARCHIVED_EVENT_ID,
  FOREIGN_EVENT_ID,
  RSVP_EVENT_ID,
  CAPACITY_EVENT_ID,
  INTEREST_EVENT_ID,
  STALE_EVENT_ID,
  PROMOTED_BUG_REPORT_ID,
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
  ensurePublicDemoEvents,
  removePublicDemoEvents,
  removeLockedRoadmapItem,
  removeReleasableRoadmapItem,
  removeUnpromotedBugReport,
  removePromotedBugReport,
  removeDraftEvent,
  removeArchivedEvent,
  removeForeignEvent,
  removeRsvpEvent,
  removeCapacityEvent,
  removeInterestEvent,
  removeStaleEvent,
  removeEventByKey,
  clearEventSignups,
  clearEventImages,
  eventAuditContains,
  clearGravCache,
};
