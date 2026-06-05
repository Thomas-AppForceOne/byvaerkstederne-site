// @ts-check
'use strict';

/**
 * Invariant: both Playwright test-account YAMLs must be ignored by git via
 * the existing `config/www/user/accounts/*` wildcard at .gitignore line 44.
 *
 * If this test ever fails, do NOT add a new entry — the wildcard already
 * exists and a leak indicates someone removed or weakened the rule.
 */

const { test, expect } = require('@playwright/test');
const { execFileSync } = require('child_process');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');

const ACCOUNT_PATHS = [
  'config/www/user/accounts/pw-test-user.yaml',
  'config/www/user/accounts/pw-test-admin.yaml',
];

test.describe('Gitignore invariant — account YAMLs', () => {
  for (const accountPath of ACCOUNT_PATHS) {
    test(`${accountPath} is git-ignored`, () => {
      let exitCode = 0;
      try {
        execFileSync('git', ['check-ignore', '--', accountPath], {
          cwd: REPO_ROOT,
          stdio: ['ignore', 'pipe', 'pipe'],
        });
      } catch (err) {
        exitCode = /** @type {any} */ (err).status ?? 1;
      }
      // git check-ignore exits 0 when the path IS ignored.
      expect(exitCode, `${accountPath} must be reported ignored by git check-ignore`).toBe(0);
    });
  }
});
