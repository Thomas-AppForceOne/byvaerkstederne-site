// @ts-check
'use strict';

/**
 * Mailpit email.yaml override lifecycle — owned by the Playwright run.
 *
 * The committed config/www/user/config/plugins/email.yaml is credential-free
 * and does NOT point at any SMTP host (so real tiers fail closed if their env
 * override is missing). To exercise the email-bearing auth flows locally, the
 * suite must temporarily repoint the mailer at the Mailpit sink (mailpit:1025).
 *
 * That override is written by global-setup (only when Mailpit is reachable) and
 * removed by global-teardown via `git checkout`. mailpit-up.sh NO LONGER writes
 * it — it only starts the sink container — so the working-tree override can only
 * ever exist for the duration of a run that this module manages.
 *
 * Catastrophic guard (assertEmailConfigCleanOrThrow): if email.yaml is already
 * modified when a run STARTS, a previous run was killed before its teardown
 * restored it (or someone hand-edited it). We refuse to run rather than risk
 * the test-only mailer config being committed — committing it would point a
 * real tier at the non-existent `mailpit` host. The operator restores with
 * `git checkout` (or scripts/mailpit-down.sh) and re-runs.
 */

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const EMAIL_REL = 'config/www/user/config/plugins/email.yaml';
const EMAIL_ABS = path.join(REPO_ROOT, EMAIL_REL);

// Marker line embedded in the override so it is greppable and unmistakable.
const MAILPIT_MARKER = 'TEST-ONLY Mailpit override';

// The exact test-only form. Keep the From identity identical to the committed
// non-prod default; only the transport (smtp.server/port/encryption) changes.
const OVERRIDE_YAML = `# ${MAILPIT_MARKER} written by tests/global-setup.js. The committed,
# credential-free file is restored by tests/global-teardown.js via
# \`git checkout\`. DO NOT COMMIT this form — it points the mailer at the
# Mailpit sink (mailpit:1025) which only exists inside the test compose network.
enabled: true
from: 'noreply@hackersbychoice.dk'
from_name: 'Byværkstederne'
charset: utf-8
content_type: text/html
debug: false
mailer:
  engine: smtp
  smtp:
    server: mailpit
    port: 1025
    encryption: none
    user: ''
    password: ''
`;

/**
 * True when the working-tree email.yaml differs from HEAD.
 * `git diff --quiet` exits 0 (clean), 1 (differs), or >1 (error).
 * @returns {boolean}
 */
function isEmailConfigDirty() {
  try {
    execFileSync('git', ['diff', '--quiet', '--', EMAIL_REL], {
      cwd: REPO_ROOT,
      stdio: 'ignore',
    });
    return false;
  } catch (err) {
    if (err && /** @type {any} */ (err).status === 1) return true;
    // Not a git repo / git missing — can't prove dirtiness; don't block.
    return false;
  }
}

/**
 * Abort the whole run if email.yaml was left modified by a prior crashed run.
 * Called at the very top of global-setup, BEFORE any override is applied.
 * @throws {Error} when email.yaml is dirty at run start
 */
function assertEmailConfigCleanOrThrow() {
  if (!isEmailConfigDirty()) return;
  throw new Error(
    [
      '',
      '╔══════════════════════════════════════════════════════════════════════╗',
      '║ FATAL: email.yaml is modified at suite start.                         ║',
      '╚══════════════════════════════════════════════════════════════════════╝',
      `  ${EMAIL_REL}`,
      '',
      'The Mailpit test override was NOT torn down by a previous run (a crashed',
      'or killed run, or a manual edit). Refusing to start: committing this',
      'test-only mailer config would point a real tier at the non-existent',
      '`mailpit` host and silently break transactional email.',
      '',
      'Restore it, then re-run:',
      `  git checkout -- ${EMAIL_REL}`,
      '  # or: scripts/mailpit-down.sh .',
      '',
    ].join('\n'),
  );
}

/** Resolve the worktree's Grav container, or null if discovery fails. */
function gravContainerOrNull() {
  try {
    const { discoverGravEnv } = require(path.join(REPO_ROOT, 'scripts', 'discover-grav-port.js'));
    return discoverGravEnv(REPO_ROOT).container;
  } catch (_) {
    return null;
  }
}

/**
 * Clear the Grav cache as the `abc` web user so Grav re-reads the rewritten
 * email.yaml. Clearing as root leaves root-owned cache files that 500 the whole
 * site, so `-u abc` is mandatory. Non-fatal: a stale cache only delays the
 * config flip, it does not corrupt state.
 */
function clearGravCacheAsAbc() {
  const container = gravContainerOrNull();
  if (!container) return;
  try {
    execFileSync(
      'docker',
      ['exec', '-u', 'abc', '-w', '/app/www/public', container, 'bin/grav', 'clearcache'],
      { stdio: 'ignore', timeout: 30_000 },
    );
  } catch (_) {
    /* non-fatal */
  }
}

/**
 * Write the Mailpit transport override into the working-tree email.yaml and
 * clear the Grav cache. Idempotent. The caller is responsible for guaranteeing
 * teardown restores it (global-teardown does, unconditionally).
 */
function applyMailpitOverride() {
  fs.writeFileSync(EMAIL_ABS, OVERRIDE_YAML, 'utf8');
  clearGravCacheAsAbc();
}

/**
 * Restore the committed email.yaml from git and clear the cache. A no-op when
 * the file is already clean, so safe to call on every teardown.
 */
function restoreEmailConfig() {
  try {
    execFileSync('git', ['checkout', '--', EMAIL_REL], {
      cwd: REPO_ROOT,
      stdio: 'ignore',
    });
  } catch (_) {
    /* non-fatal — not a git checkout, or nothing to restore */
  }
  clearGravCacheAsAbc();
}

module.exports = {
  EMAIL_REL,
  MAILPIT_MARKER,
  isEmailConfigDirty,
  assertEmailConfigCleanOrThrow,
  applyMailpitOverride,
  restoreEmailConfig,
};
