// @ts-check
'use strict';

/**
 * Scheduler trigger — the token-gated URL an external cron service calls.
 *
 * The hosting plan has no cron and no crontab, so this endpoint is the only
 * thing that makes the site's scheduled work run at all. Two properties carry
 * the security of that arrangement, and both are asserted here:
 *
 *   - a wrong, missing or unprovisioned token produces Grav's ORDINARY 404,
 *     identical to any unknown URL, so the endpoint cannot be found by
 *     probing;
 *   - a valid token actually runs the scheduler — proven by Grav's own
 *     last-run marker moving, not by the response, which is deliberately
 *     empty.
 *
 * The throttle is asserted too: a second call inside the window answers the
 * same 204 without re-running, so a leaked URL cannot be used to make the
 * site work harder than its schedule intends.
 */

const { test, expect } = require('@playwright/test');
const { execFileSync } = require('child_process');
const path = require('path');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const ROUTE = '/scheduler-trigger';
const STATE_DIR = '/app/www/public/user/data/scheduler-trigger';
const LAST_CRON = '/app/www/public/logs/lastcron.run';
const GRAV_LOG = '/app/www/public/logs/grav.log';

let _container = null;
function container() {
  if (!_container) ({ container: _container } = discoverGravEnv(REPO_ROOT));
  return _container;
}

/** Run a shell command in the container as the web user. */
function sh(script) {
  return execFileSync('docker', ['exec', '-u', 'abc', container(), 'sh', '-c', script], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 30_000,
  });
}

function provisionToken() {
  return sh(
    `mkdir -p ${STATE_DIR} && openssl rand -hex 32 > ${STATE_DIR}/token ` +
      `&& chmod 600 ${STATE_DIR}/token && cat ${STATE_DIR}/token`,
  ).trim();
}

function removeToken() {
  sh(`rm -f ${STATE_DIR}/token ${STATE_DIR}/last-run`);
}

/** Clear the throttle marker so the next call is allowed to run for real. */
function clearThrottle() {
  sh(`rm -f ${STATE_DIR}/last-run`);
}

/**
 * The handler's own throttle marker. Written the moment the handler ACCEPTS a
 * call and decides to run — so it is a synchronous, precise observable of
 * "this request was accepted", unlike Grav's cron marker below.
 */
function acceptMarker() {
  try {
    return sh(`cat ${STATE_DIR}/last-run 2>/dev/null || true`).trim();
  } catch (_) {
    return '';
  }
}

/**
 * Grav's own "cron last ran" marker. Proof that the scheduler really ran —
 * but written when the run FINISHES, which can be after the response has
 * returned. Good for "did it eventually run", useless for "did this exact
 * request run it": an earlier test's run can land in the middle of a later
 * one, which is exactly how the first version of this file failed.
 */
function lastCronRun() {
  try {
    return sh(`cat ${LAST_CRON} 2>/dev/null || true`).trim();
  } catch (_) {
    return '';
  }
}

/** Lines this plugin wrote to Grav's log, newest last. */
function triggerLogLines() {
  try {
    return sh(`grep scheduler-trigger ${GRAV_LOG} 2>/dev/null || true`).trim();
  } catch (_) {
    return '';
  }
}

test.describe('Scheduler trigger (token-gated cron endpoint)', () => {
  let token = '';

  test.beforeAll(() => {
    token = provisionToken();
    expect(token.length, 'a provisioned token must be long').toBeGreaterThanOrEqual(32);
  });

  test.afterAll(() => {
    removeToken();
  });

  test('a valid token runs the scheduler and answers 204 with no body', async ({ request }) => {
    clearThrottle();
    const before = lastCronRun();

    const res = await request.get(`${ROUTE}?token=${token}`, { maxRedirects: 0 });
    expect(res.status(), 'valid token is accepted').toBe(204);
    expect((await res.body()).length, 'the response body is empty by design').toBe(0);

    // Grav writes logs/lastcron.run when the scheduler runs. If this did not
    // move, the endpoint answered without doing the one thing it exists for.
    await expect
      .poll(() => lastCronRun(), { timeout: 10_000 })
      .not.toBe(before);
  });

  test('a wrong token is indistinguishable from a page that does not exist', async ({ request }) => {
    clearThrottle();
    const beforeAccept = acceptMarker();

    const bad = 'd'.repeat(64);
    const res = await request.get(`${ROUTE}?token=${bad}`, { maxRedirects: 0 });
    // A control request to a path that certainly has no handler. "Looks like
    // any unknown URL" is only meaningful against an actual unknown URL.
    const control = await request.get('/der-findes-helt-sikkert-ikke-9f3a', { maxRedirects: 0 });

    expect(res.status(), 'a wrong token must answer like an unknown URL').toBe(control.status());
    expect(res.status()).toBe(404);

    // Same themed error page. The requested path is echoed by the theme, so
    // the bodies differ by that alone — compare the titles, which is what a
    // prober would actually read.
    const titleOf = (html) => (html.match(/<title>([^<]*)<\/title>/i) || [])[1] || '';
    expect(titleOf(await res.text()), 'same error page as any unknown URL').toBe(
      titleOf(await control.text()),
    );

    // And nothing ran: the handler never reached the point where it records
    // an accepted call.
    expect(acceptMarker(), 'a rejected caller must not be accepted').toBe(beforeAccept);
  });

  test('no token at all is refused the same way', async ({ request }) => {
    const res = await request.get(ROUTE, { maxRedirects: 0 });
    expect(res.status()).toBe(404);
  });

  test('an unprovisioned tier refuses even a plausible token', async ({ request }) => {
    removeToken();
    try {
      const res = await request.get(`${ROUTE}?token=${token}`, { maxRedirects: 0 });
      expect(
        res.status(),
        'without a provisioned token the endpoint must not exist at all',
      ).toBe(404);
    } finally {
      token = provisionToken();
    }
  });

  test('a rejected call with a token is logged; a bare visit is not', async ({ request }) => {
    // Silent to the caller, not to the operator. A cron service whose URL lost
    // its query string, or that still holds a rotated token, is
    // indistinguishable from a job that was never created — and shared
    // hosting gives no access log to tell them apart. This line is the only
    // way to answer "is anything even reaching us?".
    const before = triggerLogLines();

    await request.get(`${ROUTE}?token=abc123`, { maxRedirects: 0 });
    await expect.poll(() => triggerLogLines(), { timeout: 10_000 }).not.toBe(before);

    const logged = triggerLogLines();
    expect(logged, 'the length is recorded — it separates a truncated paste from a wrong secret')
      .toMatch(/token length 6/);
    expect(logged, 'the reason is recorded').toMatch(/does not match/);
    expect(logged, 'the token itself must never be written').not.toContain('abc123');

    // A bare visit to the path is noise, not signal: logging it would let
    // anyone fill the log by refreshing a URL.
    const beforeBare = triggerLogLines();
    await request.get(ROUTE, { maxRedirects: 0 });
    await new Promise((r) => setTimeout(r, 1500));
    expect(triggerLogLines(), 'a visit without a token is not logged').toBe(beforeBare);
  });

  test('the throttle cannot swallow a scheduled call', async () => {
    // The throttle is burst protection, not a scheduling knob. It must stay
    // well below the trigger interval: a throttle that swallows a scheduled
    // call silently drops whatever was due in that minute — the failure this
    // endpoint exists to prevent, reintroduced one layer up. The caller runs
    // every 5 minutes (see deploy/SCHEDULER.md), so anything under 30s is
    // comfortably safe and still stops a flood cold.
    const yaml = require('fs').readFileSync(
      path.join(REPO_ROOT, 'config/www/user/plugins/scheduler-trigger/scheduler-trigger.yaml'),
      'utf8',
    );
    const configured = Number((yaml.match(/^min_interval:\s*(\d+)/m) || [])[1]);
    expect(configured, 'min_interval must be set').toBeGreaterThan(0);
    expect(configured, 'min_interval must leave a per-minute cadence intact').toBeLessThan(30);
  });

  test('a second call inside the window answers 204 but does not re-run', async ({ request }) => {
    clearThrottle();
    const first = await request.get(`${ROUTE}?token=${token}`, { maxRedirects: 0 });
    expect(first.status()).toBe(204);
    const afterFirst = acceptMarker();
    expect(afterFirst, 'the first call is recorded as accepted').not.toBe('');

    // Immediately again — inside min_interval. Same answer, no work: the
    // caller cannot tell, which is what keeps the throttle from leaking
    // information about the endpoint's state.
    const second = await request.get(`${ROUTE}?token=${token}`, { maxRedirects: 0 });
    expect(second.status(), 'a throttled call is answered identically').toBe(204);
    expect(acceptMarker(), 'the throttled call must not have started a new run').toBe(afterFirst);
  });
});
