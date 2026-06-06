// @ts-check
'use strict';

/**
 * Mobile-rendering — event rows.
 *
 * Covers two visible defects from the user's iPhone report:
 *   Screenshot 4: on workshop sub-pages the right-hand drop-in pill /
 *     "Tilmeld" button overflowed the row's right edge — "DRO", "Ing",
 *     "tilmeld" letters cut at the viewport edge.
 *   Screenshot 2: long Danish workshop titles ("TEGN OG SNIT ET
 *     GUMMISTEMPEL" — represented in the seeded begivenheder.yaml data as
 *     "Billedkunst — gummistempel intro v. Elsebeth") hugged the card's
 *     right edge with no breathing room.
 *
 * Probing strategy
 * ----------------
 * The seeded begivenheder.yaml events all wrap cleanly at whitespace at
 * 390 px, and the longest seeded button text ("SMS Bitten 22 39 54 80")
 * is short enough that, even on baseline CSS, the .bv-event-row__meta
 * width:100% + flex-wrap:wrap path keeps it inside the row. To make the
 * mobile-event-row-no-right-overflow test demonstrate the actual fix,
 * we inject a deterministic high-overflow probe row into the live DOM
 * after navigation — a .bv-event-row whose embedded .bv-btn carries a
 * long unbreakable token that mirrors the contact-format CTAs the
 * screenshot reported overflowing ("SMS Bitten 22 39 54 80" became
 * "DRO" / "Ing" / "tilmeld" letters at the viewport edge). On baseline
 * CSS the injected button is wider than the row; on the new CSS,
 * .bv-event-row__meta .bv-btn { max-width:100%; overflow-wrap:anywhere }
 * lets it wrap inside the row.
 *
 * Long-title probing follows the same pattern for the same reason — the
 * seeded "Billedkunst — gummistempel intro v. Elsebeth" wraps at
 * whitespace at 390 px and never exercises the new overflow-wrap rule.
 * The injected probe title is a 30-character no-space token; on baseline
 * it overflows the body content-box, on HEAD it breaks mid-token because
 * the new CSS sets overflow-wrap:anywhere on .bv-event-row__title.
 */

const { test, expect } = require('@playwright/test');
const { useDevHost } = require('./_helpers');

const ROUTE = '/vaerkstedskalenderen';

// Injected probe rows. Each row mirrors the live event_list.html.twig markup
// exactly so the same .bv-event-row CSS cascade applies. Unique data-test
// hooks let the assertions target the probe rows specifically.

// Long unbreakable token used to force the right-overflow on baseline. The
// .bv-btn renders inside a flex parent (meta) as a block-level item with
// padding, letter-spacing:0.1em and text-transform:uppercase. At 0.875rem
// the rendered width of a 40-char no-space token comfortably exceeds the
// meta column's 322 px content box on a 390 px viewport, so the button's
// right edge falls outside the row's right edge. Only the new
// .bv-event-row__meta .bv-btn rule (max-width:100%; overflow-wrap:anywhere)
// breaks the token so the button stays inside.
const OVERFLOW_BTN_TEXT = 'SMSBITTENABCDEFGHIJKLMNOPQRSTUVWXYZABCDE';

// Long unbreakable title token for the long-title test. Same 35-char shape;
// without overflow-wrap:anywhere on the title element this text renders as
// one unbreakable run that pushes the title's right edge past the body
// content-box on a 390 px viewport.
const OVERFLOW_TITLE_TEXT = 'TEGNOGSNITGUMMISTEMPELXYZABCDEFGHIJ';

/**
 * Inject a deterministic .bv-event-row into the live event-list page so
 * the no-right-overflow probe has a row whose meta column carries an
 * unbreakable CTA token. The markup mirrors event_list.html.twig exactly
 * so the cascade picks up the same selectors.
 *
 * @param {import('@playwright/test').Page} page
 */
async function injectOverflowProbeRow(page, btnText) {
  await page.evaluate((t) => {
    const host = document.querySelector('section.bv-section--sm .bv-container');
    if (!host) throw new Error('event-list section.bv-section--sm .bv-container not found');
    const row = document.createElement('div');
    row.className = 'bv-event-row bv-event-row--secondary';
    row.setAttribute('data-test', 'gen-b-overflow-probe');
    row.innerHTML = `
      <div class="bv-event-row__date" style="color: var(--primary);">
        <div class="bv-event-row__date-month">June</div>
        <div class="bv-event-row__date-day">28</div>
      </div>
      <div class="bv-event-row__body">
        <div class="bv-event-row__title">Probe</div>
        <div class="bv-event-row__desc">Synthetic row to lock down the .bv-event-row__meta .bv-btn overflow fix.</div>
      </div>
      <div class="bv-event-row__meta">
        <a href="#" class="bv-btn bv-btn--secondary bv-btn--sm">${t}</a>
      </div>
    `;
    host.appendChild(row);
  }, btnText);
}

/**
 * Inject a deterministic long-title .bv-event-row whose title is a 30-char
 * no-space token, mirroring the screenshot-2 defect ("TEGN OG SNIT ET
 * GUMMISTEMPEL" cropped against the right edge with no breathing room).
 *
 * @param {import('@playwright/test').Page} page
 */
async function injectLongTitleProbeRow(page, titleText) {
  await page.evaluate((t) => {
    const host = document.querySelector('section.bv-section--sm .bv-container');
    if (!host) throw new Error('event-list section.bv-section--sm .bv-container not found');
    const row = document.createElement('div');
    row.className = 'bv-event-row bv-event-row--tertiary';
    row.setAttribute('data-test', 'gen-b-longtitle-probe');
    row.innerHTML = `
      <div class="bv-event-row__date" style="color: var(--primary);">
        <div class="bv-event-row__date-month">July</div>
        <div class="bv-event-row__date-day">02</div>
      </div>
      <div class="bv-event-row__body">
        <div class="bv-event-row__title">${t}</div>
      </div>
      <div class="bv-event-row__meta">
        <a href="#" class="bv-btn bv-btn--tertiary bv-btn--sm">Tilmeld</a>
      </div>
    `;
    host.appendChild(row);
  }, titleText);
}

test.describe('Mobile — event rows (screenshots 2, 3, 4)', () => {
  test.beforeEach(async ({ page }) => { await useDevHost(page); });

  test('mobile-event-row-no-right-overflow', async ({ page }) => {
    const response = await page.goto(ROUTE);
    expect(response?.status()).toBe(200);

    // Inject the deterministic overflow-probe row before measuring. The
    // seeded begivenheder.yaml CTAs all fit the meta column on baseline
    // CSS too — they have whitespace between tokens and short enough
    // total widths that the existing flex-wrap path keeps them inside
    // the row even without the fix. The injected row carries a CTA token
    // wide enough that only the new .bv-event-row__meta .bv-btn rule
    // (max-width:100%; overflow-wrap:anywhere) can keep its right edge
    // inside the row.
    await injectOverflowProbeRow(page, OVERFLOW_BTN_TEXT);

    const rows = page.locator('.bv-event-row');
    const count = await rows.count();
    expect(count, `expected at least one .bv-event-row on ${ROUTE}`).toBeGreaterThan(0);

    // 0.5 px tolerance for sub-pixel rounding; the contract's wording is
    // "at or inside" the row's right edge.
    const TOL = 0.5;

    for (let i = 0; i < count; i += 1) {
      const row = rows.nth(i);
      if (!(await row.isVisible())) continue;
      const rowBox = await row.boundingBox();
      if (!rowBox) continue;
      const rowRight = rowBox.x + rowBox.width;

      // Probe every direct-child and the inner CTA/capacity span. The
      // contract names: .bv-event-row__meta, embedded .bv-btn,
      // capacity span, .bv-event-row__body.
      const childSelectors = [
        '.bv-event-row__date',
        '.bv-event-row__body',
        '.bv-event-row__meta',
        '.bv-event-row__meta .bv-btn',
        '.bv-event-row__capacity',
      ];

      for (const sel of childSelectors) {
        const child = row.locator(sel);
        const cn = await child.count();
        for (let j = 0; j < cn; j += 1) {
          const c = child.nth(j);
          if (!(await c.isVisible())) continue;
          const box = await c.boundingBox();
          if (!box) continue;
          const childRight = box.x + box.width;
          expect(
            childRight,
            `row ${i} ${sel}[${j}] right (${childRight}) must not exceed row right (${rowRight})`
          ).toBeLessThanOrEqual(rowRight + TOL);
        }
      }
    }
  });

  test('mobile-event-row-long-title-respects-padding — long title respects right padding', async ({ page }) => {
    await page.goto(ROUTE);

    // The seeded "Billedkunst — gummistempel intro v. Elsebeth" wraps at
    // whitespace at 390 px on both the base ref and HEAD, so the
    // geometric breathing-room / content-box assertions hold even when
    // the new overflow-wrap:anywhere rule is absent (independent review
    // F2 + F3). Inject a deterministic 30-character no-space token so the
    // geometric assertions actually exercise the wrap fix.
    await injectLongTitleProbeRow(page, OVERFLOW_TITLE_TEXT);

    // Pick the injected probe row first; fall back to the seeded
    // gummistempel row only if the inject failed (defensive).
    const candidate = page.locator('.bv-event-row[data-test="gen-b-longtitle-probe"]').first();
    await expect(
      candidate,
      'injected long-title probe row must be present after DOM injection'
    ).toBeVisible();

    const body = candidate.locator('.bv-event-row__body');
    const title = candidate.locator('.bv-event-row__title');

    const bodyBox = await body.boundingBox();
    const titleBox = await title.boundingBox();
    expect(bodyBox).not.toBeNull();
    expect(titleBox).not.toBeNull();
    if (!bodyBox || !titleBox) return;

    // C3: (body.right - title.right) >= 8 px AND every line right edge
    // <= body content-box right (body.right - paddingRight). We approximate
    // "every line" by the title element's rendered border box right — for
    // a wrapped block element, that border box right IS the max line right.
    const bodyRight = bodyBox.x + bodyBox.width;
    const titleRight = titleBox.x + titleBox.width;

    const paddingRight = await body.evaluate((el) => parseFloat(getComputedStyle(el).paddingRight) || 0);
    const bodyContentRight = bodyRight - paddingRight;

    expect(
      bodyRight - titleRight,
      `long-title row: body.right - title.right = ${bodyRight - titleRight}, expected >= 8 px breathing room`
    ).toBeGreaterThanOrEqual(8 - 0.5);

    expect(
      titleRight,
      `long-title row: title.right (${titleRight}) must be inside body content-box right (${bodyContentRight})`
    ).toBeLessThanOrEqual(bodyContentRight + 0.5);

    // Word-break guard: at least one of overflow-wrap or word-break must be
    // set to a value that lets long Danish tokens break mid-word. This
    // pins the fix so a future refactor can't silently revert.
    const wrap = await title.evaluate((el) => {
      const s = getComputedStyle(el);
      return { overflowWrap: s.overflowWrap, wordBreak: s.wordBreak };
    });
    const breakable =
      wrap.overflowWrap === 'anywhere' ||
      wrap.overflowWrap === 'break-word' ||
      wrap.wordBreak === 'break-word' ||
      wrap.wordBreak === 'break-all';
    expect(breakable, `long-title row: overflow-wrap or word-break must allow mid-word breaks (got ${JSON.stringify(wrap)})`).toBe(true);
  });
});
