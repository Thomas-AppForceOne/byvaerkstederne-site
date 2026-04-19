// @ts-check
'use strict';

/**
 * Reusable teardown primitives for the Playwright suite.
 *
 *   - removeVote(page, itemId): post a `remove` action to /roadmap/vote
 *     using the current DOM nonce. Best-effort: never throws so callers can
 *     use it from afterEach without masking the original failure.
 *   - testMarker(prefix): build a greppable `[TEST] <iso> <uuid>` string
 *     to prefix domain items the suite cannot otherwise clean up.
 */

const { randomUUID } = require('crypto');

/**
 * Best-effort: remove a vote the test left behind on a roadmap item.
 * Reads the current `vote_nonce` from the page DOM (the handler issues a
 * fresh nonce on every successful vote, so we always pick up the latest).
 *
 * @param {import('@playwright/test').Page} page
 * @param {string|number} itemId
 * @returns {Promise<{ok: boolean, status?: number, reason?: string}>}
 */
async function removeVote(page, itemId) {
  if (itemId === undefined || itemId === null || itemId === '') {
    return { ok: false, reason: 'missing-item-id' };
  }
  try {
    const nonce = await page.evaluate(() => {
      const el = document.querySelector('input[name="vote_nonce"]');
      return el ? /** @type {HTMLInputElement} */ (el).value : null;
    });
    if (!nonce) {
      return { ok: false, reason: 'no-nonce' };
    }
    const response = await page.request.post('/roadmap/vote', {
      form: {
        item_id: String(itemId),
        action: 'remove',
        vote_nonce: nonce,
      },
    });
    return { ok: response.ok(), status: response.status() };
  } catch (err) {
    // Never throw from a teardown helper; surface the reason for diagnostics.
    return { ok: false, reason: 'exception' };
  }
}

/**
 * Build a `[TEST] <iso 8601> <uuid>` marker string for prefixing test-created
 * domain items that cannot be cleaned through a public endpoint.
 *
 * @param {string} [prefix='TEST']
 * @returns {string}
 */
function testMarker(prefix = 'TEST') {
  const safePrefix = typeof prefix === 'string' && prefix.length > 0 ? prefix : 'TEST';
  return `[${safePrefix}] ${new Date().toISOString()} ${randomUUID()}`;
}

module.exports = { removeVote, testMarker };
