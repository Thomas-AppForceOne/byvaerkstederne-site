// @ts-check
'use strict';

/**
 * Account self-service — anonymous access control
 * (account_self_service_specification.md §10).
 *
 *   - anonymous GET /konto redirects to login (redirect_to_login) and never
 *     leaks page content;
 *   - anonymous POSTs to the mutation endpoints are refused with 401 under
 *     the internal (all-on) profile — the endpoint authn check IS the
 *     boundary, page frontmatter does not cover the /konto/<action> subpaths;
 *   - with the flag off (public-demo profile via Host header) the page and
 *     every endpoint are byte-indistinguishable from nonexistent routes
 *     (404, no feature leak).
 *
 * No credentials required — runs in anonymous-only mode.
 */

const { test, expect, request: apiRequest } = require('@playwright/test');
const path = require('path');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

const { port: PORT } = discoverGravEnv(path.resolve(__dirname, '..', '..'));
const BASE = `http://127.0.0.1:${PORT}`;

// Endpoint list grows as the account-manager work packages land.
const ACCOUNT_POST_ENDPOINTS = [
  '/konto/change-fullname',
  '/konto/change-password',
  '/konto/request-email-change',
  '/konto/resend-email-change',
  '/konto/cancel-email-change',
  '/konto/request-access',
  '/konto/cancel-access-request',
];

// Tokens a flag-off 404 body must never contain (feature-leak guard). The
// bare token 'konto' would false-positive on the nav link 'kontakt'. The
// requested PATH is deliberately not a token: the themed 404 echoes it (the
// login overlay's form action posts to the current path for any URL), which
// reveals nothing about the feature — the byte-equivalence test below is the
// authoritative no-leak check for the page route.
const LEAK_DENYLIST = ['Min konto', 'bv-account', 'change-fullname', 'change-password'];

function assertNoLeak(body, description) {
  const lower = body.toLowerCase();
  for (const token of LEAK_DENYLIST) {
    expect(
      lower.includes(token.toLowerCase()),
      `404 body for ${description} leaks token "${token}"`,
    ).toBe(false);
  }
}

test.describe('account self-service: anonymous access control', () => {
  test('anonymous GET /konto redirects to /login without leaking content', async ({ page }) => {
    await page.goto('/konto');
    await expect(page).toHaveURL(/\/login/);
    expect(await page.locator('.bv-account-section').count()).toBe(0);
  });

  test('the /konto redirect response itself carries no account markup', async () => {
    const ctx = await apiRequest.newContext({ baseURL: BASE });
    try {
      const resp = await ctx.get('/konto', { maxRedirects: 0 });
      expect(resp.status()).toBe(302);
      expect((resp.headers()['location'] || '')).toContain('/login');
      assertNoLeak(await resp.text(), 'GET /konto redirect');
    } finally {
      await ctx.dispose();
    }
  });

  test('anonymous POSTs to account endpoints are refused with 401', async () => {
    const ctx = await apiRequest.newContext({ baseURL: BASE });
    try {
      for (const endpoint of ACCOUNT_POST_ENDPOINTS) {
        const resp = await ctx.post(endpoint, { maxRedirects: 0 });
        expect(resp.status(), `expected 401 for anonymous POST ${endpoint}`).toBe(401);
      }
    } finally {
      await ctx.dispose();
    }
  });

  test.describe('flag off (public-demo profile)', () => {
    /** @type {import('@playwright/test').APIRequestContext} */
    let ctx;

    test.beforeAll(async () => {
      ctx = await apiRequest.newContext({
        baseURL: BASE,
        extraHTTPHeaders: { Host: 'test.hackersbychoice.dk' },
      });
    });

    test.afterAll(async () => {
      if (ctx) await ctx.dispose();
    });

    test('GET /konto is a 404 with no feature leak', async () => {
      const resp = await ctx.get('/konto', { maxRedirects: 0 });
      expect(resp.status()).toBe(404);
      assertNoLeak(await resp.text(), 'GET /konto (flag off)');
    });

    test('GET /konto 404 is byte-indistinguishable from a nonexistent route', async () => {
      // The themed 404 echoes the requested path (login-overlay form action,
      // register-CTA redirect param) for EVERY route, so equality modulo that
      // echo is the spec's "indistinguishable from a missing page" bar.
      const kontoResp = await ctx.get('/konto', { maxRedirects: 0 });
      const controlRoute = '/findes-slet-ikke';
      const controlResp = await ctx.get(controlRoute, { maxRedirects: 0 });
      expect(kontoResp.status()).toBe(404);
      expect(controlResp.status()).toBe(404);

      const normalize = (body, route) => body
        .split(encodeURIComponent(route)).join('%2FROUTE')
        .split(route).join('/ROUTE')
        // CSRF nonces, the Form plugin's per-render form id, and the theme's
        // per-second asset cache-buster (?v=<unix ts>) vary per request —
        // noise, not signal.
        .replace(/value="[0-9a-f]{32}"/g, 'value="NONCE"')
        .replace(/name="__unique_form_id__" value="[a-z0-9]+"/g, 'name="__unique_form_id__" value="FORMID"')
        .replace(/\?v=\d+/g, '?v=TS');
      expect(normalize(await kontoResp.text(), '/konto'))
        .toBe(normalize(await controlResp.text(), controlRoute));
    });

    for (const endpoint of ACCOUNT_POST_ENDPOINTS) {
      test(`POST ${endpoint} is a 404 with no feature leak`, async () => {
        const resp = await ctx.post(endpoint, { maxRedirects: 0 });
        expect(resp.status()).toBe(404);
        assertNoLeak(await resp.text(), `POST ${endpoint} (flag off)`);
      });
    }
  });
});
