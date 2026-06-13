#!/usr/bin/env bash
#
# Unit test for deploy/lib/version-bump.sh — bv_bump_semver.
#
# Coverage:
#   * major/minor/patch on a clean X.Y.Z (resets lower components)
#   * pre-release/build suffix is dropped (bumps the numeric core)
#   * leading-zero core handled (base-10, not octal)
#   * invalid core → error; unknown part → error

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/version-bump.sh
. "$PROJECT_ROOT/deploy/lib/version-bump.sh"

PASS=0; FAIL=0
eq() { [ "$2" = "$3" ] && { echo "  ✓ $1"; PASS=$((PASS+1)); } || { echo "  ✗ $1 (want '$2', got '$3')" >&2; FAIL=$((FAIL+1)); }; }
err() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ✗ $name (expected failure, got success)" >&2; FAIL=$((FAIL+1));
    else echo "  ✓ $name"; PASS=$((PASS+1)); fi
}

echo "Unit test: version-bump.sh (bv_bump_semver)"
echo "---"

eq "patch: 1.3.2 → 1.3.3" "1.3.3" "$(bv_bump_semver 1.3.2 patch)"
eq "minor: 1.3.2 → 1.4.0 (patch reset)" "1.4.0" "$(bv_bump_semver 1.3.2 minor)"
eq "major: 1.3.2 → 2.0.0 (minor+patch reset)" "2.0.0" "$(bv_bump_semver 1.3.2 major)"

eq "patch drops -dev suffix: 1.3.0-dev → 1.3.1" "1.3.1" "$(bv_bump_semver 1.3.0-dev patch)"
eq "minor drops -rc suffix: 1.3.0-rc.1 → 1.4.0" "1.4.0" "$(bv_bump_semver 1.3.0-rc.1 minor)"
eq "patch drops +build metadata: 1.3.0+109.gabc → 1.3.1" "1.3.1" "$(bv_bump_semver 1.3.0+109.gabc patch)"

eq "leading zero handled (base-10): 1.0.08 → 1.0.9" "1.0.9" "$(bv_bump_semver 1.0.08 patch)"

# pre-release label (the "open next dev iteration" use case)
eq "pre: 1.1.0 minor dev → 1.2.0-dev" "1.2.0-dev" "$(bv_bump_semver 1.1.0 minor dev)"
eq "pre: 1.1.0 patch rc.1 → 1.1.1-rc.1" "1.1.1-rc.1" "$(bv_bump_semver 1.1.0 patch rc.1)"
eq "pre: 1.1.0 major dev → 2.0.0-dev" "2.0.0-dev" "$(bv_bump_semver 1.1.0 major dev)"
eq "pre re-applied over existing suffix: 1.2.0-dev patch dev → 1.2.1-dev" "1.2.1-dev" "$(bv_bump_semver 1.2.0-dev patch dev)"
eq "empty pre → clean number (no suffix)" "1.2.0" "$(bv_bump_semver 1.1.0 minor "")"

err "invalid core → error" bv_bump_semver "not-a-version" patch
err "two-part core → error" bv_bump_semver "1.2" patch
err "unknown part → error" bv_bump_semver "1.2.3" build
err "invalid pre label (leading dot) → error" bv_bump_semver "1.2.3" patch ".bad"
err "invalid pre label (trailing dash) → error" bv_bump_semver "1.2.3" patch "dev-"

echo "---"
echo "version-bump: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
