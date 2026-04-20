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

const LOCKED_ROADMAP_ITEM_ID = 'rm_fixture_locked';
const RELEASABLE_ROADMAP_ITEM_ID = 'rm_fixture_releasable';
const UNPROMOTED_BUG_REPORT_ID = 'br_fixture_unpromoted';
const LOCKED_ROADMAP_YAML_PATH = '/config/www/user/data/flex-objects/roadmap-items.yaml';
const BUG_REPORTS_YAML_PATH = '/config/www/user/data/flex-objects/bug-reports.yaml';

const LOCKED_FIXTURE_YAML = `
${LOCKED_ROADMAP_ITEM_ID}:
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

const RELEASABLE_FIXTURE_YAML = `
${RELEASABLE_ROADMAP_ITEM_ID}:
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

const UNPROMOTED_BUG_YAML = `
${UNPROMOTED_BUG_REPORT_ID}:
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

function appendIfMissing(path, key, yaml) {
  if (yamlContains(path, `^${key}:`)) return { seeded: false };
  execFileSync(
    'docker',
    ['exec', '-i', 'grav', 'sh', '-c', `cat >> ${path}`],
    { input: yaml, stdio: ['pipe', 'pipe', 'pipe'], timeout: 10_000 }
  );
  return { seeded: true };
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

function removeFixture(path, key) {
  // Delete the fixture block (header line + its indented body). The fixture
  // key is a compile-time constant, so there's no interpolation from
  // untrusted input.
  const script = `sed -i '/^${key}:$/,/^[a-zA-Z_]/{ /^${key}:$/d; /^[a-zA-Z_]/!d; }' ${path}`;
  try {
    execFileSync('docker', ['exec', 'grav', 'sh', '-c', script], {
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
    execFileSync('docker', ['exec', 'grav', 'grep', '-qE', pattern, path], {
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
  ensureLockedRoadmapItem,
  ensureReleasableRoadmapItem,
  ensureUnpromotedBugReport,
  removeLockedRoadmapItem,
  removeReleasableRoadmapItem,
  removeUnpromotedBugReport,
};
