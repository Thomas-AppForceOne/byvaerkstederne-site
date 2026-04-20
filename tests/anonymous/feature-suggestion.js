// @ts-check
'use strict';

/**
 * Anonymous feature-suggestion access control.
 *
 * Two assertions:
 *   1. GET /foreslaa-feature anonymously renders a login prompt and the
 *      fs_title input is absent from the DOM (the form is auth-gated).
 *   2. POST to the feature-suggestion submit endpoint is rejected.
 *
 * The plain GET status<400 check on /foreslaa-feature lives in
 * tests/anonymous/access-control.js; we do NOT duplicate that standalone
 * assertion here. Visiting the page below is solely to inspect the
 * login-prompt + absent-form behaviour.
 *
 * The footer-trigger-absence assertion lives in tests/anonymous/footer.js
 * and is intentionally NOT duplicated here.
 */

const { test, expect } = require('@playwright/test');

const PAGE_URL = '/foreslaa-feature';
const SUBMIT_ENDPOINT = '/feature-suggestion/submit';

test.describe('Anonymous feature-suggestion access control — Page rendering', () => {
  test('anonymous visit shows login prompt and hides fs_title form input', async ({ page }) => {
    await page.goto(PAGE_URL);

    // (a) A login prompt / login affordance is visible on the page.
    // The template renders a "Log ind" call-to-action inside .bv-fs-login-prompt
    // for anonymous users (see foreslaa-feature.html.twig).
    const loginPrompt = page.locator('.bv-fs-login-prompt');
    await expect(loginPrompt).toBeVisible();
    await expect(loginPrompt.getByText(/log ind/i).first()).toBeVisible();

    // (b) The fs_title input must NOT be present in the DOM — the form
    // is rendered only for authenticated users.
    await expect(page.locator('[name="fs_title"]')).toHaveCount(0);
  });
});

test.describe('Anonymous feature-suggestion access control — Submission', () => {
  test('POST to feature-suggestion submit endpoint is rejected for anonymous callers', async ({ request }) => {
    const response = await request.post(SUBMIT_ENDPOINT, {
      form: {
        fs_title: 'anon-attempt',
        fs_description: 'anon-attempt',
        fs_community_value: 'anon-attempt',
      },
      maxRedirects: 0,
    });

    const status = response.status();

    // Positively affirm a rejection shape:
    //   - HTTP 401 (Unauthorized), or
    //   - HTTP 403 (Forbidden — the handler's actual response when the
    //     user is unauthenticated; see feature-suggestion.php handleSubmit),
    //   - or a 3xx redirect (typically to a login page).
    // A 200 / 404 / 500 here would indicate the server silently accepted
    // the submission or the endpoint is missing entirely — fail the run.
    const isUnauthorized = status === 401;
    const isForbidden = status === 403;
    const isRedirect = status >= 300 && status < 400;

    expect(
      isUnauthorized || isForbidden || isRedirect,
      `Expected 401, 403, or 3xx redirect from anonymous POST ${SUBMIT_ENDPOINT}, got ${status}`,
    ).toBe(true);
  });
});
