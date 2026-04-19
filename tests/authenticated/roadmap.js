// @ts-check
'use strict';

/**
 * Authenticated Roadmap end-to-end coverage (Sprint 3).
 *
 * Describe blocks mirror the spec sections: Page rendering, Vote flow,
 * Nonce re-issue, Budget enforcement, Locked items, AJAX error surfacing,
 * Admin smoke. Whole file skipped when TEST_PASSWORD is unset; admin smoke
 * additionally requires TEST_ADMIN_PASSWORD. Skip reasons name the env var.
 *
 * Selector notes:
 *   - Items render as `.bv-rm-card` (contract names `.bv-rm-item` — same
 *     thing in this codebase, per the contract's "documented equivalent").
 *   - Budget widget: `.bv-rm-star-budget` (`#bv-rm-bug-star-budget` /
 *     `#bv-rm-feature-star-budget`). Toast container: `#bv-rm-toast`.
 *   - Action-bar vote buttons live inside a `[hidden]` action-bar that
 *     opens when the card is expanded by a non-button click.
 *
 * Security: never logs passwords, session cookies, or vote_nonce values.
 */

const { test, expect } = require('@playwright/test');
const { execFileSync } = require('child_process');
const { login, loginAsAdmin, hasUserPassword, hasAdminPassword } = require('../helpers/auth');
const { removeVote } = require('../helpers/cleanup');

const LOCKED_STATUSES = ['under_implementation', 'klar_til_test', 'loest'];

/** @type {WeakMap<object, Set<string>>} added-vote tracker per test */
const addedVotesByTest = new WeakMap();

function trackVote(testInfo, itemId) {
  let set = addedVotesByTest.get(testInfo);
  if (!set) { set = new Set(); addedVotesByTest.set(testInfo, set); }
  set.add(String(itemId));
}

async function readVoteNonce(page) {
  return page.evaluate(() => {
    const el = document.querySelector('#bv-rm-vote-nonces input[name="vote_nonce"]')
      || document.querySelector('input[name="vote_nonce"]');
    return el ? /** @type {HTMLInputElement} */ (el).value : null;
  });
}

async function readVoteCount(page, itemId) {
  return page.evaluate((id) => {
    const card = document.querySelector(`.bv-rm-card[data-item-id="${CSS.escape(id)}"]`);
    if (!card) return null;
    const el = card.querySelector('.bv-rm-card__vote-count');
    if (!el) return null;
    const n = parseInt((el.textContent || '').trim(), 10);
    return Number.isFinite(n) ? n : null;
  }, itemId);
}

async function findVotableItem(page, itemType) {
  return page.evaluate((type) => {
    const cards = Array.from(document.querySelectorAll('.bv-rm-card[data-item-id]'));
    for (const card of cards) {
      if (card.getAttribute('data-item-type') !== type) continue;
      if (card.classList.contains('bv-rm-card--locked')) continue;
      if (card.classList.contains('bv-rm-card--solved')) continue;
      if (card.getAttribute('data-voted') === 'true') continue;
      const id = card.getAttribute('data-item-id');
      if (id) return { id, status: card.getAttribute('data-item-status') };
    }
    return null;
  }, itemType);
}

async function findCandidates(page, itemType) {
  return page.evaluate((type) => {
    return Array.from(document.querySelectorAll('.bv-rm-card[data-item-id]'))
      .filter((c) => c.getAttribute('data-item-type') === type
        && !c.classList.contains('bv-rm-card--locked')
        && !c.classList.contains('bv-rm-card--solved')
        && c.getAttribute('data-voted') !== 'true')
      .map((c) => c.getAttribute('data-item-id'));
  }, itemType);
}

async function findLockedItem(page) {
  return page.evaluate((locked) => {
    const cards = Array.from(document.querySelectorAll('.bv-rm-card[data-item-id]'));
    for (const card of cards) {
      const status = card.getAttribute('data-item-status') || '';
      if (locked.indexOf(status) !== -1) {
        return { id: card.getAttribute('data-item-id'), status };
      }
    }
    return null;
  }, LOCKED_STATUSES);
}

async function expandCard(page, itemId) {
  await page.locator(`.bv-rm-card[data-item-id="${itemId}"] .bv-rm-card__title`).first().click();
  await expect(
    page.locator(`.bv-rm-card[data-item-id="${itemId}"] .bv-rm-card__action-bar`)
  ).toBeVisible({ timeout: 5_000 });
}

function waitVoteResponse(page) {
  return page.waitForResponse((r) =>
    r.url().includes('/roadmap/vote') && r.request().method() === 'POST');
}

test.describe('Roadmap — authenticated', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — skipping authenticated roadmap tests');

  test.beforeEach(async ({ page }) => { await login(page); });

  test.afterEach(async ({ page }, testInfo) => {
    const set = addedVotesByTest.get(testInfo);
    if (!set || set.size === 0) return;
    try { await page.goto('/roadmap'); } catch (_) { /* best effort */ }
    for (const itemId of set) {
      try { await removeVote(page, itemId); } catch (_) { /* never throw from teardown */ }
    }
    addedVotesByTest.delete(testInfo);
  });

  // ──────────────────────────────────────────────────────────────────────
  test.describe('Page rendering', () => {
    test('renders /roadmap with items, budget widget, and locked-status guard', async ({ page }) => {
      const response = await page.goto('/roadmap');
      expect(response?.status()).toBe(200);

      const itemCount = await page.locator('.bv-rm-card[data-item-id]').count();
      expect(itemCount).toBeGreaterThanOrEqual(1);

      await expect(page.locator('.bv-rm-star-budget').first()).toBeVisible();

      // Locked statuses must NOT expose any enabled add-vote affordance.
      const offenders = await page.evaluate((locked) => {
        const out = [];
        const cards = Array.from(document.querySelectorAll('.bv-rm-card[data-item-id]'));
        for (const card of cards) {
          const status = card.getAttribute('data-item-status') || '';
          if (locked.indexOf(status) === -1) continue;
          // Action-bar add buttons: must be disabled OR inside hidden bar.
          for (const b of Array.from(card.querySelectorAll('.bv-rm-vote-btn[data-action="add"]'))) {
            const disabled = b.hasAttribute('disabled') || b.getAttribute('aria-disabled') === 'true';
            const bar = b.closest('.bv-rm-card__action-bar');
            const barHidden = bar ? bar.hasAttribute('hidden') : false;
            if (!disabled && !barHidden) out.push({ id: card.getAttribute('data-item-id'), status });
          }
          // Face vote add buttons: must be disabled.
          for (const b of Array.from(card.querySelectorAll('.bv-rm-card__vote-btn'))) {
            if (b.getAttribute('data-action') !== 'add') continue;
            const disabled = b.hasAttribute('disabled') || b.getAttribute('aria-disabled') === 'true';
            if (!disabled) out.push({ id: card.getAttribute('data-item-id'), status });
          }
        }
        return out;
      }, LOCKED_STATUSES);
      expect(offenders).toEqual([]);
    });

    // F6.6 — feature-flag touchpoint. Single assertion that verifies
    // feature_enabled() from the roadmap step 1 plugin is callable and
    // returns a boolean for a known flag. Does NOT test the flag plugin
    // itself beyond callability — that is covered by the plugin's own
    // PHPUnit suite under config/www/user/plugins/feature-flags/tests.
    test('feature_enabled(\'promo_banner\') returns a boolean via Twig', async () => {
      // Exercise the Twig function the same way production templates do,
      // via a tiny inline render run inside the grav container. The known
      // flag 'promo_banner' is the canonical example from the plugin README.
      const tpl = "{{ feature_enabled('promo_banner') is same as(true) ? 'bool-true' : "
        + "(feature_enabled('promo_banner') is same as(false) ? 'bool-false' : 'NOT-BOOL') }}";
      const php =
        "require '/app/www/public/vendor/autoload.php';"
        + "use Grav\\Common\\Grav;"
        + "$g = Grav::instance();"
        + "$g['config']->init(); $g['uri']->init(); $g['plugins']->init();"
        + "$g->fireEvent('onPluginsInitialized');"
        + "$g['themes']->init(); $g->fireEvent('onThemeInitialized');"
        + "$g['twig']->init();"
        + "echo $g['twig']->twig()->createTemplate(getenv('TPL'))->render([]);";
      const out = execFileSync(
        'docker',
        ['exec', '-e', `TPL=${tpl}`, '-w', '/app/www/public', 'grav', 'php', '-r', php],
        { encoding: 'utf8', timeout: 30_000 }
      ).trim();
      expect(['bool-true', 'bool-false']).toContain(out);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  test.describe('Vote flow', () => {
    test('add then remove updates count and toggles buttons with no JS errors', async ({ page }, testInfo) => {
      const errors = [];
      page.on('pageerror', (err) => errors.push(err.message));

      await page.goto('/roadmap');
      const item = await findVotableItem(page, 'bug') || await findVotableItem(page, 'feature');
      test.skip(!item, 'no votable (non-locked, non-voted) roadmap item rendered');
      const itemId = /** @type {{id: string}} */ (item).id;

      const cardSel = `.bv-rm-card[data-item-id="${itemId}"]`;
      const addSel = `${cardSel} .bv-rm-vote-btn[data-action="add"]`;
      const removeSel = `${cardSel} .bv-rm-vote-btn[data-action="remove"]`;

      const before = await readVoteCount(page, itemId);
      expect(before).not.toBeNull();

      await expandCard(page, itemId);
      await expect(page.locator(addSel)).toBeVisible();

      const addResp = waitVoteResponse(page);
      await page.locator(addSel).click();
      expect((await addResp).status()).toBe(200);
      trackVote(testInfo, itemId);

      await expect(page.locator(removeSel)).toBeVisible({ timeout: 5_000 });
      await expect.poll(async () => readVoteCount(page, itemId), { timeout: 5_000 })
        .toBe(/** @type {number} */ (before) + 1);

      const remResp = waitVoteResponse(page);
      await page.locator(removeSel).click();
      expect((await remResp).status()).toBe(200);

      await expect(page.locator(addSel)).toBeVisible({ timeout: 5_000 });
      await expect.poll(async () => readVoteCount(page, itemId), { timeout: 5_000 })
        .toBe(before);

      // Test removed its own vote — drop from cleanup tracker.
      const tracked = addedVotesByTest.get(testInfo);
      if (tracked) tracked.delete(itemId);

      expect(errors).toEqual([]);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  test.describe('Nonce re-issue', () => {
    test('vote_nonce DOM value rotates after a successful add', async ({ page }, testInfo) => {
      await page.goto('/roadmap');
      const item = await findVotableItem(page, 'bug') || await findVotableItem(page, 'feature');
      test.skip(!item, 'no votable roadmap item available for nonce re-issue test');
      const itemId = /** @type {{id: string}} */ (item).id;

      const noncePre = await readVoteNonce(page);
      expect(typeof noncePre).toBe('string');
      expect((noncePre || '').length).toBeGreaterThan(0);

      await expandCard(page, itemId);
      const respPromise = waitVoteResponse(page);
      await page.locator(`.bv-rm-card[data-item-id="${itemId}"] .bv-rm-vote-btn[data-action="add"]`).click();
      expect((await respPromise).status()).toBe(200);
      trackVote(testInfo, itemId);

      // JS rewrites the hidden input from `new_nonce`; poll for rotation.
      await expect.poll(async () => {
        const cur = await readVoteNonce(page);
        return cur && cur !== noncePre;
      }, { timeout: 5_000 }).toBeTruthy();

      const noncePost = await readVoteNonce(page);
      expect(typeof noncePost).toBe('string');
      expect((noncePost || '').length).toBeGreaterThan(0);
      expect(noncePost).not.toBe(noncePre);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  test.describe('Budget enforcement', () => {
    test('exceeding category budget surfaces error toast and does not increment count', async ({ page }, testInfo) => {
      await page.goto('/roadmap');

      let category = 'bug';
      let candidates = await findCandidates(page, category);
      if (candidates.length < 4) {
        category = 'feature';
        candidates = await findCandidates(page, category);
      }
      test.skip(candidates.length < 4,
        `not enough votable ${category} items (need >=4 to exercise budget cap of 3)`);

      const widgetId = category === 'bug' ? 'bv-rm-bug-star-budget' : 'bv-rm-feature-star-budget';
      const startingBudget = await page.evaluate((id) => {
        const w = document.getElementById(id);
        return w ? w.querySelectorAll('.bv-rm-star-budget__star--filled').length : null;
      }, widgetId);
      test.skip(startingBudget !== 3,
        `category '${category}' budget is ${startingBudget}/3 before test — pre-existing votes, skipping`);

      const ids = candidates.slice(0, 4);
      for (let i = 0; i < 3; i++) {
        const nonce = await readVoteNonce(page);
        const resp = await page.request.post('/roadmap/vote', {
          form: { item_id: String(ids[i]), action: 'add', vote_nonce: String(nonce) },
        });
        expect(resp.status()).toBe(200);
        trackVote(testInfo, ids[i]);
        // Reload to surface the rotated nonce for the next request.
        await page.goto('/roadmap');
      }

      const fourth = ids[3];
      const before = await readVoteCount(page, fourth);
      await expandCard(page, fourth);
      const respPromise = waitVoteResponse(page);
      await page.locator(
        `.bv-rm-card[data-item-id="${fourth}"] .bv-rm-vote-btn[data-action="add"]`
      ).click();
      const resp = await respPromise;
      expect(resp.status()).toBeGreaterThanOrEqual(400);
      expect(resp.status()).toBeLessThan(500);

      const toast = page.locator('#bv-rm-toast');
      await expect(toast).toBeVisible({ timeout: 5_000 });
      await expect(toast).toHaveText(/\S/);

      const after = await readVoteCount(page, fourth);
      expect(after).toBe(before);
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  test.describe('Locked items', () => {
    test('POST /roadmap/vote on a locked item returns a 4xx JSON error', async ({ page }) => {
      await page.goto('/roadmap');
      const locked = await findLockedItem(page);
      test.skip(!locked, 'no locked-status roadmap item rendered to test against');
      const lockedId = /** @type {{id: string}} */ (locked).id;

      const nonce = await readVoteNonce(page);
      expect(typeof nonce).toBe('string');

      const resp = await page.request.post('/roadmap/vote', {
        form: { item_id: String(lockedId), action: 'add', vote_nonce: String(nonce) },
      });
      const status = resp.status();
      expect(status).toBeGreaterThanOrEqual(400);
      expect(status).toBeLessThan(500);

      let body;
      try { body = await resp.json(); }
      catch (_) { throw new Error(`expected JSON error body, got non-JSON (status ${status})`); }
      const hasErrorShape = (body && typeof body === 'object') && (
        body.success === false
        || typeof body.error === 'string'
        || (body.data && typeof body.data.error === 'string')
        || body.status === 'error'
      );
      expect(hasErrorShape).toBeTruthy();
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  test.describe('AJAX error surfacing', () => {
    test('intercepted 500 surfaces toast and leaves button state unchanged', async ({ page }) => {
      await page.goto('/roadmap');
      const item = await findVotableItem(page, 'bug') || await findVotableItem(page, 'feature');
      test.skip(!item, 'no votable item available for AJAX 500 surfacing test');
      const itemId = /** @type {{id: string}} */ (item).id;

      const cardSel = `.bv-rm-card[data-item-id="${itemId}"]`;
      const addSel = `${cardSel} .bv-rm-vote-btn[data-action="add"]`;

      await page.route('**/roadmap/vote', (route) => {
        route.fulfill({
          status: 500,
          contentType: 'application/json',
          body: JSON.stringify({ success: false, error: 'forced-500' }),
        });
      });

      const beforeCount = await readVoteCount(page, itemId);
      await expandCard(page, itemId);
      await expect(page.locator(addSel)).toBeVisible();

      const respPromise = waitVoteResponse(page);
      await page.locator(addSel).click();
      const resp = await respPromise;
      expect(resp.status()).toBe(500);

      const toast = page.locator('#bv-rm-toast');
      await expect(toast).toBeVisible({ timeout: 5_000 });
      await expect(toast).toHaveText(/\S/);

      // Add button still present, remove still hidden.
      expect(await page.locator(addSel).count()).toBeGreaterThanOrEqual(1);
      const removeVisible = await page.locator(
        `${cardSel} .bv-rm-vote-btn[data-action="remove"]:not(.bv-rm-vote-btn--hidden)`
      ).count();
      expect(removeVisible).toBe(0);

      const afterCount = await readVoteCount(page, itemId);
      expect(afterCount).toBe(beforeCount);

      await page.unroute('**/roadmap/vote');
    });
  });

  // ──────────────────────────────────────────────────────────────────────
  test.describe('Admin smoke', () => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — skipping admin smoke');

    test('POST /admin/roadmap/release-votes returns success:true for a single item', async ({ page }) => {
      await loginAsAdmin(page);

      // Resolve a `release_nonce` (action `roadmap-release-votes`) by visiting
      // the admin flex-objects edit page for any roadmap item.
      let nonce = null;
      let itemId = null;

      const listResp = await page.goto('/admin/flex-objects/roadmap-items');
      if (listResp && listResp.ok()) {
        const href = await page.evaluate(() => {
          const a = document.querySelector('a[href*="/admin/flex-objects/roadmap-items/"]');
          return a ? a.getAttribute('href') : null;
        });
        if (href) {
          await page.goto(href);
          nonce = await page.evaluate(() => {
            const el = document.querySelector('input[name="release_nonce"]');
            return el ? /** @type {HTMLInputElement} */ (el).value : null;
          });
          const m = href.match(/\/roadmap-items\/([^\/?#]+)/);
          if (m) itemId = decodeURIComponent(m[1]);
        }
      }

      test.skip(!nonce || !itemId,
        'could not resolve release_nonce / item id from admin flex-objects edit page');

      const resp = await page.request.post('/admin/roadmap/release-votes', {
        form: { item_id: String(itemId), release_nonce: String(nonce) },
      });
      expect(resp.status()).toBe(200);
      const body = await resp.json();
      expect(body && body.success).toBe(true);
    });
  });
});
