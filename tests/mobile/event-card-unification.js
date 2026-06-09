// @ts-check
'use strict';

/**
 * Mobile — event-card unification (sprint 1).
 *
 * Real content lands at sprint-1 step 10. At step 2 this file only
 * carries a trivial wiring-smoke assertion so the mobile-chromium
 * project reports > 0 passing tests immediately — without that, the
 * project's testMatch could silently resolve to zero tests and mask a
 * broken require() chain (the Sprint-5 silent-failure mode CLAUDE.md
 * flags, contract criterion C28).
 *
 * The wiring-smoke test is REPLACED by the real F1/F2/F3 + a11y guards
 * when step 10 lands; it is not left behind.
 */

const { test, expect } = require('@playwright/test');

test.describe('mobile-event-card-unification', () => {
  test('wiring smoke', () => {
    // Trivial assertion to prove the file is reachable via the
    // tests/mobile.spec.js require() chain. Replaced by the real
    // content in step 10.
    expect(1 + 1).toBe(2);
  });
});
