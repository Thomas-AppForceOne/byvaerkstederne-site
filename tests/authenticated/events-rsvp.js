// @ts-check
'use strict';

/**
 * Event RSVP — authenticated coverage (event_rsvp_specification.md §7).
 * Exercises signup/withdraw from the card button, the Interesseret path,
 * capacity enforcement (race + full line), the forced-browsing negatives that
 * only surface after auth+CSRF (unknown key, past, unpublished, archived), and
 * the owner-only attendee list. Gates on TEST_PASSWORD + TEST_ORGANIZER_PASSWORD
 * and on the RSVP fixtures being seeded; skips-with-reason otherwise.
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
const {
  RSVP_EVENT_ID,
  CAPACITY_EVENT_ID,
  INTEREST_EVENT_ID,
  clearEventSignups,
  eventAuditContains,
} = require('../helpers/fixtures');

const EVENTS_YAML = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'begivenheder.yaml');
const haveCreds = hasUserPassword && hasOrganizerPassword;
const fixturesSeeded = () => {
  try { return fs.readFileSync(EVENTS_YAML, 'utf8').includes(`${RSVP_EVENT_ID}:`); } catch { return false; }
};

/** Read the rotating RSVP nonce off a page that renders it (authenticated). */
async function readRsvpNonce(page, eventKey) {
  await page.goto(`/begivenheder/${eventKey}`);
  return page.locator('#bv-em-rsvp-nonce [name="rsvp_nonce"]').inputValue();
}

test.describe('Event RSVP — signup from the card button', () => {
  test.skip(!haveCreds, 'TEST_PASSWORD + TEST_ORGANIZER_PASSWORD required');
  test.beforeAll(() => { test.skip(!fixturesSeeded(), 'RSVP fixtures not seeded'); });
  test.beforeEach(() => clearEventSignups());
  test.afterAll(() => clearEventSignups());

  test('signup flips the button + count without navigation, writes an audit row; withdraw reverses', async ({ page }) => {
    await login(page);
    await page.goto(`/begivenheder/${RSVP_EVENT_ID}`);
    const urlBefore = page.url();
    const btn = page.locator(`[data-rsvp-key="${RSVP_EVENT_ID}"]`).first();
    const line = page.locator(`[data-rsvp-availability="${RSVP_EVENT_ID}"]`).first();

    await expect(btn).toHaveText(/^Deltag$/);
    await expect(btn).not.toHaveClass(/is-signed-up/);
    await expect(line).toHaveText(/0 tilmeldte/);

    await btn.click();
    await expect(btn).toHaveText('Deltag', { timeout: 10_000 });
    await expect(line).toHaveText(/1 tilmeldt/);
    expect(page.url(), 'signup must not navigate').toBe(urlBefore);
    expect(eventAuditContains(`"action":"signup".*"key":"${RSVP_EVENT_ID}"`)).toBe(true);

    await btn.click();
    await expect(btn).toHaveText(/^Deltag$/, { timeout: 10_000 });
    await expect(line).toHaveText(/0 tilmeldte/);
    expect(eventAuditContains(`"action":"withdraw".*"key":"${RSVP_EVENT_ID}"`)).toBe(true);
  });

  test('an expired session mid-signup opens the login overlay, not a dead error note', async ({ page }) => {
    await login(page);
    await page.goto(`/begivenheder/${RSVP_EVENT_ID}`);
    // Simulate a session that expired server-side after the page loaded (e.g. a
    // redeploy): the page still carries the user's nonce input, so the client
    // thinks it is logged in, but the POST comes back 401.
    await page.route('**/begivenheder/tilmeld', (route) => route.fulfill({
      status: 401,
      contentType: 'application/json',
      body: JSON.stringify({ success: false, error: 'Ikke autoriseret. Log ind for at fortsætte.' }),
    }));
    await page.locator(`[data-rsvp-key="${RSVP_EVENT_ID}"]`).first().click();
    // The login overlay opens; no dead "not authorized" note is left on the card.
    await expect(page.locator('#bv-login-overlay.is-open')).toHaveCount(1);
    await expect(page.locator('.bv-event-row__rsvp-note')).toHaveCount(0);
  });

  test('Interesseret is never capacity-blocked', async ({ page }) => {
    await login(page);
    await page.goto(`/begivenheder/${INTEREST_EVENT_ID}`);
    const btn = page.locator(`[data-rsvp-key="${INTEREST_EVENT_ID}"]`).first();
    // Capacity is 1 on the fixture, but Interesseret ignores it entirely.
    await expect(btn).toBeEnabled();
    await expect(btn).toHaveText(/^Interesseret$/);
    await expect(btn).not.toHaveClass(/is-signed-up/);
    await btn.click();
    // The label stays "Interesseret"; the marked state shows via the checkbox
    // (is-signed-up) and the availability count.
    await expect(btn).toHaveClass(/is-signed-up/, { timeout: 10_000 });
    await expect(page.locator(`[data-rsvp-availability="${INTEREST_EVENT_ID}"]`).first())
      .toHaveText(/1 interesseret/);
  });

  test('the interesseret count uses correct Danish for any number (1 interesseret → 2 interesserede)', async ({ browser }) => {
    const ctxA = await browser.newContext();
    const ctxB = await browser.newContext();
    try {
      const pageA = await ctxA.newPage();
      await login(pageA);
      await pageA.goto(`/begivenheder/${INTEREST_EVENT_ID}`);
      const lineA = pageA.locator(`[data-rsvp-availability="${INTEREST_EVENT_ID}"]`).first();
      await pageA.locator(`[data-rsvp-key="${INTEREST_EVENT_ID}"]`).first().click();
      // One → singular "interesseret" (live JS), never the "interesserete" bug.
      await expect(lineA).toHaveText(/^\s*1 interesseret\s*$/, { timeout: 10_000 });

      const pageB = await ctxB.newPage();
      await loginAsOrganizer(pageB);
      await pageB.goto(`/begivenheder/${INTEREST_EVENT_ID}`);
      const lineB = pageB.locator(`[data-rsvp-availability="${INTEREST_EVENT_ID}"]`).first();
      await pageB.locator(`[data-rsvp-key="${INTEREST_EVENT_ID}"]`).first().click();
      // Two → plural "interesserede" (live JS path), NOT "interesserete".
      await expect(lineB).toHaveText(/^\s*2 interesserede\s*$/, { timeout: 10_000 });

      // Server-rendered plural too (a fresh load reads the stored count).
      await pageA.reload();
      await expect(lineA).toHaveText(/^\s*2 interesserede\s*$/);
    } finally {
      await ctxA.close();
      await ctxB.close();
    }
  });
});

test.describe('Event RSVP — capacity enforcement', () => {
  test.skip(!haveCreds, 'TEST_PASSWORD + TEST_ORGANIZER_PASSWORD required');
  test.beforeAll(() => { test.skip(!fixturesSeeded(), 'RSVP fixtures not seeded'); });
  test.beforeEach(() => clearEventSignups());
  test.afterAll(() => clearEventSignups());

  test('a full capacity-1 event refuses the second member; withdraw frees the seat', async ({ browser }) => {
    const ctxA = await browser.newContext();
    const ctxB = await browser.newContext();
    try {
      const pageA = await ctxA.newPage();
      await login(pageA);
      await pageA.goto(`/begivenheder/${CAPACITY_EVENT_ID}`);
      const btnA = pageA.locator(`[data-rsvp-key="${CAPACITY_EVENT_ID}"]`).first();
      const lineA = pageA.locator(`[data-rsvp-availability="${CAPACITY_EVENT_ID}"]`).first();
      await expect(lineA).toHaveText(/1 plads tilbage/);
      await btnA.click();
      await expect(btnA).toHaveText('Deltag', { timeout: 10_000 });
      await expect(lineA).toHaveText(/Alle pladser er optaget/);

      // Member B is refused server-side with 409.
      const pageB = await ctxB.newPage();
      await loginAsOrganizer(pageB);
      const nonceB = await readRsvpNonce(pageB, CAPACITY_EVENT_ID);
      const resB = await pageB.request.post('/begivenheder/tilmeld', {
        form: { 'data[key]': CAPACITY_EVENT_ID, rsvp_nonce: nonceB },
        headers: { Accept: 'application/json' },
      });
      expect(resB.status()).toBe(409);
      expect((await resB.json()).data.error).toContain('Alle pladser er optaget');

      // A withdraws → the seat frees → B can now sign up.
      await btnA.click();
      await expect(btnA).toHaveText(/^Deltag$/, { timeout: 10_000 });
      const nonceB2 = await readRsvpNonce(pageB, CAPACITY_EVENT_ID);
      const resB2 = await pageB.request.post('/begivenheder/tilmeld', {
        form: { 'data[key]': CAPACITY_EVENT_ID, rsvp_nonce: nonceB2 },
        headers: { Accept: 'application/json' },
      });
      expect(resB2.status()).toBe(200);
      expect((await resB2.json()).action).toBe('signed_up');
    } finally {
      await ctxA.close();
      await ctxB.close();
    }
  });
});

test.describe('Event RSVP — forced-browsing negatives (after auth+CSRF)', () => {
  test.skip(!haveCreds, 'TEST_PASSWORD + TEST_ORGANIZER_PASSWORD required');
  test.beforeAll(() => { test.skip(!fixturesSeeded(), 'RSVP fixtures not seeded'); });

  test('bad nonce → 403', async ({ page }) => {
    await login(page);
    const res = await page.request.post('/begivenheder/tilmeld', {
      form: { 'data[key]': RSVP_EVENT_ID, rsvp_nonce: 'deadbeef' },
      headers: { Accept: 'application/json' },
    });
    expect(res.status()).toBe(403);
  });

  test('unknown / unpublished / archived / past events are rejected', async ({ page }) => {
    await login(page);
    const nonce = await readRsvpNonce(page, RSVP_EVENT_ID);
    const post = (key) => page.request.post('/begivenheder/tilmeld', {
      form: { 'data[key]': key, rsvp_nonce: nonce },
      headers: { Accept: 'application/json' },
    });
    expect((await post('ev_does_not_exist')).status(), 'unknown key').toBe(404);
    expect((await post('ev_fixture_draft')).status(), 'unpublished').toBe(404);
    expect((await post('ev_fixture_archived')).status(), 'archived').toBe(404);
    // event001 is a legacy seed that ran long ago → auto-archived (stale) →
    // 404, indistinguishable from missing (existence not disclosed).
    expect((await post('event001')).status(), 'stale (auto-archived) event').toBe(404);
  });
});

test.describe('Event RSVP — attendee visibility', () => {
  test.skip(!haveCreds, 'TEST_PASSWORD + TEST_ORGANIZER_PASSWORD required');
  test.beforeAll(() => { test.skip(!fixturesSeeded(), 'RSVP fixtures not seeded'); });
  test.beforeEach(() => clearEventSignups());
  test.afterAll(() => clearEventSignups());

  test('the owner sees the attendee on the dashboard; the name never leaks publicly', async ({ browser }) => {
    const ctxU = await browser.newContext();
    const ctxO = await browser.newContext();
    try {
      // Member signs up.
      const pageU = await ctxU.newPage();
      await login(pageU);
      const nonce = await readRsvpNonce(pageU, RSVP_EVENT_ID);
      const res = await pageU.request.post('/begivenheder/tilmeld', {
        form: { 'data[key]': RSVP_EVENT_ID, rsvp_nonce: nonce },
        headers: { Accept: 'application/json' },
      });
      expect(res.status()).toBe(200);

      // Owner (organizer) sees the attendee list — columns tidspunkt · navn ·
      // email, and NO per-attendee mode chip (the event's own mode already
      // says whether these are tilmeldte or interesserede).
      const pageO = await ctxO.newPage();
      await loginAsOrganizer(pageO);
      await pageO.goto('/begivenheder/mine');
      const row = pageO.locator(`.bv-event-dashboard__item[data-event-key="${RSVP_EVENT_ID}"]`);
      await expect(row.locator('.bv-event-dashboard__attendees')).toHaveCount(1);
      // The email is shown so the organizer can make contact.
      await expect(row.locator('.bv-event-dashboard__attendee-email')).toContainText('pw-test-user@');
      // No status badge inside the attendee table.
      await expect(row.locator('.bv-event-dashboard__attendee-table .bv-badge')).toHaveCount(0);

      // The public surface never carries the attendee's name/email/list markup.
      await pageU.goto(`/begivenheder/${RSVP_EVENT_ID}`);
      await expect(pageU.locator('.bv-event-dashboard__attendees')).toHaveCount(0);
      const body = await pageU.locator('body').innerText();
      expect(body).not.toContain('pw-test-user');
    } finally {
      await ctxU.close();
      await ctxO.close();
    }
  });
});

test.describe('Event auto-archive — events that ran more than a day ago', () => {
  test.skip(!haveCreds, 'TEST_PASSWORD + TEST_ORGANIZER_PASSWORD required');
  test.beforeAll(() => { test.skip(!fixturesSeeded(), 'RSVP fixtures not seeded'); });

  /** The persisted `archived:` value of one event key, or null if unset. */
  function eventArchived(key) {
    let inBlock = false;
    let archived = null;
    for (const line of fs.readFileSync(EVENTS_YAML, 'utf8').split('\n')) {
      const km = line.match(/^([A-Za-z0-9_-]+):\s*$/);
      if (km) { inBlock = km[1] === key; continue; }
      if (inBlock) {
        const m = line.match(/^ {2}archived:\s*(.*)$/);
        if (m) { archived = m[1].trim() === 'true'; }
      }
    }
    return archived;
  }

  test('opening the dashboard persists archived=true on stale events, leaves future ones alone', async ({ page }) => {
    // event001 is a legacy 2026 seed (ran long ago) → must be swept to archived.
    // ev_fixture_rsvp is dated 2030 (future) → must stay active.
    await loginAsOrganizer(page);
    await page.goto('/begivenheder/mine');
    // The sweep runs server-side during the GET; the flag is on disk by the
    // time the response lands. Poll to be robust against fs flush timing.
    await expect.poll(() => eventArchived('event001'), { timeout: 10_000 }).toBe(true);
    expect(eventArchived(RSVP_EVENT_ID), 'a future event is never auto-archived').toBe(false);
  });
});
