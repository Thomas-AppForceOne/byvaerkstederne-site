#!/usr/bin/env bash
#
# Unit test for deploy/lib/release-pr-guard.sh — bv_release_pr_guard
# against a fixture repo with a `main` base, VERSION files for both
# components, and a mix of annotated + lightweight tags.
#
# Coverage mirrors the spec's acceptance criteria
# (specifications/ci_release_protection_part1_specification.md):
#   * release/v* (grav) passes when bumped, clean, tag-free
#   * release/landing-v* is scoped to apex/VERSION + landing-v* tags
#   * hotfix/v* resolves the grav component
#   * feature/* → rule 1 message; release/version-foo → rule 2 message
#   * -dev version → rule 3 message
#   * not-bumped (lower / equal) → rule 4 message
#   * existing tag (annotated AND lightweight) → rule 5 message
#   * a multiply-broken PR reports rule 4 AND rule 5 in one run

set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/release-pr-guard.sh
. "$PROJECT_ROOT/deploy/lib/release-pr-guard.sh"

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $1" >&2; FAIL=$((FAIL+1)); }

echo "Unit test: release-pr-guard.sh (bv_release_pr_guard)"
echo "---"

STUB_PREFIX="bv-unit-release-pr-guard."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 -exec rm -rf {} + 2>/dev/null || true
R="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")/repo"
trap 'rm -rf "$(dirname "$R")"' EXIT

mkdir -p "$R/config/www" "$R/apex"
git init -q "$R"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name Test
git -C "$R" config commit.gpgsign false
git -C "$R" symbolic-ref HEAD refs/heads/main

# Base state on main: grav 1.1.0, landing 0.2.0.
echo "1.1.0" > "$R/config/www/VERSION"
echo "0.2.0" > "$R/apex/VERSION"
git -C "$R" add -A
git -C "$R" commit -qm "base versions"

# Tags that already exist on the remote: an ANNOTATED grav tag and a
# LIGHTWEIGHT landing tag, so rule 5 is exercised for both kinds.
git -C "$R" tag -a v1.1.0    -m "grav 1.1.0"      # annotated
git -C "$R" tag    landing-v0.2.0                 # lightweight

# set_head_version <component> <value> — overwrite the working-tree
# VERSION file the guard reads as "the PR head's version".
set_head() {
    case "$1" in
        grav)    echo "$2" > "$R/config/www/VERSION" ;;
        landing) echo "$2" > "$R/apex/VERSION" ;;
    esac
}

# run_guard <head_ref> — captures stderr to GUARD_ERR, exit to GUARD_RC.
run_guard() {
    GUARD_ERR="$(bv_release_pr_guard "$1" "$R" main 2>&1)"
    GUARD_RC=$?
}

# pass_case <name> <head_ref>
pass_case() {
    run_guard "$2"
    if [ "$GUARD_RC" -eq 0 ]; then ok "$1"; else bad "$1 (expected pass, got rc=$GUARD_RC: $GUARD_ERR)"; fi
}
# fail_case <name> <head_ref> <substr...>
fail_case() {
    local name="$1" ref="$2"; shift 2
    run_guard "$ref"
    if [ "$GUARD_RC" -eq 0 ]; then bad "$name (expected failure, got pass)"; return; fi
    local missing=""
    local s
    for s in "$@"; do
        case "$GUARD_ERR" in *"$s"*) ;; *) missing="$missing [$s]";; esac
    done
    if [ -z "$missing" ]; then ok "$name"; else bad "$name (rc=$GUARD_RC but message missing:$missing — got: $GUARD_ERR)"; fi
}

# ── Pass paths ────────────────────────────────────────────────────────
set_head grav 1.3.0
pass_case "release/v1.3.0 (bumped 1.1.0→1.3.0, clean, tag-free) passes" "release/v1.3.0"

# Landing is scoped to apex/VERSION + landing-v*: leave grav's VERSION
# at a value that WOULD fail (== base) to prove the grav file is ignored.
set_head grav 1.1.0
set_head landing 0.3.0
pass_case "release/landing-v0.3.0 evaluated against apex/VERSION (grav file ignored)" "release/landing-v0.3.0"

set_head grav 1.1.1
pass_case "hotfix/v1.1.1 resolves the grav component and passes" "hotfix/v1.1.1"

# ── Rule 1: not a release branch ──────────────────────────────────────
fail_case "feature/x → rule 1 (release/* or hotfix/* only)" "feature/x" "[rule 1]" "release/* or hotfix/*"

# ── Rule 2: release branch but component unresolvable ─────────────────
fail_case "release/version-foo → rule 2 (cannot resolve component)" "release/version-foo" "[rule 2]" "cannot resolve component"

# ── Rule 3: pre-release version ───────────────────────────────────────
set_head grav 1.3.0-dev
fail_case "config/www/VERSION 1.3.0-dev → rule 3 (must be finalised)" "release/v1.3.0" "[rule 3]" "finalised"

# ── Rule 4: not bumped (lower, then equal) ────────────────────────────
set_head grav 1.0.0
fail_case "1.0.0 < base 1.1.0 → rule 4 (not bumped)" "release/v1.0.0" "[rule 4]" "not bumped"

# ── Rule 4: comparator-error arm (shadow bv_semver_compare to fail) ────
# An otherwise-valid clean, bumped head; force the comparator to error so
# rule 4 takes its internal-error arm rather than the "not bumped" arm.
set_head grav 1.3.0
bv_semver_compare() { return 1; }
fail_case "comparator failure → rule 4 (internal: comparison failed), fails closed" \
    "release/v1.3.0" "[rule 4]" "internal" "comparison failed"
unset -f bv_semver_compare

# ── Rule 5: tag already exists (annotated grav, lightweight landing) ──
set_head grav 2.0.0
git -C "$R" tag v2.0.0                              # lightweight, bumped & clean
fail_case "v2.0.0 tag exists (lightweight) → rule 5 (tag already exists)" "release/v2.0.0" "[rule 5]" "already exists"

set_head landing 0.2.0
fail_case "landing 0.2.0 == base AND landing-v0.2.0 tag exists → rule 4 + rule 5" \
    "release/landing-v0.2.0" "[rule 4]" "[rule 5]"

# ── Multiply-broken: one run reports rule 4 AND rule 5 ───────────────
set_head grav 1.1.0                                   # == base (rule 4) ...
# ... and v1.1.0 is an annotated tag (rule 5)
fail_case "multiply-broken release/v1.1.0 reports rule 4 AND rule 5 together" \
    "release/v1.1.0" "[rule 4]" "[rule 5]"

echo "---"
echo "release-pr-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
