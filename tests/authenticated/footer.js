// @ts-check
'use strict';

const { test, expect } = require('@playwright/test');
const { login, hasCredentials } = require('../helpers/auth');

// The Fællesskab footer column must be visible for authenticated users and all
// three triggers must be present and functional. See decisions/ADR-001.
//
// Note: the footer also contains an always-visible h2 "Fællesskab gennem
// håndværk" — tests targeting the column heading must use the h3 selector.

test.describe('Footer — authenticated', () => {
  test.skip(!hasCredentials, 'Set TEST_USERNAME and TEST_PASSWORD to run authenticated tests');
  test.beforeEach(async ({ page }) => { await login(page); });

  test('Fællesskab column is visible', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer');
    await expect(footer.locator('h3.bv-footer__heading', { hasText: 'Fællesskab' })).toBeVisible();
  });

  test('Roadmap link is present and navigates to /roadmap', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer');
    const link = footer.getByRole('link', { name: /^roadmap$/i });
    await expect(link).toBeVisible();
    await link.click();
    await expect(page).toHaveURL(/\/roadmap/);
  });

  test('Forslå Feature button opens the feature suggestion overlay', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer');
    await footer.getByRole('button', { name: /forsl/i }).click();
    await expect(page.locator('#bv-feature-suggestion-overlay, .bv-feature-suggestion-overlay')).toBeVisible();
  });

  test('Rapportér fejl button opens the bug report overlay', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer');
    await footer.getByRole('button', { name: /rapportér/i }).click();
    await expect(page.locator('#bv-bug-report-overlay')).toBeVisible();
  });
});
