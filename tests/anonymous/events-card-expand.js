// @ts-check
'use strict';

/**
 * Event card inline expansion (event_rsvp_specification.md §4/§7). Anonymous —
 * clicking a card (anywhere but the signup button) expands it in place: the
 * details unfold in a panel below the card and the other events push down
 * (accordion). No modal, no URL change; a direct load of /begivenheder/<key>
 * still renders the full server detail page.
 */

const { test, expect } = require('@playwright/test');

async function firstExpandableCard(page) {
  await page.goto('/vaerkstedskalenderen');
  const card = page.locator('.bv-event-row[data-event-key]').first();
  await expect(card).toHaveCount(1);
  const key = await card.getAttribute('data-event-key');
  return { card, key };
}

test.describe('Event card inline expansion', () => {
  test('clicking the card body expands it in place — a panel below, no modal, no navigation', async ({ page }) => {
    const { card, key } = await firstExpandableCard(page);
    const urlBefore = page.url();
    await card.locator('.bv-event-row__date').click();
    await expect(card).toHaveClass(/is-expanded/);
    await expect(card).toHaveAttribute('aria-expanded', 'true');
    await expect(page.locator(`#bv-ev-details-${key}`)).toBeVisible();
    // No modal, URL unchanged, still the calendar list.
    await expect(page.locator('.bv-event-modal')).toHaveCount(0);
    expect(page.url()).toBe(urlBefore);
    await expect(page.locator('.bv-event-list')).toHaveCount(1);
  });

  test('clicking the title expands in place, it does NOT navigate to the detail page', async ({ page }) => {
    const { card } = await firstExpandableCard(page);
    await card.locator('.bv-event-row__title').click();
    await expect(card).toHaveClass(/is-expanded/);
    await expect(page.locator('.bv-event-list')).toHaveCount(1); // not a detail-page load
  });

  test('clicking an expanded card again collapses it', async ({ page }) => {
    const { card, key } = await firstExpandableCard(page);
    await card.locator('.bv-event-row__date').click();
    await expect(card).toHaveClass(/is-expanded/);
    await card.locator('.bv-event-row__date').click();
    await expect(card).not.toHaveClass(/is-expanded/);
    await expect(page.locator(`#bv-ev-details-${key}`)).toBeHidden();
  });

  test('accordion: opening a second card collapses the first', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    const cards = page.locator('.bv-event-row[data-event-key]');
    test.skip((await cards.count()) < 2, 'need at least two expandable cards');
    await cards.nth(0).locator('.bv-event-row__date').click();
    await expect(cards.nth(0)).toHaveClass(/is-expanded/);
    await cards.nth(1).locator('.bv-event-row__date').click();
    await expect(cards.nth(1)).toHaveClass(/is-expanded/);
    await expect(cards.nth(0)).not.toHaveClass(/is-expanded/);
  });

  test('Esc collapses the expanded card', async ({ page }) => {
    const { card } = await firstExpandableCard(page);
    await card.locator('.bv-event-row__date').click();
    await expect(card).toHaveClass(/is-expanded/);
    await page.keyboard.press('Escape');
    await expect(card).not.toHaveClass(/is-expanded/);
  });

  test('the event title is plain text, not a link', async ({ page }) => {
    const { card } = await firstExpandableCard(page);
    await expect(card.locator('.bv-event-row__title a')).toHaveCount(0);
  });

  test('clicking the signup button never expands the card (offers login instead)', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    const btn = page.locator('.bv-event-row[data-event-key] [data-rsvp-key]:not([disabled])').first();
    await btn.scrollIntoViewIfNeeded();
    await btn.click();
    await expect(page.locator('.bv-event-row.is-expanded')).toHaveCount(0);
    await expect(page.locator('#bv-login-overlay.is-open')).toHaveCount(1);
  });

  test('the details panel has padding on every edge and its content stays inside', async ({ page }) => {
    // Regression: the panel's padding used var(--space-5), which was never
    // defined — the invalid shorthand collapsed to padding:0 and list bullets
    // hung outside the panel's left edge.
    const { card, key } = await firstExpandableCard(page);
    await card.locator('.bv-event-row__date').click();
    const panel = page.locator(`#bv-ev-details-${key}`);
    await expect(panel).toBeVisible();

    const padding = await panel.evaluate((el) => {
      const s = getComputedStyle(el);
      return [s.paddingTop, s.paddingRight, s.paddingBottom, s.paddingLeft].map(parseFloat);
    });
    for (const edge of padding) { expect(edge).toBeGreaterThan(0); }

    // No child's border box may cross the panel's padding box on either side.
    const overflow = await panel.evaluate((el) => {
      const box = el.getBoundingClientRect();
      const s = getComputedStyle(el);
      const left = box.left + parseFloat(s.borderLeftWidth) + parseFloat(s.paddingLeft);
      const right = box.right - parseFloat(s.borderRightWidth) - parseFloat(s.paddingRight);
      return Array.from(el.querySelectorAll('*'))
        .map((child) => child.getBoundingClientRect())
        .filter((r) => r.width > 0 && (r.left < left - 0.5 || r.right > right + 0.5))
        .length;
    });
    expect(overflow).toBe(0);
  });
});
