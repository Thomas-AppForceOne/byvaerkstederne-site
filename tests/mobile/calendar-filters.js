// @ts-check
'use strict';

/**
 * Mobile calendar filters — at iPhone-class widths every filter must stack on
 * its own line (desktop keeps them on a single row; see the desktop assertion
 * in tests/anonymous/events-public.js). Anonymous, so the personal "Mine
 * aktiviteter" filter is absent; the workshop filters + "Alle aktiviteter"
 * still stack one-per-line.
 */

const { test, expect } = require('@playwright/test');

test('calendar filters stack one per line on mobile', async ({ page }) => {
  await page.goto('/vaerkstedskalenderen');
  const btns = page.locator('.bv-filter-btn');
  const count = await btns.count();
  expect(count).toBeGreaterThan(1);
  const tops = await btns.evaluateAll((els) => els.map((e) => Math.round(e.getBoundingClientRect().top)));
  // Each button starts a new row → as many distinct top offsets as buttons.
  expect(new Set(tops).size).toBe(count);
});
