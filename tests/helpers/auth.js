// @ts-check
'use strict';

const USERNAME = process.env.TEST_USERNAME;
const PASSWORD = process.env.TEST_PASSWORD;
const hasCredentials = Boolean(USERNAME && PASSWORD);

/**
 * Log in via the Grav login form.
 * Use as a beforeEach fixture in authenticated test suites.
 *
 * @param {import('@playwright/test').Page} page
 */
async function login(page) {
  await page.goto('/login');
  await page.fill('[name="username"], #username', USERNAME);
  await page.fill('[name="password"], #password', PASSWORD);
  await page.click('[type="submit"]');
  await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 10_000 });
}

module.exports = { login, hasCredentials };
