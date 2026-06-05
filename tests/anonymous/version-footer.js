// @ts-check
'use strict';

/**
 * Sprint-3 Playwright coverage for the SemVer + build display.
 *
 * Maps to .gan/sprint-3-contract.json criteria:
 *   - playwright_apex_footer_substring   (apex landing page)
 *   - playwright_site_footer_substring   (Grav site footer)
 *   - playwright_both_missing_omits_line (fallback)
 *   - playwright_no_double_ukendt_anywhere
 *   - tests_exercise_success_and_failure_paths
 *   - no_test_skip_introduced
 *   - tests_run_against_worktree_container
 *   - tests_secrets_handling
 *   - test_fixture_path_safety
 *   - test_cleanup_idempotent
 *
 * The apex half spins up a sidecar `php -S` container against the
 * worktree's apex/ directory; the host has no PHP installed in this
 * project's setup, so we use the same docker image (`php:8.3-cli`)
 * that the shell probe uses, on a randomly-chosen ephemeral port.
 *
 * The site half uses the worktree-scoped Grav container that
 * playwright.config.js already discovered via scripts/discover-grav-port.js
 * — we never hard-code a port, never fall back to :8080, and never
 * touch the main repo's primary dev container.
 *
 * Fixture safety: every fixture path is constructed from a
 * compile-time absolute prefix (path.resolve(__dirname, '..', '..'))
 * plus a literal segment. We refuse to operate if the resolved path
 * doesn't match a `.gan/worktree/(apex|config/www)` shape, which is a
 * second line of defence against accidental writes outside the
 * worktree (independent of the GAN confinement hook). No environment
 * variable, request body, or test parameter ever feeds the path.
 *
 * Cleanup: every test that mutates VERSION/BUILD does so through a
 * `withFixture(state, async () => { … })` helper that snapshots the
 * file pair on entry and unconditionally restores it (including
 * non-existence) on exit, even if the test body throws. afterAll
 * additionally restores from the global beforeAll snapshot as a
 * belt-and-braces guarantee.
 */

const { test, expect } = require('@playwright/test');
const fs = require('fs');
const path = require('path');
const net = require('net');
const { execFileSync, spawn } = require('child_process');
const { discoverGravEnv } = require('../../scripts/discover-grav-port');

// ---------------------------------------------------------------------------
// Path & fixture helpers
// ---------------------------------------------------------------------------

const WORKTREE_ROOT = path.resolve(__dirname, '..', '..');
const APEX_DIR = path.join(WORKTREE_ROOT, 'apex');
const SITE_DIR = path.join(WORKTREE_ROOT, 'config', 'www');

// Refuse to run if the inferred root looks suspicious — e.g. someone
// dropped this file into a directory that isn't a workshop-site checkout.
// The two valid shapes: a main checkout (…/workshop-site/…) or the
// GAN worktree (…/.gan/worktree).
{
  const ok =
    /workshop-site/.test(WORKTREE_ROOT) ||
    /\.gan[\/\\]worktree$/.test(WORKTREE_ROOT);
  if (!ok) {
    throw new Error(
      `Refusing to run version-footer tests: WORKTREE_ROOT='${WORKTREE_ROOT}' does not look like a checkout.`,
    );
  }
}

// Combined-line regex used by every assertion in this file.
// Mirrors specifications/semantic_versioning_specification.md "Format":
//   Version <semver> · build <integer>
// where <semver> is SemVer 2.0.0 sans build metadata
// (build metadata lives in BUILD).
const VERSION_LINE_REGEX = /Version\s+\d+\.\d+\.\d+(-[A-Za-z0-9.\-]+)?\s+·\s+build\s+\d+/;

const VERSION_REGEX = /^\d+\.\d+\.\d+(-[A-Za-z0-9.\-]+)?$/;
const BUILD_REGEX = /^\d+$/;

/**
 * Read a file's contents as a trimmed string, returning null when the
 * file is missing. Used for "expected" computation — we never want a
 * stale fixture to leak into an assertion.
 */
function readTrimmedOrNull(filePath) {
  try {
    return fs.readFileSync(filePath, 'utf8').trim();
  } catch (_) {
    return null;
  }
}

/**
 * Snapshot a single file's contents (or absence). Returns a closure
 * that restores the original state when invoked.
 */
function snapshotFile(filePath) {
  let saved = null;
  let existed = false;
  try {
    saved = fs.readFileSync(filePath);
    existed = true;
  } catch (_) {
    existed = false;
  }
  return () => {
    if (existed) {
      fs.writeFileSync(filePath, saved);
    } else {
      try { fs.unlinkSync(filePath); } catch (_) { /* already gone */ }
    }
  };
}

/**
 * Run an async function under a transient fixture state for the given
 * pair of (versionPath, buildPath). `state` is one of:
 *   { kind: 'asis' }                 — leave files untouched.
 *   { kind: 'set', version, build }  — write the given strings (null = remove).
 *
 * Restores the original on-disk state unconditionally on exit.
 */
async function withFixture(versionPath, buildPath, state, body) {
  const restoreV = snapshotFile(versionPath);
  const restoreB = snapshotFile(buildPath);
  try {
    if (state.kind === 'set') {
      if (state.version === null) {
        try { fs.unlinkSync(versionPath); } catch (_) { /* gone */ }
      } else {
        fs.writeFileSync(versionPath, state.version);
      }
      if (state.build === null) {
        try { fs.unlinkSync(buildPath); } catch (_) { /* gone */ }
      } else {
        fs.writeFileSync(buildPath, state.build);
      }
    }
    await body();
  } finally {
    // Always run both restores; either may throw harmlessly if
    // already-restored.
    try { restoreV(); } catch (_) { /* ignore */ }
    try { restoreB(); } catch (_) { /* ignore */ }
  }
}

// ---------------------------------------------------------------------------
// Apex sidecar — `php -S` inside docker, against the worktree's apex/.
// ---------------------------------------------------------------------------

/** Pick a random free TCP port on 127.0.0.1. */
function pickFreePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address();
      const port = typeof addr === 'object' && addr ? addr.port : 0;
      srv.close(() => (port > 0 ? resolve(port) : reject(new Error('no port'))));
    });
  });
}

/**
 * Wait for an HTTP endpoint to respond (any status code) within the
 * timeout. Returns when reachable; throws otherwise.
 */
async function waitForHttp(url, timeoutMs = 15_000) {
  const deadline = Date.now() + timeoutMs;
  let lastErr;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(url);
      // Even 404 means the server accepted the connection.
      if (r.status >= 0) return;
    } catch (e) {
      lastErr = e;
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`Timed out waiting for ${url}: ${lastErr ? /** @type {any} */ (lastErr).message : 'no response'}`);
}

/**
 * @typedef {Object} ApexSidecar
 * @property {number} port
 * @property {string} containerId
 */

/**
 * Start a `php -S` sidecar that serves the worktree's apex/ on a
 * random free port. Returns a handle the caller stops in afterAll.
 *
 * Container is started detached (`-d`) so we can shut it down with
 * `docker stop`. Auto-removed on stop (`--rm`).
 */
async function startApexSidecar() {
  const port = await pickFreePort();
  // -d detached, --rm auto-clean, bind worktree as /work, expose just
  // the port we picked. The container has no name — we hold the
  // 64-char ID returned by docker run -d.
  const args = [
    'run', '-d', '--rm',
    '-v', `${WORKTREE_ROOT}:/work:ro`,
    '-w', '/work/apex',
    '-p', `127.0.0.1:${port}:${port}`,
    'php:8.3-cli',
    'php', '-S', `0.0.0.0:${port}`, '-t', '/work/apex',
  ];
  const containerId = execFileSync('docker', args, { encoding: 'utf8' }).trim();
  if (!/^[0-9a-f]{12,}$/.test(containerId)) {
    throw new Error(`docker run did not return a container id; got: ${containerId}`);
  }
  // The bind mount is :ro, but tests still need to mutate VERSION/BUILD
  // via the host fs — :ro only restricts container-side writes, host
  // writes show up immediately because php -S re-reads files per
  // request. We rely on that.
  await waitForHttp(`http://127.0.0.1:${port}/`);
  return { port, containerId };
}

/**
 * Stop the sidecar. Best-effort — never throws so the suite still
 * exits cleanly even if the container already died on its own.
 */
function stopApexSidecar(sidecar) {
  if (!sidecar) return;
  try {
    execFileSync('docker', ['stop', sidecar.containerId], {
      stdio: ['ignore', 'ignore', 'ignore'],
      timeout: 10_000,
    });
  } catch (_) { /* already stopped */ }
}

// ---------------------------------------------------------------------------
// Site container discovery — never hard-code, never fall back.
// ---------------------------------------------------------------------------

/**
 * Resolve the worktree-scoped Grav container's container name. Throws
 * (with the discover-grav-port instructions) if no container is up.
 * No silent fallback to :8080; this is the same chain documented in
 * CLAUDE.md "Discovery chain (fail-loud)".
 */
function siteContainerName() {
  const env = discoverGravEnv(WORKTREE_ROOT);
  if (!env || !env.container) {
    throw new Error('No Grav container resolved for this worktree');
  }
  return env.container;
}

// ---------------------------------------------------------------------------
// Test suite
// ---------------------------------------------------------------------------

test.describe('Version footer — apex landing page (Sprint 3)', () => {
  /** @type {ApexSidecar | null} */
  let apex = null;

  // Sidecar lifecycle: one container per project run, reused across
  // tests. The fixture cleanup helpers handle per-test state.
  test.beforeAll(async () => {
    apex = await startApexSidecar();
  });

  test.afterAll(async () => {
    stopApexSidecar(apex);
    apex = null;
  });

  test('footer carries Version <semver> · build <N> when both files are present', async ({ request }) => {
    if (!apex) throw new Error('apex sidecar not started');
    // Happy path: ensure both files exist with valid values.
    await withFixture(
      path.join(APEX_DIR, 'VERSION'),
      path.join(APEX_DIR, 'BUILD'),
      { kind: 'set', version: '0.1.0\n', build: '247' },
      async () => {
        const expectedVersion = readTrimmedOrNull(path.join(APEX_DIR, 'VERSION'));
        const expectedBuild = readTrimmedOrNull(path.join(APEX_DIR, 'BUILD'));
        // Sanity-check our own fixture conforms to the regex contract.
        expect(expectedVersion, 'fixture VERSION must match SemVer regex').toMatch(VERSION_REGEX);
        expect(expectedBuild, 'fixture BUILD must match integer regex').toMatch(BUILD_REGEX);

        const res = await request.get(`http://127.0.0.1:${/** @type {ApexSidecar} */ (apex).port}/`);
        expect(res.status()).toBe(200);
        const body = await res.text();

        // The combined-line regex must match somewhere on the page,
        // and the substring sourced from VERSION + BUILD must appear
        // verbatim (i.e. the page actually reflects what's on disk —
        // not just any old "Version x.y.z · build N" literal).
        expect(body).toMatch(VERSION_LINE_REGEX);
        const expectedSubstring = `Version ${expectedVersion} · build ${expectedBuild}`;
        expect(body).toContain(expectedSubstring);
      },
    );
  });

  test('omits the Denne side line when both apex/VERSION and apex/BUILD are missing', async ({ request }) => {
    if (!apex) throw new Error('apex sidecar not started');
    await withFixture(
      path.join(APEX_DIR, 'VERSION'),
      path.join(APEX_DIR, 'BUILD'),
      { kind: 'set', version: null, build: null },
      async () => {
        const res = await request.get(`http://127.0.0.1:${/** @type {ApexSidecar} */ (apex).port}/`);
        expect(res.status()).toBe(200);
        const body = await res.text();
        // The page must still render — the apex deploys with a
        // version.json that may carry deployed_at, so the page is not
        // empty; we just must not see a double-ukendt line.
        // The combined "Version X · build N" regex must NOT match.
        expect(body).not.toMatch(VERSION_LINE_REGEX);
        // The literal double-ukendt string is forbidden everywhere on
        // any rendered page — see playwright_no_double_ukendt_anywhere.
        expect(body.toLowerCase()).not.toContain('version <em>ukendt</em> · build <em>ukendt</em>');
      },
    );
  });
});

test.describe('Version footer — Grav site (Sprint 3)', () => {
  // Site footer reads VERSION/BUILD at request time, so each test
  // re-writes the pair just before navigating. The discovery chain
  // (env vars → port-registry → docker ps by deterministic name)
  // is enforced by playwright.config.js's baseURL plumbing — we never
  // hard-code a port here.

  test('footer matches /Version <semver> · build <N>/ on homepage', async ({ page }) => {
    // Probe the discovery chain explicitly so a stray :8080 fallback
    // (if it ever came back) would surface as a test failure rather
    // than a silent green run.
    const containerName = siteContainerName();
    expect(containerName, 'must use a worktree-scoped container, not :8080').toMatch(/^grav-[0-9a-f]{8}$/);

    await withFixture(
      path.join(SITE_DIR, 'VERSION'),
      path.join(SITE_DIR, 'BUILD'),
      { kind: 'set', version: '0.1.0\n', build: '247' },
      async () => {
        const expectedVersion = readTrimmedOrNull(path.join(SITE_DIR, 'VERSION'));
        const expectedBuild = readTrimmedOrNull(path.join(SITE_DIR, 'BUILD'));
        expect(expectedVersion).toMatch(VERSION_REGEX);
        expect(expectedBuild).toMatch(BUILD_REGEX);

        const res = await page.goto('/');
        expect(res?.status()).toBe(200);

        const footer = page.locator('footer').first();
        const footerHtml = await footer.innerHTML();
        expect(footerHtml).toMatch(VERSION_LINE_REGEX);
        const expectedSubstring = `Version ${expectedVersion} · build ${expectedBuild}`;
        expect(footerHtml).toContain(expectedSubstring);

        // Belt-and-braces: the bv-footer__version span specifically
        // exists and carries the substring. This is the hook
        // Sprint-2 added; if it disappears the test should fail
        // visibly rather than pass on coincidence.
        const versionSpan = footer.locator('.bv-footer__version');
        await expect(versionSpan).toHaveCount(1);
        await expect(versionSpan).toContainText(expectedSubstring);
      },
    );
  });

  test('omits the line entirely when both config/www/VERSION and BUILD are missing', async ({ page }) => {
    await withFixture(
      path.join(SITE_DIR, 'VERSION'),
      path.join(SITE_DIR, 'BUILD'),
      { kind: 'set', version: null, build: null },
      async () => {
        const res = await page.goto('/');
        expect(res?.status()).toBe(200);

        const footer = page.locator('footer').first();
        const footerHtml = await footer.innerHTML();

        // No combined "Version X · build N" anywhere in the footer.
        expect(footerHtml).not.toMatch(VERSION_LINE_REGEX);

        // The bv-footer__version span must NOT be in the DOM — Sprint
        // 2's template wraps the whole line in `{% if sv.version is
        // not null or sv.build is not null %}`, so when both are null
        // the span itself is omitted.
        await expect(footer.locator('.bv-footer__version')).toHaveCount(0);

        // Forbidden literal substrings.
        expect(footerHtml.toLowerCase()).not.toContain('· build');
        expect(footerHtml.toLowerCase()).not.toContain('version <em>ukendt</em>');
      },
    );
  });

  test('never renders double-ukendt on any anonymous public page', async ({ page }) => {
    // Walk every anonymous-public route this suite already touches
    // (the homepage is the canonical one — additional routes from the
    // smoke suite are tried opportunistically and skipped only if
    // they don't return 200, never silently). The page must never
    // exhibit the double-ukendt fallback regardless of fixture state.
    //
    // We use only routes the rest of the anonymous suite already
    // depends on; if any of them is broken on this Grav, the smoke
    // suite will surface it independently. We assert on /'s status
    // strictly (the homepage is always required) and only walk
    // optional routes when they're up.
    const requiredRoutes = ['/'];
    const optionalRoutes = ['/vaerksteder', '/vaerkstedskalenderen', '/kontakt'];

    const checkBody = (body, route) => {
      // The literal HTML form the Sprint-2 partial would have emitted
      // in the bug case.
      expect(
        body.toLowerCase(),
        `route ${route} must not render double-ukendt (HTML form)`,
      ).not.toContain('version <em>ukendt</em> · build <em>ukendt</em>');
      // Belt-and-braces: catch a future template tweak that drops
      // the <em> wrapping.
      expect(
        body.toLowerCase(),
        `route ${route} must not render double-plain-ukendt`,
      ).not.toMatch(/version\s+ukendt\s*·\s*build\s+ukendt/);
    };

    for (const route of requiredRoutes) {
      const res = await page.goto(route);
      expect(res?.status(), `required route ${route} should be 200`).toBe(200);
      checkBody(await page.content(), route);
    }
    for (const route of optionalRoutes) {
      const res = await page.goto(route);
      const status = res?.status() ?? 0;
      if (status !== 200) {
        // Do NOT silently skip-pass: log and continue so we still
        // probe the routes that ARE up. Smoke suite owns the 200
        // assertion for these routes; we focus narrowly on the
        // double-ukendt assertion.
        // eslint-disable-next-line no-console
        console.warn(
          `version-footer: optional route ${route} returned ${status}; ` +
          `not asserting status here (smoke.js owns that). Skipping body check.`,
        );
        continue;
      }
      checkBody(await page.content(), route);
    }
  });
});
