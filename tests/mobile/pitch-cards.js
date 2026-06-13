// @ts-check
'use strict';

/**
 * Mobile-rendering — pitch / technique cards on /vaerksteder/eventvaerkstedet.
 *
 * Covers screenshot 5: the faded decorative numeral "05" overlapped the
 * headline "DU HAR SCENESKRÆK — OG EN HEMMELIG DRØM". Root cause: the
 * numeral was inline-styled with font-size:3rem and opacity:0.1 anchored
 * top/right; on a narrow column the headline wrapped and intersected the
 * numeral's bounding box.
 *
 * Fix promotes the inline style to a class .bv-technique-card__index so
 * the mobile breakpoint can shrink + tuck the numeral and constrain the
 * headline's max-width so the two bounding boxes are disjoint.
 *
 * Failure path: against the pre-fix CSS the numeral's bounding rect
 * intersects the h3's bounding rect on the wider pitch cards.
 */

const { test, expect } = require('@playwright/test');
const { useDevHost } = require('./_helpers');

const ROUTE = '/vaerksteder/eventvaerkstedet';

// Two locators, two selector dialects:
//   POST_RENAME_SELECTOR  matches the new .bv-technique-card class the fix
//                         emits via atelier_techniques.html.twig.
//   FALLBACK_SELECTOR     matches the pre-rename inline-styled card wrapper
//                         (the screenshot-5 base tree has no card-level
//                         class at all, only the inline-styled div with
//                         position:relative + overflow:hidden that the
//                         template emitted before the rename).
// The for-loop below binds `cards` to whichever locator's count() returned
// positive, so the iterated locator is always the one that resolved.
// Iterating the original (post-rename) locator after only the fallback
// resolved was the F1 silent-pass bug — the loop ran zero iterations on
// the base ref and the geometric assertion never executed.
const POST_RENAME_SELECTOR = '.bv-technique-card';
const FALLBACK_SELECTOR = 'section.bv-section div[style*="position: relative"][style*="overflow: hidden"]';

test.describe('Mobile — pitch / technique cards (screenshot 5, numeral overlap)', () => {
  test.beforeEach(async ({ page }) => { await useDevHost(page); });

  test('mobile-pitch-numeral-does-not-overlap-headline', async ({ page }) => {
    const response = await page.goto(ROUTE);
    expect(response?.status()).toBe(200);

    // Resolve the cards locator: prefer the post-rename class; fall back
    // to the inline-styled signature only if the post-rename count is
    // zero. Bind `cards` to whichever locator resolved positive so the
    // for-loop iterates a non-empty locator on every tree (HEAD or base).
    const postRename = page.locator(POST_RENAME_SELECTOR);
    const fallback = page.locator(FALLBACK_SELECTOR);
    const postRenameCount = await postRename.count();
    const cards = postRenameCount > 0 ? postRename : fallback;
    const count = postRenameCount > 0 ? postRenameCount : await fallback.count();
    expect(count, `expected pitch cards on ${ROUTE}`).toBeGreaterThan(0);

    const TOL = 0.5;

    for (let i = 0; i < count; i += 1) {
      const card = cards.nth(i);
      // Numeral: prefer the new class, fall back to "first child of card"
      // (the inline-styled span on the base ref).
      const numeralByClass = card.locator('.bv-technique-card__index');
      const numeralCount = await numeralByClass.count();
      const numeral = numeralCount > 0 ? numeralByClass.first() : card.locator(':scope > div').first();

      const h3 = card.locator('h3').first();

      await expect(numeral).toBeVisible();
      await expect(h3).toBeVisible();

      // Visibility guard: numeral must not be display:none or
      // visibility:hidden — the design intent is "decorative numeral
      // remains visible, just relayered / repositioned".
      const visStyle = await numeral.evaluate((el) => {
        const s = getComputedStyle(el);
        return { display: s.display, visibility: s.visibility };
      });
      expect(visStyle.display, 'numeral.display must not be none').not.toBe('none');
      expect(visStyle.visibility, 'numeral.visibility must not be hidden').not.toBe('hidden');

      const numBox = await numeral.boundingBox();
      const h3Box = await h3.boundingBox();
      expect(numBox, `card ${i}: numeral bounding box`).not.toBeNull();
      expect(h3Box, `card ${i}: h3 bounding box`).not.toBeNull();
      if (!numBox || !h3Box) continue;

      // Non-intersection: numeral.right <= h3.left OR numeral.left >= h3.right
      //              OR  numeral.bottom <= h3.top OR numeral.top >= h3.bottom
      const numRight = numBox.x + numBox.width;
      const numBottom = numBox.y + numBox.height;
      const h3Right = h3Box.x + h3Box.width;
      const h3Bottom = h3Box.y + h3Box.height;

      const disjoint =
        numRight <= h3Box.x + TOL ||
        numBox.x >= h3Right - TOL ||
        numBottom <= h3Box.y + TOL ||
        numBox.y >= h3Bottom - TOL;

      expect(
        disjoint,
        `card ${i}: numeral box {${numBox.x}, ${numBox.y}, ${numRight}, ${numBottom}} must not intersect h3 box {${h3Box.x}, ${h3Box.y}, ${h3Right}, ${h3Bottom}}`
      ).toBe(true);
    }
  });

  test('mobile-pitch-numeral-remains-inside-card', async ({ page }) => {
    // Guard against a future "just move the numeral way off-card" regression
    // that would technically satisfy the non-intersection rule but break the
    // visual design. Uses the same post-rename / fallback locator resolution
    // as the overlap test so the loop iterates a non-empty locator on both
    // HEAD and the base ref (no silent no-op when the post-rename class is
    // absent).
    await page.goto(ROUTE);
    const postRename = page.locator(POST_RENAME_SELECTOR);
    const fallback = page.locator(FALLBACK_SELECTOR);
    const postRenameCount = await postRename.count();
    const cards = postRenameCount > 0 ? postRename : fallback;
    const count = postRenameCount > 0 ? postRenameCount : await fallback.count();
    expect(count, `expected pitch cards on ${ROUTE}`).toBeGreaterThan(0);
    for (let i = 0; i < count; i += 1) {
      const card = cards.nth(i);
      const numeral = card.locator('.bv-technique-card__index, :scope > div').first();
      const cardBox = await card.boundingBox();
      const numBox = await numeral.boundingBox();
      if (!cardBox || !numBox) continue;
      const TOL = 1;
      expect(numBox.x, `card ${i}: numeral left should be inside card`).toBeGreaterThanOrEqual(cardBox.x - TOL);
      expect(numBox.x + numBox.width, `card ${i}: numeral right should be inside card`).toBeLessThanOrEqual(cardBox.x + cardBox.width + TOL);
      expect(numBox.y, `card ${i}: numeral top should be inside card`).toBeGreaterThanOrEqual(cardBox.y - TOL);
      expect(numBox.y + numBox.height, `card ${i}: numeral bottom should be inside card`).toBeLessThanOrEqual(cardBox.y + cardBox.height + TOL);
    }
  });
});
