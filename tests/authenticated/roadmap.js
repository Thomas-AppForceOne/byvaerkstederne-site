// @ts-check
'use strict';

const { test, expect } = require('@playwright/test');
const { login, hasCredentials } = require('../helpers/auth');

test.describe('Roadmap — authenticated', () => {
  test.skip(!hasCredentials, 'Set TEST_USERNAME and TEST_PASSWORD to run authenticated tests');
  test.beforeEach(async ({ page }) => { await login(page); });

  test('/roadmap is accessible', async ({ page }) => {
    const response = await page.goto('/roadmap');
    expect(response?.status()).toBe(200);
    expect(page.url()).toContain('/roadmap');
  });

  test('vote add and remove works without JS errors', async ({ page }) => {
    await page.goto('/roadmap');

    const errors = [];
    page.on('pageerror', (err) => errors.push(err.message));

    const addBtn = page.locator('.bv-rm-vote-btn[data-action="add"]').first();
    await expect(addBtn).toBeVisible();

    await addBtn.click();
    const removeBtn = addBtn.locator('..').locator('.bv-rm-vote-btn[data-action="remove"]');
    await expect(removeBtn).toBeVisible({ timeout: 5_000 });

    await removeBtn.click();
    await expect(addBtn).toBeVisible({ timeout: 5_000 });

    expect(errors).toHaveLength(0);
  });
});
