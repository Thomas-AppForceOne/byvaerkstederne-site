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
const { removeEventByKey, ensureRsvpEvent, RSVP_EVENT_ID } = require('../helpers/fixtures');

test.describe('Event create — inline card editor', () => {
  test.skip(!hasOrganizerPassword, 'TEST_ORGANIZER_PASSWORD required');
  const created = [];
  test.afterAll(() => { for (const k of created) { try { removeEventByKey(k); } catch (_) { /* */ } } });

  test('Gem is always available; Offentlig gates on the full set, then creates a public event', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const key = await page.locator('[name="data[key]"]').inputValue();
    const save = page.locator('#ee-save');
    const publish = page.locator('[data-published="1"]');
    // Gem is available from the very start — an empty in-progress event is a
    // saveable draft. Offentlig is gated until every required field is filled.
    await expect(save).toBeEnabled();
    await expect(publish).toBeDisabled();

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

    // description — now a publish requirement
    await page.locator('#ee-desc').fill('En kort beskrivelse af begivenheden.');

    // capacity (default limited → count required)
    await page.locator('[data-ee-open="capacity"]').click();
    await page.locator('#ee-cap-input').fill('8');
    await page.locator('#ee-backdrop').click();
    await expect(page.locator('#ee-cap-text')).toHaveText('8');

    // event type is the last required field — Offentlig stays gated until it is set
    await expect(publish).toBeDisabled();
    await page.locator('[data-ee-open="event-type"]').click();
    await page.locator('.bv-ee-typeopt[data-event-type="Gratis"]').click();

    // set complete → Offentlig unlocks; select it (Gem stays available throughout)
    await expect(publish).toBeEnabled();
    await publish.click();
    await expect(save).toBeEnabled();

    // submit → PRG to the dashboard, event present and published
    await Promise.all([page.waitForURL(/\/begivenheder\/mine/), save.click()]);
    created.push(key);
    const row = page.locator(`[data-event-key="${key}"]`);
    await expect(row).toContainText('Inline Editor Test');
    await expect(row).toHaveAttribute('data-event-status', 'publiceret');
  });

  test('opret previews the organizer (current user username) as arrangør', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    // The creator IS the arrangør — owner is stamped to them on save, so the
    // editor card previews their username (read-only; no popover on the line).
    // The username, not the real name, keeps the (also public) card PII-free.
    const organizer = page.locator('#ee-card .bv-event-row__organizer');
    await expect(organizer).toBeVisible();
    await expect(organizer).toContainText('Arrangør: pw-test-org');
    await expect(organizer).not.toContainText('Playwright Test Organizer');
    // It is a preview, not an input — no data[owner] is ever posted.
    await expect(page.locator('[name="data[owner]"]')).toHaveCount(0);
  });

  test('rediger previews the stored owner (username) as arrangør', async ({ page }) => {
    ensureRsvpEvent(); // owned by pw-test-org
    await loginAsOrganizer(page);
    await page.goto(`/begivenheder/rediger/${RSVP_EVENT_ID}`);
    const organizer = page.locator('#ee-card .bv-event-row__organizer');
    await expect(organizer).toBeVisible();
    await expect(organizer).toContainText('Arrangør: pw-test-org');
  });

  test('the CTA is locked and follows the event type (Drop-in ⇒ Interesseret, else ⇒ Tilmeld)', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const cta = page.locator('#ee-cta-val');

    // Default (no type chosen yet): a Tilmeld event → shows "Deltag" (the
    // visitor label), locked. The stored button_text stays "Tilmeld".
    await expect(cta).toBeVisible();
    await expect(cta).toHaveText('Deltag');
    await expect(cta).toBeDisabled();
    await expect(page.locator('#ee-button-text')).toHaveValue('Tilmeld');

    // Drop-in ⇒ Interesseret (locked) + unlimited capacity.
    await page.locator('[data-ee-open="event-type"]').click();
    await page.locator('.bv-ee-typeopt[data-event-type="Drop-in"]').click();
    await expect(cta).toHaveText('Interesseret');
    await expect(cta).toBeDisabled();
    await expect(page.locator('#ee-button-text')).toHaveValue('Interesseret');
    await expect(page.locator('#ee-cap-unlim')).toHaveValue('1');

    // Back to a non-Drop-in type ⇒ "Deltag" again (stored "Tilmeld").
    await page.locator('[data-ee-open="event-type"]').click();
    await page.locator('.bv-ee-typeopt[data-event-type="Gratis"]').click();
    await expect(cta).toHaveText('Deltag');
    await expect(cta).toBeDisabled();
    await expect(page.locator('#ee-button-text')).toHaveValue('Tilmeld');
  });

  test('Drop-in locks capacity to unlimited; another type lifts the lock', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const nej = page.locator('[data-unlim="0"]');

    // Default type: capacity is a free choice — the "Nej" (limited) option is
    // selectable.
    await expect(nej).toBeEnabled();

    // Drop-in ⇒ forced unlimited, and the "Nej" option is locked out so a cap
    // can't be turned on.
    await page.locator('[data-ee-open="event-type"]').click();
    await page.locator('.bv-ee-typeopt[data-event-type="Drop-in"]').click();
    await expect(page.locator('#ee-cap-unlim')).toHaveValue('1');
    await expect(page.locator('#ee-cap-text')).toHaveText('Ubegrænset');
    await expect(nej).toBeDisabled();

    // Selecting any other type lifts the lock — "Nej" is selectable again.
    await page.locator('[data-ee-open="event-type"]').click();
    await page.locator('.bv-ee-typeopt[data-event-type="Brugerbetaling"]').click();
    await expect(nej).toBeEnabled();
  });

  test('Offentlig stays disabled and names the missing fields; Gem is unaffected', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const save = page.locator('#ee-save');
    const publish = page.locator('[data-published="1"]');
    await page.locator('#ee-title').fill('Kun en titel');
    // A draft with just a title still saves.
    await expect(save).toBeEnabled();
    // Offentlig is disabled and its tooltip names what is still missing.
    await expect(publish).toBeDisabled();
    await expect(publish).toHaveAttribute('title', /Udfyld for at kunne udgive/);
    await expect(publish).toHaveAttribute('title', /Værkstedsbanner/);
    await expect(publish).toHaveAttribute('title', /Beskrivelse/);
    await expect(publish).toHaveAttribute('title', /Begivenhedstype/);
  });

  test('Offentlig enables only once the last field (begivenhedstype) is chosen', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const publish = page.locator('[data-published="1"]');

    // Fill everything required for publishing EXCEPT the type.
    await page.locator('#ee-title').fill('Type-krav test');
    await page.locator('#ee-badge').click();
    await page.locator('.bv-ee-groupopt[data-group="makerspace"]').click();
    await page.locator('[data-ee-open="date"]').click();
    await page.locator('#ee-date-input').fill('2030-08-15');
    await page.locator('#ee-backdrop').click();
    await page.locator('[data-ee-open="time"]').click();
    await page.locator('#ee-ts-input').fill('10:00');
    await page.locator('#ee-te-input').fill('12:00');
    await page.locator('#ee-te-input').blur();
    await page.locator('#ee-backdrop').click();
    await page.locator('#ee-desc').fill('Beskrivelse til udgivelse.');
    await page.locator('[data-ee-open="capacity"]').click();
    await page.locator('#ee-cap-input').fill('8');
    await page.locator('#ee-backdrop').click();

    // Still blocked purely on the missing type.
    await expect(publish).toBeDisabled();
    await expect(publish).toHaveAttribute('title', /Begivenhedstype/);

    // Choosing a type is the last thing needed → Offentlig enables.
    await page.locator('[data-ee-open="event-type"]').click();
    await page.locator('.bv-ee-typeopt[data-event-type="Drop-in"]').click();
    await expect(publish).toBeEnabled();
  });
});
