// @ts-check
'use strict';

const { test, expect } = require('@playwright/test');

// Community affordances (Forslå Feature, Roadmap, Rapportér fejl) must not
// appear in the main navigation for anonymous users. They are footer-only
// and only visible to authenticated users. See decisions/ADR-001.

test.describe('Navigation — anonymous', () => {
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
    await expect(nav.getByRole('link', { name: /rapportér/i })).toHaveCount(0);
    await expect(nav.getByRole('button', { name: /rapportér/i })).toHaveCount(0);
  });

  test('mobile nav does not contain Forslå Feature', async ({ page }) => {
    await page.goto('/');
    const mobileNav = page.locator('.bv-mobile-menu');
    await expect(mobileNav.getByRole('link', { name: /forsl/i })).toHaveCount(0);
  });

  test('mobile nav does not contain Roadmap', async ({ page }) => {
    await page.goto('/');
    const mobileNav = page.locator('.bv-mobile-menu');
    await expect(mobileNav.getByRole('link', { name: /roadmap/i })).toHaveCount(0);
  });
});
