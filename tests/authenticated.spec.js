// @ts-check
'use strict';

/**
 * Authenticated test suite entry point.
 * Actual test cases live in tests/authenticated/ — one file per concern.
 *
 * Requires TEST_USERNAME and TEST_PASSWORD environment variables.
 * All tests are skipped automatically when credentials are not set.
 * Run with: make test-auth
 */

require('./authenticated/navigation');
require('./authenticated/footer');
require('./authenticated/roadmap');
require('./authenticated/bug-report');
require('./authenticated/feature-suggestion');
// WI-6 — login success/failure + rate-limit coverage.
require('./authenticated/login');
// Frontend event CRUD — organizer success paths + forced-browsing authz.
require('./authenticated/events-crud');
require('./authenticated/events-authz');
// Account self-service (/konto) — one file per operation; destructive flows
// run on disposable accounts only.
require('./authenticated/account-access-request');
require('./authenticated/account-dropdown');
require('./authenticated/account-email-change');
require('./authenticated/account-fullname');
require('./authenticated/account-password-change');
