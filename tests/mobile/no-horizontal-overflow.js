// @ts-check
'use strict';

/**
 * Mobile-rendering — four-route horizontal-overflow sweep.
 *
 * Regression guard for the whole sprint (spec Acceptance #5, contract C5).
 * For each probed route at 390 × 844, assert that the document does not
 * scroll horizontally — i.e. nothing pushes the layout wider than the
 * viewport. This is the safety net that catches "a fix shrank one element
 * but another inline-styled child still bleeds off the edge".
 *
 * The four routes mirror the spec exactly:
 *   /vaerksteder/krea-cafe       — workgroup cards (defect 1)
 *   /vaerksteder                 — workgroups index (defect 1, four cards)
 *   /vaerkstedskalenderen        — event-list (defects 2 + 3)
 *   /vaerksteder/eventvaerkstedet — technique cards (defect 4)
 */

const { test, expect } = require('@playwright/test');
const { useDevHost } = require('./_helpers');

const ROUTES = [
  '/vaerksteder/krea-cafe',
  '/vaerksteder',
  '/vaerkstedskalenderen',
  '/vaerksteder/eventvaerkstedet',
];

test.describe('Mobile — no horizontal page overflow on the four probed routes', () => {
  test.beforeEach(async ({ page }) => { await useDevHost(page); });

  for (const route of ROUTES) {
    test(`mobile-no-horizontal-overflow on ${route}`, async ({ page }) => {
      const response = await page.goto(route);
      expect(response?.status(), `${route} should return 200`).toBe(200);

      const result = await page.evaluate(() => ({
        scrollWidth: document.documentElement.scrollWidth,
        innerWidth: window.innerWidth,
      }));

      // C5 wording: documentElement.scrollWidth === window.innerWidth.
      // Strict equality — anything wider is the regression we're guarding.
      expect(
        result.scrollWidth,
        `${route}: documentElement.scrollWidth (${result.scrollWidth}) should equal window.innerWidth (${result.innerWidth})`
      ).toBe(result.innerWidth);
    });
  }
});
