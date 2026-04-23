// @ts-check
const { defineConfig, devices } = require('@playwright/test');
const path = require('path');

// Resolve the base URL for this worktree's Grav container.
// Precedence:
//   1. BASE_URL (explicit override — used in CI or when pointing at staging).
//   2. GRAV_PORT env var (set by scripts/grav-up.sh within a session).
//   3. Port-discovery helper (registry → docker ps) so tests still find the
//      container after a Claude Desktop restart clears the env.
//   4. Default 8080 with a warning — matches the primary dev container.
//
// Use 127.0.0.1 explicitly — on macOS 'localhost' may resolve to IPv6 (::1)
// while Docker only binds to IPv4, causing Playwright's Chromium to fail
// silently.

let baseURL;
if (process.env.BASE_URL) {
  baseURL = process.env.BASE_URL;
} else if (process.env.GRAV_PORT) {
  baseURL = `http://127.0.0.1:${process.env.GRAV_PORT}`;
} else {
  try {
    const { discoverGravPort } = require(path.join(__dirname, 'scripts/discover-grav-port.js'));
    const port = discoverGravPort('.');
    baseURL = `http://127.0.0.1:${port}`;
    console.log(`📍 Discovered Grav on port ${port} for tests`);
  } catch (e) {
    baseURL = 'http://127.0.0.1:8080';
    console.warn(`⚠️  ${e.message}`);
    console.warn(`⚠️  Defaulting to ${baseURL}. Tests may fail if the port is wrong.`);
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
