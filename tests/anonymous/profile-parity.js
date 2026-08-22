// @ts-check
'use strict';

/**
 * Production-profile parity — the guard for "works on dev, broken on prod".
 *
 * WHAT WENT WRONG
 * ---------------
 * Event cards branch on the `event_rsvp` flag. With it ON (dev, test) the
 * card renders a working JS signup button. With it OFF (staging, prod) it
 * falls back to a link built in modular/event_list.html.twig:
 *
 *     href: '/begivenheder/' ~ key
 *
 * That route does not exist — `pages/begivenheder/` holds only the
 * organizer CRUD pages — so it 302s straight back to the calendar. Every
 * event on production had exactly one call to action and it was a link to
 * the page you were already on. Nobody could sign up for anything.
 *
 * WHY NOTHING CAUGHT IT
 * ---------------------
 * Three gaps lined up:
 *   1. The event fixture carried hardcoded ISO dates. They all drifted
 *      into the past, event_is_stale() filtered them, and the calendar
 *      rendered EMPTY in CI and on every laptop. Assertions about event
 *      cards were vacuous. (Fixed: the seed now carries @today±N tokens.)
 *   2. The flags-off profile WAS exercised — but only for absence: "the
 *      link is hidden", "the page 404s", "no HTML leak". Nothing asked
 *      whether what REMAINS is usable.
 *   3. Staging shares prod's flag profile but holds no events, so the
 *      fallback never rendered there either.
 *
 * So the combination "flag off + a rendered event card" — exactly what
 * production runs — had never executed anywhere.
 *
 * WHAT THIS FILE ASSERTS
 * ----------------------
 * Per flag profile, including the one production actually runs:
 *   • the calendar renders events at all          (kills gap 1 forever)
 *   • every card offers exactly one action        (no card is a no-op)
 *   • every link goes SOMEWHERE ELSE              (the general invariant)
 *
 * The third is deliberately generic. It is not "check /begivenheder" — it
 * is "a link whose target redirects back to the page it was rendered on is
 * a dead end", which catches this whole class without anyone having to
 * predict the next instance of it.
 */

const { test, expect, request: apiRequest } = require('@playwright/test');

/** Flag profiles resolved by Host header, per user/env/<host>/. */
const PROFILES = [
  {
    host: 'flags-off.invalid',
    label: 'production-shaped (all flags off)',
    // Prod and staging both resolve an all-off profile. This fixture host
    // is the committed stand-in — see env/flags-off.invalid/.
    rsvp: false,
  },
  {
    host: 'dev.hackersbychoice.dk',
    label: 'internal (all flags on)',
    rsvp: true,
  },
];

/** Pages whose links must all lead somewhere. Extend freely. */
const CRAWLED = ['/vaerkstedskalenderen', '/', '/vaerksteder'];

async function ctx(baseURL, host) {
  return apiRequest.newContext({
    baseURL,
    extraHTTPHeaders: { Host: host },
    ignoreHTTPSErrors: true,
  });
}

/** Internal hrefs on a page, minus fragments, mailto/tel and task links. */
function internalLinks(html) {
  const out = new Set();
  for (const m of html.matchAll(/href="(\/[^"#?]*)"/g)) {
    const href = m[1];
    if (!href || href === '/') continue;
    if (href.includes('task:')) continue; // logout etc. — side-effecting
    out.add(href);
  }
  return [...out];
}

for (const profile of PROFILES) {
  test.describe(`profile parity — ${profile.label}`, () => {
    let api;

    test.beforeAll(async ({ baseURL }) => {
      api = await ctx(/** @type {string} */ (baseURL), profile.host);
    });
    test.afterAll(async () => { await api?.dispose(); });

    test('the calendar renders events — the fixture has not rotted', async () => {
      const html = await (await api.get('/vaerkstedskalenderen')).text();
      const cards = html.match(/bv-event-row\b/g) || [];
      // The seed provides eight future events. Requiring several rather
      // than one means a fixture that quietly loses most of its entries
      // still fails, instead of limping along on the last survivor.
      expect(
        cards.length,
        'no event cards rendered — the seed is empty or its dates have gone stale, ' +
          'which makes every assertion below vacuous (that is how the dead signup ' +
          'link reached production)',
      ).toBeGreaterThanOrEqual(4);
    });

    test('every event card offers exactly one usable action', async () => {
      const html = await (await api.get('/vaerkstedskalenderen')).text();
      const rsvpButtons = (html.match(/data-rsvp-key="/g) || []).length;
      const ctaLinks = (html.match(/href="\/begivenheder\/ev[^"]*"/g) || []).length;

      if (profile.rsvp) {
        expect(rsvpButtons, 'RSVP on: cards must carry live signup buttons').toBeGreaterThan(0);
        expect(
          ctaLinks,
          'RSVP on: the static fallback link must not render alongside the button',
        ).toBe(0);
      } else {
        expect(
          rsvpButtons,
          'RSVP off: no live signup control should render',
        ).toBe(0);
        // No signup feature means no signup button. What must NOT happen is
        // a button that looks like one and does nothing — the state
        // production shipped in. An honest card with no action is correct;
        // the dead-end test below is what enforces the difference.
        expect(
          ctaLinks,
          'RSVP off: no card may link to /begivenheder/<key> — that route has no page ' +
            'and redirects back to the calendar, which is a signup button that cannot sign you up',
        ).toBe(0);
      }
    });

    for (const page of CRAWLED) {
      test(`no link on ${page} is a dead end`, async () => {
        const res = await api.get(page);
        expect(res.status(), `${page} must render`).toBe(200);
        const html = await res.text();

        /** @type {string[]} */
        const deadEnds = [];
        for (const href of internalLinks(html)) {
          const r = await api.get(href, { maxRedirects: 0 });
          const status = r.status();

          if (status === 200) continue;                 // resolves
          if (status === 404) continue;                 // flag-gated: hidden elsewhere
          if (status !== 301 && status !== 302) {
            deadEnds.push(`${href} → ${status}`);
            continue;
          }
          // A redirect is fine as long as it takes you somewhere NEW. A
          // link that bounces back to the page it was rendered on is, by
          // definition, an affordance that does nothing.
          const target = (r.headers()['location'] || '').replace(/^https?:\/\/[^/]+/, '');
          if (target.split('?')[0].replace(/\/$/, '') === page.replace(/\/$/, '')) {
            deadEnds.push(`${href} → ${status} → ${target} (tilbage til ${page})`);
          }
        }

        expect(
          deadEnds,
          `links on ${page} that lead nowhere — an affordance that returns the ` +
            'user to the page they were already on is broken, whatever it is labelled',
        ).toEqual([]);
      });
    }
  });
}
