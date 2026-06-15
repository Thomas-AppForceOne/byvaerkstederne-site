#!/usr/bin/env bash
# =============================================================================
# Probe for deploy.sh's --skip-data-migration flag.
#
# The flag suppresses deploy.sh's in-deploy schema-bump step (Step 7.5) so an
# orchestrator that owns data migration out of band — promote-to-staging.sh —
# can deploy code to a remote tier without deploy.sh invoking the (unshipped)
# remote-mode migration runner and aborting.
#
# --dry-run exits before Step 7.5, so the flag's effect is asserted via the
# dry-run posture preview deploy.sh prints early. Runs entirely locally
# (--dry-run skips credentials and any remote contact). Covers:
#   * flag present  → posture line says SUPPRESSED   (success path)
#   * flag absent   → posture line says "would run"  (default path)
#   * flag does not leak into the positional tier arg (still deploys staging)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SH="$REPO_ROOT/deploy/deploy.sh"

[ -f "$DEPLOY_SH" ] || { echo "FATAL: $DEPLOY_SH not found" >&2; exit 1; }

PASS_COUNT=0
FAIL_COUNT=0
report_pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
report_fail() { printf '  FAIL  %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Capture combined output of a dry-run deploy. Never touches the network.
run_dry() { bash "$DEPLOY_SH" "$@" 2>&1 || true; }

# The dry-run posture line carries the RESOLVED tier in [..] plus the flag
# state, and prints BEFORE deploy.sh's full-history (shallow-clone) guard — so
# it is the CI-safe hook. (GitHub's actions/checkout is shallow by default, so
# deploy.sh aborts at that guard before the later "Environment:" banner; the
# posture line is what we can rely on.) A grep for "[staging]" also proves the
# flag was not swallowed into the tier positional.
echo "→ test: --skip-data-migration suppresses the in-deploy migration step"
OUT="$(run_dry staging --dry-run --skip-data-migration)"
if printf '%s' "$OUT" | grep -q "dry-run \[staging\]: in-deploy data-migration (Step 7.5) would be SUPPRESSED"; then
    report_pass "flag present → tier resolves to staging AND Step 7.5 reported SUPPRESSED"
else
    printf '%s\n' "$OUT" | tail -20 >&2
    report_fail "flag present → expected '[staging] … would be SUPPRESSED' posture, not found"
fi

echo "→ test: without the flag, the in-deploy migration step stays active"
OUT_DEFAULT="$(run_dry staging --dry-run)"
if printf '%s' "$OUT_DEFAULT" | grep -q "dry-run \[staging\]: in-deploy data-migration (Step 7.5) would run"; then
    report_pass "flag absent → tier resolves to staging AND Step 7.5 reported active (default)"
else
    printf '%s\n' "$OUT_DEFAULT" | tail -20 >&2
    report_fail "flag absent → expected '[staging] … would run' posture, not found"
fi
if printf '%s' "$OUT_DEFAULT" | grep -q "would be SUPPRESSED"; then
    report_fail "flag absent → unexpectedly reported SUPPRESSED"
else
    report_pass "flag absent → does not report SUPPRESSED"
fi

echo ""
echo "skip-data-migration: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
