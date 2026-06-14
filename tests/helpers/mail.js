// @ts-check
'use strict';

/**
 * Mailpit query/clear helper (WI-6).
 *
 * Email-bearing auth flows (activation, password reset) are verified
 * end-to-end against an API-queryable, non-delivering sink — Mailpit. The
 * test reads the captured message over Mailpit's REST API, extracts the
 * activation/reset URL from the body, and drives that URL to prove the token
 * works. Nothing is mocked at the Grav layer; the real login + email plugin
 * path runs and sends to Mailpit via SMTP.
 *
 * The sink base URL comes from MAILPIT_URL (exported by scripts/mailpit-up.sh,
 * default http://127.0.0.1:8025). When MAILPIT_URL is unset OR the sink is
 * unreachable, isMailSinkConfigured() returns false so specs can skip-with-
 * reason rather than fail (anonymous-only / no-sink mode).
 *
 * Mailpit REST endpoints used:
 *   GET    /api/v1/info                 — reachability probe
 *   GET    /api/v1/search?query=...     — find messages (e.g. to:<addr>)
 *   GET    /api/v1/message/{ID}         — full message (From/To/Subject/Text/HTML)
 *   DELETE /api/v1/messages            — clear the whole inbox
 */

const MAILPIT_URL = (process.env.MAILPIT_URL || 'http://127.0.0.1:8025').replace(/\/+$/, '');

/**
 * Probe the Mailpit API. Cached per-process after the first call.
 * @returns {Promise<boolean>}
 */
let _sinkOk = null;
async function isMailSinkConfigured() {
  if (_sinkOk !== null) return _sinkOk;
  if (!process.env.MAILPIT_URL && !process.env.CI) {
    // No explicit MAILPIT_URL: still try the default once (local convenience).
  }
  try {
    const res = await fetch(`${MAILPIT_URL}/api/v1/info`, { method: 'GET' });
    _sinkOk = res.ok;
  } catch (_) {
    _sinkOk = false;
  }
  return _sinkOk;
}

/** The sink base URL, for diagnostics in skip reasons. */
function mailSinkUrl() {
  return MAILPIT_URL;
}

/**
 * Delete every captured message. Call before an action so waitForMail only
 * sees the message that action produced.
 * @returns {Promise<void>}
 */
async function clearMail() {
  const res = await fetch(`${MAILPIT_URL}/api/v1/messages`, { method: 'DELETE' });
  if (!res.ok) {
    throw new Error(`clearMail: Mailpit DELETE /api/v1/messages returned ${res.status}`);
  }
}

/**
 * Return the captured messages addressed to `to` (most recent first), as
 * Mailpit search summaries. Empty array when none.
 * @param {string} to
 * @returns {Promise<Array<any>>}
 */
async function searchMail(to) {
  const url = `${MAILPIT_URL}/api/v1/search?query=${encodeURIComponent(`to:${to}`)}`;
  const res = await fetch(url, { method: 'GET' });
  if (!res.ok) {
    throw new Error(`searchMail: Mailpit search returned ${res.status}`);
  }
  const data = await res.json();
  return Array.isArray(data.messages) ? data.messages : [];
}

/**
 * Fetch the full message (From, To, Subject, Text, HTML) by ID.
 * @param {string} id
 * @returns {Promise<any>}
 */
async function getMessage(id) {
  const res = await fetch(`${MAILPIT_URL}/api/v1/message/${encodeURIComponent(id)}`, {
    method: 'GET',
  });
  if (!res.ok) {
    throw new Error(`getMessage: Mailpit GET /api/v1/message/${id} returned ${res.status}`);
  }
  return res.json();
}

/**
 * Poll until at least one message addressed to `to` is captured, then return
 * the full most-recent message. Throws on timeout — a missing message is a
 * test failure (the email-sent assertion), never a silent pass.
 *
 * @param {string} to
 * @param {number} [timeoutMs=15000]
 * @returns {Promise<any>}
 */
async function waitForMail(to, timeoutMs = 15000) {
  const deadline = Date.now() + timeoutMs;
  let lastCount = 0;
  while (Date.now() < deadline) {
    const summaries = await searchMail(to);
    lastCount = summaries.length;
    if (summaries.length > 0) {
      // Search summaries are newest-first; fetch the full first message.
      return getMessage(summaries[0].ID);
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(
    `waitForMail: no message to ${to} within ${timeoutMs}ms (saw ${lastCount}) — ` +
      `the email-sent assertion failed. Is Mailpit up and email.yaml pointed at it?`,
  );
}

/**
 * Assert that NO message was captured for `to` after a settle window. Used by
 * the user-enumeration / no-mail failure paths.
 * @param {string} to
 * @param {number} [settleMs=3000]
 * @returns {Promise<boolean>} true when none captured
 */
async function expectNoMail(to, settleMs = 3000) {
  const deadline = Date.now() + settleMs;
  while (Date.now() < deadline) {
    const summaries = await searchMail(to);
    if (summaries.length > 0) return false; // a message arrived — caller asserts
    await new Promise((r) => setTimeout(r, 400));
  }
  const summaries = await searchMail(to);
  return summaries.length === 0;
}

/**
 * Extract the first match of `pattern` from a captured message's Text or HTML
 * body. Returns the matched string, or null if not found.
 *
 * Grav's login plugin renders activation/reset URLs as PATH-PARAM links, e.g.
 *   /activate_user/token:<hex>/username:<name>
 *   /reset_password/.../token:<hex>...
 * The default pattern handles both. HTML bodies escape `&` etc.; we decode the
 * common entities before matching.
 *
 * @param {any} msg full Mailpit message (has .Text and .HTML)
 * @param {RegExp} [pattern]
 * @returns {string|null}
 */
function extractLink(msg, pattern = /\/(?:activate_user|reset_password)\/[^\s"'<>)]+/) {
  const decode = (s) =>
    String(s || '')
      .replace(/&amp;/g, '&')
      .replace(/\\u0026/g, '&')
      .replace(/&#x2F;/g, '/');
  for (const field of ['Text', 'HTML']) {
    const body = decode(msg[field]);
    const m = body.match(pattern);
    if (m) return m[0];
  }
  return null;
}

module.exports = {
  isMailSinkConfigured,
  mailSinkUrl,
  clearMail,
  searchMail,
  getMessage,
  waitForMail,
  expectNoMail,
  extractLink,
};
