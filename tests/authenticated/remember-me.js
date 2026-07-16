// @ts-check
'use strict';

/**
 * Remember-me ("Husk mig") resilience — regression coverage for the three
 * defects that broke persistent login in real browsers:
 *
 *   1. RACE (primary): the stock login plugin rotated the single-use token on
 *      EVERY cookie auto-login. Two requests carrying the same cookie (multi-
 *      tab session restore, prefetch) → the winner rotates + logs in, the loser
 *      presents the now-stale token, is served TRIPLET_INVALID, throws a 403
 *      (REMEMBER_ME_STOLEN_COOKIE) AND wipes the user's ENTIRE server-side
 *      token store (cleanAllTriplets) — orphaning even the winner's cookie.
 *   2. UA-BOUND SALT: the token salt mixed in HTTP_USER_AGENT, so any browser
 *      version bump silently invalidated every remembered session.
 *   3. BROKEN EXPIRY CHECK: TokenStorage.findTriplet compared an array to an
 *      int, so the server-side triplets never expired.
 *
 * The suite drives the running Grav over raw HTTP (no browser) so each request
 * carries EXACTLY the cookies we choose — auto-login only fires when a
 * rememberme cookie is present and NO session cookie is. That control is what
 * lets us reproduce the race and the UA swap deterministically.
 *
 * Gated on TEST_PASSWORD (hasUserPassword) like the rest of the authenticated
 * suite; anonymous-only mode skips-with-reason.
 */

const { test, expect } = require('@playwright/test');
const http = require('http');
const path = require('path');
const { hasUserPassword } = require('../helpers/auth');
const { TEST_USER } = require('../helpers/accounts');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

const { port: PORT } = discoverGravEnv(path.resolve(__dirname, '..', '..'));
// The default host (no env dir) resolves to the all-on local profile; remember
// -me is not feature-flagged, so 127.0.0.1 is enough.
const HOST = '127.0.0.1';
const REMEMBER_COOKIE = 'grav-rememberme';
// Grav binds a form nonce to the User-Agent, so a login's GET+POST must share a
// UA. This is the "browser version" used when a cookie is minted.
const UA = 'bv-remember-me-spec/1.0';
// A different UA used to prove auto-login survives a browser update (bug 2).
const UA_UPDATED = 'bv-remember-me-spec/2.0-updated';

/**
 * Minimal cookie-controlled HTTP fetcher (mirrors the raw-HTTP helper in
 * tests/anonymous/feature-flags-html.js). Sends only the cookies passed in,
 * returns the raw Set-Cookie lines (so we can read Max-Age) plus the parsed jar
 * and body. Uses 127.0.0.1 explicitly (macOS 'localhost' may resolve to IPv6).
 *
 * @param {{ path: string, method?: string, headers?: object, body?: string|null,
 *           cookies?: Record<string,string>, ua?: string, maxRedirects?: number }} opts
 */
function rawFetch(opts) {
  const method = opts.method || 'GET';
  const ua = opts.ua || UA;
  const maxRedirects = opts.maxRedirects ?? 0;
  const jar = Object.assign({}, opts.cookies || {});
  return new Promise((resolve, reject) => {
    function doReq(reqPath, redirectsLeft) {
      const cookieHeader = Object.entries(jar).map(([k, v]) => `${k}=${v}`).join('; ');
      const headers = Object.assign(
        {
          Host: HOST,
          'User-Agent': ua,
          Accept: 'text/html,application/xhtml+xml',
          Connection: 'close',
        },
        opts.headers || {},
        cookieHeader ? { Cookie: cookieHeader } : {},
      );
      const req = http.request(
        { host: '127.0.0.1', port: PORT, path: reqPath, method, headers },
        (res) => {
          const setCookies = res.headers['set-cookie'] || [];
          for (const line of setCookies) {
            const [pair] = String(line).split(';');
            const eq = pair.indexOf('=');
            if (eq > 0) jar[pair.slice(0, eq).trim()] = pair.slice(eq + 1).trim();
          }
          const chunks = [];
          res.on('data', (c) => chunks.push(c));
          res.on('end', () => {
            if (
              redirectsLeft > 0 &&
              [301, 302, 303, 307, 308].includes(res.statusCode) &&
              res.headers.location
            ) {
              const loc = res.headers.location;
              const next = loc.startsWith('http')
                ? new URL(loc).pathname + (new URL(loc).search || '')
                : loc;
              doReq(next, redirectsLeft - 1);
              return;
            }
            resolve({
              status: res.statusCode,
              headers: res.headers,
              setCookies,
              cookies: jar,
              body: Buffer.concat(chunks).toString('utf8'),
            });
          });
        },
      );
      req.on('error', reject);
      if (opts.body) req.write(opts.body);
      req.end();
    }
    doReq(opts.path, maxRedirects);
  });
}

/** True when a response body carries the logged-in markers (matches the rest of the suite). */
function isAuthenticated(body) {
  return /Log ud|logout-form/i.test(body);
}

/** Return the raw grav-rememberme Set-Cookie line, or null when absent. */
function rememberSetCookie(setCookies) {
  return (setCookies || []).find((l) => l.startsWith(`${REMEMBER_COOKIE}=`)) || null;
}

/** Extract the grav-rememberme value (still URL-encoded — sent back verbatim, browser-faithful). */
function rememberValue(setCookies) {
  const line = rememberSetCookie(setCookies);
  if (!line) return null;
  return line.split(';')[0].split('=').slice(1).join('=');
}

/** Parse the Max-Age (seconds) from a Set-Cookie line, or null. */
function maxAgeOf(setCookieLine) {
  const m = String(setCookieLine || '').match(/max-age=(-?\d+)/i);
  return m ? parseInt(m[1], 10) : null;
}

/**
 * Log in over raw HTTP and return the POST response (status ~303 + Set-Cookies).
 * GET /login (for the session cookie + nonce) and the POST share a UA so the
 * nonce validates. Never logs the password.
 *
 * @param {string} password
 * @param {{ remember?: boolean, ua?: string }} [opts]
 */
async function login(password, { remember = false, ua = UA } = {}) {
  const get = await rawFetch({ path: '/login', method: 'GET', ua, maxRedirects: 5 });
  const m = get.body.match(/name="login-form-nonce"\s+value="([a-f0-9]+)"/i);
  if (!m) throw new Error('remember-me: could not extract login-form-nonce from /login');
  const parts = [
    `username=${encodeURIComponent(TEST_USER.username)}`,
    `password=${encodeURIComponent(password)}`,
    `login-form-nonce=${encodeURIComponent(m[1])}`,
    'task=login.login',
  ];
  if (remember) parts.push('rememberme=1');
  const body = parts.join('&');
  return rawFetch({
    path: '/login',
    method: 'POST',
    ua,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Content-Length': Buffer.byteLength(body).toString(),
    },
    body,
    cookies: get.cookies, // carry the session cookie so the nonce validates
    maxRedirects: 0,
  });
}

/** Mint a fresh, valid rememberme cookie value for a fresh browser (returns the encoded value). */
async function mintRememberCookie(password, ua = UA) {
  const post = await login(password, { remember: true, ua });
  const value = rememberValue(post.setCookies);
  if (!value) throw new Error('remember-me: login did not set a grav-rememberme cookie');
  return value;
}

/** Auto-login by requesting a page carrying ONLY the rememberme cookie (no session). */
async function autoLogin(rememberCookieValue, { ua = UA, reqPath = '/' } = {}) {
  return rawFetch({
    path: reqPath,
    method: 'GET',
    ua,
    cookies: { [REMEMBER_COOKIE]: rememberCookieValue },
    maxRedirects: 0,
  });
}

/**
 * Flip one hex char in the token (middle) segment of a rememberme cookie value,
 * leaving the credential + persistent-token segments intact. The value is
 * URL-encoded (`%7C` separators) exactly as PHP's setcookie emitted it.
 */
function tamperToken(encodedValue) {
  const sep = encodedValue.includes('%7C') ? '%7C' : '|';
  const parts = encodedValue.split(sep);
  const token = parts[1];
  parts[1] = token.slice(0, -1) + (token.slice(-1) === '0' ? '1' : '0');
  return parts.join(sep);
}

test.describe('Remember-me ("Husk mig") resilience', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — remember-me suite skipped (anonymous-only mode)');

  const PW = () => process.env.TEST_PASSWORD || '';

  // ── Case 1: baseline — the cookie is issued and auto-logins on its own ──────
  test('login with "husk mig" issues a ~7-day cookie that auto-logins by itself', async () => {
    const post = await login(PW(), { remember: true });
    expect([200, 302, 303]).toContain(post.status);

    const line = rememberSetCookie(post.setCookies);
    expect(line, 'login response must Set-Cookie grav-rememberme').not.toBeNull();
    const maxAge = maxAgeOf(line);
    expect(maxAge, 'grav-rememberme must carry a ~7-day Max-Age').not.toBeNull();
    expect(maxAge).toBeGreaterThanOrEqual(600_000); // ~6.9 days
    expect(maxAge).toBeLessThanOrEqual(604_800); //     7 days exactly

    // A fresh browser holding ONLY the rememberme cookie (no session) is
    // authenticated on a normal page, without ever visiting /login.
    const value = rememberValue(post.setCookies) || '';
    const res = await autoLogin(value);
    expect(res.status, 'auto-login GET must not error').toBeLessThan(400);
    expect(isAuthenticated(res.body), 'rememberme-only request must be authenticated').toBe(true);
  });

  // ── Case 2: RACE regression — concurrent requests must not 403 or wipe ──────
  test('concurrent requests with the same cookie all succeed and the token store survives', async () => {
    const value = await mintRememberCookie(PW());

    // Three truly concurrent auto-logins, each carrying only the rememberme
    // cookie and no session. On the unpatched plugin the token rotates, so the
    // losers get a 403 (or 500) and cleanAllTriplets wipes the store.
    const results = await Promise.all([0, 1, 2].map(() => autoLogin(value)));
    for (const r of results) {
      expect(r.status, `concurrent auto-login returned ${r.status} (expected < 400)`).toBeLessThan(400);
    }

    // The store must be intact: the ORIGINAL cookie still authenticates.
    const after = await autoLogin(value);
    expect(after.status).toBeLessThan(400);
    expect(
      isAuthenticated(after.body),
      'after concurrent use the original cookie must still authenticate (store not wiped)',
    ).toBe(true);
  });

  // ── Case 3: UA swap regression — a browser update must not log you out ──────
  test('a valid cookie still authenticates under a different User-Agent', async () => {
    const value = await mintRememberCookie(PW(), UA); // minted on "old browser"
    const res = await autoLogin(value, { ua: UA_UPDATED }); // requested on "updated browser"
    expect(res.status, 'UA-swapped auto-login must not error').toBeLessThan(400);
    expect(
      isAuthenticated(res.body),
      'a browser version bump (different UA) must not invalidate the remembered session',
    ).toBe(true);
  });

  // ── Case 4: failure path — a tampered token is anonymous, not destructive ───
  test('a tampered cookie renders anonymous without a 403 and leaves the real token intact', async () => {
    const value = await mintRememberCookie(PW());
    const tampered = tamperToken(value);

    // The tampered request must be treated as an unauthenticated visitor — not
    // a "stolen cookie" 403/500 error page.
    const bad = await autoLogin(tampered);
    expect(bad.status, `tampered-cookie request returned ${bad.status} (expected < 400)`).toBeLessThan(400);
    expect(isAuthenticated(bad.body), 'a tampered cookie must render as anonymous').toBe(false);

    // Crucially, the tampered attempt must NOT wipe the store (no
    // cleanAllTriplets side effect): the ORIGINAL cookie still authenticates.
    const good = await autoLogin(value);
    expect(good.status).toBeLessThan(400);
    expect(
      isAuthenticated(good.body),
      'the original cookie must survive a tampered-cookie attempt (no cleanAllTriplets)',
    ).toBe(true);
  });

  // ── Case 5: opting out — no "husk mig" means no persistent cookie ───────────
  test('login without "husk mig" issues no grav-rememberme cookie', async () => {
    const post = await login(PW(), { remember: false });
    expect([200, 302, 303]).toContain(post.status);
    expect(
      rememberSetCookie(post.setCookies),
      'a login without rememberme must not Set-Cookie grav-rememberme',
    ).toBeNull();
  });
});
