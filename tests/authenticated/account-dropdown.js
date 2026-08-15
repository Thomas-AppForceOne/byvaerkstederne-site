// @ts-check
'use strict';

/**
 * Account self-service — header dropdown
 * (account_self_service_specification.md §5/§10).
 *
 *   - the logged-in chip is an accessible menu button: opens on click,
 *     closes on Escape (focus returns), outside click; keyboard navigation;
 *   - entries deep-link to the right /konto sections;
 *   - "Log ud" stays a separate, functional header link;
 *   - the mobile overlay lists the same entries inline;
 *   - anonymous pages carry no menu markup;
 *   - with the flag off the chip renders as today's dead <span> (profile
 *     cache-flip, restored in afterAll — the run probes 127.0.0.1, which Grav
 *     aliases to the `localhost` environment, so the flip has to land in
 *     user/env/localhost/, not in the empty fail-closed fallback at
 *     user/config/features.yaml — see ADR-007).
 *
 * Read-only against the seeded pw-test-user.
 */

const { test, expect } = require('@playwright/test');
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { login, hasUserPassword } = require('../helpers/auth');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

const WORKTREE = path.resolve(__dirname, '..', '..');
const LOCALHOST_FEATURES_YAML = path.join(
  WORKTREE, 'config', 'www', 'user', 'env', 'localhost', 'config', 'features.yaml',
);

function clearGravCache() {
  const { container } = discoverGravEnv(WORKTREE);
  execSync(`docker exec -u abc -w /app/www/public ${container} bin/grav clearcache`, {
    stdio: ['ignore', 'pipe', 'pipe'],
    timeout: 30_000,
  });
}

test.describe('account self-service: header dropdown', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');

  test('opens on click, closes on Escape with focus returned', async ({ page }) => {
    await login(page);
    await page.goto('/');
    const button = page.locator('.bv-nav__user--menu');
    const menu = page.locator('#bv-account-menu');

    await expect(button).toBeVisible();
    await expect(button).toHaveAttribute('aria-expanded', 'false');
    await expect(menu).toBeHidden();

    await button.click();
    await expect(menu).toBeVisible();
    await expect(button).toHaveAttribute('aria-expanded', 'true');

    await page.keyboard.press('Escape');
    await expect(menu).toBeHidden();
    await expect(button).toHaveAttribute('aria-expanded', 'false');
    await expect(button).toBeFocused();
  });

  test('closes on outside click', async ({ page }) => {
    await login(page);
    await page.goto('/');
    const button = page.locator('.bv-nav__user--menu');
    const menu = page.locator('#bv-account-menu');

    await button.click();
    await expect(menu).toBeVisible();
    // Raw viewport-coordinate click well below the fixed header (the <main>
    // element's top edge sits underneath it and would be intercepted).
    await page.mouse.click(20, 400);
    await expect(menu).toBeHidden();
  });

  test('keyboard: ArrowDown opens and focuses the first item; arrows cycle', async ({ page }) => {
    await login(page);
    await page.goto('/');
    const button = page.locator('.bv-nav__user--menu');
    const items = page.locator('#bv-account-menu [role="menuitem"]');

    await button.focus();
    await page.keyboard.press('ArrowDown');
    await expect(items.first()).toBeFocused();

    await page.keyboard.press('ArrowDown');
    await expect(items.nth(1)).toBeFocused();

    await page.keyboard.press('End');
    await expect(items.last()).toBeFocused();

    await page.keyboard.press('Escape');
    await expect(page.locator('#bv-account-menu')).toBeHidden();
  });

  test('entries deep-link to the right /konto sections', async ({ page }) => {
    await login(page);
    await page.goto('/');
    await page.locator('.bv-nav__user--menu').click();
    await page.locator('#bv-account-menu [role="menuitem"]', { hasText: 'Skift adgangskode' }).click();

    await expect(page).toHaveURL(/\/konto#password/);
    await expect(page.locator('#password')).toBeVisible();

    // From /konto the anchors are same-page navigations.
    await page.locator('.bv-nav__user--menu').click();
    await page.locator('#bv-account-menu [role="menuitem"]', { hasText: 'Slet konto' }).click();
    await expect(page).toHaveURL(/\/konto#delete/);
    await expect(page.locator('#delete')).toBeVisible();
    await expect(page.locator('#bv-account-menu')).toBeHidden();
  });

  test('"Log ud" stays a separate header link and still logs out', async ({ page }) => {
    await login(page);
    await page.goto('/');
    const logout = page.locator('.bv-nav__links a', { hasText: 'Log ud' });
    await expect(logout).toBeVisible();
    await logout.click();
    await page.waitForLoadState('networkidle');
    await expect(page.locator('.bv-nav__user')).toHaveCount(0);
  });

  test('mobile overlay lists the account entries under the user name', async ({ page }) => {
    await login(page);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/');
    await page.locator('.bv-nav__hamburger').click();

    const entries = page.locator('.bv-mobile-menu__link--account');
    await expect(entries).toHaveCount(6);
    await entries.first().click(); // "Min konto"
    await expect(page).toHaveURL(/\/konto/);
  });

  test('anonymous pages carry no menu markup', async ({ page }) => {
    await page.goto('/');
    expect(await page.locator('.bv-nav__user--menu').count()).toBe(0);
    expect(await page.locator('#bv-account-menu').count()).toBe(0);
  });

  test.describe('flag off (base-profile cache flip)', () => {
    let originalYaml = '';

    test.beforeAll(() => {
      originalYaml = fs.readFileSync(LOCALHOST_FEATURES_YAML, 'utf8');
      expect(originalYaml).toContain('account_self_service: "true"');
      fs.writeFileSync(
        LOCALHOST_FEATURES_YAML,
        originalYaml.replace(/(\n\s*account_self_service:\s*)"true"/, '$1"false"'),
        'utf8',
      );
      clearGravCache();
    });

    test.afterAll(() => {
      // Belt-and-braces restore — the file must never stay flipped.
      try {
        fs.writeFileSync(LOCALHOST_FEATURES_YAML, originalYaml, 'utf8');
        clearGravCache();
      } catch (_) { /* best-effort */ }
    });

    test('chip renders as a dead span; no dropdown, no mobile entries; Log ud intact', async ({ page }) => {
      await login(page);
      await page.goto('/');

      await expect(page.locator('span.bv-nav__user')).toBeVisible();
      expect(await page.locator('.bv-nav__user--menu').count()).toBe(0);
      expect(await page.locator('#bv-account-menu').count()).toBe(0);
      await expect(page.locator('.bv-nav__links a', { hasText: 'Log ud' })).toBeVisible();

      await page.setViewportSize({ width: 390, height: 844 });
      await page.locator('.bv-nav__hamburger').click();
      expect(await page.locator('.bv-mobile-menu__link--account').count()).toBe(0);
    });
  });
});
