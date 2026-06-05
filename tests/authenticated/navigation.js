// @ts-check
'use strict';

const { test, expect } = require('@playwright/test');
const { login, hasUserPassword } = require('../helpers/auth');

// Community affordances must not appear in the main navigation even when
// logged in — they are footer-only. See decisions/ADR-001.

test.describe('Navigation — authenticated', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — skipping authenticated navigation tests');
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
