#!/usr/bin/env bash
# =============================================================================
# TC-03 — Data-migration runner   [applies to #53 and #54]
#
# The data-versioning migration runner + the deploy↔migrate integration
# (the user/-shaped data-dir contract).
#
# Preconditions: Docker running (installs migrations/vendor + runs PHP via
# Docker; first run pulls an image).   Exit: 0 PASS · 1 FAIL · 2 BLOCKED.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "TC-03 migration runner  (branch: $(git branch --show-current 2>/dev/null || echo '?'))"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "BLOCKED: Docker not available/running — start Docker Desktop and retry" >&2
    exit 2
fi

rc=0

# --- step 2: per-migration fixture tests ------------------------------------
echo "  → migrations/run-tests.sh"
if bash migrations/run-tests.sh >/tmp/tc03a.log 2>&1; then
    grep -E 'PASSED:|FAILED:|all green' /tmp/tc03a.log | sed 's/^/    /' || true
else
    echo "    ✗ run-tests.sh failed"; tail -20 /tmp/tc03a.log | sed 's/^/    /' >&2; rc=1
fi

# --- step 3: deploy↔migrate integration -------------------------------------
echo "  → tests/deploy/migrate-integration.sh"
if bash tests/deploy/migrate-integration.sh >/tmp/tc03b.log 2>&1; then
    grep -E 'PASSED:|FAILED:' /tmp/tc03b.log | sed 's/^/    /' || true
else
    echo "    ✗ migrate-integration.sh failed"; tail -20 /tmp/tc03b.log | sed 's/^/    /' >&2; rc=1
fi

rm -f /tmp/tc03a.log /tmp/tc03b.log
if [ "$rc" -ne 0 ]; then echo "TC-03 FAIL" >&2; exit 1; fi
echo "TC-03 PASS: migration runner + integration green"
exit 0
