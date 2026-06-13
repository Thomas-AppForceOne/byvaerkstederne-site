// @ts-check
'use strict';

/**
 * Helpers shared by the tests under tests/mobile/.
 *
 * Feature-flag profile note
 * -------------------------
 * Grav's environment-overlay layer keys feature-flag profiles by the
 * incoming HTTP Host header (user/env/<host>/config/features.yaml). The
 * default profile at user/config/features.yaml leaves every flag commented
 * out — so /vaerkstedskalenderen, which is gated on `workshop_calendar`,
 * 404s for any client whose Host is plain `127.0.0.1` or `localhost`.
 *
 * The spec/contract requires probing /vaerkstedskalenderen as one of the
 * four mobile routes, so the mobile-chromium project in playwright.config.js
 * sets:
 *   baseURL: 'http://dev.hackersbychoice.dk:<port>'
 *   launchOptions.args: ['--host-resolver-rules=MAP dev.hackersbychoice.dk 127.0.0.1']
 * The browser then sends `Host: dev.hackersbychoice.dk` natively (which
 * Grav resolves to the env profile where every flag is "true") while DNS
 * still lands on the worktree-scoped Grav container.
 *
 * This module exists so future mobile tests have an explicit re-entry
 * point if the project-level mechanism ever needs to be moved into the
 * tests themselves (e.g. when Playwright tightens its launch-options
 * model). For now the helper is intentionally a no-op so it stays cheap
 * to import.
 */

/**
 * @param {import('@playwright/test').Page} _page
 */
async function useDevHost(_page) {
  // Intentionally empty: Host-override happens at the launchOptions
  // level in playwright.config.js (mobile-chromium project). See module
  // docblock for the full rationale.
}

module.exports = { useDevHost };
