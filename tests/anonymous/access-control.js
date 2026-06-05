// @ts-check
'use strict';

const { test, expect } = require('@playwright/test');

// Pages and features that require a login must be inaccessible to anonymous
// users — either redirecting to /login or rendering a login prompt.

test.describe('Access control — anonymous', () => {
  test('/roadmap redirects to login', async ({ page }) => {
    await page.goto('/roadmap');
    expect(page.url()).toContain('/login');
  });

  test('/foreslaa-feature is reachable and does not 4xx', async ({ page }) => {
    const response = await page.goto('/foreslaa-feature');
    expect(response?.status()).toBeLessThan(400);
  });
});
