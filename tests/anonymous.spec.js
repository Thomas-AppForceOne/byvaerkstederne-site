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
