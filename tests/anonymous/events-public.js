// @ts-check
'use strict';

/**
 * Frontend event CRUD — anonymous coverage (spec §12 M1 + anonymous
 * negatives from M2). Runs credential-less: the published-events assertions
 * use the committed legacy seed data; the draft/archived no-leak cases use
 * the ev_fixture_* rows and skip-with-reason when the fixtures are absent
 * (they are seeded by global-setup only when TEST_ORGANIZER_PASSWORD is set).
 */

const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');

const EVENTS_YAML = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'begivenheder.yaml');

/**
 * Minimal reader for the flat begivenheder store: top-level keys with a
 * two-space-indented scalar body. Returns [{key, published, archived,
 * featured, title}]. Good enough for counting — the file shape is stable
 * and owned by this repo.
 */
function readEvents() {
  const text = fs.readFileSync(EVENTS_YAML, 'utf8');
  /** @type {{key: string, published: boolean, archived: boolean, featured: boolean, title: string}[]} */
  const events = [];
  let current = null;
  for (const line of text.split('\n')) {
    const keyMatch = line.match(/^([A-Za-z0-9_-]+):\s*$/);
    if (keyMatch) {
      current = { key: keyMatch[1], published: false, archived: false, featured: false, title: '' };
      events.push(current);
      continue;
    }
    if (!current) continue;
    const field = line.match(/^ {2}(published|archived|featured|title):\s*(.*)$/);
    if (field) {
      const [, name, raw] = field;
      if (name === 'title') {
        current.title = raw.replace(/^['"]|['"]$/g, '');
      } else {
        current[name] = raw.trim() === 'true';
      }
    }
  }
  return events;
}

test.describe('Events — public read (M1)', () => {
  test('calendar lists every published, non-archived event (legacy seeds intact)', async ({ page }) => {
    const events = readEvents();
    const visible = events.filter((e) => e.published && !e.archived && !e.featured);
    // Regression guard for the legacy seeds: the repo ships 16 events and
    // all of them must still render. Assert against the file, not a literal.
    expect(visible.length).toBeGreaterThanOrEqual(16);

    await page.goto('/vaerkstedskalenderen');
    const items = page.locator('.bv-event-list .bv-event-item');
    await expect(items).toHaveCount(visible.length);
  });

  test('detail view renders a published event', async ({ page }) => {
    const first = readEvents().find((e) => e.published && !e.archived);
    if (!first) test.skip(true, 'no published event in the data file');
    const response = await page.goto(`/begivenheder/${first.key}`);
    expect(response?.status()).toBe(200);
    await expect(page.locator('.bv-event-row__title')).toContainText(first.title.slice(0, 30));
    await expect(page.locator('.bv-event-detail')).toBeVisible();
  });

  test('unknown event key returns 404', async ({ page }) => {
    const response = await page.goto('/begivenheder/ev_does_not_exist');
    expect(response?.status()).toBe(404);
  });

  test('unpublished event returns 404 for anonymous (no existence leak)', async ({ page }) => {
    const hasFixture = readEvents().some((e) => e.key === 'ev_fixture_draft');
    test.skip(!hasFixture, 'ev_fixture_draft not seeded (TEST_ORGANIZER_PASSWORD unset)');
    const response = await page.goto('/begivenheder/ev_fixture_draft');
    expect(response?.status()).toBe(404);
  });

  test('archived event returns 404 for anonymous and is absent from the calendar', async ({ page }) => {
    const hasFixture = readEvents().some((e) => e.key === 'ev_fixture_archived');
    test.skip(!hasFixture, 'ev_fixture_archived not seeded (TEST_ORGANIZER_PASSWORD unset)');
    const response = await page.goto('/begivenheder/ev_fixture_archived');
    expect(response?.status()).toBe(404);

    await page.goto('/vaerkstedskalenderen');
    await expect(page.locator('body')).not.toContainText('[FIXTURE] Archived event');
  });

  test('/begivenheder redirects to the calendar', async ({ page }) => {
    await page.goto('/begivenheder');
    await expect(page).toHaveURL(/\/vaerkstedskalenderen$/);
  });
});

test.describe('Events — anonymous management gating (M2 negatives)', () => {
  for (const route of ['/begivenheder/mine', '/begivenheder/opret']) {
    test(`anonymous GET ${route} lands on the login flow`, async ({ page }) => {
      await page.goto(route);
      // login plugin redirects (redirect_to_login: true) to /login.
      await expect(page).toHaveURL(/\/login/);
    });
  }

  test('anonymous direct POST to the create action is rejected and writes nothing', async ({ request }) => {
    const before = fs.readFileSync(EVENTS_YAML, 'utf8');
    const response = await request.post('/begivenheder/opret', {
      form: {
        'data[title]': 'Anonymous forced browse',
        'data[group]': 'makerspace',
        'data[event_date]': '2030-01-01',
      },
      maxRedirects: 0,
    });
    // §8.1.3: 401 (or the login plugin's 3xx redirect) — never 2xx.
    expect([301, 302, 303, 401, 403]).toContain(response.status());
    expect(fs.readFileSync(EVENTS_YAML, 'utf8')).toBe(before);
  });

  test('management routes are 404 when the event_management flag is off (test-tier profile)', async ({ browser }) => {
    // The test-tier host profile resolves every flag false; Grav picks the
    // profile from the Host header (same technique as the mobile suite).
    const context = await browser.newContext({
      extraHTTPHeaders: { Host: 'test.hackersbychoice.dk' },
    });
    try {
      const req = context.request;
      for (const route of ['/begivenheder/opret', '/begivenheder/mine', '/begivenheder/event001']) {
        const response = await req.get(route, { maxRedirects: 0 });
        expect(response.status(), `${route} with flag off`).toBe(404);
      }
    } finally {
      await context.close();
    }
  });

  test('footer shows no event-management entry to anonymous visitors', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('.bv-footer')).not.toContainText('Mine begivenheder');
  });
});
