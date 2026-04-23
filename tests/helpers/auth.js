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
  // The login form is rendered inside #bv-login-overlay, which is hidden by
  // default on /login. Force it open so page.fill doesn't wait for visibility.
  await page.evaluate(() => {
    const overlay = document.getElementById('bv-login-overlay');
    if (overlay) overlay.classList.add('is-open');
  });
  const form = page.locator('#bv-login-overlay form');
  await form.locator('[name="username"]').fill(username);
  await form.locator('[name="password"]').fill(password);
  await form.locator('[type="submit"]').click();
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
 * Grav runs separate session cookies for the site (/login) and admin (/admin).
 * We submit the admin login form at /admin directly so subsequent /admin/*
 * navigation sees the authenticated admin session.
 *
 * @param {import('@playwright/test').Page} page
 */
async function loginAsAdmin(page) {
  const password = process.env.TEST_ADMIN_PASSWORD;
  if (!password) {
    throw new Error('loginAsAdmin(): TEST_ADMIN_PASSWORD env var is not set');
  }
  await page.goto('/admin');
  const form = page.locator('#admin-login form');
  await form.locator('[name="data[username]"]').fill(TEST_ADMIN.username);
  await form.locator('[name="data[password]"]').fill(password);
  await Promise.all([
    page.waitForURL((url) => !/\/admin\/?$/.test(url.pathname) || url.search.includes('task') === false,
      { timeout: 10_000 }).catch(() => {}),
    form.locator('[type="submit"], button[type="submit"]').first().click(),
  ]);
  // Confirm we are past the login form.
  await page.waitForFunction(() => !document.getElementById('admin-login'), null, { timeout: 10_000 });
}

module.exports = {
  login,
  loginAsAdmin,
  hasUserPassword,
  hasAdminPassword,
};
