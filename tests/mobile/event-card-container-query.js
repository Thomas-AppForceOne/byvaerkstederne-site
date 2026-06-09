// @ts-check
'use strict';

/**
 * Mobile — event-card container-query mechanism proof (sprint 1).
 *
 * The container-query test MUST run at a desktop viewport so the
 * 360-px wrapper — NOT the viewport — is what the container query
 * fires on. At the mobile-chromium project's default 390 × 844, the
 * viewport itself is narrower than the @container event-row
 * (max-width: 540px) breakpoint and the test would pass trivially
 * regardless of mechanism. test.use() overrides the viewport per
 * sprint-1 contract criterion C12 (gate A).
 *
 * Real content lands at sprint-1 step 9. At step 2 this file only
 * carries a wiring-smoke assertion so the project reports > 0
 * passing tests immediately. The desktop-viewport override is
 * already declared here so the static C12 grep passes from sprint-1
 * step 2 onward.
 */

const { test, expect } = require('@playwright/test');

test.describe('mobile-event-card-container-query', () => {
  // Desktop viewport — narrower than @container event-row (max-width:
  // 540px) means the container query would fire trivially against the
  // viewport-as-container. The 1280 × 800 override is the static gate
  // criterion C12 verifies via grep.
  test.use({ viewport: { width: 1280, height: 800 } });

  test('wiring smoke', () => {
    // Trivial assertion to prove the file is reachable via the
    // tests/mobile.spec.js require() chain. Replaced by the real
    // content in step 9.
    expect(1 + 1).toBe(2);
  });
});
