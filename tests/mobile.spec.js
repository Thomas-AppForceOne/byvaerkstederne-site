// @ts-check
'use strict';

/**
 * Mobile-rendering suite entry point — iPhone-class viewports (390 × 844).
 *
 * Actual test cases live in tests/mobile/ — one file per defect area.
 * Run with: npx playwright test --project=mobile-chromium
 *
 * Anonymous-only by design. The four defects this suite locks down are all
 * public-page rendering bugs; the suite must NOT call seedWorktreeAdmin()
 * and must NOT gate on TEST_PASSWORD (CLAUDE.md hard constraints, spec
 * "Notes for the proposer and evaluator → anonymousMobileSuite").
 *
 * Defect → file mapping (screenshot numbers from the user's iPhone report):
 *   tests/mobile/workgroup-cards.js          — screenshot 1
 *   tests/mobile/event-row.js                — screenshots 2, 3, 4
 *   tests/mobile/pitch-cards.js              — screenshot 5
 *   tests/mobile/no-horizontal-overflow.js   — four-route sweep
 */
require('./mobile/workgroup-cards');
require('./mobile/event-row');
require('./mobile/pitch-cards');
require('./mobile/no-horizontal-overflow');
require('./mobile/event-card-unification');
require('./mobile/event-card-container-query');
