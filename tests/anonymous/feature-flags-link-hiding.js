// @ts-check
'use strict';

/**
 * Per-flag link-hiding audit.
 *
 * Design intent (from product owner): when a feature flag is OFF, no
 * control anywhere on the site may link to that feature's routes — not
 * just nav/footer, but page-body CTAs, hero buttons, module tiles,
 * overlay content, in-page anchors, everything.
 *
 * Existing specs cover:
 *   - feature-flags-pages.js — direct GET of gated URLs returns 404.
 *   - feature-flags-html.js  — nav/footer anchors are absent.
 *   - feature-flags-plugins.js — POST endpoints 404 under public-demo.
 *
 * Gap that this spec closes: page-body links emitted by modular
 * templates (home hero, workgroup cards, CTA sections, login-overlay
 * "opret medlemskab" link, etc.) were not asserted against. This spec
 * crawls every page reachable under public-demo as anonymous and
 * asserts that NO href or action attribute anywhere in the response
 * points to a route belonging to a disabled flag.
 *
 * One test per flag; each test names the flag in its title so a
 * failure points directly at the feature whose links are leaking.
 *
 * Internal profile is NOT checked here — those pages render fully and
 * are expected to link to flagged routes. This spec is a public-demo
 * leak audit.
 */

const { test, expect, request: apiRequest } = require('@playwright/test');
const { execSync } = require('child_process');
const path = require('path');
const {
  discoverGravEnv,
} = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

const WORKTREE = path.resolve(__dirname, '..', '..');
const { port: PORT, container: CONTAINER } = discoverGravEnv(WORKTREE);
const BASE = `http://127.0.0.1:${PORT}`;

function clearGravCache() {
  execSync(`docker exec -u abc -w /app/www/public ${CONTAINER} bin/grav clearcache`, {
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 30_000,
  });
}

/**
 * Every page that renders 200 under public-demo as an anonymous
 * visitor. If a page is missing from this list, the link audit won't
 * catch leaks rendered on it.
 */
const CRAWL_URLS = [
  '/',
  '/vaerksteder',
  '/privatlivspolitik',
  '/login',
  '/forgot_password',
];

/**
 * Flag → list of route prefixes that must NOT appear as link targets
 * anywhere in the crawled pages when the flag is off.
 *
 * A "route prefix" matches the start of an href/action path; we use
 * `^prefix(?:[/?#]|$)` so `/roadmap` matches `/roadmap`, `/roadmap/`,
 * `/roadmap?x=1`, but NOT `/roadmap-unrelated`.
 *
 * Flags with no route surface (e.g. community_footer_column,
 * event_highlight) are intentionally omitted — they are covered by
 * feature-flags-html.js DOM-class absence assertions instead.
 */
const FLAG_ROUTES = {
  roadmap: ['/roadmap'],
  feature_suggestion: ['/foreslaa-feature', '/feature-suggestion'],
  bug_report: ['/bug-report', '/bug-report-submit'],
  membership_signup: ['/opret-medlemskab'],
  press_page: ['/presse'],
  minutes_archive: ['/referater'],
  workshop_calendar: ['/vaerkstedskalenderen'],
  workshop_detail_pages: [
    '/vaerksteder/makerspace',
    '/vaerksteder/kreativ-fitness',
    '/vaerksteder/kulturhus',
    '/vaerksteder/det-groenne-faellesskab',
  ],
  contact_page: ['/kontakt'],
  statutes_page: ['/vedtaegter'],
};

/** Extract every href/action path from a response body. */
function extractAllTargets(body) {
  const out = [];
  const re = /\b(?:href|action)\s*=\s*"([^"]+)"/gi;
  let m;
  while ((m = re.exec(body)) !== null) {
    out.push(m[1]);
  }
  return out;
}

/** Build a regex that matches a route prefix at the start of a path. */
function prefixRe(prefix) {
  const escaped = prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  // Allow a fully-qualified URL or a bare path. We only care about the
  // path portion — scheme+host is stripped by comparing the trailing
  // substring. Anchor on either `"/prefix"` or `://host/prefix`.
  return new RegExp(`(?:^|://[^/]+)${escaped}(?:[/?#]|$)`);
}

async function profileContext(host) {
  return await apiRequest.newContext({
    baseURL: BASE,
    extraHTTPHeaders: { Host: host },
    ignoreHTTPSErrors: true,
  });
}

/**
 * Fetch every CRAWL_URL under public-demo and return an array of
 * { url, targets[] } tuples.
 */
async function crawlPublicDemo(ctx) {
  const results = [];
  for (const url of CRAWL_URLS) {
    const resp = await ctx.get(url, { maxRedirects: 0 });
    if (resp.status() !== 200) {
      throw new Error(`crawl URL ${url} did not 200 under public-demo (got ${resp.status()})`);
    }
    results.push({ url, targets: extractAllTargets(await resp.text()) });
  }
  return results;
}

test.describe('feature-flags link-hiding audit: public-demo must not link to any disabled route', () => {
  /** @type {import('@playwright/test').APIRequestContext} */
  let ctx;
  /** @type {Array<{url: string, targets: string[]}>} */
  let pages;

  test.beforeAll(async () => {
    clearGravCache();
    ctx = await profileContext('public-demo.example.com');
    pages = await crawlPublicDemo(ctx);
  });

  test.afterAll(async () => {
    if (ctx) await ctx.dispose();
  });

  for (const [flag, routes] of Object.entries(FLAG_ROUTES)) {
    test(`flag=${flag}: zero links to ${routes.join(', ')} anywhere on public-demo`, () => {
      const leaks = [];
      for (const route of routes) {
        const re = prefixRe(route);
        for (const { url, targets } of pages) {
          for (const t of targets) {
            if (re.test(t)) {
              leaks.push(`  on ${url}: ${t}`);
            }
          }
        }
      }
      expect(
        leaks,
        `flag=${flag} is disabled on public-demo but ${leaks.length} link(s) still point at ${routes.join(', ')}:\n${leaks.join('\n')}`
      ).toHaveLength(0);
    });
  }
});
