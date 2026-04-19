// @ts-check
'use strict';

/**
 * Authentication helpers for Playwright tests.
 *
 * Canonical account definitions and the password-availability flags now live
 * in tests/helpers/accounts.js — this module re-exports the flags so test
 * files have a single import surface for "do I have credentials?" checks.
 */

const {
  TEST_USER,
  TEST_ADMIN,
  hasUserPassword,
  hasAdminPassword,
} = require('./accounts');

/**
 * Internal: perform the Grav login form POST for the supplied username and
 * password. Both arguments are required and are read directly from the
 * environment by the public wrappers below — never logged.
 *
 * @param {import('@playwright/test').Page} page
 * @param {string} username
 * @param {string} password
 */
async function loginWith(page, username, password) {
  await page.goto('/login');
  await page.fill('[name="username"], #username', username);
  await page.fill('[name="password"], #password', password);
  await page.click('[type="submit"]');
  await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 10_000 });
}

/**
 * Log in as the canonical test user. Reads TEST_PASSWORD from the env.
 * Signature is unchanged from the previous helper: a single Page argument.
 *
 * @param {import('@playwright/test').Page} page
 */
async function login(page) {
  const password = process.env.TEST_PASSWORD;
  if (!password) {
    throw new Error('login(): TEST_PASSWORD env var is not set');
  }
  await loginWith(page, TEST_USER.username, password);
}

/**
 * Log in as the canonical test admin. Reads TEST_ADMIN_PASSWORD from the env.
 *
 * @param {import('@playwright/test').Page} page
 */
async function loginAsAdmin(page) {
  const password = process.env.TEST_ADMIN_PASSWORD;
  if (!password) {
    throw new Error('loginAsAdmin(): TEST_ADMIN_PASSWORD env var is not set');
  }
  await loginWith(page, TEST_ADMIN.username, password);
}

module.exports = {
  login,
  loginAsAdmin,
  hasUserPassword,
  hasAdminPassword,
};
