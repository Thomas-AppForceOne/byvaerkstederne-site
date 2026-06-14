#!/usr/bin/env bash
# =============================================================================
# TC-02 — Deploy regression suite (make test-deploy)   [applies to #53 and #54]
#
# The hermetic deploy suite: atomic-layout, rollback, migrate, skip-data-
# migration, lint-remote-ssh, promote-to-staging, promote-to-prod, release-gate,
# version-bump, etc. This is the required CI check.
#
# Preconditions: Docker running; make/git/rsync/age/coreutils/python3; full git
# history (not a shallow clone).   Exit: 0 PASS · 1 FAIL · 2 BLOCKED.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "TC-02 make test-deploy  (branch: $(git branch --show-current 2>/dev/null || echo '?'))"

# --- precondition: Docker (tests/deploy/migrate.sh runs PHP in Docker) -------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "BLOCKED: Docker not available/running — start Docker Desktop and retry" >&2
    exit 2
fi
# --- precondition: not a shallow clone (deploy.sh build-number guard) --------
if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = "true" ]; then
    echo "BLOCKED: shallow clone — re-clone with full history (no --depth)" >&2
    exit 2
fi
for bin in make git rsync age python3; do
    command -v "$bin" >/dev/null 2>&1 || { echo "BLOCKED: missing '$bin'" >&2; exit 2; }
done

# --- step 2: run the suite ---------------------------------------------------
log="$(mktemp -t tc02.XXXXXX)"
if make test-deploy >"$log" 2>&1; then
    rc=0
else
    rc=$?
fi

# --- step 3: interpret -------------------------------------------------------
# Show the per-group summaries for the operator's eye.
grep -E 'passed, [0-9]+ failed|Pass: [0-9]+ +Fail: [0-9]+|all green|EXIT' "$log" | tail -25 | sed 's/^/  /' || true

if [ "$rc" -ne 0 ]; then
    echo "  --- tail of failing output ---" >&2
    tail -30 "$log" >&2
    rm -f "$log"
    echo "TC-02 FAIL: make test-deploy exited $rc" >&2
    exit 1
fi
rm -f "$log"
echo "TC-02 PASS: make test-deploy exit 0 (all probes green)"
exit 0
