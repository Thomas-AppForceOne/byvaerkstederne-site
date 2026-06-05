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
    },
  ],
});
