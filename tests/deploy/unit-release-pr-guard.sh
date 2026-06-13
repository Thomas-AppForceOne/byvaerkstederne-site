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

# Pristine base commit (grav 1.1.0 / landing 0.2.0). restore_base resets
# main back to this so a case that mutates the base never bleeds into the
# next one.
BASE_SHA="$(git -C "$R" rev-parse HEAD)"

# set_head_version <component> <value> — overwrite the working-tree
# VERSION file the guard reads as "the PR head's version".
set_head() {
    case "$1" in
        grav)    echo "$2" > "$R/config/www/VERSION" ;;
        landing) echo "$2" > "$R/apex/VERSION" ;;
    esac
}

# del_head <component> — remove the working-tree VERSION file so the guard
# sees the PR head as missing that component's VERSION (rule 3 absence).
del_head() {
    case "$1" in
        grav)    rm -f "$R/config/www/VERSION" ;;
        landing) rm -f "$R/apex/VERSION" ;;
    esac
}

# set_base <component> <value> — write a VERSION onto the base commit and
# commit it, so the guard's `git show main:<file>` reads <value> as the
# base. Mutates both the committed base and the working tree; pair every
# call with restore_base before the next case.
set_base() {
    set_head "$1" "$2"
    git -C "$R" commit -aqm "base $1=$2"
}

# restore_base — return main (committed base + working tree) to the
# pristine grav 1.1.0 / landing 0.2.0 state, undoing any set_base/set_head
# mutation so cases stay independent of one another.
restore_base() {
    git -C "$R" reset -q --hard "$BASE_SHA"
}

# run_guard <head_ref> [<base_ref>] — captures stderr to GUARD_ERR, exit
# to GUARD_RC. base_ref defaults to main; pass a bogus ref to exercise the
# unfetched-base branch (rule 4).
run_guard() {
    GUARD_ERR="$(bv_release_pr_guard "$1" "$R" "${2:-main}" 2>&1)"
    GUARD_RC=$?
}

# pass_case <name> <head_ref>
pass_case() {
    run_guard "$2"
    if [ "$GUARD_RC" -eq 0 ]; then ok "$1"; else bad "$1 (expected pass, got rc=$GUARD_RC: $GUARD_ERR)"; fi
}
# fail_case <name> <head_ref> <present-substr...> [-- <absent-substr...>]
#
# Asserts a non-zero exit AND that every present-substr appears in the
# diagnostics. A literal `--` argument switches to absent-substrs: every
# token after it MUST be missing from the diagnostics. The absent half is
# how a case proves a rule fired in ISOLATION (e.g. `-- "[rule 5]"`
# guarantees rule 5 did NOT co-fire and mask the branch under test).
#
# The base ref defaults to main; set GUARD_BASE before the call to drive a
# bogus/unfetched base (rule 4's "is the base ref fetched?" branch).
fail_case() {
    local name="$1" ref="$2"; shift 2
    run_guard "$ref" "${GUARD_BASE:-}"
    if [ "$GUARD_RC" -eq 0 ]; then bad "$name (expected failure, got pass)"; return; fi
    local missing="" unexpected="" s mode="present"
    for s in "$@"; do
        if [ "$s" = "--" ]; then mode="absent"; continue; fi
        case "$mode" in
            present) case "$GUARD_ERR" in *"$s"*) ;; *) missing="$missing [$s]";; esac ;;
            absent)  case "$GUARD_ERR" in *"$s"*) unexpected="$unexpected [$s]";; *) ;; esac ;;
        esac
    done
    if [ -z "$missing" ] && [ -z "$unexpected" ]; then
        ok "$name"
    elif [ -n "$unexpected" ]; then
        bad "$name (rc=$GUARD_RC but unexpected present:$unexpected${missing:+ — and missing:$missing} — got: $GUARD_ERR)"
    else
        bad "$name (rc=$GUARD_RC but message missing:$missing — got: $GUARD_ERR)"
    fi
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

# The comparator-error case above shadows then `unset -f`s
# bv_semver_compare, which drops the sourced definition; re-source the
# library so the comparator-dependent cases below run against the real one.
. "$PROJECT_ROOT/deploy/lib/release-pr-guard.sh"

# ── Rule 3: head VERSION file absent on the PR head ──────────────────
# Deleting config/www/VERSION drives head_version empty: rule 3 fires the
# "does not exist" arm and rules 4/5 cascade to "not evaluated" (I-001).
restore_base
del_head grav
fail_case "config/www/VERSION absent on head → rule 3 (does not exist), rules 4/5 not evaluated" \
    "release/v1.3.0" "[rule 3]" "does not exist on the PR head" "not evaluated"
restore_base

# ── Rule 4: base ref unfetched / unreadable (empty base_version) ─────
# A clean, bumped head with a base ref the checkout does not carry: the
# `git show <ref>:VERSION` read fails to "", so rule 4 takes its
# "could not read base … is the base ref fetched?" arm, rc=1 (I-002).
set_head grav 1.3.0
GUARD_BASE="refs/heads/no-such-base" \
fail_case "unfetched base ref → rule 4 (could not read base, is the base ref fetched?)" \
    "release/v1.3.0" "[rule 4]" "is the base ref fetched"
restore_base

# ── Rule 4: base core malformed (two-part base VERSION) ──────────────
# Commit a malformed base VERSION (1.2). The head is clean+bumped, but the
# base has no clean X.Y.Z core, so rule 4 reports "no clean X.Y.Z core to
# compare against" rather than running the comparator (I-015).
set_base grav 1.2
set_head grav 1.3.0
fail_case "malformed base core 1.2 → rule 4 (no clean X.Y.Z core to compare against)" \
    "release/v1.3.0" "[rule 4]" "no clean X.Y.Z core"
restore_base

# ── Rule 4 in ISOLATION: head == base, no matching tag ───────────────
# Move the base to a version with NO matching tag (v1.5.0 is untagged),
# then set the head equal to it. The comparator returns 0 → rule 4 fires
# "not bumped"; the tag is free → rule 5 stays silent. Asserting [rule 5]
# ABSENT proves rule 4's equality verdict is observed on its own, not
# inferred behind a co-firing rule 5 (I-009).
set_base grav 1.5.0
set_head grav 1.5.0
fail_case "head 1.5.0 == base, tag-free → rule 4 only (rule 5 absent)" \
    "release/v1.5.0" "[rule 4]" "not bumped" -- "[rule 5]"
restore_base

echo "---"
echo "release-pr-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
