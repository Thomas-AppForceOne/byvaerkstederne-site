// @ts-check
'use strict';

/**
 * Event rich details + image upload (event_rsvp_specification.md §5/§7).
 * Server-side sanitisation is asserted against the STORED YAML (like
 * events-crud does), the allowlist survives a save->edit->save round-trip, and
 * the upload endpoint rejects the negatives and renders a real uploaded image
 * on the detail page. Gates on the organizer + user credentials.
 */

const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const {
  login,
  loginAsOrganizer,
  hasUserPassword,
  hasOrganizerPassword,
} = require('../helpers/auth');
const { removeEventByKey } = require('../helpers/fixtures');

const EVENTS_YAML = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'begivenheder.yaml');
const haveCreds = hasUserPassword && hasOrganizerPassword;

// A real 1x1 PNG.
const PNG_1x1 = Buffer.from(
  '89504e470d0a1a0a0000000d494844520000000100000001080600000' +
  '01f15c4890000000a49444154789c6300010000050001' +
  '0d0a2db40000000049454e44ae426082',
  'hex',
);

/**
 * The event form (create or edit) — scoped by its unique data[key] field so
 * the form-nonce lookup never collides with the globally-included registration
 * overlay's own form-nonce.
 */
function eventForm(page) {
  return page.locator('form').filter({ has: page.locator('[name="data[key]"]') });
}

/** Log in as organizer, read a fresh create form, and POST a new event. */
async function createEvent(page, fields) {
  await loginAsOrganizer(page);
  await page.goto('/begivenheder/opret');
  const formNonce = await eventForm(page).locator('[name="form-nonce"]').inputValue();
  const key = await page.locator('[name="data[key]"]').inputValue();
  const form = {
    'form-nonce': formNonce,
    'data[key]': key,
    'data[title]': 'Detaljer Test',
    'data[group]': 'makerspace',
    'data[event_date]': '2030-06-01',
    'data[time_start]': '10:00',
    'data[time_end]': '11:00',
    'data[button_text]': 'Tilmeld',
    'data[capacity_unlimited]': '1',
    ...fields,
  };
  const res = await page.request.post('/begivenheder/opret', { form, maxRedirects: 0 });
  expect(res.status(), 'create should PRG-redirect').toBe(303);
  return key;
}

function storedYaml() {
  return fs.readFileSync(EVENTS_YAML, 'utf8');
}

test.describe('Event details — sanitize on write', () => {
  test.skip(!haveCreds, 'TEST_PASSWORD + TEST_ORGANIZER_PASSWORD required');
  const created = [];
  test.afterAll(() => { for (const k of created) { try { removeEventByKey(k); } catch (_) { /* */ } } });

  test('script / iframe / js-href are stripped; allowlisted formatting survives', async ({ page }) => {
    const key = await createEvent(page, {
      'data[details]': '<h2>Program</h2><p>Kom og vær <strong>med</strong>!</p>'
        + '<script>alert(1)</script><a href="javascript:evil()">x</a>'
        + '<iframe src="https://evil.example"></iframe>',
    });
    created.push(key);
    const yaml = storedYaml();
    // Assert against the block for THIS event key.
    const block = yaml.slice(yaml.indexOf(`${key}:`));
    expect(block).toContain('<h2>Program</h2>');
    expect(block).toContain('<strong>med</strong>');
    expect(block).not.toContain('<script');
    expect(block).not.toContain('javascript:');
    expect(block).not.toContain('<iframe');
  });

  test('allowlisted formatting survives a save -> edit -> save round-trip', async ({ page }) => {
    const key = await createEvent(page, {
      'data[details]': '<h2>Overskrift</h2><ul><li>Et</li><li>To</li></ul>',
    });
    created.push(key);

    // Re-open the edit form: its details field is prefilled with the stored,
    // sanitized value; re-save unchanged.
    await page.goto(`/begivenheder/rediger/${key}`);
    const formNonce = await eventForm(page).locator('[name="form-nonce"]').inputValue();
    const details = await page.locator('[name="data[details]"]').inputValue();
    expect(details).toContain('<h2>Overskrift</h2>');
    expect(details).toContain('<li>Et</li>');
    const res = await page.request.post('/begivenheder/rediger', {
      form: {
        'form-nonce': formNonce,
        'data[key]': key,
        'data[title]': 'Detaljer Test',
        'data[group]': 'makerspace',
        'data[event_date]': '2030-06-01',
        'data[time_start]': '10:00',
        'data[time_end]': '11:00',
        'data[button_text]': 'Tilmeld',
        'data[capacity_unlimited]': '1',
        'data[details]': details,
      },
      maxRedirects: 0,
    });
    expect(res.status()).toBe(303);
    const block = storedYaml().slice(storedYaml().indexOf(`${key}:`));
    expect(block).toContain('<h2>Overskrift</h2>');
    expect(block).toContain('<li>Et</li>');
  });
});

test.describe('Event details — image upload', () => {
  test.skip(!haveCreds, 'TEST_PASSWORD + TEST_ORGANIZER_PASSWORD required');
  const created = [];
  test.afterAll(() => { for (const k of created) { try { removeEventByKey(k); } catch (_) { /* */ } } });

  test('non-image with an image extension is rejected (magic bytes)', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const formNonce = await eventForm(page).locator('[name="form-nonce"]').inputValue();
    const key = await page.locator('[name="data[key]"]').inputValue();
    const res = await page.request.post('/begivenheder/upload', {
      multipart: {
        'form-nonce': formNonce,
        'data[key]': key,
        file: { name: 'evil.png', mimeType: 'image/png', buffer: Buffer.from('#!/bin/sh not an image') },
      },
    });
    expect(res.status()).toBe(400);
  });

  test('a plain member (no events capability) cannot upload', async ({ page }) => {
    await login(page); // pw-test-user — authenticated, no admin.events.*
    const res = await page.request.post('/begivenheder/upload', {
      multipart: {
        'form-nonce': 'x',
        'data[key]': 'event001',
        file: { name: 'x.png', mimeType: 'image/png', buffer: PNG_1x1 },
      },
    });
    // Rejected before any file is stored — CSRF or capability, both 4xx.
    expect([401, 403]).toContain(res.status());
  });

  test('a valid upload is stored and renders in the inline card expansion', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/opret');
    const formNonce = await eventForm(page).locator('[name="form-nonce"]').inputValue();
    const key = await page.locator('[name="data[key]"]').inputValue();

    // Upload against the pre-generated create key.
    const up = await page.request.post('/begivenheder/upload', {
      multipart: {
        'form-nonce': formNonce,
        'data[key]': key,
        file: { name: 'pic.png', mimeType: 'image/png', buffer: PNG_1x1 },
      },
    });
    expect(up.status()).toBe(200);
    const location = (await up.json()).location;
    expect(location).toMatch(new RegExp(`^/begivenheder/billede/${key}/[0-9a-f]{32}$`));

    // The served image is a real PNG with the hardening headers.
    const img = await page.request.get(location);
    expect(img.status()).toBe(200);
    expect(img.headers()['content-type']).toBe('image/png');
    expect(img.headers()['x-content-type-options']).toBe('nosniff');

    // Create the event with details embedding that image, then load the detail
    // page and confirm it renders (the src survived sanitisation).
    const create = await page.request.post('/begivenheder/opret', {
      form: {
        'form-nonce': formNonce,
        'data[key]': key,
        'data[title]': 'Billede Test',
        'data[group]': 'makerspace',
        'data[event_date]': '2030-06-02',
        'data[time_start]': '10:00',
        'data[time_end]': '11:00',
        'data[button_text]': 'Tilmeld',
        'data[capacity_unlimited]': '1',
        'data[details]': `<p>Foto:</p><img src="${location}" alt="Foto">`,
      },
      maxRedirects: 0,
    });
    expect(create.status()).toBe(303);
    created.push(key);

    // The image renders in the inline card expansion on the calendar (the
    // standalone detail page is retired). Expand the event's card and assert it.
    await page.goto('/vaerkstedskalenderen');
    await page.locator(`.bv-event-row[data-event-key="${key}"] .bv-event-row__date`).click();
    await expect(page.locator(`#bv-ev-details-${key} img[src="${location}"]`)).toHaveCount(1);
  });
});
