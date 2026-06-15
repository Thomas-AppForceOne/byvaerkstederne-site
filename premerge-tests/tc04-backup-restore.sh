#!/usr/bin/env bash
# =============================================================================
# TC-04 — Backup/restore tooling (bats)   [applies to #53 and #54]
#
# backup.sh + restore.sh round-trip, retention sweep, age encryption, the prod
# safety gate, and input validation.
#
# Preconditions: bats-core + age installed.   Exit: 0 PASS · 1 FAIL · 2 BLOCKED.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "TC-04 backup/restore bats  (branch: $(git branch --show-current 2>/dev/null || echo '?'))"

for bin in bats age age-keygen; do
    command -v "$bin" >/dev/null 2>&1 || {
        echo "BLOCKED: '$bin' not installed — brew install bats-core age" >&2; exit 2; }
done

log="$(mktemp -t tc04.XXXXXX)"
if make test-backup-restore >"$log" 2>&1; then rc=0; else rc=$?; fi
grep -E '[0-9]+ tests?,|not ok|ok [0-9]+' "$log" | tail -8 | sed 's/^/  /' || true

if [ "$rc" -ne 0 ]; then
    echo "  --- tail ---" >&2; tail -25 "$log" >&2; rm -f "$log"
    echo "TC-04 FAIL: make test-backup-restore exited $rc" >&2; exit 1
fi
rm -f "$log"
echo "TC-04 PASS: backup/restore bats green"
exit 0
