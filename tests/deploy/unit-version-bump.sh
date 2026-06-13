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
echo "Unit test: version-bump.sh (bv_semver_compare)"
echo "---"

# Equal
eq "equal: 1.2.3 == 1.2.3 → 0" "0" "$(bv_semver_compare 1.2.3 1.2.3)"
eq "equal: 0.0.0 == 0.0.0 → 0" "0" "$(bv_semver_compare 0.0.0 0.0.0)"

# Greater (a > b → 1) across each component
eq "patch greater: 1.2.4 > 1.2.3 → 1" "1" "$(bv_semver_compare 1.2.4 1.2.3)"
eq "minor greater: 1.3.0 > 1.2.9 → 1" "1" "$(bv_semver_compare 1.3.0 1.2.9)"
eq "major greater: 2.0.0 > 1.9.9 → 1" "1" "$(bv_semver_compare 2.0.0 1.9.9)"

# Lower (a < b → -1)
eq "patch lower: 1.2.3 < 1.2.4 → -1" "-1" "$(bv_semver_compare 1.2.3 1.2.4)"
eq "minor lower: 1.2.9 < 1.3.0 → -1" "-1" "$(bv_semver_compare 1.2.9 1.3.0)"
eq "major lower: 1.9.9 < 2.0.0 → -1" "-1" "$(bv_semver_compare 1.9.9 2.0.0)"

# Numeric (not lexicographic) ordering: 0.10.0 > 0.2.0
eq "numeric not lexical: 0.10.0 > 0.2.0 → 1" "1" "$(bv_semver_compare 0.10.0 0.2.0)"
eq "numeric not lexical: 0.2.0 < 0.10.0 → -1" "-1" "$(bv_semver_compare 0.2.0 0.10.0)"

# Leading zero handled base-10 (08 == 8, not octal error)
eq "leading zero: 1.0.08 == 1.0.8 → 0" "0" "$(bv_semver_compare 1.0.08 1.0.8)"

# Failure paths: a pre-release / malformed value must ERROR, never be
# silently treated as equal (rule 4 must screen via rule 3 first).
err "pre-release on a → error" bv_semver_compare "1.2.0-dev" "1.2.0"
err "pre-release on b → error" bv_semver_compare "1.2.0" "1.2.0-rc.1"
err "build metadata → error" bv_semver_compare "1.2.0+build" "1.2.0"
err "two-part version → error" bv_semver_compare "1.2" "1.2.0"
err "non-numeric → error" bv_semver_compare "x.y.z" "1.2.3"

echo "---"
echo "Unit test: version-bump.sh (bv_is_clean_semver)"
echo "---"

# ok: predicate returns 0 (true) for a clean X.Y.Z; err: returns non-zero.
ok() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name (expected true, got false)" >&2; FAIL=$((FAIL+1)); fi
}

# Success path: clean X.Y.Z shapes are accepted (leading zeros are a
# structural-only check — like the regex, the predicate does not reject
# them; base-10 forcing lives in the comparator/bump helpers).
ok "clean: 1.2.3 → true" bv_is_clean_semver "1.2.3"
ok "clean: 0.0.0 → true" bv_is_clean_semver "0.0.0"
ok "clean: 10.20.30 → true" bv_is_clean_semver "10.20.30"
ok "clean: leading zero 1.0.08 → true" bv_is_clean_semver "1.0.08"

# Failure path: any non-X.Y.Z shape is rejected.
err "pre-release suffix → false" bv_is_clean_semver "1.2.3-dev"
err "build metadata → false" bv_is_clean_semver "1.2.3+build"
err "two-part version → false" bv_is_clean_semver "1.2"
err "four-part version → false" bv_is_clean_semver "1.2.3.4"
err "non-numeric → false" bv_is_clean_semver "x.y.z"
err "empty string → false" bv_is_clean_semver ""

echo "---"
echo "version-bump: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
