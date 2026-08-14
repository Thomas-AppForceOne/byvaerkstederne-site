#!/usr/bin/env bash
# =============================================================================
# TC-06 — Authenticated + email-verification (Mailpit)   [applies to #54]
#
# The full custom auth surface: registration → activation email → token gate →
# login, the reset-email flow, and the hardened session cookie (WI-1/WI-2/WI-4).
#
# Preconditions: TC-05's (Docker, running Grav container, Playwright) PLUS test
# creds at ~/.gan-secrets/workshop-site.env (TEST_PASSWORD, TEST_ADMIN_PASSWORD)
# and seeded accounts pw-test-user / pw-test-admin
# (tests/fixtures/grav-seeds/playwright/apply.sh <container>).
#
# Always runs scripts/mailpit-down.sh on exit to restore the working tree.
# Exit: 0 PASS · 1 FAIL · 2 BLOCKED.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "TC-06 authenticated + Mailpit  (branch: $(git branch --show-current 2>/dev/null || echo '?'))"

# --- preconditions -----------------------------------------------------------
npx --no-install playwright --version >/dev/null 2>&1 || { echo "BLOCKED: Playwright missing — make test-install" >&2; exit 2; }
node scripts/discover-grav-port.js >/dev/null 2>&1 || { echo "BLOCKED: no Grav container — make start" >&2; exit 2; }
[ -f "$HOME/.gan-secrets/workshop-site.env" ] || { echo "BLOCKED: missing ~/.gan-secrets/workshop-site.env (TEST_PASSWORD/TEST_ADMIN_PASSWORD)" >&2; exit 2; }
# shellcheck disable=SC1090
set -a; . "$HOME/.gan-secrets/workshop-site.env"; set +a
[ -n "${TEST_PASSWORD:-}" ] && [ -n "${TEST_ADMIN_PASSWORD:-}" ] || { echo "BLOCKED: TEST_PASSWORD/TEST_ADMIN_PASSWORD not set in the env file" >&2; exit 2; }
[ -x scripts/mailpit-up.sh ] || { echo "BLOCKED: scripts/mailpit-up.sh not found (are you on the #54 branch?)" >&2; exit 2; }

# --- step 1: start Mailpit; ALWAYS tear it down on exit ----------------------
cleanup() {
    echo "  → scripts/mailpit-down.sh . (restoring working tree)"
    scripts/mailpit-down.sh . >/dev/null 2>&1 || echo "  ⚠ mailpit-down reported an issue — check 'git status'" >&2
    # Step 5: committed files must be unchanged after the run.
    if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "  ⚠ working tree not clean after teardown:" >&2
        git status --short | sed 's/^/      /' >&2
    else
        echo "  ✓ working tree clean after teardown"
    fi
}
trap cleanup EXIT
echo "  → scripts/mailpit-up.sh ."
# mailpit-up.sh/down.sh REQUIRE the worktree path as $1 (it derives the
# deterministic container name from it). REPO_ROOT is the current dir here, so '.'.
scripts/mailpit-up.sh . || { echo "BLOCKED: mailpit-up failed" >&2; exit 2; }

rc=0
# --- step 3: anonymous suite (registration/reset/policy/session, with inbox) -
echo "  → make test (anonymous, with Mailpit inbox)"
if ! make test >/tmp/tc06a.log 2>&1; then
    grep -E '[0-9]+ passed|[0-9]+ failed' /tmp/tc06a.log | tail -3 | sed 's/^/    /' >&2
    tail -20 /tmp/tc06a.log | sed 's/^/    /' >&2; rc=1
else
    grep -E '[0-9]+ passed|[0-9]+ failed|[0-9]+ skipped' /tmp/tc06a.log | tail -3 | sed 's/^/    /' || true
fi

# --- step 4: authenticated suite (login) ------------------------------------
echo "  → make test-auth (login)"
if ! make test-auth >/tmp/tc06b.log 2>&1; then
    grep -E '[0-9]+ passed|[0-9]+ failed' /tmp/tc06b.log | tail -3 | sed 's/^/    /' >&2
    tail -20 /tmp/tc06b.log | sed 's/^/    /' >&2; rc=1
else
    grep -E '[0-9]+ passed|[0-9]+ failed' /tmp/tc06b.log | tail -3 | sed 's/^/    /' || true
fi

rm -f /tmp/tc06a.log /tmp/tc06b.log
if [ "$rc" -ne 0 ]; then echo "TC-06 FAIL: an auth suite failed (see above)" >&2; exit 1; fi
echo "TC-06 PASS: registration/verification/reset/login + session-cookie green"
exit 0
