// @ts-check
const { test, expect } = require('@playwright/test');

/**
 * Anonymous (unauthenticated) user tests.
 * These run against the live Docker site with no credentials required.
 */

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

test.describe('Footer — anonymous', () => {
  test('footer does not show Fællesskab column', async ({ page }) => {
    await page.goto('/');
    // Target the column heading specifically — the footer also has an h2
    // "Fællesskab gennem håndværk" that is always visible, so we must not
    // match on substring. The auth-gated column heading is an h3.
    const footer = page.locator('footer');
    await expect(footer.locator('h3.bv-footer__heading', { hasText: 'Fællesskab' })).toHaveCount(0);
  });

  test('footer does not contain Roadmap link', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    await expect(footer.getByRole('link', { name: /^roadmap$/i })).toHaveCount(0);
  });

  test('footer does not contain Forslå Feature trigger', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    await expect(footer.getByText(/forsl/i)).toHaveCount(0);
  });

  test('footer does not contain Rapportér fejl trigger', async ({ page }) => {
    await page.goto('/');
    const footer = page.locator('footer, .bv-footer');
    await expect(footer.getByText(/rapportér/i)).toHaveCount(0);
  });
});

test.describe('Access control — anonymous', () => {
  test('/roadmap redirects anonymous users to login', async ({ page }) => {
    const response = await page.goto('/roadmap');
    // Grav issues a redirect; final URL should contain /login
    expect(page.url()).toContain('/login');
  });

  test('/foreslaa-feature is accessible but shows login prompt', async ({ page }) => {
    const response = await page.goto('/foreslaa-feature');
    expect(response?.status()).toBeLessThan(400);
  });
});

test.describe('Core pages — smoke', () => {
  const routes = ['/', '/vaerkstedskalenderen', '/vaerksteder', '/kontakt'];

  for (const route of routes) {
    test(`${route} returns 200`, async ({ page }) => {
      const response = await page.goto(route);
      expect(response?.status()).toBe(200);
    });
  }

  test('theme CSS loads without error', async ({ page }) => {
    const failed = [];
    page.on('response', (response) => {
      if (response.url().includes('theme.css') && response.status() >= 400) {
        failed.push(response.url());
      }
    });
    await page.goto('/');
    expect(failed).toHaveLength(0);
  });

  test('site.js loads without error', async ({ page }) => {
    const failed = [];
    page.on('response', (response) => {
      if (response.url().includes('site.js') && response.status() >= 400) {
        failed.push(response.url());
      }
    });
    await page.goto('/');
    expect(failed).toHaveLength(0);
  });

  test('no JavaScript console errors on homepage', async ({ page }) => {
    const errors = [];
    page.on('pageerror', (err) => errors.push(err.message));
    await page.goto('/');
    expect(errors).toHaveLength(0);
  });
});
