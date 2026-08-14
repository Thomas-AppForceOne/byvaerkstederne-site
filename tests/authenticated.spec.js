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
// Remember-me ("Husk mig") resilience — race/UA-swap/tamper regression coverage.
require('./authenticated/remember-me');
// Frontend event CRUD — organizer success paths + forced-browsing authz.
require('./authenticated/events-crud');
require('./authenticated/events-authz');
// Inline card editor for /begivenheder/opret (the redesigned create page).
require('./authenticated/events-create-editor');
// Event RSVP — signup/withdraw, capacity, forced-browsing negatives, attendee
// visibility; rich details sanitisation + image upload.
require('./authenticated/events-rsvp');
require('./authenticated/events-details');
// Account self-service (/konto) — one file per operation; destructive flows
// run on disposable accounts only.
require('./authenticated/account-access-request');
// Privilege-escalation alert fired by the tier tooling after a super grant.
require('./authenticated/super-granted-alert');
// Site-side detection of a super created outside the tooling.
require('./authenticated/super-watch');
require('./authenticated/account-deletion');
require('./authenticated/account-dropdown');
require('./authenticated/account-email-change');
require('./authenticated/account-fullname');
require('./authenticated/account-password-change');
require('./authenticated/account-purge');
