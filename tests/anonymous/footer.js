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

// The EU co-funding acknowledgement is a funding obligation: it must appear
// in the footer of every page, for every visitor, with no feature flag and no
// auth gate in front of it.
test.describe('Footer — EU co-funding logo', () => {
  const routes = ['/', '/vaerkstedskalenderen', '/vaerksteder', '/kontakt'];

  for (const route of routes) {
    test(`is shown on ${route}`, async ({ page }) => {
      await page.goto(route);
      const logo = page.locator('footer img.bv-footer__funding-logo');
      await expect(logo).toHaveCount(1);
      await expect(logo).toBeVisible();
      await expect(logo).toHaveAttribute('alt', 'Medfinansieret af Den Europæiske Union');
    });
  }

  // Failure path: a typo'd or missing asset still renders an <img> element, so
  // presence alone proves nothing. Fetch the src and decode it — a 404 or a
  // corrupt file gives a non-200 response and naturalWidth 0.
  test('image asset actually loads (broken src fails this test)', async ({ page }) => {
    await page.goto('/');
    const logo = page.locator('footer img.bv-footer__funding-logo');
    const src = await logo.getAttribute('src');
    expect(src).toBeTruthy();

    const response = await page.request.get(new URL(String(src), page.url()).toString());
    expect(response.status()).toBe(200);
    expect((await response.body()).length).toBeGreaterThan(0);

    const naturalWidth = await logo.evaluate((img) => /** @type {HTMLImageElement} */ (img).naturalWidth);
    expect(naturalWidth).toBeGreaterThan(0);
  });

  // Regression guard: it must not end up inside the auth-gated Fællesskab
  // column or any feature-flagged block — anonymous visitors see it too, and
  // this suite runs anonymous.
  test('is outside the auth-gated Fællesskab column', async ({ page }) => {
    await page.goto('/');
    const inCommunityColumn = page.locator('footer .bv-footer__col img.bv-footer__funding-logo');
    await expect(inCommunityColumn).toHaveCount(0);
  });
});
