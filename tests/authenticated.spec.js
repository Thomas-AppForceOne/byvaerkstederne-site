// @ts-check
const { test, expect } = require('@playwright/test');

/**
 * Authenticated user tests.
 *
 * Requires environment variables:
 *   TEST_USERNAME  — a valid Grav account username
 *   TEST_PASSWORD  — the account's password
 *
 * Run with:
 *   TEST_USERNAME=myuser TEST_PASSWORD=mypass npx playwright test tests/authenticated.spec.js
 *
 * Or add to a local .env.test file and source it before running.
 * Tests are skipped automatically when credentials are not set.
 */

const USERNAME = process.env.TEST_USERNAME;
const PASSWORD = process.env.TEST_PASSWORD;
const hasCredentials = Boolean(USERNAME && PASSWORD);

/**
 * Log in and return authenticated page state via storage state.
 * Used as a test fixture so each test starts already logged in.
 */
async function login(page) {
  await page.goto('/login');
  await page.fill('[name="username"], #username', USERNAME);
  await page.fill('[name="password"], #password', PASSWORD);
  await page.click('[type="submit"]');
  // Wait for redirect away from /login
  await page.waitForURL((url) => !url.pathname.includes('/login'), { timeout: 10_000 });
}

test.describe('Navigation — authenticated', () => {
  test.skip(!hasCredentials, 'Set TEST_USERNAME and TEST_PASSWORD to run authenticated tests');

  test.beforeEach(async ({ page }) => { await login(page); });

  test('main nav does not contain Forslå Feature', async ({ page }) => {
    await page.goto('/');
    const nav = page.locator('nav.bv-nav__links, .bv-nav');
    await expect(nav.getByRole('link', { name: /forsl/i })).toHaveCount(0);
  });

  test('main nav does not contain Roadmap', async ({ page }) => {
    await page.goto('/');
    const nav = page.locator('nav.bv-nav__links, .bv-nav');
    await expect(nav.getByRole('link', { name: /roadmap/i })).toHaveCount(0);
  });

  test('main nav does not contain Rapportér fejl', async ({ page }) => {
    await page.goto('/');
    const nav = page.locator('nav.bv-nav__links, .bv-nav');
    await expect(nav.getByText(/rapportér/i)).toHaveCount(0);
  });
});

test.describe('Footer — authenticated', () => {
  test.skip(!hasCredentials, 'Set TEST_USERNAME and TEST_PASSWORD to run authenticated tests');

  test.beforeEach(async ({ page }) => { await login(page); });

  test('footer shows Fællesskab column', async ({ page }) => {
    await page.goto('/');
    // The auth-gated column heading is an h3 — target it specifically to
    // avoid matching the always-visible h2 "Fællesskab gennem håndværk".
    const footer = page.locator('footer');
    await expect(footer.locator('h3.bv-footer__heading', { hasText: 'Fællesskab' })).toBeVisible();
  });

  test('footer contains Roadmap link', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    await expect(footer.getByRole('link', { name: /^roadmap$/i })).toBeVisible();
  });

  test('footer Roadmap link navigates to /roadmap', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    await footer.getByRole('link', { name: /^roadmap$/i }).click();
    await expect(page).toHaveURL(/\/roadmap/);
  });

  test('footer contains Forslå Feature trigger', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    await expect(footer.getByText(/forsl/i)).toBeVisible();
  });

  test('footer Forslå Feature trigger opens overlay', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    const trigger = footer.getByRole('button', { name: /forsl/i });
    await trigger.click();
    await expect(page.locator('#bv-feature-suggestion-overlay, .bv-feature-suggestion-overlay')).toBeVisible();
  });

  test('footer contains Rapportér fejl trigger', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    await expect(footer.getByText(/rapportér/i)).toBeVisible();
  });

  test('footer Rapportér fejl trigger opens bug report overlay', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    const trigger = footer.getByRole('button', { name: /rapportér/i });
    await trigger.click();
    await expect(page.locator('#bv-bug-report-overlay')).toBeVisible();
  });
});

test.describe('Roadmap — authenticated', () => {
  test.skip(!hasCredentials, 'Set TEST_USERNAME and TEST_PASSWORD to run authenticated tests');

  test.beforeEach(async ({ page }) => { await login(page); });

  test('/roadmap renders for authenticated users', async ({ page }) => {
    const response = await page.goto('/roadmap');
    expect(response?.status()).toBe(200);
    expect(page.url()).toContain('/roadmap');
  });

  test('vote button add and remove works without error', async ({ page }) => {
    await page.goto('/roadmap');

    // Find a voteable add button
    const addBtn = page.locator('.bv-rm-vote-btn[data-action="add"]').first();
    await expect(addBtn).toBeVisible();

    const errors = [];
    page.on('pageerror', (err) => errors.push(err.message));

    // Add vote
    await addBtn.click();
    // Wait for the remove button to appear (state toggled)
    const removeBtn = addBtn.locator('..').locator('.bv-rm-vote-btn[data-action="remove"]');
    await expect(removeBtn).toBeVisible({ timeout: 5_000 });

    // Remove vote
    await removeBtn.click();
    await expect(addBtn).toBeVisible({ timeout: 5_000 });

    expect(errors).toHaveLength(0);
  });
});
