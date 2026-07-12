// @ts-check
'use strict';

/**
 * Frontend event CRUD — authenticated success paths (spec §12 M2–M4).
 *
 * Requires TEST_ORGANIZER_PASSWORD (the seeded arrangør); the super
 * (hard-delete) cases additionally require TEST_ADMIN_PASSWORD. global-setup
 * FAILS the run when TEST_PASSWORD is set without TEST_ORGANIZER_PASSWORD,
 * so this suite can never silently skip on a credentialed machine.
 *
 * Events created here get server keys `ev_<hex>`; each test tracks what it
 * creates and removes it again via fixtures.removeEventByKey, with the
 * global teardown's `git checkout -- config/www/user/data/flex-objects`
 * as backstop.
 */

const fs = require('fs');
const path = require('path');
const { test, expect } = require('@playwright/test');
const { loginAsOrganizer, loginAsSiteAdmin, hasOrganizerPassword, hasAdminPassword } = require('../helpers/auth');
const { removeEventByKey, clearGravCache } = require('../helpers/fixtures');

const EVENTS_YAML = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'begivenheder.yaml');
const AUDIT_LOG = path.resolve(__dirname, '..', '..', 'config', 'www', 'user', 'data', 'flex-objects', 'events-audit.jsonl');

function readEventsFile() {
  return fs.readFileSync(EVENTS_YAML, 'utf8');
}

function readAuditLog() {
  return fs.existsSync(AUDIT_LOG) ? fs.readFileSync(AUDIT_LOG, 'utf8') : '';
}

/** Extract the block of one event from the YAML store (header + indented body). */
function eventBlock(key) {
  const match = readEventsFile().match(new RegExp(`^${key}:\\n((?:[ ].*\\n?)*)`, 'm'));
  return match ? match[1] : null;
}

/** @param {import('@playwright/test').Page} page */
async function getFormNonce(page) {
  const value = await page.locator('input[name="form-nonce"]').first().inputValue();
  expect(value).toMatch(/^[0-9a-f]+$/);
  return value;
}

/**
 * Create an event through the organizer's session and return its key.
 * Uses the page's own form nonce + request POST — the exact wire contract
 * the browser form submits.
 *
 * @param {import('@playwright/test').Page} page
 * @param {{title: string, published: '0'|'1'}} opts
 */
async function createEvent(page, { title, published }) {
  await page.goto('/begivenheder/opret');
  const nonce = await getFormNonce(page);
  const response = await page.request.post('/begivenheder/opret', {
    form: {
      'data[title]': title,
      'data[description]': 'Oprettet af Playwright.',
      'data[group]': 'makerspace',
      'data[event_date]': '2030-06-01',
      'data[time_start]': '10:00',
      'data[time_end]': '12:00',
      'data[price]': 'Gratis',
      'data[published]': published,
      'form-nonce': nonce,
    },
    maxRedirects: 0,
  });
  expect(response.status()).toBe(303);
  expect(response.headers()['location']).toContain('/begivenheder/mine');
  const match = readEventsFile().match(new RegExp(`^(ev_[0-9a-f]+):\\n(?:[ ].*\\n)*?[ ]{2}title: '?${title}'?\\n`, 'm'));
  expect(match, `event '${title}' persisted with an ev_ key`).toBeTruthy();
  return /** @type {RegExpMatchArray} */ (match)[1];
}

test.describe('Events — organizer CRUD (M2–M4)', () => {
  test.skip(!hasOrganizerPassword, 'TEST_ORGANIZER_PASSWORD not set');

  /** @type {string[]} */
  let createdKeys = [];

  test.afterEach(() => {
    for (const key of createdKeys) {
      try { removeEventByKey(key); } catch (_) { /* already gone */ }
    }
    if (createdKeys.length) clearGravCache();
    createdKeys = [];
  });

  test('create published: owner-stamped, audited, immediately in the public list', async ({ page, browser }) => {
    await loginAsOrganizer(page);
    const auditBefore = readAuditLog();

    const title = `PW publiceret ${Date.now()}`;
    const key = await createEvent(page, { title, published: '1' });
    createdKeys.push(key);

    // Server-managed stamps on the stored object; owner from the session.
    const block = eventBlock(key) || '';
    expect(block).toContain('owner: pw-test-org');
    expect(block).toContain('created_by: pw-test-org');
    expect(block).toContain('published: true');
    expect(block).toContain('archived: false');
    // The accent AND the category badge are DERIVED from the group
    // (makerspace → secondary / 'Makerspace & Reparation'); the client
    // cannot choose them.
    expect(block).toContain('button_style: secondary');
    expect(block).toContain("badge: 'Makerspace & Reparation'");
    expect(block).toContain('price: Gratis');
    // The two native time inputs compose the stored card string.
    expect(block).toContain("event_time: '10:00 - 12:00'");

    // Audit row appended.
    const auditAfter = readAuditLog();
    expect(auditAfter.startsWith(auditBefore)).toBe(true);
    const newLines = auditAfter.slice(auditBefore.length).trim().split('\n');
    const record = JSON.parse(newLines[newLines.length - 1]);
    expect(record).toMatchObject({ actor: 'pw-test-org', action: 'create', key });

    // Dashboard shows it with a success flash and 'publiceret' chip.
    await page.goto('/begivenheder/mine');
    const item = page.locator(`[data-event-key="${key}"]`);
    await expect(item).toHaveAttribute('data-event-status', 'publiceret');

    // Public list freshness: an ANONYMOUS visitor sees it immediately.
    const anon = await browser.newContext();
    try {
      const anonPage = await anon.newPage();
      await anonPage.goto('/vaerkstedskalenderen');
      await expect(anonPage.locator('.bv-event-list')).toContainText(title);
    } finally {
      await anon.close();
    }
  });

  test('create draft (Synlig = Nej): owner sees it, the public does not', async ({ page, browser }) => {
    await loginAsOrganizer(page);
    const title = `PW kladde ${Date.now()}`;
    const key = await createEvent(page, { title, published: '0' });
    createdKeys.push(key);

    // Owner sees the draft on the dashboard with a 'kladde' chip.
    await page.goto('/begivenheder/mine');
    await expect(page.locator(`[data-event-key="${key}"]`)).toHaveAttribute('data-event-status', 'kladde');

    const anon = await browser.newContext();
    try {
      const anonPage = await anon.newPage();
      // Absent from the public calendar...
      await anonPage.goto('/vaerkstedskalenderen');
      await expect(anonPage.locator('body')).not.toContainText(title);
      // ...and the detail route redirects to the calendar (no preview, no leak).
      await anonPage.goto(`/begivenheder/${key}`);
      await expect(anonPage).toHaveURL(/\/vaerkstedskalenderen$/);
      await expect(anonPage.locator('body')).not.toContainText(title);
    } finally {
      await anon.close();
    }
  });

  test('edit own event via the prefilled form: fields change, owner preserved, updated stamps set', async ({ page }) => {
    await loginAsOrganizer(page);
    const title = `PW rediger ${Date.now()}`;
    const key = await createEvent(page, { title, published: '1' });
    createdKeys.push(key);

    await page.goto(`/begivenheder/rediger/${key}`);
    // Prefill from the stored object.
    await expect(page.locator('input[name="data[title]"]')).toHaveValue(title);
    await expect(page.locator('input[name="data[key]"]')).toHaveValue(key);

    const newTitle = `${title} (opdateret)`;
    await page.fill('input[name="data[title]"]', newTitle);
    await page.click('form [type="submit"]');
    await page.waitForURL(/\/begivenheder\/mine/);

    const block = eventBlock(key) || '';
    expect(block).toContain(`title: '${newTitle}'`);
    expect(block).toContain('owner: pw-test-org');
    expect(block).toContain('updated_by: pw-test-org');
    // Flash rendered through the shared component.
    await expect(page.locator('.bv-message--success')).toContainText('opdateret');
  });

  test('publish/unpublish own event through the Synlig toggle', async ({ page }) => {
    await loginAsOrganizer(page);
    const title = `PW synlig ${Date.now()}`;
    const key = await createEvent(page, { title, published: '1' });
    createdKeys.push(key);

    // Unpublish via the edit form (owner self-service, no admin involved).
    await page.goto(`/begivenheder/rediger/${key}`);
    const nonce = await getFormNonce(page);
    const response = await page.request.post('/begivenheder/rediger', {
      form: {
        'data[key]': key,
        'data[title]': title,
        'data[group]': 'makerspace',
        'data[event_date]': '2030-06-01',
        'data[time_start]': '10:00',
        'data[time_end]': '12:00',
        'data[published]': '0',
        'form-nonce': nonce,
      },
      maxRedirects: 0,
    });
    expect(response.status()).toBe(303);
    expect(eventBlock(key)).toContain('published: false');
  });

  test('Slet = soft delete: retained but hidden from the owner + public; super sees it and restores', async ({ page, browser }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set');
    await loginAsOrganizer(page);
    const title = `PW slet ${Date.now()}`;
    const key = await createEvent(page, { title, published: '1' });
    createdKeys.push(key);
    const auditBefore = readAuditLog();

    // Owner soft-deletes from the dashboard (mode=delete).
    await page.goto('/begivenheder/mine');
    const nonce = await getFormNonce(page);
    const res = await page.request.post('/begivenheder/slet', {
      form: { 'data[key]': key, 'data[mode]': 'delete', 'form-nonce': nonce },
      maxRedirects: 0,
    });
    expect(res.status()).toBe(303);

    // Retained with deleted:true + unpublished; audit appends a 'delete' row.
    const block = eventBlock(key) || '';
    expect(block).toContain('deleted: true');
    expect(block).toContain('published: false');
    expect(readAuditLog().slice(auditBefore.length)).toContain('"action":"delete"');

    // Gone from the OWNER's own dashboard.
    await page.goto('/begivenheder/mine');
    await expect(page.locator(`[data-event-key="${key}"]`)).toHaveCount(0);

    // Gone from the public surface + not signup-able (detail route redirects).
    const anon = await browser.newContext();
    try {
      const anonPage = await anon.newPage();
      await anonPage.goto('/vaerkstedskalenderen');
      await expect(anonPage.locator('body')).not.toContainText(title);
      await anonPage.goto(`/begivenheder/${key}`);
      await expect(anonPage).toHaveURL(/\/vaerkstedskalenderen$/);
    } finally {
      await anon.close();
    }

    // A super DOES see it (status 'slettet') and can restore it (both flags cleared).
    const adminCtx = await browser.newContext();
    try {
      const adminPage = await adminCtx.newPage();
      await loginAsSiteAdmin(adminPage);
      await adminPage.goto('/begivenheder/mine');
      const item = adminPage.locator(`[data-event-key="${key}"]`);
      await expect(item).toHaveAttribute('data-event-status', 'slettet');
      // Super's actions on a deleted event are Gendan + Slet helt (the
      // owner-facing Slet/Arkiver are gone).
      await expect(item.locator('button:has-text("Gendan")')).toHaveCount(1);
      await expect(item.locator('.bv-event-dashboard__confirm > summary')).toHaveText('Slet helt');
      const anonce = await getFormNonce(adminPage);
      const rres = await adminPage.request.post('/begivenheder/slet', {
        form: { 'data[key]': key, 'data[mode]': 'restore', 'form-nonce': anonce },
        maxRedirects: 0,
      });
      expect(rres.status()).toBe(303);
    } finally {
      await adminCtx.close();
    }
    const restored = eventBlock(key) || '';
    expect(restored).toContain('deleted: false');
    expect(restored).toContain('archived: false');
  });

  test('Arkiver: hidden publicly, stays on the owner dashboard as arkiveret; editing lifts the archive', async ({ page, browser }) => {
    await loginAsOrganizer(page);
    const title = `PW arkiv ${Date.now()}`;
    const key = await createEvent(page, { title, published: '1' });
    createdKeys.push(key);

    // Owner archives (mode=archive).
    await page.goto('/begivenheder/mine');
    const nonce = await getFormNonce(page);
    const res = await page.request.post('/begivenheder/slet', {
      form: { 'data[key]': key, 'data[mode]': 'archive', 'form-nonce': nonce },
      maxRedirects: 0,
    });
    expect(res.status()).toBe(303);
    expect(eventBlock(key) || '').toContain('archived: true');

    // Still on the owner's dashboard (arkiveret), with Arkiver disabled.
    await page.goto('/begivenheder/mine');
    const item = page.locator(`[data-event-key="${key}"]`);
    await expect(item).toHaveAttribute('data-event-status', 'arkiveret');
    await expect(item.locator('.bv-event-dashboard__actions .bv-btn', { hasText: 'Arkiver' })).toBeDisabled();

    // Gone from the public calendar.
    const anon = await browser.newContext();
    try {
      const anonPage = await anon.newPage();
      await anonPage.goto('/vaerkstedskalenderen');
      await expect(anonPage.locator('body')).not.toContainText(title);
    } finally {
      await anon.close();
    }

    // Editing lifts the archive (archived → false) — the organizer's reactivation.
    await page.goto(`/begivenheder/rediger/${key}`);
    const enonce = await getFormNonce(page);
    const eres = await page.request.post('/begivenheder/rediger', {
      form: {
        'data[key]': key, 'data[title]': title, 'data[group]': 'makerspace',
        'data[event_date]': '2030-06-02', 'data[time_start]': '10:00', 'data[time_end]': '12:00',
        'data[published]': '1', 'form-nonce': enonce,
      },
      maxRedirects: 0,
    });
    expect(eres.status()).toBe(303);
    expect(eventBlock(key) || '').toContain('archived: false');
  });

  test('past dates are rejected server-side on create and on edit', async ({ page }) => {
    await loginAsOrganizer(page);

    // Create with a clearly-past date → 400 with a date error; nothing persisted.
    await page.goto('/begivenheder/opret');
    const title = `PW fortid ${Date.now()}`;
    const key = await page.locator('[name="data[key]"]').inputValue();
    const nonce = await getFormNonce(page);
    const res = await page.request.post('/begivenheder/opret', {
      form: {
        'data[key]': key, 'data[title]': title, 'data[group]': 'makerspace',
        'data[event_date]': '2020-01-01', 'data[time_start]': '10:00', 'data[time_end]': '12:00',
        'data[published]': '1', 'form-nonce': nonce,
      },
      headers: { Accept: 'application/json' },
      maxRedirects: 0,
    });
    expect(res.status()).toBe(400);
    expect(JSON.stringify(await res.json())).toContain('event_date');
    expect(eventBlock(key)).toBeNull();

    // A valid event, then an edit INTO the past → rejected; the date is unchanged.
    const key2 = await createEvent(page, { title: `${title} ok`, published: '1' });
    createdKeys.push(key2);
    await page.goto(`/begivenheder/rediger/${key2}`);
    const enonce = await getFormNonce(page);
    const eres = await page.request.post('/begivenheder/rediger', {
      form: {
        'data[key]': key2, 'data[title]': `${title} ok`, 'data[group]': 'makerspace',
        'data[event_date]': '2020-01-01', 'data[time_start]': '10:00', 'data[time_end]': '12:00',
        'data[published]': '1', 'form-nonce': enonce,
      },
      headers: { Accept: 'application/json' },
      maxRedirects: 0,
    });
    expect(eres.status()).toBe(400);
    expect(eventBlock(key2) || '').toContain("event_date: '2030-06-01'");
  });

  test('super: sees all events in the dashboard and can hard-delete permanently', async ({ page, browser }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set');

    // The organizer creates; the super removes.
    await loginAsOrganizer(page);
    const title = `PW hard-delete ${Date.now()}`;
    const key = await createEvent(page, { title, published: '1' });
    createdKeys.push(key);

    const adminContext = await browser.newContext();
    try {
      const adminPage = await adminContext.newPage();
      await loginAsSiteAdmin(adminPage);

      // Super's dashboard lists other owners' events too.
      await adminPage.goto('/begivenheder/mine');
      await expect(adminPage.locator(`[data-event-key="${key}"]`)).toBeVisible();

      // Super escalates to a permanent hard delete (mode=hard).
      const nonce = await getFormNonce(adminPage);
      const response = await adminPage.request.post('/begivenheder/slet', {
        form: { 'data[key]': key, 'data[mode]': 'hard', 'form-nonce': nonce },
        maxRedirects: 0,
      });
      expect(response.status()).toBe(303);
      expect(eventBlock(key)).toBeNull();
      expect(readAuditLog()).toContain('"action":"hard_delete"');
      createdKeys = createdKeys.filter((k) => k !== key);
    } finally {
      await adminContext.close();
    }
  });

  test('organizer sees the create button on the calendar page', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/vaerkstedskalenderen');
    const link = page.locator('[data-testid="calendar-create-link"]');
    await expect(link).toBeVisible();
    await link.click();
    await expect(page).toHaveURL(/\/begivenheder\/opret/);
  });

  test('organizer sees the footer entry and reaches the dashboard from it', async ({ page }) => {
    await loginAsOrganizer(page);
    await page.goto('/');
    const link = page.locator('.bv-footer a[href="/begivenheder/mine"]');
    await expect(link).toBeVisible();
    await link.click();
    await expect(page).toHaveURL(/\/begivenheder\/mine/);
    await expect(page.locator('h1')).toContainText('Mine begivenheder');
  });
});
