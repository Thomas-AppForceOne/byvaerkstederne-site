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

  test('the previously-exposed salt is absent from tracked config/code (docs may narrate it)', () => {
    // grep the salt across tracked files. git grep exits 1 (no match) when
    // clean. We then exclude the markdown that legitimately documents the
    // value-to-rotate (specifications/decisions/README) — the salt appearing
    // as prose in a rotation runbook is documentation, not an active secret.
    // What must NOT happen is the salt living in a config/YAML/PHP file.
    let matched = '';
    try {
      matched = execFileSync('git', ['grep', '--cached', '-l', EXPOSED_SALT], {
        cwd: REPO_ROOT,
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'pipe'],
      });
    } catch (err) {
      // exit 1 = no match. Any other status is unexpected.
      const status = /** @type {any} */ (err).status;
      if (status !== 1) throw err;
      matched = '';
    }
    const offending = matched
      .split('\n')
      .map((l) => l.trim())
      .filter(Boolean)
      // Markdown docs/specs/ADRs may quote the salt as the value to rotate.
      .filter((p) => !p.endsWith('.md'));
    expect(
      offending,
      `the exposed salt ${EXPOSED_SALT} must not live in any tracked config/code file (found in: ${offending.join(', ')})`,
    ).toEqual([]);
  });

  test('a tracked .example template exists for security.yaml', () => {
    expect(
      gitTracks(`${ROOT_SECURITY}.example`),
      'security.yaml.example must be tracked so a fresh checkout has a provisioning template',
    ).toBe(true);
  });
});
