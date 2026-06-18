// @ts-check
'use strict';

/**
 * Auth surface UI/UX — shared floating card (partials/auth_card.html.twig) and
 * the unified feedback component (.bv-message). Covers the spec's success AND
 * failure paths; fully anonymous — no credentials and no mail sink required.
 *
 *  - login: shared card, no horizontal overflow @1280x800, brand image rendered
 *  - account-creation + forgot present the shared floating card (.bv-auth-card)
 *  - forgot carries no English "Recover your password" boilerplate (head or body)
 *  - feedback variants are distinct + stable:
 *      forgot(unknown email) -> .bv-message--success  (login plugin flashes the
 *        no-enumeration "instructions sent" as scope 'info'; the theme maps
 *        info -> success — see partials/messages.html.twig)
 *      login(bad credentials) -> .bv-message--error
 */

const { test, expect } = require('@playwright/test');

test.describe('Auth surface UI/UX', () => {
  test('login: shared card, no horizontal overflow @1280x800, brand image rendered', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    const res = await page.goto('/login');
    expect(res?.status()).toBe(200);

    const card = page.locator('.bv-auth-card').first();
    await expect(card).toBeVisible();

    // The card shows its full text without a horizontal slider.
    const overflow = await card.evaluate((el) => el.scrollWidth - el.clientWidth);
    expect(overflow, 'login card must not overflow horizontally').toBeLessThanOrEqual(1);

    // The left brand image is present AND actually loads.
    const img = page.locator('.bv-auth-card__image img').first();
    await expect(img).toHaveAttribute('src', /login-panel\.svg/);
    const loaded = await img.evaluate((/** @type {HTMLImageElement} */ el) => el.complete && el.naturalWidth > 0);
    expect(loaded, 'login-panel.svg must load').toBe(true);
  });

  test('login overlay: no horizontal overflow @1280x800, brand image rendered', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/');
    // The overlay is the header-triggered login modal (always in the DOM).
    await page.evaluate(() => {
      const o = document.getElementById('bv-login-overlay');
      if (o) o.classList.add('is-open');
    });
    const panel = page.locator('.bv-login-overlay__panel').first();
    await expect(panel).toBeVisible();
    // Heading "Medlemslogin" must fit — no horizontal slider on the panel.
    const overflow = await panel.evaluate((el) => el.scrollWidth - el.clientWidth);
    expect(overflow, 'login overlay must not overflow horizontally').toBeLessThanOrEqual(1);
    // Brand image present and loaded (in colour — no grayscale placeholder look).
    const img = page.locator('.bv-login-overlay__image img').first();
    await expect(img).toHaveAttribute('src', /login-panel\.svg/);
    const loaded = await img.evaluate((/** @type {HTMLImageElement} */ el) => el.complete && el.naturalWidth > 0);
    expect(loaded, 'login-panel.svg must load in the overlay').toBe(true);
  });

  test('account creation presents the shared floating card', async ({ page }) => {
    const res = await page.goto('/opret-medlemskab');
    expect(res?.status()).toBe(200);
    await expect(page.locator('.bv-auth-card').first()).toBeVisible();
    // The registration form is rendered inside the card.
    expect(
      await page.locator('.bv-auth-card .bv-register-card form').count(),
      'registration form inside the auth card',
    ).toBeGreaterThan(0);
  });

  test('signup + recover open as modals over the current page (dimmed real site)', async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 800 });
    await page.goto('/home');
    // The nav "Bliv medlem" / login-modal links call bvOpenOverlay().
    await page.evaluate(() => bvOpenOverlay('bv-register-overlay'));
    const reg = page.locator('#bv-register-overlay');
    await expect(reg).toHaveClass(/is-open/);
    // Fixed, dimmed modal over the page (NOT a standalone gray page).
    const style = await reg.evaluate((el) => {
      const cs = getComputedStyle(el);
      return { position: cs.position, bg: cs.backgroundColor };
    });
    expect(style.position).toBe('fixed');
    expect(style.bg, 'dims the real page behind').toMatch(/rgba\(26,\s*28,\s*28,\s*0?\.5\)/);
    expect(await reg.locator('.bv-register-card form').count(), 'registration form in the modal').toBeGreaterThan(0);
    // One at a time: opening recover closes signup.
    await page.evaluate(() => bvOpenOverlay('bv-forgot-overlay'));
    await expect(page.locator('#bv-forgot-overlay')).toHaveClass(/is-open/);
    await expect(reg).not.toHaveClass(/is-open/);
    await expect(page.locator('#bv-forgot-overlay input[name="email"]')).toBeVisible();
  });

  test('recover modal submits from the current page (no-enumeration success)', async ({ page }) => {
    await page.goto('/home');
    await page.evaluate(() => bvOpenOverlay('bv-forgot-overlay'));
    await page.locator('#bv-forgot-overlay input[name="email"]').fill('definitely-not-a-user@example.invalid');
    await Promise.all([
      page.waitForLoadState('networkidle'),
      page.locator('#bv-forgot-overlay button[type="submit"]').click(),
    ]);
    // Proves task=login.forgot is processed from the homepage (not only /forgot_password).
    await expect(
      page.locator('.bv-message--success').first(),
      'forgot confirmation flash renders after submitting from the modal',
    ).toBeVisible();
  });

  test('forgot presents the shared card with no English boilerplate', async ({ page }) => {
    const res = await page.goto('/forgot_password');
    expect(res?.status()).toBe(200);
    await expect(page.locator('.bv-auth-card').first()).toBeVisible();

    const html = (await page.content()) || '';
    expect(html, 'no English forgot boilerplate anywhere on the surface (head or body)')
      .not.toMatch(/Recover your password|Enter your email to recover/i);
    // The plugin form (with its CSRF nonce) is still rendered inside the card.
    expect(html, 'forgot form nonce still present').toMatch(/name="forgot-form-nonce"/);
  });

  test('feedback variants are distinct and stable (success vs error)', async ({ page }) => {
    // --- Success variant: forgot for an unknown account -> info flash -> success. ---
    await page.goto('/forgot_password');
    const email = page
      .locator('#grav-login form input[type="email"], #grav-login form input[name="data[email]"], #grav-login form input[type="text"]')
      .first();
    await email.fill('definitely-not-a-user@example.invalid');
    await Promise.all([
      page.waitForLoadState('networkidle'),
      page.locator('#grav-login form button[type="submit"], #grav-login form [name="task"][value="login.forgot"]').first().click(),
    ]);
    await expect(
      page.locator('.bv-message--success').first(),
      'forgot confirmation renders the success variant',
    ).toBeVisible();
    expect(
      await page.locator('.bv-message--error').count(),
      'success path must not also show the error variant',
    ).toBe(0);

    // --- Error variant: login with bad credentials -> error flash -> error. ---
    await page.goto('/login');
    const loginForm = page.locator('.bv-auth-card form').filter({ has: page.locator('input[name="username"]') }).first();
    await loginForm.locator('input[name="username"]').fill('definitely-not-a-user');
    await loginForm.locator('input[name="password"]').fill('wrong-password-xyz');
    await Promise.all([
      page.waitForLoadState('networkidle'),
      loginForm.locator('button[type="submit"]').click(),
    ]);
    await expect(
      page.locator('.bv-message--error').first(),
      'failed login renders the error variant',
    ).toBeVisible();
  });
});
