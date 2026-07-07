// @ts-check
'use strict';

/**
 * Frontend event CRUD — forced-browsing / authorization negatives
 * (spec §12 M2–M4 negatives + cross-cutting suite).
 *
 * Every mutating endpoint must enforce authn + capability + CSRF +
 * per-object ownership server-side, regardless of UI gating. Asserts the
 * §8.1 contract's exact status codes and that denied requests leave the
 * data store byte-identical.
 *
 * Fixtures (global-setup): ev_fixture_foreign (owner that matches no test
 * account) and ev_fixture_draft/ev_fixture_archived (owner
 * pw-test-org).
 */

const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const { login, loginAsOrganizer, hasUserPassword, hasOrganizerPassword } = require('../helpers/auth');

const EVENTS_YAML = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'begivenheder.yaml');
const AUDIT_LOG = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'events-audit.jsonl');

function readEventsFile() {
  return fs.readFileSync(EVENTS_YAML, 'utf8');
}

/** @param {import('@playwright/test').Page} page */
async function organizerNonce(page) {
  await page.goto('/begivenheder/opret');
  return page.locator('input[name="form-nonce"]').first().inputValue();
}

test.describe('Events — member without the organizer role', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set');

  test('GET dashboard and create form are 403', async ({ page }) => {
    await login(page); // pw-test-user: site.login only, no admin.events.*
    for (const route of ['/begivenheder/mine', '/begivenheder/opret']) {
      const response = await page.goto(route);
      expect(response?.status(), route).toBe(403);
    }
  });

  test('direct POST to every mutating endpoint is 403 and writes nothing', async ({ page }) => {
    await login(page);
    const before = readEventsFile();
    for (const route of ['/begivenheder/opret', '/begivenheder/rediger', '/begivenheder/slet']) {
      const response = await page.request.post(route, {
        form: {
          'data[key]': 'ev_fixture_draft',
          'data[title]': 'Member forced browse',
          'data[group]': 'makerspace',
          'data[event_date]': '2030-01-01',
          'form-nonce': 'not-a-nonce',
        },
        maxRedirects: 0,
      });
      expect(response.status(), route).toBe(403);
    }
    expect(readEventsFile()).toBe(before);
  });

  test('member footer has no event-management entry', async ({ page }) => {
    await login(page);
    await page.goto('/');
    await expect(page.locator('.bv-footer')).not.toContainText('Mine begivenheder');
  });

  test('member sees no create button on the calendar page', async ({ page }) => {
    await login(page);
    await page.goto('/vaerkstedskalenderen');
    await expect(page.locator('[data-testid="calendar-create-link"]')).toHaveCount(0);
  });

  test('member cannot read another owner\'s draft (404, no existence leak)', async ({ page }) => {
    await login(page);
    const response = await page.goto('/begivenheder/ev_fixture_draft');
    expect(response?.status()).toBe(404);
  });
});

test.describe('Events — organizer forced browsing (per-object authz)', () => {
  test.skip(!hasOrganizerPassword, 'TEST_ORGANIZER_PASSWORD not set');

  test('missing/invalid CSRF nonce is 403 even with full permissions', async ({ page }) => {
    await loginAsOrganizer(page);
    const before = readEventsFile();
    const response = await page.request.post('/begivenheder/opret', {
      form: {
        'data[title]': 'CSRF bypass attempt',
        'data[group]': 'makerspace',
        'data[event_date]': '2030-01-01',
        'form-nonce': 'deadbeef',
      },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(403);
    expect(readEventsFile()).toBe(before);
  });

  test('browser-form validation failure redirects back to the form with a flash (no raw JSON)', async ({ page }) => {
    await loginAsOrganizer(page);
    const nonce = await organizerNonce(page);
    const response = await page.request.post('/begivenheder/opret', {
      headers: { Accept: 'text/html' }, // what a real browser form POST sends
      form: {
        'data[title]': 'Ugyldig dato rundtur',
        'data[group]': 'makerspace',
        'data[event_date]': '2030-13-99',
        'form-nonce': nonce,
      },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(303);
    expect(response.headers()['location']).toContain('/begivenheder/opret');
    // The form shows the Danish field error as a flash and repopulates the
    // submitted title (one-shot stash).
    await page.goto('/begivenheder/opret');
    await expect(page.locator('.bv-message--error', { hasText: 'Datoen skal have formatet' })).toBeVisible();
    await expect(page.locator('input[name="data[title]"]')).toHaveValue('Ugyldig dato rundtur');
    // The stash is read-once: a fresh load renders a clean form.
    await page.goto('/begivenheder/opret');
    await expect(page.locator('input[name="data[title]"]')).toHaveValue('');
  });

  test('invalid input is 400 with field-level Danish errors and no object written', async ({ page }) => {
    await loginAsOrganizer(page);
    const nonce = await organizerNonce(page);
    const before = readEventsFile();
    const response = await page.request.post('/begivenheder/opret', {
      form: {
        'data[title]': '<script>alert(1)</script>',
        'data[group]': 'not-a-group',
        'data[event_date]': '2030-13-99',
        'data[time_start]': '12:00',
        'data[time_end]': '10:00', // ends before it starts
        'data[capacity_unlimited]': '0',
        'data[capacity_count]': 'mange', // must be a number
        'data[price]': '1000 kr. kontant', // price is a closed choice
        'data[button_text]': 'Køb nu', // only Tilmeld/Interesseret
        'form-nonce': nonce,
      },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(400);
    const body = await response.json();
    expect(Object.keys(body.errors)).toEqual(
      expect.arrayContaining(['title', 'group', 'event_date', 'time_end', 'capacity_count', 'price', 'button_text'])
    );
    expect(readEventsFile()).toBe(before);
  });

  test('update/delete against another owner\'s event is 403 and the object is untouched', async ({ page }) => {
    await loginAsOrganizer(page);
    const nonce = await organizerNonce(page);
    const before = readEventsFile();

    for (const route of ['/begivenheder/rediger', '/begivenheder/slet']) {
      const response = await page.request.post(route, {
        form: {
          'data[key]': 'ev_fixture_foreign',
          'data[title]': 'Hijacked title',
          'data[group]': 'makerspace',
          'data[event_date]': '2030-01-01',
          'form-nonce': nonce,
        },
        maxRedirects: 0,
      });
      expect(response.status(), route).toBe(403);
    }
    expect(readEventsFile()).toBe(before);

    // The edit form for the foreign event is not served either.
    const formResponse = await page.goto('/begivenheder/rediger/ev_fixture_foreign');
    expect(formResponse?.status()).toBe(403);
  });

  test('legacy event with no owner is super-only: organizer update is 403', async ({ page }) => {
    await loginAsOrganizer(page);
    const nonce = await organizerNonce(page);
    const before = readEventsFile();
    const response = await page.request.post('/begivenheder/rediger', {
      form: {
        'data[key]': 'event001',
        'data[title]': 'Legacy hijack',
        'data[group]': 'makerspace',
        'data[event_date]': '2030-01-01',
        'form-nonce': nonce,
      },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(403);
    expect(readEventsFile()).toBe(before);
  });

  test('client-submitted owner is ignored on update (owner preserved from storage)', async ({ page }) => {
    await loginAsOrganizer(page);
    const nonce = await organizerNonce(page);
    const response = await page.request.post('/begivenheder/rediger', {
      form: {
        'data[key]': 'ev_fixture_draft',
        'data[title]': '[FIXTURE] Draft event for Playwright tests',
        'data[group]': 'makerspace',
        'data[event_date]': '2030-01-15',
        'data[time_start]': '10:00',
        'data[time_end]': '12:00',
        'data[published]': '0',
        'data[owner]': 'attacker',
        'data[created_by]': 'attacker',
        'form-nonce': nonce,
      },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(303);
    const block = readEventsFile().match(/^ev_fixture_draft:\n((?:[ ].*\n?)*)/m)?.[1] || '';
    expect(block).toContain('owner: pw-test-org');
    expect(block).toContain('created_by: pw-test-org');
    expect(block).not.toContain('attacker');
  });

  test('unknown key is 404 on update and delete', async ({ page }) => {
    await loginAsOrganizer(page);
    const nonce = await organizerNonce(page);
    for (const route of ['/begivenheder/rediger', '/begivenheder/slet']) {
      const response = await page.request.post(route, {
        form: {
          'data[key]': 'ev_0000000000000000',
          'data[title]': 'X',
          'data[group]': 'makerspace',
          'data[event_date]': '2030-01-01',
          'form-nonce': nonce,
        },
        maxRedirects: 0,
      });
      expect(response.status(), route).toBe(404);
    }
  });

  test('organizer cannot escalate to hard delete (mode=hard without admin.super is 403)', async ({ page }) => {
    await loginAsOrganizer(page);
    const nonce = await organizerNonce(page);
    const response = await page.request.post('/begivenheder/slet', {
      form: { 'data[key]': 'ev_fixture_draft', 'data[mode]': 'hard', 'form-nonce': nonce },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(403);
    expect(readEventsFile()).toContain('ev_fixture_draft:');
  });

  test('audit log is append-only across mutations', async ({ page }) => {
    await loginAsOrganizer(page);
    const nonce = await organizerNonce(page);

    const mutate = (published) => page.request.post('/begivenheder/rediger', {
      form: {
        'data[key]': 'ev_fixture_draft',
        'data[title]': '[FIXTURE] Draft event for Playwright tests',
        'data[group]': 'makerspace',
        'data[event_date]': '2030-01-15',
        'data[time_start]': '10:00',
        'data[time_end]': '12:00',
        'data[published]': published,
        'form-nonce': nonce,
      },
      maxRedirects: 0,
    });

    expect((await mutate('0')).status()).toBe(303);
    const afterFirst = fs.readFileSync(AUDIT_LOG, 'utf8');
    expect((await mutate('0')).status()).toBe(303);
    const afterSecond = fs.readFileSync(AUDIT_LOG, 'utf8');

    // Second mutation adds a line without altering any prior line.
    expect(afterSecond.startsWith(afterFirst)).toBe(true);
    expect(afterSecond.length).toBeGreaterThan(afterFirst.length);
    // Every line is a well-formed JSON record with the required fields.
    for (const line of afterSecond.trim().split('\n')) {
      const record = JSON.parse(line);
      expect(record).toEqual(expect.objectContaining({
        ts: expect.any(String),
        actor: expect.any(String),
        action: expect.any(String),
        key: expect.any(String),
      }));
    }
  });

  test('organizers group does not confer admin-panel access', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/admin');
    // The admin plugin must not accept the site session of an
    // admin.events.*-only account: it serves its own login form — never the
    // dashboard (admin access needs admin.login, which organizers lack).
    await expect(page.locator('input[name="data[username]"]')).toBeVisible({ timeout: 10_000 });
    await expect(page.locator('body')).not.toContainText('Dashboard');
  });
});
