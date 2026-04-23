// @ts-check
'use strict';

/**
 * Worktree-aware account seeding for the anonymous test suite.
 *
 * Context: tests/global-setup.js provisions accounts inside the literal
 * "grav" container (the primary :8080 dev instance). When a GAN run
 * brings up its own container via scripts/grav-up.sh, those accounts
 * live in the wrong container and the worktree Grav instance boots
 * with zero users — which trips Grav's admin plugin into serving the
 * "Register Admin User" page for every route. All anonymous tests that
 * expect 404 / redirect-to-login then fail spuriously.
 *
 * This helper fills the gap by seeding at least one admin account into
 * the CURRENT worktree's container. Credentials come from the standard
 * CLAUDE.md secrets file; when absent we no-op (anonymous-only mode).
 *
 * Safe to call multiple times — `docker exec ... test -f ...` short-
 * circuits when the account YAML is already present.
 */

const { execFileSync } = require('child_process');
const path = require('path');
const { discoverGravEnv } = require(path.join(__dirname, '..', '..', 'scripts', 'discover-grav-port.js'));

/**
 * Idempotently seed pw-test-admin into the worktree container so the
 * Grav admin plugin stops intercepting routes with its register form.
 */
function seedWorktreeAdmin() {
  const adminPw = process.env.TEST_ADMIN_PASSWORD;
  if (!adminPw) return { seeded: false, reason: 'no TEST_ADMIN_PASSWORD' };

  const worktree = path.resolve(__dirname, '..', '..');
  let container;
  try {
    ({ container } = discoverGravEnv(worktree));
  } catch (err) {
    // No container for this worktree — nothing to seed. Callers treat
    // this as an anonymous-only mode signal rather than an error.
    return { seeded: false, reason: `no worktree container: ${err.message.split('\n')[0]}` };
  }

  // Short-circuit if the YAML already exists in the container.
  try {
    execFileSync(
      'docker',
      ['exec', container, 'test', '-f', '/app/www/public/user/accounts/pw-test-admin.yaml'],
      { stdio: ['ignore', 'pipe', 'pipe'] }
    );
    return { seeded: false, reason: 'already present' };
  } catch (_) { /* file missing */ }

  try {
    execFileSync(
      'docker',
      [
        'exec', '-w', '/app/www/public', container,
        'bin/plugin', 'login', 'new-user',
        '-u', 'pw-test-admin',
        '-p', adminPw,
        '-e', 'pw-test-admin@example.invalid',
        '-N', 'Playwright Test Admin',
        '-l', 'en',
        '-t', 'Admin',
        '-P', 'b',
        '-s', 'enabled',
        '-n',
      ],
      { stdio: ['ignore', 'pipe', 'pipe'], timeout: 30_000 }
    );
    return { seeded: true };
  } catch (err) {
    return { seeded: false, reason: `seed failed: ${err && /** @type {any} */ (err).message}` };
  }
}

module.exports = { seedWorktreeAdmin };
