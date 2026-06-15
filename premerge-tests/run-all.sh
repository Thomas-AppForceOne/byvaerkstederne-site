#!/usr/bin/env bash
# =============================================================================
# Runs every pre-merge test case (TC-01…TC-06) against the CURRENTLY checked-out
# branch and prints a summary. Per-script contract: 0 PASS · 1 FAIL · 2 BLOCKED.
#
# Overall exit: 1 if ANY test FAILED (block the merge); 0 otherwise. BLOCKED
# tests (missing Docker/container/creds) are reported but do not fail the run —
# provision the environment and re-run those. The deterministic gate is
# TC-01 + TC-02 (the CI-equivalent); they must reach PASS before merge.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE/.."
echo "=== pre-merge tests — branch: $(git branch --show-current 2>/dev/null || echo '?') ==="
echo ""

declare -a NAMES RESULTS
any_fail=0
for tc in tc01-bash-n-parse-check tc02-deploy-regression-suite tc03-migration-runner \
          tc04-backup-restore tc05-anonymous-browser tc06-authenticated-mailpit; do
    echo "────────────────────────────────────────────────────────────"
    if "$HERE/$tc.sh"; then rc=0; else rc=$?; fi
    case "$rc" in
        0) verdict="PASS" ;;
        2) verdict="BLOCKED (precondition)" ;;
        *) verdict="FAIL"; any_fail=1 ;;
    esac
    NAMES+=("$tc"); RESULTS+=("$verdict")
    echo ""
done

echo "════════════════════════ SUMMARY ════════════════════════"
for i in "${!NAMES[@]}"; do printf '  %-32s %s\n' "${NAMES[$i]}" "${RESULTS[$i]}"; done
echo "──────────────────────────────────────────────────────────"
if [ "$any_fail" -ne 0 ]; then
    echo "  RESULT: FAIL — at least one test failed; do NOT merge."
    exit 1
fi
echo "  RESULT: no failures (BLOCKED tests, if any, need their environment)."
exit 0
