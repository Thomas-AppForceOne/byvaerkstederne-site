// @ts-check
'use strict';

/**
 * Event card modal expansion (event_rsvp_specification.md §4/§7). Anonymous —
 * the modal needs no login. Clicking a card (not the button or a link) floats
 * it modally, updates the URL via pushState, and closes on Esc/backdrop; a
 * direct load of the deep link renders the full server detail page.
 */

const { test, expect } = require('@playwright/test');

async function firstExpandableCard(page) {
  await page.goto('/vaerkstedskalenderen');
  const card = page.locator('.bv-event-row[data-event-key]').first();
  await expect(card).toHaveCount(1);
  const key = await card.getAttribute('data-event-key');
  return { card, key };
}

test.describe('Event card modal', () => {
  test('clicking the card body opens the modal and pushes the deep link', async ({ page }) => {
    const { card, key } = await firstExpandableCard(page);
    await card.locator('.bv-event-row__date').click();
    await expect(page.locator('.bv-event-modal.is-open')).toHaveCount(1);
    await expect(page).toHaveURL(new RegExp(`/begivenheder/${key}$`));
    // The modal carries the card summary.
    await expect(page.locator('.bv-event-modal .bv-event-row__title')).toHaveCount(1);
  });

  test('clicking the title opens the modal in place, it does NOT navigate to the detail page', async ({ page }) => {
    const { card } = await firstExpandableCard(page);
    await card.locator('.bv-event-row__title').click();
    await expect(page.locator('.bv-event-modal.is-open')).toHaveCount(1);
    // Still the calendar with the modal over it — not a full detail-page load
    // (the detail page has no .bv-event-list).
    await expect(page.locator('.bv-event-list')).toHaveCount(1);
  });

  test('Esc closes the modal and restores the calendar URL', async ({ page }) => {
    const { card } = await firstExpandableCard(page);
    await card.locator('.bv-event-row__date').click();
    await expect(page.locator('.bv-event-modal.is-open')).toHaveCount(1);
    await page.keyboard.press('Escape');
    await expect(page.locator('.bv-event-modal.is-open')).toHaveCount(0);
    await expect(page).toHaveURL(/\/vaerkstedskalenderen$/);
  });

  test('backdrop click closes the modal', async ({ page }) => {
    const { card } = await firstExpandableCard(page);
    await card.locator('.bv-event-row__date').click();
    const overlay = page.locator('.bv-event-modal');
    await expect(overlay).toHaveClass(/is-open/);
    await expect(page.locator('.bv-event-modal__panel')).toBeVisible();
    // Click the overlay's own top-left corner — backdrop, away from the
    // centered panel — so the overlay (not a child) is the event target.
    await overlay.click({ position: { x: 5, y: 5 } });
    await expect(page.locator('.bv-event-modal.is-open')).toHaveCount(0);
  });

  test('a direct load of the deep link renders the server detail page, no modal', async ({ page }) => {
    const { key } = await firstExpandableCard(page);
    await page.goto(`/begivenheder/${key}`);
    await expect(page.locator('.bv-event-detail')).toHaveCount(1);
    await expect(page.locator('.bv-event-modal')).toHaveCount(0);
  });

  test('clicking the signup button never opens the modal (offers login instead)', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    const btn = page.locator('.bv-event-row[data-event-key] [data-rsvp-key]:not([disabled])').first();
    await btn.scrollIntoViewIfNeeded();
    await btn.click();
    await expect(page.locator('.bv-event-modal.is-open')).toHaveCount(0);
    await expect(page.locator('#bv-login-overlay.is-open')).toHaveCount(1);
  });
});
