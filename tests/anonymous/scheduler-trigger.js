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

  test('the throttle is short enough for a per-minute caller', async () => {
    // Grav only runs a job when the call lands in the job's own minute, so
    // the caller must fire every minute. A throttle at or above 60s would
    // swallow roughly every other call, and any job whose minute fell in a
    // swallowed call would never run at all — the failure this endpoint
    // exists to prevent, reintroduced one layer up.
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
