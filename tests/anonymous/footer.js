// @ts-check
'use strict';

const { test, expect } = require('@playwright/test');

// The Fællesskab footer column (Roadmap, Forslå Feature, Rapportér fejl)
// must be hidden entirely for anonymous users. See decisions/ADR-001.
//
// Note: the footer contains an always-visible h2 "Fællesskab gennem håndværk",
// so tests must target the auth-gated h3 column heading specifically.

test.describe('Footer — anonymous', () => {
  test('Fællesskab column is not shown', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer');
    await expect(footer.locator('h3.bv-footer__heading', { hasText: 'Fællesskab' })).toHaveCount(0);
  });

  test('Roadmap link is not shown', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer');
    await expect(footer.getByRole('link', { name: /^roadmap$/i })).toHaveCount(0);
  });

  test('Forslå Feature trigger is not shown', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer');
    await expect(footer.getByText(/forsl/i)).toHaveCount(0);
  });

  test('Rapportér fejl trigger is not shown', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer');
    await expect(footer.getByText(/rapportér/i)).toHaveCount(0);
  });
});
