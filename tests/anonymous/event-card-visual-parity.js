// @ts-check
'use strict';

/**
 * Anonymous — event-card visual-parity baselines (sprint 1).
 *
 * Captures desktop-viewport (chromium project default) screenshots of
 * the affected routes and compares them against baselines captured
 * AFTER all migrations landed. Baselines from any prior attempt are
 * discarded.
 *
 * The atelier_sessions surface (/vaerksteder/krea-cafe/syvaerkstedet and
 * /vaerksteder/krea-cafe/billedkunst) is no longer covered: the workshop
 * calendar (/vaerkstedskalenderen) supersedes the hardcoded per-workshop
 * event sections, which were removed, so those routes no longer render
 * event cards. atelier_sessions.html.twig is now a routeless card
 * template — same situation as calendar_featured.html.twig below — and
 * its parity is locked by the template-level grep criteria instead of a
 * screenshot baseline.
 *
 * Tolerance: 5 % pixel-diff threshold (maxDiffPixelRatio: 0.05). This
 * absorbs the small typographic / sub-pixel deltas font hinting and
 * antialiasing introduce across runs without surfacing them as visual
 * regressions, while still catching meaningful layout drift.
 *
 * The v2 handoff at documentation/design/event-row-handoff/ is the
 * ground-truth visual contract; baselines are checked side-by-side
 * against reference/demo.html before being committed.
 *
 * Contract criteria covered: C18, C30. Sprint 2 adds the event_highlight
 * route (/ — home). calendar_featured.html.twig is migrated but has NO
 * route: its page (02.vaerkstedskalenderen/_03.featured) was removed in
 * the opening-day cleanup (980eb9c), so the spec's "every route that
 * renders calendar_featured" set is empty and no baseline exists for it.
 */

const { test, expect } = require('@playwright/test');

// Wait for any web-fonts referenced by the page (Space Grotesk, Work
// Sans, Material Symbols Outlined) to finish loading before capturing
// so the baseline doesn't lock in mid-swap typography.
async function waitForFontsAndStability(page) {
  await page.evaluate(async () => {
    if (document.fonts && document.fonts.ready) {
      await document.fonts.ready;
    }
  });
  // Small wait to let any layout-shift-on-font-swap settle.
  await page.waitForTimeout(250);
}

test.describe('event-card-visual-parity (sprint 1)', () => {
  test('event_list — /vaerkstedskalenderen visual parity', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    await waitForFontsAndStability(page);
    await expect(page).toHaveScreenshot('vaerkstedskalenderen.png', {
      maxDiffPixelRatio: 0.05,
      fullPage: false,
    });
  });

});

test.describe('event-card-visual-parity (sprint 2)', () => {
  test('event_highlight — / (home, primary featured card) visual parity', async ({ page }) => {
    // Captured AFTER both sprint-2 migrations (calendar_featured +
    // event_highlight) landed — never piecemeal (spec step 13a). The
    // home sidebar card is the only live surface rendering the
    // partial's single-card (inList: false) + featured path.
    await page.goto('/');
    await waitForFontsAndStability(page);
    await expect(page).toHaveScreenshot('home-event-highlight.png', {
      maxDiffPixelRatio: 0.05,
      fullPage: false,
    });
  });
});
