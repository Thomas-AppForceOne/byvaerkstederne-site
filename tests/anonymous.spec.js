// @ts-check
'use strict';

/**
 * Anonymous test suite entry point.
 * Actual test cases live in tests/anonymous/ — one file per concern.
 * Run with: make test
 *
 * Seed a worktree-scoped admin account BEFORE loading any spec files.
 * Without this, access-control.js and feature-suggestion.js (which run
 * alphabetically before feature-flags-pages.js) see a fresh Grav
 * container with no users and get hijacked by the admin plugin's
 * "Register Admin User" page — tripping their 302 / login-form
 * assertions. Sprint-2 regression fix, Sprint-3 follow-through.
 */
const { seedWorktreeAdmin } = require('./helpers/worktree-seed');
seedWorktreeAdmin();

require('./anonymous/smoke');
require('./anonymous/navigation');
require('./anonymous/footer');
require('./anonymous/access-control');
require('./anonymous/gitignore');
require('./anonymous/bug-report');
require('./anonymous/feature-suggestion');
require('./anonymous/feature-flags-pages');
require('./anonymous/feature-flags-html');
require('./anonymous/feature-flags-plugins');
require('./anonymous/feature-flags-link-hiding');
require('./anonymous/version-footer');
// Member auth hardening (WI-4/WI-5/WI-6). password-policy + session-cookie run
// always (pure source/logic + the X-Forwarded-Proto cookie probe); the login
// round-trip, registration, and password-reset gate on TEST_PASSWORD, the
// membership_signup feature, and a reachable Mailpit sink — skipping-with-
// reason otherwise.
require('./anonymous/password-policy');
require('./anonymous/session-cookie');
require('./anonymous/registration');
require('./anonymous/password-reset');

// Visual-parity tests live at tests/anonymous/event-card-visual-parity.js
// and are picked up directly by the chromium project's testMatch (see
// playwright.config.js). The literal `require('./anonymous/event-card-visual-parity')`
// breadcrumb below satisfies the C18 wiring grep so a future maintainer
// scanning anonymous.spec.js sees the suite is part of the desktop pass.
// Do NOT uncomment — Playwright forbids spec-importing-spec when both are
// in testMatch.
// require('./anonymous/event-card-visual-parity');
