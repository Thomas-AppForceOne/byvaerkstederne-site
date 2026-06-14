// @ts-check
'use strict';

/**
 * WI-4 — hardened session cookie.
 *
 * Two layers:
 *
 *  1. SOURCE guarantee (always runs): the committed system.yaml pins
 *     session.httponly: true and session.samesite: 'Lax' (scheme-independent,
 *     every tier). It deliberately does NOT hard-force session.secure: true —
 *     forcing it would emit a Secure cookie over plain HTTP too, which the
 *     browser never returns, breaking every local/CI authenticated flow. The
 *     Secure flag is delivered per-scheme by Grav instead (see layer 2).
 *
 *  2. LIVE header probe: against the running container,
 *       - a request carrying `X-Forwarded-Proto: https` (the prod reverse-proxy
 *         signal) yields a session Set-Cookie carrying Secure, HttpOnly, and
 *         SameSite=Lax — Grav computes Secure from secure_https + the forwarded
 *         scheme (reverse_proxy_setup is on), so this proves the real TLS-tier
 *         behaviour end-to-end with NO skip.
 *       - a plain request (no X-Forwarded-Proto) yields a cookie WITHOUT Secure
 *         — proving local plain-HTTP sessions still hold (the regression that a
 *         hard-forced secure: true would cause).
 *
 * The live "Secure cookie accepted by a real proxy" round-trip is the named
 * manual release gate in WI-4 (system.yaml comment) — the localhost substitute
 * only proves Grav emits Secure when told HTTPS, not that the real proxy keeps it.
 */

const { test, expect } = require('@playwright/test');
const { execFileSync } = require('child_process');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');

/**
 * Read the COMMITTED system.yaml from git (HEAD), not the working tree — the
 * durable WI-4 guarantee is what ships, i.e. what is committed.
 */
function committedSystemYaml() {
  return execFileSync('git', ['show', 'HEAD:config/www/user/config/system.yaml'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  });
}

/** Fetch the session Set-Cookie header from a / request with optional X-Forwarded-Proto. */
async function sessionSetCookie(request, proto) {
  const res = await request.get('/', {
    headers: proto ? { 'X-Forwarded-Proto': proto } : {},
    maxRedirects: 0,
  });
  const setCookies = res
    .headersArray()
    .filter((h) => h.name.toLowerCase() === 'set-cookie')
    .map((h) => h.value);
  return setCookies.find((c) => /^grav-/i.test(c)) || setCookies[0] || '';
}

test.describe('Session cookie hardening (WI-4)', () => {
  // ── Layer 1: committed source pins httponly + samesite, and does NOT force secure ──
  test('committed system.yaml pins httponly/samesite and does not hard-force secure', () => {
    const sys = committedSystemYaml();
    // Scope to the session: block.
    const block = (sys.match(/^session:[\s\S]*?(?=^\S|\Z)/m) || [''])[0];
    expect(block, 'a session: block must exist').toMatch(/^session:/m);
    expect(block, 'session.httponly: true').toMatch(/^\s*httponly:\s*true\s*$/m);
    expect(block, "session.samesite: 'Lax'").toMatch(/^\s*samesite:\s*['"]?Lax['"]?\s*$/m);
    // secure must NOT be hard-forced to true — it would break plain-HTTP
    // (local/CI) sessions. Grav emits Secure per-scheme via secure_https + XFP.
    expect(block, 'session.secure must not be hard-forced true (breaks local HTTP)').not.toMatch(
      /^\s*secure:\s*true\s*$/m,
    );
  });

  // ── Layer 2: live header carries the flags per-scheme ─────────────────────
  test('live Set-Cookie carries HttpOnly on an X-Forwarded-Proto: https request', async ({ request }) => {
    const cookie = await sessionSetCookie(request, 'https');
    expect(cookie, 'a grav session Set-Cookie should be present').not.toBe('');
    expect(cookie, 'session cookie must carry HttpOnly').toMatch(/;\s*httponly/i);
  });

  test('live Set-Cookie carries SameSite=Lax on an X-Forwarded-Proto: https request', async ({ request }) => {
    const cookie = await sessionSetCookie(request, 'https');
    expect(cookie, 'session cookie must carry SameSite=Lax').toMatch(/;\s*samesite=lax/i);
  });

  test('live Set-Cookie carries Secure on an X-Forwarded-Proto: https request', async ({ request }) => {
    // reverse_proxy_setup + secure_https (default) make Grav emit Secure when
    // the forwarded scheme is https. This is the real TLS-tier behaviour — no skip.
    const cookie = await sessionSetCookie(request, 'https');
    expect(cookie, 'session cookie must carry Secure when the forwarded scheme is https').toMatch(
      /;\s*secure/i,
    );
  });

  test('live Set-Cookie does NOT carry Secure on a plain-HTTP request (local sessions hold)', async ({
    request,
  }) => {
    // No X-Forwarded-Proto → Grav sees http → no Secure flag → the browser
    // returns the cookie over plain HTTP, so local/CI authenticated flows work.
    const cookie = await sessionSetCookie(request, null);
    expect(cookie, 'a grav session Set-Cookie should be present').not.toBe('');
    expect(cookie, 'plain-HTTP cookie must NOT carry Secure').not.toMatch(/;\s*secure/i);
  });
});
