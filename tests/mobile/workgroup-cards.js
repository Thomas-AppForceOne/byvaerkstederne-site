// @ts-check
'use strict';

/**
 * Mobile-rendering — workgroup cards.
 *
 * Covers screenshot 1 from the user's iPhone report: on
 * /vaerksteder/krea-cafe the atelier card with title "BILLEDKUNST" had its
 * heading clipped at the top edge. Root cause: at @media (max-width: 767px)
 * the .bv-workgroup-card had a fixed 16/9 aspect-ratio combined with
 * overflow:hidden and a bottom-anchored content stack — when the content
 * stack was taller than the card the title pushed up out of the box.
 *
 * Two routes are probed:
 *   /vaerksteder/krea-cafe  — two atelier cards
 *   /vaerksteder            — four workgroup cards
 *
 * Failure path: against the pre-fix CSS the krea-cafe BILLEDKUNST title
 * sits ABOVE the card's top edge, so title.top < card.top and the test
 * fails — exactly the C6 failure-path test the contract requires.
 */

const { test, expect } = require('@playwright/test');
const { useDevHost } = require('./_helpers');

const ROUTES = [
  { path: '/vaerksteder/krea-cafe', minCards: 2 },
  { path: '/vaerksteder', minCards: 4 },
];

test.describe('Mobile — workgroup cards (screenshot 1, BILLEDKUNST clip)', () => {
  test.beforeEach(async ({ page }) => { await useDevHost(page); });

  for (const { path: route, minCards } of ROUTES) {
    test(`mobile-workgroup-title-fully-visible on ${route}`, async ({ page }) => {
      const response = await page.goto(route);
      expect(response?.status(), `${route} should return 200`).toBe(200);

      const cards = page.locator('.bv-workgroup-card');
      const count = await cards.count();
      expect(count, `expected at least ${minCards} workgroup card(s) on ${route}`).toBeGreaterThanOrEqual(minCards);

      for (let i = 0; i < count; i += 1) {
        const card = cards.nth(i);
        const title = card.locator('.bv-workgroup-card__title');

        await expect(title).toBeVisible();

        const cardBox = await card.boundingBox();
        const titleBox = await title.boundingBox();
        expect(cardBox, `card ${i} on ${route} should have a bounding box`).not.toBeNull();
        expect(titleBox, `card ${i} title on ${route} should have a bounding box`).not.toBeNull();
        if (!cardBox || !titleBox) continue;

        // The title must be wholly inside the card (no clip on any edge).
        // 0.5 px tolerance for sub-pixel rounding on real device pixels.
        const TOL = 0.5;
        expect(titleBox.y, `card ${i} on ${route}: title top should be inside card top`).toBeGreaterThanOrEqual(cardBox.y - TOL);
        expect(titleBox.x, `card ${i} on ${route}: title left should be inside card left`).toBeGreaterThanOrEqual(cardBox.x - TOL);
        expect(titleBox.x + titleBox.width, `card ${i} on ${route}: title right should be inside card right`).toBeLessThanOrEqual(cardBox.x + cardBox.width + TOL);
        expect(titleBox.y + titleBox.height, `card ${i} on ${route}: title bottom should be inside card bottom`).toBeLessThanOrEqual(cardBox.y + cardBox.height + TOL);
      }
    });
  }

  test('mobile-workgroup-title-not-clipped-when-desc-revealed', async ({ page }) => {
    // Failure-path-of-a-failure-path: simulate the hover state that reveals
    // the description (the original 16:9 + overflow:hidden combination
    // showed the clip most aggressively when the desc was shown). With the
    // fix the card grows to fit content, so the title stays inside the box
    // even with the description rendered at full opacity.
    await page.goto('/vaerksteder/krea-cafe');
    const cards = page.locator('.bv-workgroup-card');
    const count = await cards.count();
    expect(count).toBeGreaterThanOrEqual(2);

    for (let i = 0; i < count; i += 1) {
      const card = cards.nth(i);
      await card.hover();
      const title = card.locator('.bv-workgroup-card__title');
      const cardBox = await card.boundingBox();
      const titleBox = await title.boundingBox();
      if (!cardBox || !titleBox) continue;
      const TOL = 0.5;
      expect(titleBox.y, `card ${i} (hovered): title top should be inside card`).toBeGreaterThanOrEqual(cardBox.y - TOL);
      expect(titleBox.y + titleBox.height, `card ${i} (hovered): title bottom should be inside card`).toBeLessThanOrEqual(cardBox.y + cardBox.height + TOL);
    }
  });
});
