// @ts-check
'use strict';

/**
 * Anonymous bug-report access control.
 *
 * Verifies that the bug-report submission endpoint rejects requests from
 * unauthenticated callers. The intent (per spec security section) is that
 * an anonymous POST returns 401 or a redirect to a login URL, never 200.
 *
 * The footer-trigger-absence assertion lives in tests/anonymous/footer.js
 * and is intentionally NOT duplicated here.
 *
 * NOTE on endpoint path: the spec text reads "/bug-report/submit" as a
 * shorthand for the bug-report submit endpoint; the actual route handled
 * by the plugin (config/www/user/plugins/bug-report/bug-report.php) is
 * "/bug-report-submit". We test the real endpoint — the goal is to assert
 * the server rejects anonymous submissions, not to test a non-existent path.
 */

const { test, expect } = require('@playwright/test');

const SUBMIT_ENDPOINT = '/bug-report-submit';

test.describe('Anonymous bug-report access control — Submission', () => {
  test('POST to bug-report submit endpoint is rejected for anonymous callers', async ({ request }) => {
    const response = await request.post(SUBMIT_ENDPOINT, {
      // Minimal form payload — server must reject before even validating fields.
      form: {
        description: 'anon-attempt',
        expected: 'rejected',
      },
      maxRedirects: 0,
    });

    const status = response.status();

    // Positively affirm a rejection shape: HTTP 401 (Unauthorized) or a
    // 3xx redirect (typically to a login page). A 200 here would indicate
    // the server silently accepted the anonymous submission — fail the run.
    const isUnauthorized = status === 401;
    const isRedirect = status >= 300 && status < 400;

    expect(
      isUnauthorized || isRedirect,
      `Expected 401 or 3xx redirect from anonymous POST ${SUBMIT_ENDPOINT}, got ${status}`,
    ).toBe(true);
  });
});
