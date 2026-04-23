// @ts-check
'use strict';

/**
 * Feature-flag page-gate coverage.
 *
 * Profile-switching mechanism (scoped to THIS spec only — no changes to
 * playwright.config.js):
 *
 *   Grav's env-switch reads the HTTP_HOST header to pick a profile dir
 *   under config/www/user/env/. Chromium refuses to let page.goto() set
 *   the Host header (ERR_INVALID_ARGUMENT — forbidden by the Fetch spec),
 *   so we use playwright.request.newContext({ extraHTTPHeaders: { Host }})
 *   instead. APIRequestContext is Node-level; it passes Host through to
 *   the server verbatim, which is exactly what the Grav env-switch needs.
 *
 *   Host 'staging.example.com'       -> PROFILE=internal   (all 17 flags "true")
 *   Host 'public-demo.example.com'   -> PROFILE=public_demo (0 flags enabled)
 *
 *   Other specs continue to hit 127.0.0.1 directly and resolve to whatever
 *   default profile the Grav container ships — unchanged by this spec.
 *
 * Cache discipline:
 *   Every profile switch (and therefore every describe block's beforeAll)
 *   runs `docker exec -w /app/www/public <container> bin/grav clearcache`
 *   so the test reflects the post-clear rendering. The `-w /app/www/public`
 *   working-directory flag is mandatory on the linuxserver/grav image
 *   (its default WORKDIR is `/`, which does not contain `bin/grav`).
 */

const { test, expect, request: apiRequest } = require('@playwright/test');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const {
  discoverGravEnv,
} = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

// Resolve port + container for this worktree through the single shared
// chain. Throws loud if the worktree's container isn't running — no
// silent fallback to :8080 or to a stray 'grav' container, which was
// the Sprint-5 regression vector.
const WORKTREE = path.resolve(__dirname, '..', '..');
const { port: PORT, container: CONTAINER } = discoverGravEnv(WORKTREE);
const BASE = `http://127.0.0.1:${PORT}`;

/**
 * Clear Grav cache INSIDE the container. The `-w /app/www/public` flag is
 * required; without it the linuxserver/grav image's default WORKDIR ("/")
 * is inherited and `bin/grav` resolves to nothing.
 */
function clearGravCache() {
  execSync(`docker exec -w /app/www/public ${CONTAINER} bin/grav clearcache`, {
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 30_000,
  });
}

/**
 * Ensure at least one admin account exists in the worktree-scoped Grav
 * container. Without one, Grav's admin plugin intercepts every route with
 * its "Register Admin User" page and our 404 assertions fail spuriously.
 *
 * The shared tests/global-setup.js uses the literal "grav" container
 * (primary :8080 dev instance) — it does not seed the worktree container
 * a GAN run brings up via scripts/grav-up.sh. This helper closes that gap.
 * Idempotent: if the account YAML already exists we skip the docker exec.
 *
 * Credentials are sourced from ~/.gan-secrets/workshop-site.env per
 * CLAUDE.md; if absent we skip without failing.
 */
function seedAdminIfPossible() {
  const adminPw = process.env.TEST_ADMIN_PASSWORD;
  if (!adminPw) return;
  const { execFileSync } = require('child_process');
  // Check container-side whether the account is already provisioned.
  try {
    execFileSync(
      'docker',
      ['exec', CONTAINER, 'test', '-f', '/app/www/public/user/accounts/pw-test-admin.yaml'],
      { stdio: ['ignore', 'pipe', 'pipe'] }
    );
    return; // already exists
  } catch (_) {
    // file missing — create the account
  }
  try {
    execFileSync(
      'docker',
      [
        'exec', '-w', '/app/www/public', CONTAINER,
        'bin/plugin', 'login', 'new-user',
        '-u', 'pw-test-admin',
        '-p', adminPw,
        '-e', 'pw-test-admin@example.invalid',
        '-N', 'Playwright Test Admin',
        '-l', 'en',
        '-t', 'Admin',
        '-P', 'b',
        '-s', 'enabled',
        '-n',
      ],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000 }
    );
  } catch (err) {
    // Non-fatal — any test that actually needs the admin will surface
    // the failure downstream with a clear error message.
    console.warn(`feature-flags-pages: admin seed failed (non-fatal): ${err && err.message}`);
  }
}

// URLs that are gated in public-demo and open in internal.
const GATED_URLS = [
  '/roadmap',
  '/foreslaa-feature',
  '/opret-medlemskab',
  '/presse',
  '/referater',
  '/vaerkstedskalenderen',
  '/kontakt',
  '/vedtaegter',
  '/privatlivspolitik',
  '/vaerksteder/makerspace', // representative workshop detail subpage
];

// Distinctive title text that must NOT leak in a 404 body for each URL.
const LEAK_STRINGS = {
  '/roadmap': 'Website Roadmap',
  '/foreslaa-feature': 'Foreslå ny Feature',
  '/opret-medlemskab': 'Opret Medlemskab',
  '/presse': 'Presse',
  '/referater': 'Referater',
  '/vaerkstedskalenderen': 'Værkstedskalenderen',
  '/kontakt': 'Kontakt',
  '/vedtaegter': 'Vedtægter',
  '/privatlivspolitik': 'Privatlivspolitik',
  '/vaerksteder/makerspace': 'Makerspace',
};

/** Build an APIRequestContext that forces a specific Host header. */
async function profileContext(host) {
  return await apiRequest.newContext({
    baseURL: BASE,
    extraHTTPHeaders: { Host: host },
    // Do NOT follow the rare login redirect to a different host — we want
    // to observe the status code of the flagged URL itself.
    ignoreHTTPSErrors: true,
  });
}

test.describe('feature-flags: public-demo profile 404s flagged pages', () => {
  /** @type {import('@playwright/test').APIRequestContext} */
  let ctx;

  test.beforeAll(async () => {
    seedAdminIfPossible();
    clearGravCache();
    ctx = await profileContext('public-demo.example.com');
  });

  test.afterAll(async () => {
    if (ctx) await ctx.dispose();
  });

  for (const url of GATED_URLS) {
    test(`GET ${url} returns 404 under public-demo`, async () => {
      const resp = await ctx.get(url, { maxRedirects: 0 });
      expect(resp.status(), `expected 404 for ${url}`).toBe(404);

      // Leak check — disabled feature must not betray its existence via
      // the main content area (page heading). Navigation and footer are
      // Sprint-3 concerns and will be gated there; Sprint 2 only asserts
      // that the 404 response does not render the disabled page's own
      // hero/heading content. We check that the page's title does NOT
      // appear inside an <h1> or <h2> — the Grav 404 template itself
      // renders <h1>404</h1><h2>Page not Found</h2>, so any additional
      // heading-text match would indicate content leakage.
      const body = await resp.text();
      const leak = LEAK_STRINGS[url];
      if (leak) {
        const headingRe = new RegExp(
          `<h[12][^>]*>[^<]*${leak.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^<]*<\\/h[12]>`,
          'i'
        );
        expect(
          headingRe.test(body),
          `404 body for ${url} leaks title "${leak}" in a page heading`
        ).toBe(false);
      }
    });
  }

  test('/vaerksteder grid does not link to gated subpages under public-demo', async () => {
    const resp = await ctx.get('/vaerksteder');
    expect(resp.status()).toBe(200);
    const body = await resp.text();
    // Scope to the workgroups grid only — other link surfaces (footer,
    // nav) are Sprint-3's concern. Match the <div class="bv-workgroups">
    // wrapper and extract just that section.
    const gridMatch = body.match(
      /<div class="bv-workgroups"[^>]*>([\s\S]*?)<\/div>\s*<\/div>\s*<\/section>/
    );
    expect(gridMatch, 'expected workgroups grid container in response').not.toBeNull();
    const grid = gridMatch[1];
    const disabledHrefRe =
      /href="[^"]*\/vaerksteder\/(det-groenne-faellesskab|kreativ-fitness|kulturhus|makerspace)[^"]*"/g;
    const matches = grid.match(disabledHrefRe) || [];
    expect(
      matches,
      'public-demo workgroups grid must not link to gated subpages'
    ).toHaveLength(0);
  });
});

test.describe('feature-flags: internal profile renders flagged pages', () => {
  /** @type {import('@playwright/test').APIRequestContext} */
  let ctx;

  test.beforeAll(async () => {
    seedAdminIfPossible();
    clearGravCache();
    ctx = await profileContext('staging.example.com');
  });

  test.afterAll(async () => {
    if (ctx) await ctx.dispose();
  });

  for (const url of GATED_URLS) {
    test(`GET ${url} is reachable under internal`, async () => {
      const resp = await ctx.get(url, { maxRedirects: 0 });
      const status = resp.status();
      // Accept 200 or a 301/302 redirect to a canonical URL (e.g., an
      // auth-protected route like /roadmap that bounces to a login page).
      expect(
        [200, 301, 302].includes(status),
        `expected 200/301/302 for ${url}, got ${status}`
      ).toBe(true);
    });
  }

  test('/vaerksteder grid links to subpages under internal', async () => {
    const resp = await ctx.get('/vaerksteder');
    expect(resp.status()).toBe(200);
    const body = await resp.text();
    const gridMatch = body.match(
      /<div class="bv-workgroups"[^>]*>([\s\S]*?)<\/div>\s*<\/div>\s*<\/section>/
    );
    expect(gridMatch, 'expected workgroups grid container in response').not.toBeNull();
    const grid = gridMatch[1];
    const disabledHrefRe =
      /href="[^"]*\/vaerksteder\/(det-groenne-faellesskab|kreativ-fitness|kulturhus|makerspace)[^"]*"/g;
    const matches = grid.match(disabledHrefRe) || [];
    expect(
      matches.length,
      'internal workgroups grid must link to at least one workshop subpage'
    ).toBeGreaterThanOrEqual(1);
  });
});
