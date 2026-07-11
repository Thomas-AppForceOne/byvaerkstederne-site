// @ts-check
'use strict';

/**
 * Event create — inline card editor (event_create.html.twig). The organizer
 * edits the event directly on the card via popovers; Gem is gated client-side
 * and POSTs the same data[...] fields as before. Drives the editor UI end to
 * end (the API contract itself is covered by events-crud/events-authz).
 * Gates on TEST_ORGANIZER_PASSWORD.
 */

const { test, expect } = require('@playwright/test');
const { loginAsOrganizer, hasOrganizerPassword } = require('../helpers/auth');
const { removeEventByKey } = require('../helpers/fixtures');

test.describe('Event create — inline card editor', () => {
  test.skip(!hasOrganizerPassword, 'TEST_ORGANIZER_PASSWORD required');
  const created = [];
  test.afterAll(() => { for (const k of created) { try { removeEventByKey(k); } catch (_) { /* */ } } });

  test('gates Gem, reflects edits live on the card, and creates the event', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const key = await page.locator('[name="data[key]"]').inputValue();
    const save = page.locator('#ee-save');
    await expect(save).toBeDisabled();

    // date → the date block updates
    await page.locator('[data-ee-open="date"]').click();
    await page.locator('#ee-date-input').fill('2030-08-15');
    await page.locator('#ee-backdrop').click();
    await expect(page.locator('#ee-day')).toHaveText('15');

    // group → accent + badge follow the workshop
    await page.locator('#ee-badge').click();
    await page.locator('.bv-ee-groupopt[data-group="makerspace"]').click();
    await expect(page.locator('#ee-card')).toHaveAttribute('style', /secondary/);
    await expect(page.locator('#ee-badge')).toContainText('Makerspace');

    // title (direct in-card input)
    await page.locator('#ee-title').fill('Inline Editor Test');

    // time — free-typed, normalized
    await page.locator('[data-ee-open="time"]').click();
    await page.locator('#ee-ts-input').fill('10:00');
    await page.locator('#ee-te-input').fill('12:00');
    await page.locator('#ee-te-input').blur();
    await page.locator('#ee-backdrop').click();
    await expect(page.locator('#ee-time-text')).toHaveText('10:00 - 12:00');

    // capacity (default limited → count required)
    await page.locator('[data-ee-open="capacity"]').click();
    await page.locator('#ee-cap-input').fill('8');
    await page.locator('#ee-backdrop').click();
    await expect(page.locator('#ee-cap-text')).toHaveText('8');

    // publish
    await page.locator('[data-published="1"]').click();
    await expect(save).toBeEnabled();

    // submit → PRG to the dashboard, event present and published
    await Promise.all([page.waitForURL(/\/begivenheder\/mine/), save.click()]);
    created.push(key);
    const row = page.locator(`[data-event-key="${key}"]`);
    await expect(row).toContainText('Inline Editor Test');
    await expect(row).toHaveAttribute('data-event-status', 'publiceret');
  });

  test('Drop-in hides the CTA and forces unlimited capacity', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    await page.locator('[data-ee-open="price"]').click();
    await page.locator('.bv-ee-priceopt[data-price="Drop-in"]').click();
    await expect(page.locator('#ee-cta-field')).toBeHidden();
    await expect(page.locator('#ee-cap-unlim')).toHaveValue('1');
  });

  test('Gem stays disabled and names the missing fields until required data is valid', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const save = page.locator('#ee-save');
    await page.locator('#ee-title').fill('Kun en titel');
    await expect(save).toBeDisabled();
    await expect(save).toHaveAttribute('title', /Mangler:/);
    await expect(save).toHaveAttribute('title', /Værksted/);
  });
});
