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

echo "→ test: --skip-data-migration suppresses the in-deploy migration step"
OUT="$(run_dry staging --dry-run --skip-data-migration)"
if printf '%s' "$OUT" | grep -q "Step 7.5) would be SUPPRESSED"; then
    report_pass "flag present → Step 7.5 reported SUPPRESSED"
else
    printf '%s\n' "$OUT" | tail -20 >&2
    report_fail "flag present → expected SUPPRESSED posture, not found"
fi
# Sanity: the flag must not have been swallowed into the tier positional —
# the run must still be a Staging deploy.
if printf '%s' "$OUT" | grep -q "Environment: Staging"; then
    report_pass "flag present → tier still resolves to Staging (flag not eaten as positional)"
else
    report_fail "flag present → tier no longer resolves to Staging"
fi

echo "→ test: without the flag, the in-deploy migration step stays active"
OUT_DEFAULT="$(run_dry staging --dry-run)"
if printf '%s' "$OUT_DEFAULT" | grep -q "Step 7.5) would run if the live data version differs"; then
    report_pass "flag absent → Step 7.5 reported active (default)"
else
    printf '%s\n' "$OUT_DEFAULT" | tail -20 >&2
    report_fail "flag absent → expected active posture, not found"
fi
if printf '%s' "$OUT_DEFAULT" | grep -q "would be SUPPRESSED"; then
    report_fail "flag absent → unexpectedly reported SUPPRESSED"
else
    report_pass "flag absent → does not report SUPPRESSED"
fi

echo ""
echo "skip-data-migration: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
