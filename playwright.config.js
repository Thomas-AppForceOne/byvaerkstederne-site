// @ts-check
const { defineConfig, devices } = require('@playwright/test');
const path = require('path');

// Resolve the base URL for this worktree's Grav container.
// Precedence:
//   1. BASE_URL (explicit override — used in CI or when pointing at staging).
//   2. Port-discovery helper (env → registry → docker ps by this
//      worktree's deterministic container name). Fails loud if the
//      worktree's container isn't running — no silent fallback to :8080
//      or to some other container, because that's how tests end up
//      probing a Grav that doesn't reflect the code under test.
//
// Use 127.0.0.1 explicitly — on macOS 'localhost' may resolve to IPv6 (::1)
// while Docker only binds to IPv4, causing Playwright's Chromium to fail
// silently.

let baseURL;
if (process.env.BASE_URL) {
  baseURL = process.env.BASE_URL;
} else {
  const { discoverGravEnv } = require(path.join(__dirname, 'scripts/discover-grav-port.js'));
  try {
    const { port } = discoverGravEnv('.');
    baseURL = `http://127.0.0.1:${port}`;
    console.log(`📍 Using Grav on port ${port} for tests`);
  } catch (e) {
    console.error(`❌ ${e.message}`);
    process.exit(1);
  }
}

module.exports = defineConfig({
  testDir: './tests',
  timeout: 60_000,
  retries: 1,
  reporter: [['list'], ['html', { open: 'never' }]],
  globalSetup: require.resolve('./tests/global-setup.js'),
  globalTeardown: require.resolve('./tests/global-teardown.js'),

  use: {
    baseURL: baseURL,
    navigationTimeout: 60_000,
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
      // Keep the desktop project on the existing entry points (anonymous +
      // authenticated). The new mobile suite is scoped to its own project
      // below to avoid running every desktop case at a 390 × 844 viewport.
      testIgnore: ['tests/mobile/**', 'tests/mobile.spec.js'],
    },
    {
      // Mobile-rendering suite for the four iPhone-class defects (workgroup
      // card clip, event-row overflow, long-title crowding, pitch-card
      // numeral overlap) plus the four-route horizontal-overflow sweep.
      // Anonymous-only — must NOT gate on TEST_PASSWORD (CLAUDE.md, spec
      // hard constraints).
      //
      // Engine note: the project is "mobile-chromium" — we keep Chromium
      // (not WebKit, which devices['iPhone 14 Pro'] defaults to) so the
      // suite reuses the existing browser binary and so the bug surface
      // matches the user's actual reporting context (Chromium on iPhone
      // viewport-class emulation is the closest reproduction we can run
      // headlessly in CI without a WebKit install step). The viewport,
      // device pixel ratio, isMobile and hasTouch flags taken from the
      // iPhone 14 Pro descriptor give the exact 390 × 844 layout the
      // spec calls for.
      name: 'mobile-chromium',
      use: {
        browserName: 'chromium',
        viewport: { width: 390, height: 844 },
        deviceScaleFactor: 3,
        isMobile: true,
        hasTouch: true,
        userAgent:
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        // /vaerkstedskalenderen is gated behind the `workshop_calendar`
        // feature flag, which is OFF in the default localhost Grav profile
        // (user/config/features.yaml leaves every flag commented out). The
        // dev-tier env profile (user/env/dev.hackersbychoice.dk/) has every
        // flag "true", so we force Grav into that profile by:
        //   - overriding baseURL with dev.hackersbychoice.dk so the browser
        //     sends Host: dev.hackersbychoice.dk natively, and
        //   - adding a Chromium host-resolver rule so the DNS lookup still
        //     lands on the local Grav container.
        baseURL: `http://dev.hackersbychoice.dk:${(baseURL.match(/:(\d+)/) || [, '8081'])[1]}`,
        launchOptions: {
          args: ['--host-resolver-rules=MAP dev.hackersbychoice.dk 127.0.0.1'],
        },
      },
      testMatch: ['tests/mobile.spec.js'],
    },
  ],
});
