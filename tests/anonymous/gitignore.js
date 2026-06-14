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

/**
 * WI-3: no authentication salt is tracked in git, and the previously-exposed
 * salt is gone from the working tree. Pure git/grep checks — run always (not
 * credential-gated). Helper: `git ls-files <path>` prints the path iff tracked.
 */
function gitTracks(relPath) {
  const out = execFileSync('git', ['ls-files', '--', relPath], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  });
  return out.trim().length > 0;
}

function gitIgnored(relPath) {
  let exitCode = 0;
  try {
    execFileSync('git', ['check-ignore', '--', relPath], {
      cwd: REPO_ROOT,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (err) {
    exitCode = /** @type {any} */ (err).status ?? 1;
  }
  return exitCode === 0;
}

test.describe('Auth-secret invariant — security.yaml salt (WI-3)', () => {
  const ROOT_SECURITY = 'config/www/user/config/security.yaml';
  const EXPOSED_SALT = 'Wbd0yZKOPckagC';

  test('root security.yaml is NOT tracked by git', () => {
    expect(
      gitTracks(ROOT_SECURITY),
      `${ROOT_SECURITY} must be untracked (git rm --cached); committing a salt pins a publicly-known secret`,
    ).toBe(false);
  });

  test('root security.yaml is git-ignored', () => {
    expect(
      gitIgnored(ROOT_SECURITY),
      `${ROOT_SECURITY} must be reported ignored by git check-ignore`,
    ).toBe(true);
  });

  test('the exposed salt is not the ACTIVE salt value in any tracked file', () => {
    // The dangerous form is the salt as a live YAML value: `salt: <exposed>`.
    // Docs/specs (.md), the .example template's narration, and this test's own
    // EXPECTED_SALT constant legitimately mention the string; what must never
    // exist in a tracked file is the active assignment. git grep exits 1 (no
    // match) when clean.
    let matched = '';
    try {
      matched = execFileSync('git', ['grep', '--cached', '-nE', `^\\s*salt:\\s*${EXPOSED_SALT}`], {
        cwd: REPO_ROOT,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (err) {
      const status = /** @type {any} */ (err).status;
      if (status !== 1) throw err; // exit 1 = no match (good)
      matched = '';
    }
    expect(
      matched.trim(),
      `the exposed salt must not be an active 'salt:' value in any tracked file (found: ${matched.trim()})`,
    ).toBe('');
  });

  test('a tracked .example template exists for security.yaml', () => {
    expect(
      gitTracks(`${ROOT_SECURITY}.example`),
      'security.yaml.example must be tracked so a fresh checkout has a provisioning template',
    ).toBe(true);
  });
});
