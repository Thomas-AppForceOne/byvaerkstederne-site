// @ts-check
'use strict';

const { test, expect } = require('@playwright/test');

test.describe('Smoke — anonymous', () => {
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
