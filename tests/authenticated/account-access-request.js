// @ts-check
'use strict';

/**
 * Account self-service — access request (arrangør)
 * (account_self_service_specification.md §8/§10).
 *
 *   - requesting shows the pending state and produces the admin email
 *     (addressed to every enabled super-admin, resolved from the accounts —
 *     there is no delivery fallback; with no reachable super the member is
 *     told to contact the association instead);
 *   - a duplicate open request is refused (direct POST — the form is
 *     hidden while a request is open);
 *   - cancelling stamps the cooldown; an immediate re-request is refused;
 *   - an unrequestable role is refused;
 *   - once the group is granted (container-side YAML patch — simulating the
 *     manual super action), the state derives to granted and the marker is
 *     lazily cleared.
 *
 * Destructive → each test runs on its own disposable account (self-
 * contained, so retries never inherit half-consumed state or nonces from
 * a previous worker).
 */

const { test, expect } = require('@playwright/test');
const { hasUserPassword } = require('../helpers/auth');
const {
  isMailSinkConfigured,
  mailSinkUrl,
  clearMail,
  waitForMail,
  expectNoMail,
  extractLink,
} = require('../helpers/mail');
const { TEST_ADMIN, hasAdminPassword, ensureAccount } = require('../helpers/accounts');
const {
  createDisposableAccount,
  removeDisposableAccount,
  readAccountYaml,
  grantGroups,
  loginAs,
  withoutReachableSupers,
} = require('../helpers/self-service');

// Operator mail is addressed to every ENABLED super-admin, resolved from the
// accounts themselves; pw-test-admin is that super here. There is no delivery
// fallback, so every mail-bearing test needs the super seeded — hence the
// TEST_ADMIN_PASSWORD skip on each of them.
const ADMIN_RECIPIENT = TEST_ADMIN.email;
// The association's PUBLIC contact address. It is what the member is told to
// write to when no super can be notified — and must never itself receive
// operator mail: whoever reads it is not necessarily a super.
const SITE_AUTHOR_CONTACT = 'kontakt@byvaerkstederne.dk';

/**
 * Mint the request-form nonce for the CURRENT session (the form must still
 * be rendered — i.e. no open request yet).
 */
async function mintRequestNonce(page) {
  await page.goto('/konto');
  return page
    .locator('#roles form[action="/konto/request-access"] input[name="account-nonce"]')
    .inputValue();
}

/** Submit the access-request form on /konto through the UI. */
async function submitAccessRequest(page, motivation) {
  await page.goto('/konto');
  await page.selectOption('#account-access-role', 'organizers');
  if (motivation) {
    await page.fill('#account-access-motivation', motivation);
  }
  await page.click('#roles form[action="/konto/request-access"] button[type="submit"]');
  await page.waitForURL(/\/konto/);
}

test.describe('account self-service: access request', () => {
  test.skip(!hasUserPassword, 'TEST_PASSWORD not set — anonymous-only mode');

  // Seed the super that operator mail is addressed to. Without it nothing is
  // sent at all — there is no fallback recipient — so the mail-bearing tests
  // skip rather than assert against a delivery that cannot happen.
  test.beforeAll(async () => {
    if (hasAdminPassword) {
      await ensureAccount(TEST_ADMIN, process.env.TEST_ADMIN_PASSWORD);
    }
  });

  test('request shows pending state, notifies admins; duplicate is refused', async ({ page }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — no super-admin to notify');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    const acct = createDisposableAccount({ tag: 'ar' });
    try {
      await clearMail();
      expect(await loginAs(page, acct)).toBe(true);
      const nonce = await mintRequestNonce(page);

      await submitAccessRequest(page, 'Jeg vil gerne arrangere træworkshops.');
      await expect(page.locator('.bv-message--success')).toContainText('afventer godkendelse');
      await expect(page.locator('[data-pending="access"]')).toContainText('Arrangør');
      expect(readAccountYaml(acct.username)).toContain('access_request');

      const msg = await waitForMail(ADMIN_RECIPIENT);
      expect(JSON.stringify(msg)).toContain(acct.username);

      // The approve/reject links must be ABSOLUTE (Utils::url $domain=true);
      // a root-relative href renders as file:///konto/... in mail clients.
      const mailBody = String(msg.HTML || msg.Text || '');
      expect(mailBody).toMatch(/https?:\/\/[^\s"'<>]+\/konto\/access-request\/approve\?/);
      expect(mailBody).toMatch(/https?:\/\/[^\s"'<>]+\/konto\/access-request\/reject\?/);

      // Duplicate open request: the form is hidden now, so forced browsing
      // is the only route — refused with 400.
      const resp = await page.request.post('/konto/request-access', {
        maxRedirects: 0,
        form: { 'account-nonce': nonce, role: 'organizers', motivation: '' },
      });
      expect(resp.status()).toBe(400);
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('the admin mail is addressed to the super-admin, never to the contact address', async ({
    page,
  }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — no super to address');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    const acct = createDisposableAccount({ tag: 'sup' });
    // An ordinary member: proves the resolver selects supers, not accounts.
    const member = createDisposableAccount({ tag: 'mem' });
    try {
      await clearMail();
      expect(await loginAs(page, acct)).toBe(true);
      await submitAccessRequest(page, 'Modtager skal være super-admin.');

      const msg = await waitForMail(TEST_ADMIN.email);
      expect(msg.Subject).toMatch(/^Anmodning om rettigheder/);
      expect(JSON.stringify(msg), 'the applicant is named in the admin mail').toContain(
        acct.username,
      );

      // The pre-change route: with a super reachable, the site-author
      // address must receive nothing at all. This is the regression that
      // sent a tier's access requests to an address nobody was reading.
      expect(
        await expectNoMail(SITE_AUTHOR_CONTACT),
        'the public contact address is never an operator-mail recipient',
      ).toBe(true);
      expect(
        await expectNoMail(member.email),
        'an ordinary member is not an operator-mail recipient',
      ).toBe(true);
    } finally {
      removeDisposableAccount(member.username);
      removeDisposableAccount(acct.username);
    }
  });

  test('with no reachable super the member is told to contact the association', async ({ page }) => {
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    const acct = createDisposableAccount({ tag: 'nsu' });
    let restoreSupers = null;
    try {
      await clearMail();
      expect(await loginAs(page, acct)).toBe(true);
      restoreSupers = withoutReachableSupers();

      await submitAccessRequest(page, 'Ingen super at underrette.');

      // Not a success claim: the member is told the notification failed and
      // where to take it. Silently answering "din anmodning er sendt" is
      // what made the original misroute invisible.
      const flash = page.locator('.bv-message--warning');
      await expect(flash).toContainText('kunne ikke give administratorerne besked');
      await expect(flash).toContainText(SITE_AUTHOR_CONTACT);
      expect(await page.locator('.bv-message--success').count()).toBe(0);

      // The request itself is stored regardless, so a super can still act
      // on it once someone escalates.
      expect(readAccountYaml(acct.username)).toContain('access_request');

      // And nothing was delivered to the contact address — it is an
      // instruction to a human, not a mail recipient.
      expect(
        await expectNoMail(SITE_AUTHOR_CONTACT),
        'the contact address must not receive the operator mail',
      ).toBe(true);
    } finally {
      if (restoreSupers) restoreSupers();
      removeDisposableAccount(acct.username);
    }
  });

  test('cancel clears the request; immediate re-request hits the cooldown', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'ac' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      const nonce = await mintRequestNonce(page);
      await submitAccessRequest(page, '');

      await page.goto('/konto');
      await page.click('#roles form[action="/konto/cancel-access-request"] button[type="submit"]');
      await page.waitForURL(/\/konto/);
      await expect(page.locator('.bv-message--success')).toContainText('fortrudt');

      const yaml = readAccountYaml(acct.username);
      expect(yaml).not.toContain('access_request:');
      expect(yaml).toContain('access_request_cleared_at');

      // Cooldown (24h default) blocks the immediate re-request.
      const resp = await page.request.post('/konto/request-access', {
        maxRedirects: 0,
        form: { 'account-nonce': nonce, role: 'organizers', motivation: '' },
      });
      expect(resp.status()).toBe(429);
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('an unrequestable role is refused', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'au' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      const nonce = await mintRequestNonce(page);
      const resp = await page.request.post('/konto/request-access', {
        maxRedirects: 0,
        form: { 'account-nonce': nonce, role: 'admins', motivation: '' },
      });
      expect(resp.status()).toBe(400);
      expect(readAccountYaml(acct.username)).not.toContain('access_request');
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('granting the group derives to granted and clears the marker', async ({ page }) => {
    const acct = createDisposableAccount({ tag: 'gr' });
    try {
      expect(await loginAs(page, acct)).toBe(true);
      await submitAccessRequest(page, '');
      expect(readAccountYaml(acct.username)).toContain('access_request');

      // The manual super action: the group lands on the account YAML.
      grantGroups(acct.username, ['organizers']);

      await page.goto('/konto');
      // Granted: role chip visible, pending state gone…
      await expect(page.locator('.bv-account-roles__item', { hasText: 'Arrangør' })).toBeVisible();
      expect(await page.locator('[data-pending="access"]').count()).toBe(0);
      // …and the stale marker was lazily cleared from the YAML (§4.2).
      expect(readAccountYaml(acct.username)).not.toContain('access_request:');
    } finally {
      removeDisposableAccount(acct.username);
    }
  });

  test('a super approves via the mail link without any admin group', async ({ page, browser }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — admin approval flow unavailable');
    await ensureAccount(TEST_ADMIN, process.env.TEST_ADMIN_PASSWORD);
    const target = createDisposableAccount({ tag: 'apr' });
    try {
      await clearMail();
      expect(await loginAs(page, target)).toBe(true);
      await submitAccessRequest(page, 'Godkendelsesflow via maillink.');
      const msg = await waitForMail(ADMIN_RECIPIENT);
      const approveLink = extractLink(
        msg,
        /https?:\/\/[^\s"'<>]+\/konto\/access-request\/approve[^\s"'<>]*/
      );
      expect(approveLink).toBeTruthy();
      // Navigate via path+query: deployed tiers get a correct absolute host
      // from system.custom_base_url, but the local container has none set,
      // so the generated host lacks the mapped port.
      const approvePath = approveLink.replace(/^https?:\/\/[^/]+/, '');

      // pw-test-admin is a super (access.admin.super) with NO groups entry —
      // the endpoint must accept supers directly, not only members of an
      // 'admin' group that groups.yaml never defined.
      const adminContext = await browser.newContext();
      const adminPage = await adminContext.newPage();
      expect(
        await loginAs(adminPage, {
          username: TEST_ADMIN.username,
          password: process.env.TEST_ADMIN_PASSWORD,
        })
      ).toBe(true);
      const approveResp = await adminPage.goto(approvePath);
      // Success renders the themed fact sheet (200) with the applicant's
      // details; a 403 means the super was refused (the pre-fix
      // phantom-group lockout).
      expect(approveResp.status()).toBe(200);
      await expect(adminPage).toHaveTitle(/Anmodning godkendt/);
      await expect(adminPage.locator('.bv-auth-card')).toContainText('Anmodning godkendt');
      await expect(adminPage.locator('.bv-ar-result')).toContainText(target.username);
      await expect(adminPage.locator('.bv-ar-result')).toContainText(target.email);
      await expect(adminPage.locator('.bv-ar-result')).toContainText('Arrangør');

      // Re-using the consumed link must show the NEUTRAL card: 404, no
      // applicant data — indistinguishable from a bad or expired token.
      const replayResp = await adminPage.goto(approvePath);
      expect(replayResp.status()).toBe(404);
      await expect(adminPage.locator('.bv-auth-card')).toContainText('kunne ikke behandles');
      expect(await adminPage.content()).not.toContain(target.username);
      await adminContext.close();

      const yaml = readAccountYaml(target.username);
      expect(yaml).toContain('- organizers');
      expect(yaml).not.toContain('access_request:');

      // The applicant is notified of the approval.
      const applicantMsg = await waitForMail(target.email);
      expect(JSON.stringify(applicantMsg)).toContain('godkendt');
    } finally {
      removeDisposableAccount(target.username);
    }
  });

  test('mail link opened in a member session offers a switch, then completes the approval', async ({
    page,
    browser,
  }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — admin approval flow unavailable');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    await ensureAccount(TEST_ADMIN, process.env.TEST_ADMIN_PASSWORD);
    const target = createDisposableAccount({ tag: 'swt' });
    // Distinct display name: the page must say who the viewer is signed in
    // as, and both disposable accounts carry the same default full name.
    const bystander = createDisposableAccount({ tag: 'byt', fullName: 'PW Bystander' });
    try {
      await clearMail();
      expect(await loginAs(page, target)).toBe(true);
      await submitAccessRequest(page, 'Kontoskift via maillink.');
      const msg = await waitForMail(ADMIN_RECIPIENT);
      const approvePath = extractLink(
        msg,
        /https?:\/\/[^\s"'<>]+\/konto\/access-request\/approve[^\s"'<>]*/,
      ).replace(/^https?:\/\/[^/]+/, '');

      // The admin opens the mail on a browser already signed in as an
      // ordinary member — the case that used to answer a raw JSON 403.
      const ctx = await browser.newContext();
      const memberPage = await ctx.newPage();
      expect(await loginAs(memberPage, bystander)).toBe(true);
      const wrongResp = await memberPage.goto(approvePath);

      expect(wrongResp.status(), 'still refused — 403, just rendered').toBe(403);
      await expect(memberPage).toHaveTitle(/Forkert konto/);
      await expect(memberPage.locator('.bv-auth-card')).toContainText('Forkert konto');
      const wrongHtml = await memberPage.content();
      expect(wrongHtml, 'no raw JSON error body on a browser GET').not.toContain('"status":"error"');
      // The viewer failed the admin check, so the page must disclose nothing
      // about the applicant — only who they themselves are signed in as.
      expect(wrongHtml, 'applicant username must not leak').not.toContain(target.username);
      expect(wrongHtml, 'applicant email must not leak').not.toContain(target.email);
      await expect(
        memberPage.locator('.bv-auth-card'),
        'the page names the account actually signed in',
      ).toContainText('PW Bystander');

      // The switch ends the member's session…
      await memberPage.click('.bv-ar-switch button[type="submit"]');
      await memberPage.waitForURL(/\/login/);
      const kontoAfter = await memberPage.request.get('/konto', { maxRedirects: 0 });
      expect(kontoAfter.status(), 'the member session is really gone').not.toBe(200);

      // …and logging in as the admin resumes the approval automatically.
      expect(
        await loginAs(memberPage, {
          username: TEST_ADMIN.username,
          password: process.env.TEST_ADMIN_PASSWORD,
        }),
      ).toBe(true);
      await expect(memberPage).toHaveTitle(/Anmodning godkendt/);
      await expect(memberPage.locator('.bv-ar-result')).toContainText(target.username);
      await ctx.close();

      expect(readAccountYaml(target.username)).toContain('- organizers');
    } finally {
      removeDisposableAccount(bystander.username);
      removeDisposableAccount(target.username);
    }
  });

  test('the account switch refuses a tampered nonce and leaves the session intact', async ({
    page,
    browser,
  }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — no super-admin to notify');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    const target = createDisposableAccount({ tag: 'nsw' });
    const bystander = createDisposableAccount({ tag: 'nby' });
    try {
      await clearMail();
      expect(await loginAs(page, target)).toBe(true);
      await submitAccessRequest(page, 'Nonce-afvisning ved kontoskift.');
      const msg = await waitForMail(ADMIN_RECIPIENT);
      const approvePath = extractLink(
        msg,
        /https?:\/\/[^\s"'<>]+\/konto\/access-request\/approve[^\s"'<>]*/,
      ).replace(/^https?:\/\/[^/]+/, '');

      const ctx = await browser.newContext();
      const memberPage = await ctx.newPage();
      expect(await loginAs(memberPage, bystander)).toBe(true);
      await memberPage.goto(approvePath);

      const nonce = await memberPage.locator('.bv-ar-switch input[name="account-nonce"]').inputValue();
      const bad = await memberPage.request.post('/konto/access-request/switch-account', {
        form: { 'account-nonce': `${nonce}x` },
        maxRedirects: 0,
      });
      expect(bad.status(), 'a tampered switch nonce is refused').toBe(403);

      // The refusal must not have logged anybody out: a CSRF attempt that
      // still ends the victim's session is the very thing the nonce is here
      // to prevent.
      const konto = await memberPage.request.get('/konto', { maxRedirects: 0 });
      expect(konto.status(), 'the session survives a refused switch').toBe(200);
      await ctx.close();
    } finally {
      removeDisposableAccount(bystander.username);
      removeDisposableAccount(target.username);
    }
  });

  test('the reject mail link clears the request, stamps the cooldown, notifies the applicant', async ({
    page,
    browser,
  }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — admin approval flow unavailable');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    await ensureAccount(TEST_ADMIN, process.env.TEST_ADMIN_PASSWORD);
    const target = createDisposableAccount({ tag: 'rej' });
    try {
      await clearMail();
      expect(await loginAs(page, target)).toBe(true);
      await submitAccessRequest(page, 'Afvisningsflow via maillink.');
      const msg = await waitForMail(ADMIN_RECIPIENT);
      const rejectLink = extractLink(
        msg,
        /https?:\/\/[^\s"'<>]+\/konto\/access-request\/reject[^\s"'<>]*/
      );
      expect(rejectLink).toBeTruthy();
      const rejectPath = rejectLink.replace(/^https?:\/\/[^/]+/, '');

      const adminContext = await browser.newContext();
      const adminPage = await adminContext.newPage();
      expect(
        await loginAs(adminPage, {
          username: TEST_ADMIN.username,
          password: process.env.TEST_ADMIN_PASSWORD,
        })
      ).toBe(true);
      const rejectResp = await adminPage.goto(rejectPath);
      expect(rejectResp.status()).toBe(200);
      await expect(adminPage).toHaveTitle(/Anmodning afvist/);
      await expect(adminPage.locator('.bv-auth-card')).toContainText('Anmodning afvist');
      await adminContext.close();

      // No role granted; request cleared with the cooldown stamp.
      const yaml = readAccountYaml(target.username);
      expect(yaml).not.toContain('- organizers');
      expect(yaml).not.toContain('access_request:');
      expect(yaml).toContain('access_request_cleared_at');

      // The applicant is notified of the rejection.
      const applicantMsg = await waitForMail(target.email);
      expect(JSON.stringify(applicantMsg)).toContain('anmodning');
      expect(JSON.stringify(applicantMsg)).not.toContain('godkendt');
    } finally {
      removeDisposableAccount(target.username);
    }
  });

  test('a logged-out super clicking the mail link is routed via login; approval completes', async ({
    page,
    browser,
  }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — admin approval flow unavailable');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    await ensureAccount(TEST_ADMIN, process.env.TEST_ADMIN_PASSWORD);
    const target = createDisposableAccount({ tag: 'lrd' });
    try {
      await clearMail();
      expect(await loginAs(page, target)).toBe(true);
      await submitAccessRequest(page, 'Login-redirect flowet.');
      const msg = await waitForMail(ADMIN_RECIPIENT);
      const approveLink = extractLink(
        msg,
        /https?:\/\/[^\s"'<>]+\/konto\/access-request\/approve[^\s"'<>]*/
      );
      expect(approveLink).toBeTruthy();
      const approvePath = approveLink.replace(/^https?:\/\/[^/]+/, '');

      const adminContext = await browser.newContext();
      const adminPage = await adminContext.newPage();
      // Logged out, the mail link must land on the site login — not a 403.
      await adminPage.goto(approvePath);
      await adminPage.waitForURL(/\/login/);
      // Logging in must bounce straight back and complete the approval.
      await adminPage.evaluate(() => {
        const overlay = document.getElementById('bv-login-overlay');
        if (overlay) overlay.classList.add('is-open');
      });
      const form = adminPage.locator('#bv-login-overlay form');
      await form.locator('[name="username"]').fill(TEST_ADMIN.username);
      await form.locator('[name="password"]').fill(process.env.TEST_ADMIN_PASSWORD);
      await Promise.all([
        adminPage.waitForURL(/\/konto\/access-request\/approve/),
        form.locator('[type="submit"]').click(),
      ]);
      await adminContext.close();

      const yaml = readAccountYaml(target.username);
      expect(yaml).toContain('- organizers');
      expect(yaml).not.toContain('access_request:');
    } finally {
      removeDisposableAccount(target.username);
    }
  });

  test('a non-super routed via login is refused and nothing is granted', async ({
    page,
    browser,
  }) => {
    test.skip(!hasAdminPassword, 'TEST_ADMIN_PASSWORD not set — no super-admin to notify');
    test.skip(
      !(await isMailSinkConfigured()),
      `Mailpit sink not reachable at ${mailSinkUrl()} — mail-layer assertion unavailable`,
    );
    const target = createDisposableAccount({ tag: 'lrn' });
    const bystander = createDisposableAccount({ tag: 'lrb' });
    try {
      await clearMail();
      expect(await loginAs(page, target)).toBe(true);
      await submitAccessRequest(page, '');
      const msg = await waitForMail(ADMIN_RECIPIENT);
      const approveLink = extractLink(
        msg,
        /https?:\/\/[^\s"'<>]+\/konto\/access-request\/approve[^\s"'<>]*/
      );
      expect(approveLink).toBeTruthy();
      const approvePath = approveLink.replace(/^https?:\/\/[^/]+/, '');

      const ctx = await browser.newContext();
      const p2 = await ctx.newPage();
      await p2.goto(approvePath);
      await p2.waitForURL(/\/login/);
      await p2.evaluate(() => {
        const overlay = document.getElementById('bv-login-overlay');
        if (overlay) overlay.classList.add('is-open');
      });
      const form = p2.locator('#bv-login-overlay form');
      await form.locator('[name="username"]').fill(bystander.username);
      await form.locator('[name="password"]').fill(bystander.password);
      await Promise.all([
        p2.waitForURL(/\/konto\/access-request\/approve/),
        form.locator('[type="submit"]').click(),
      ]);
      // Authenticated but not a super: the refusal stands. It is now the
      // themed wrong-account page (403) instead of a raw JSON body — what
      // changed is the presentation, not the outcome, and the applicant is
      // still not disclosed to a viewer who failed the admin check.
      await expect(p2).toHaveTitle(/Forkert konto/);
      await expect(p2.locator('.bv-auth-card')).toContainText('Forkert konto');
      const refusedHtml = await p2.content();
      expect(refusedHtml, 'no raw JSON error body on a browser GET').not.toContain(
        '"status":"error"',
      );
      expect(refusedHtml, 'applicant must not leak to a non-super').not.toContain(target.username);
      await ctx.close();

      const yaml = readAccountYaml(target.username);
      expect(yaml).toContain('access_request:');
      expect(yaml).not.toContain('- organizers');
    } finally {
      removeDisposableAccount(target.username);
      removeDisposableAccount(bystander.username);
    }
  });
});
