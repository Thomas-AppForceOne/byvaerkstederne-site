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
    const field = line.match(/^ {2}(published|archived|featured|title|group|event_date|event_time):\s*(.*)$/);
    if (field) {
      const [, name, raw] = field;
      if (name === 'published' || name === 'archived' || name === 'featured') {
        current[name] = raw.trim() === 'true';
      } else {
        current[name] = raw.replace(/^['"]|['"]$/g, '');
      }
    }
  }
  return events;
}

/**
 * Mirrors the plugin's auto-archive cutoff: an event that ran more than a day
 * ago (event_date strictly before today − 1 day) is stale and never renders on
 * the calendar. Unparseable dates are never stale (same as the plugin). The
 * seed/fixture dates sit years either side of today, so the exact timezone of
 * the boundary is immaterial here.
 */
function notStale(e) {
  const d = String(e.event_date || '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(d)) return true;
  const c = new Date();
  c.setDate(c.getDate() - 1);
  const p = (n) => String(n).padStart(2, '0');
  const cutoff = `${c.getFullYear()}-${p(c.getMonth() + 1)}-${p(c.getDate())}`;
  return d >= cutoff;
}

test.describe('Events — public read (M1)', () => {
  test('calendar lists every published, non-archived, non-stale event', async ({ page }) => {
    const events = readEvents();
    // Featured events are part of the list too (they only get a styling
    // boost) — the exclusions are unpublished, archived, and stale (ran more
    // than a day ago; the auto-archive rule keeps the upcoming-activities
    // calendar forward-looking). Assert against the file, not a literal.
    const visible = events.filter((e) => e.published && !e.archived && notStale(e));

    await page.goto('/vaerkstedskalenderen');
    const items = page.locator('.bv-event-list .bv-event-item');
    await expect(items).toHaveCount(visible.length);
  });

  test('calendar is sorted chronologically, ties by workshop order', async ({ page }) => {
    // Mirrors the plugin's event_sort_key: date, start time (extracted from
    // the messy legacy strings), workshop rank (makerspace, krea, grønt,
    // eventværkstedet, then fælles), insertion order as final tiebreak.
    const RANK = { makerspace: 1, kreativ: 2, krea: 2, groenne: 3, groent: 3, kulturhus: 4, alle: 5 };
    const startOf = (time) => {
      const m = String(time || '').match(/(\d{1,2})(?:[:.](\d{2}))?/);
      return m ? `${m[1].padStart(2, '0')}:${m[2] || '00'}` : '99:99';
    };
    const expected = readEvents()
      .filter((e) => e.published && !e.archived && notStale(e))
      .map((e, i) => ({ ...e, sortKey: `${e.event_date}|${startOf(e.event_time)}|${RANK[e.group] || 6}|${String(i).padStart(3, '0')}` }))
      .sort((a, b) => (a.sortKey < b.sortKey ? -1 : 1))
      .map((e) => e.title);

    await page.goto('/vaerkstedskalenderen');
    const rendered = await page.locator('.bv-event-list .bv-event-row__title').allTextContents();
    expect(rendered.map((t) => t.trim())).toEqual(expected);
  });

  test('the detail route redirects to the calendar for every key (page retired, no existence leak)', async ({ page }) => {
    // The standalone detail page is retired — details are shown inline on the
    // calendar. Every /begivenheder/<key> redirects to the calendar, whether
    // the key is published, unknown, or a draft/archived fixture, so no event's
    // existence leaks via a distinct 404.
    const events = readEvents();
    const keys = ['ev_does_not_exist'];
    const first = events.find((e) => e.published && !e.archived);
    if (first) keys.push(first.key);
    if (events.some((e) => e.key === 'ev_fixture_draft')) keys.push('ev_fixture_draft');
    if (events.some((e) => e.key === 'ev_fixture_archived')) keys.push('ev_fixture_archived');
    for (const key of keys) {
      await page.goto(`/begivenheder/${key}`);
      await expect(page, `${key} should land on the calendar`).toHaveURL(/\/vaerkstedskalenderen$/);
      await expect(page.locator('.bv-event-detail')).toHaveCount(0);
    }
  });

  test('an archived event is absent from the calendar', async ({ page }) => {
    test.skip(!readEvents().some((e) => e.key === 'ev_fixture_archived'), 'ev_fixture_archived not seeded');
    await page.goto('/vaerkstedskalenderen');
    await expect(page.locator('body')).not.toContainText('[FIXTURE] Archived event');
  });

  test('/begivenheder redirects to the calendar', async ({ page }) => {
    await page.goto('/begivenheder');
    await expect(page).toHaveURL(/\/vaerkstedskalenderen$/);
  });

  // Locate the calendar card whose title matches — the arrangør line lives
  // inside that card's body, so the assertions are scoped to one event.
  const cardFor = (page, title) => page.locator('.bv-event-list .bv-event-item', {
    has: page.locator('.bv-event-row__title', { hasText: title }),
  });

  test('an event with an owner shows the arrangør (owner username) on its card', async ({ page }) => {
    test.skip(!readEvents().some((e) => e.key === 'ev_fixture_rsvp'),
      'ev_fixture_rsvp not seeded (TEST_ORGANIZER_PASSWORD absent)');
    await page.goto('/vaerkstedskalenderen');
    const card = cardFor(page, '[FIXTURE] RSVP Tilmeld');
    await expect(card).toHaveCount(1);
    // The public arrangør line shows the owner USERNAME (a pseudonymous
    // handle), never the account's real name — no member PII on a public page.
    const organizer = card.locator('.bv-event-row__organizer');
    await expect(organizer).toContainText('Arrangør: pw-test-org');
    await expect(organizer).not.toContainText('Playwright Test Organizer');
  });

  test('an event without an owner shows no arrangør line', async ({ page }) => {
    // The public demo events (ensurePublicDemoEvents) are seeded unconditionally
    // and carry no owner, so their cards must omit the organizer line entirely.
    await page.goto('/vaerkstedskalenderen');
    const demo = cardFor(page, '[DEMO] Åbent makerspace');
    await expect(demo).toHaveCount(1);
    await expect(demo.locator('.bv-event-row__organizer')).toHaveCount(0);
  });
});

test.describe('Events — anonymous management gating (M2 negatives)', () => {
  for (const route of ['/begivenheder/arrangoerpanel', '/begivenheder/opret']) {
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

  test('management routes refuse anonymous access under an all-flags-off profile', async ({ browser }) => {
    // These routes used to 404 here because event_management was off in this
    // profile. That flag graduated to every tier and was retired, so the
    // 404 is gone — what must survive is the boundary that was always the
    // real one: login, then capability. A profile with every flag off must
    // not turn management surfaces into public pages.
    //
    // Grav picks the profile from the Host header (same technique as the
    // mobile suite).
    const context = await browser.newContext({
      extraHTTPHeaders: { Host: 'flags-off.invalid' },
    });
    try {
      const req = context.request;
      for (const route of ['/begivenheder/opret', '/begivenheder/arrangoerpanel']) {
        const response = await req.get(route, { maxRedirects: 0 });
        expect([301, 302, 303, 401, 403], `${route} anonymous, flags off`)
          .toContain(response.status());
      }
      // A keyed detail URL redirects to the calendar uniformly — published,
      // unpublished and unknown keys alike, so no event's existence leaks.
      const detail = await req.get('/begivenheder/event001', { maxRedirects: 0 });
      expect([301, 302, 303]).toContain(detail.status());
    } finally {
      await context.close();
    }
  });

  test('footer shows no event-management entry to anonymous visitors', async ({ page }) => {
    await page.goto('/');
    await expect(page.locator('.bv-footer')).not.toContainText('Arrangørpanel');
  });

  test('calendar shows no arrangør buttons (create / Arrangørpanel) to anonymous visitors', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    await expect(page.locator('[data-testid="calendar-create-link"]')).toHaveCount(0);
    await expect(page.locator('[data-testid="calendar-mine-link"]')).toHaveCount(0);
  });

  test('the "Mine aktiviteter" filter is hidden from anonymous visitors; "Alle" stays default', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    // Anonymous visitors have no signups, so the personal filter is not shown.
    await expect(page.locator('.bv-filter-btn[data-filter="mine"]')).toHaveCount(0);
    // "Alle aktiviteter" remains the default active filter.
    await expect(page.locator('.bv-filter-btn[data-filter="all"]')).toHaveClass(/is-active/);
  });

  test('all calendar filters sit on one line on desktop', async ({ page }) => {
    await page.goto('/vaerkstedskalenderen');
    const btns = page.locator('.bv-filter-btn');
    expect(await btns.count()).toBeGreaterThan(1);
    const tops = await btns.evaluateAll((els) => els.map((e) => Math.round(e.getBoundingClientRect().top)));
    // A single shared top offset → one row (mobile stacks them, tested in tests/mobile).
    expect(new Set(tops).size).toBe(1);
  });
});
