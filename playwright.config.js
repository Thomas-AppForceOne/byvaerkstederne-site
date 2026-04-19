// @ts-check
const { defineConfig, devices } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 60_000,
  retries: 1,
  reporter: [['list'], ['html', { open: 'never' }]],
  globalSetup: require.resolve('./tests/global-setup.js'),
  globalTeardown: require.resolve('./tests/global-teardown.js'),

  use: {
    // Use 127.0.0.1 explicitly — on macOS, 'localhost' may resolve to IPv6 (::1)
    // while Docker only binds to IPv4, causing Playwright's Chromium to fail silently.
    baseURL: process.env.BASE_URL || 'http://127.0.0.1:8080',
    navigationTimeout: 60_000,
    // Capture traces on first retry so failures are diagnosable
    trace: 'on-first-retry',
    // Capture screenshot on failure
    screenshot: 'only-on-failure',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
