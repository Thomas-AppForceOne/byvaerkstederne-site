// @ts-check
'use strict';

/**
 * Event RSVP — anonymous coverage (event_rsvp_specification.md §7). Runs
 * credential-less: public availability is visible to everyone, the signup
 * button offers login, and the mutating/serving endpoints reject or 404
 * appropriately. The authenticated signup flows live in
 * tests/authenticated/events-rsvp.js.
 */

const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');

const EVENTS_YAML = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'begivenheder.yaml');
const SIGNUPS_YAML = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'event-signups.yaml');

test.describe('Event RSVP — public availability (anonymous)', () => {
  test('availability line is visible on the calendar to anonymous visitors', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    const availability = page.locator('.bv-event-row__availability');
    // Every published event renders an availability line (public data, §1.3).
    expect(await availability.count()).toBeGreaterThan(0);
    await expect(availability.first()).toBeVisible();
  });

  test('an unlimited event shows only the count, never "pladser tilbage"', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    // ev_demo_makerspace is an unconditionally-seeded, future-dated unlimited
    // demo event (no capacity); its line reads as a running count, never
    // remaining seats. (The committed seeds are all past → auto-archived off
    // the calendar; capacity-limited events legitimately show "pladser tilbage",
    // covered in the authenticated capacity suite.)
    const line = page.locator('[data-rsvp-availability="ev_demo_makerspace"]').first();
    await expect(line).toHaveText(/\d+ tilmeldt/);
    await expect(line).not.toHaveText(/pladser tilbage/);
  });

  test('signup button click opens the login overlay for anonymous visitors', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    const btn = page.locator('.bv-event-row [data-rsvp-key]:not([disabled])').first();
    await btn.scrollIntoViewIfNeeded();
    await btn.click();
    await expect(page.locator('#bv-login-overlay.is-open')).toHaveCount(1);
  });

  test('the public calendar carries no attendee-list markup', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    // The attendee list is dashboard-only (owner/super); it must never render
    // on a public page.
    await expect(page.locator('.bv-event-dashboard__attendees')).toHaveCount(0);
  });
});

test.describe('Event RSVP — anonymous forced browsing', () => {
  test('direct POST to /begivenheder/tilmeld is 401 and writes nothing', async ({ request }) => {
    const before = fs.existsSync(SIGNUPS_YAML) ? fs.readFileSync(SIGNUPS_YAML, 'utf8') : null;
    const response = await request.post('/begivenheder/tilmeld', {
      form: { 'data[key]': 'event001', rsvp_nonce: 'x' },
      headers: { Accept: 'application/json' },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(401);
    const after = fs.existsSync(SIGNUPS_YAML) ? fs.readFileSync(SIGNUPS_YAML, 'utf8') : null;
    expect(after).toBe(before);
  });

  test('direct POST to /begivenheder/upload is 401 (anonymous)', async ({ request }) => {
    const response = await request.post('/begivenheder/upload', {
      multipart: { 'form-nonce': 'x', 'data[key]': 'event001', file: { name: 'x.png', mimeType: 'image/png', buffer: Buffer.from('nope') } },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(401);
  });

  test('every new endpoint is 404 when event_rsvp is off (flags-off profile)', async ({ browser }) => {
    // The dedicated never-deployed all-off profile (env/flags-off.invalid/);
    // Grav picks the profile from the Host header (same technique as
    // events-public.js). Deliberately NOT test.hackersbychoice.dk: that tier
    // is operational preview state whose flags flip freely (its features.yaml
    // documents that no test code may depend on its contents) — depending on
    // it made this assertion fail whenever a feature was being previewed.
    const context = await browser.newContext({
      extraHTTPHeaders: { Host: 'flags-off.invalid' },
    });
    try {
      const req = context.request;
      const tilmeld = await req.post('/begivenheder/tilmeld', { form: { 'data[key]': 'event001' }, maxRedirects: 0 });
      expect(tilmeld.status(), 'tilmeld flag-off').toBe(404);
      const upload = await req.post('/begivenheder/upload', { form: { 'data[key]': 'event001' }, maxRedirects: 0 });
      expect(upload.status(), 'upload flag-off').toBe(404);
      const billede = await req.get('/begivenheder/billede/event001/' + 'a'.repeat(32), { maxRedirects: 0 });
      expect(billede.status(), 'billede flag-off').toBe(404);
    } finally {
      await context.close();
    }
  });
});
