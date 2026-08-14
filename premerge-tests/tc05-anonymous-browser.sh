#!/usr/bin/env bash
# =============================================================================
# TC-05 — Anonymous browser suite (Playwright)   [applies to #54]
#
# The anonymous Playwright suite, including #54's registration / password-reset
# / password-policy / session-cookie specs that do not require a real inbox.
#
# Preconditions: Docker; a running Grav container for this checkout (make start);
# Playwright installed (make test-install).   Exit: 0 PASS · 1 FAIL · 2 BLOCKED.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "TC-05 anonymous browser  (branch: $(git branch --show-current 2>/dev/null || echo '?'))"

# --- precondition: Playwright present ----------------------------------------
if ! npx --no-install playwright --version >/dev/null 2>&1; then
    echo "BLOCKED: Playwright not installed — run: make test-install" >&2
    exit 2
fi
# --- precondition: a Grav container is up for this checkout -------------------
if ! node scripts/discover-grav-port.js >/dev/null 2>&1; then
    echo "BLOCKED: no Grav container for this worktree — run: make start" >&2
    exit 2
fi

# --- steps 2-3: run the anonymous suite --------------------------------------
log="$(mktemp -t tc05.XXXXXX)"
if make test >"$log" 2>&1; then rc=0; else rc=$?; fi
grep -E '[0-9]+ passed|[0-9]+ failed|[0-9]+ skipped|anonymous-only|Sourced test cred' "$log" | tail -6 | sed 's/^/  /' || true

if [ "$rc" -ne 0 ]; then
    # Distinguish "environment not ready" (BLOCKED) from a real test failure.
    if grep -qE 'No Grav container|not responding' "$log"; then
        echo "BLOCKED: Grav container not serving — make start / check docker ps" >&2
        rm -f "$log"; exit 2
    fi
    echo "  --- tail ---" >&2; tail -25 "$log" >&2; rm -f "$log"
    echo "TC-05 FAIL: anonymous Playwright suite failed" >&2; exit 1
fi
rm -f "$log"
echo "TC-05 PASS: anonymous browser suite green (skips without creds are expected)"
exit 0
