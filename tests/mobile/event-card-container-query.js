// @ts-check
'use strict';

/**
 * Mobile — event-card container-query mechanism proof (sprint 1, step 9).
 *
 * Proves the container-query mechanism end-to-end: at a 1280 × 800
 * DESKTOP viewport (overrides the mobile-chromium project's default
 * 390 × 844), render the canonical .bv-event-item / .bv-event-row DOM
 * inside a deliberately narrow 360 px wrapper. The @container event-row
 * (max-width: 540px) rules MUST fire because the .bv-event-item's
 * width — not the viewport — crosses the breakpoint.
 *
 * Without the desktop-viewport override, this test would inherit the
 * mobile-chromium project's 390 × 844 default; 390 < 540 means the
 * container query would fire on viewport-as-container regardless of
 * mechanism — making the assertions meaningless as a container-query
 * proof. Sprint-1 contract criterion C12 verifies the override
 * statically via grep AND the runtime assertions.
 *
 * Three structural assertions:
 *   a) getComputedStyle(row).flexDirection === 'column'        — stacked
 *   b) row.querySelector('.bv-event-row__date-day').order === '-1' — DOM-order flip
 *   c) |cta.width − cta.parentElement.contentBox.width| <= 1 px — CTA full-width
 *
 * CSS is inlined here (the structural subset the assertions depend on)
 * so the test does not need to fetch /vaerkstedskalenderen — it proves
 * the MECHANISM, not the route.
 */

const { test, expect } = require('@playwright/test');

// Desktop viewport — the mobile-chromium project defaults to 390 × 844.
// The criterion-C12 static gate greps for width >= 1024 inside test.use.
test.use({ viewport: { width: 1280, height: 800 } });

// Structural CSS subset: tokens the partial needs + the .bv-event-list
// reset + the .bv-event-item container declaration + the .bv-event-row
// rules + the @container event-row (max-width: 540px) block. Verbatim
// from theme.css's /* Calendar */ section.
const CANONICAL_CSS = `
:root {
    --primary: #13483b;
    --secondary: #325f9b;
    --tertiary: #712800;
    --kulturhus: #27272a;
    --surface-container-lowest: #ffffff;
    --on-surface-variant: #42474a;
    --font-headline: 'Space Grotesk', sans-serif;
    --space-1: 0.25rem;
    --space-2: 0.5rem;
    --space-3: 0.75rem;
    --space-4: 1rem;
    --space-6: 1.5rem;
    --space-8: 2rem;
    --border-thick: 4px;
    --tracking-tight: -0.02em;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { font-family: system-ui, sans-serif; }
.bv-event-list { list-style: none; padding: 0; margin: 0; }
.bv-event-item { container-type: inline-size; container-name: event-row; }
.bv-event-row {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    padding: var(--space-6) var(--space-4);
    background: var(--surface-container-lowest);
    border-left: var(--border-thick) solid var(--bv-accent, var(--primary));
}
.bv-event-row__date {
    flex-shrink: 0; min-width: 4rem; text-align: center;
    font-family: var(--font-headline); font-weight: 700; line-height: 1;
    display: flex; flex-direction: column; align-items: center;
}
.bv-event-row__date-month { font-size: 0.75rem; }
.bv-event-row__date-day { font-size: 1.5rem; }
.bv-event-row__body { flex: 1; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-1); }
.bv-event-row__title { margin: 0; font-family: var(--font-headline); font-weight: 700; font-size: 1.25rem; }
.bv-event-row__meta {
    flex-shrink: 0; min-width: 9rem;
    display: flex; flex-direction: column; align-items: flex-end;
    gap: var(--space-2); text-align: right;
}
.bv-btn {
    display: inline-block;
    padding: var(--space-3) var(--space-6);
    font-family: var(--font-headline);
    font-weight: 700;
    text-transform: uppercase;
    background: var(--secondary);
    color: white;
    text-decoration: none;
    border: none;
    box-sizing: border-box;
}

@container event-row (max-width: 540px) {
    .bv-event-row { flex-direction: column; align-items: flex-start; gap: var(--space-3); }
    .bv-event-row__date { flex-direction: row; align-items: baseline; gap: var(--space-2); min-width: auto; text-align: left; }
    .bv-event-row__date-day { order: -1; font-size: 1.25rem; }
    .bv-event-row__date-month { font-size: 0.8rem; }
    .bv-event-row__body,
    .bv-event-row__meta { width: 100%; }
    .bv-event-row__meta { align-items: flex-start; text-align: left; margin-top: var(--space-2); }
    .bv-event-row__meta .bv-btn { width: 100%; }
}
`;

// Canonical event-card DOM as produced by partials/event_card.html.twig.
// The wrapper width is 360 px — narrower than the @container breakpoint
// 540 px — so the stacking rules MUST fire on the row's own width even
// at a 1280 × 800 viewport.
const SANDBOX_HTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>event-card container-query mechanism sandbox</title>
<style>${CANONICAL_CSS}</style>
</head>
<body>
<div id="wrapper" style="width: 360px;">
  <ul class="bv-event-list">
    <li class="bv-event-item" data-test="probe">
      <article class="bv-event-row" data-group="makerspace" style="--bv-accent: var(--secondary);">
        <div class="bv-event-row__date">
          <span class="bv-event-row__date-month">JUN</span>
          <span class="bv-event-row__date-day">10</span>
        </div>
        <div class="bv-event-row__body">
          <h3 class="bv-event-row__title">Probe — container-query mechanism</h3>
        </div>
        <div class="bv-event-row__meta">
          <a class="bv-btn bv-btn--secondary bv-btn--sm" href="#tilmeld">Tilmeld</a>
        </div>
      </article>
    </li>
  </ul>
</div>
</body>
</html>`;

test.describe('mobile-event-card-container-query', () => {
  test('container query fires on .bv-event-item at 360 px wrapper width regardless of 1280 × 800 viewport', async ({ page }) => {
    await page.setContent(SANDBOX_HTML);

    // Sanity: confirm the viewport really is 1280 px (the desktop
    // override stuck) — without this, the assertions below would be
    // satisfied trivially by viewport-as-container.
    const vp = page.viewportSize();
    expect(vp).not.toBeNull();
    expect(vp?.width, 'desktop-viewport override must hold; mobile-chromium default 390 < 540 would defeat the criterion').toBeGreaterThanOrEqual(1024);

    // a) flex-direction stacks to column.
    const flexDirection = await page.evaluate(() => {
      const row = document.querySelector('.bv-event-row');
      return row ? getComputedStyle(row).flexDirection : null;
    });
    expect(flexDirection, '@container event-row (max-width: 540px) → row { flex-direction: column }').toBe('column');

    // b) DOM-order flip: __date-day has order: -1, rendering as "10 JUN"
    //    even though the source DOM has JUN first.
    const dayOrder = await page.evaluate(() => {
      const day = document.querySelector('.bv-event-row__date-day');
      return day ? getComputedStyle(day).order : null;
    });
    expect(dayOrder, '@container event-row → __date-day { order: -1 }').toBe('-1');

    // c) CTA renders full-width inside the meta column. Geometric (not
    //    string-equal) per criterion C12: a percentage in the source
    //    style resolves to a pixel value, so compare bounding-box widths
    //    within ±1 px.
    const { ctaWidth, parentWidth } = await page.evaluate(() => {
      const cta = document.querySelector('.bv-event-row__meta .bv-btn');
      if (!cta) return { ctaWidth: 0, parentWidth: 0 };
      const parent = cta.parentElement;
      const cBox = cta.getBoundingClientRect();
      const pBox = parent.getBoundingClientRect();
      return { ctaWidth: cBox.width, parentWidth: pBox.width };
    });
    expect(
      Math.abs(ctaWidth - parentWidth),
      `CTA full-width inside meta column: |cta (${ctaWidth}) − parent (${parentWidth})| <= 1 px`,
    ).toBeLessThanOrEqual(1);
  });

  test('no horizontal overflow inside the 360 px wrapper', async ({ page }) => {
    // Failure-path guard from the source spec's container-query test:
    // the stacked row must not push its bounding box past the wrapper's
    // right edge.
    await page.setContent(SANDBOX_HTML);

    const { scrollWidth, clientWidth } = await page.evaluate(() => {
      const wrapper = /** @type {HTMLElement} */ (document.getElementById('wrapper'));
      return { scrollWidth: wrapper.scrollWidth, clientWidth: wrapper.clientWidth };
    });
    expect(scrollWidth, 'stacked .bv-event-row must not overflow its 360 px wrapper').toBeLessThanOrEqual(clientWidth + 0.5);
  });
});
