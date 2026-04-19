// @ts-check
'use strict';

/**
 * Playwright globalSetup hook.
 *
 * Idempotently provisions the canonical test accounts when their respective
 * password env vars are set. Fails fast with an actionable error if Docker
 * or the `grav` container isn't reachable — never silently skips.
 *
 * Secrets discipline: passwords are read from the environment and passed to
 * helpers without ever being printed, logged, or interpolated into a
 * thrown error message.
 */

const {
  TEST_USER,
  TEST_ADMIN,
  hasUserPassword,
  hasAdminPassword,
  ensureAccount,
} = require('./helpers/accounts');

module.exports = async function globalSetup() {
  if (hasUserPassword) {
    const password = process.env.TEST_PASSWORD || '';
    await ensureAccount(TEST_USER, password);
  }
  if (hasAdminPassword) {
    const password = process.env.TEST_ADMIN_PASSWORD || '';
    await ensureAccount(TEST_ADMIN, password);
  }
};
