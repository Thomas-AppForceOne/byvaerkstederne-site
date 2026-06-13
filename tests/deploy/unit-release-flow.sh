#!/usr/bin/env bash
#
# Unit test for deploy/lib/release-flow.sh — bv_count_commits_ahead
# against a fixture repo with local develop/main branches.
#
# Coverage:
#   * equal branches → 0 both directions
#   * main ahead of develop (pending back-merge) → counted
#   * develop ahead of main (unreleased) → counted, independent of the above
#   * a missing ref → 0 (never reads as pending)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/release-flow.sh
. "$PROJECT_ROOT/deploy/lib/release-flow.sh"

PASS=0; FAIL=0
eq() { [ "$2" = "$3" ] && { echo "  ✓ $1"; PASS=$((PASS+1)); } || { echo "  ✗ $1 (want '$2', got '$3')" >&2; FAIL=$((FAIL+1)); }; }

echo "Unit test: release-flow.sh (bv_count_commits_ahead)"
echo "---"

STUB_PREFIX="bv-unit-release-flow."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 -exec rm -rf {} + 2>/dev/null || true
R="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")/repo"
trap 'rm -rf "$(dirname "$R")"' EXIT

git init -q "$R"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name Test
git -C "$R" config commit.gpgsign false
echo a > "$R/f"; git -C "$R" add -A; git -C "$R" commit -qm c1
git -C "$R" branch -M develop
git -C "$R" branch main                      # main == develop

eq "equal: develop..main = 0" "0" "$(bv_count_commits_ahead "$R" develop main)"
eq "equal: main..develop = 0" "0" "$(bv_count_commits_ahead "$R" main develop)"

# main gains a commit develop doesn't have → pending back-merge
git -C "$R" checkout -q main
echo b > "$R/hotfix"; git -C "$R" add -A; git -C "$R" commit -qm hotfix
eq "main ahead by 1 → develop..main = 1" "1" "$(bv_count_commits_ahead "$R" develop main)"
eq "develop not ahead → main..develop = 0" "0" "$(bv_count_commits_ahead "$R" main develop)"

# develop also gains a commit → unreleased work, independent of the above
git -C "$R" checkout -q develop
echo c > "$R/feature"; git -C "$R" add -A; git -C "$R" commit -qm feat
eq "develop ahead by 1 → main..develop = 1" "1" "$(bv_count_commits_ahead "$R" main develop)"
eq "main still ahead by 1 → develop..main = 1" "1" "$(bv_count_commits_ahead "$R" develop main)"

# missing ref → 0 (never reads as pending)
eq "missing tip ref → 0" "0" "$(bv_count_commits_ahead "$R" develop refs/heads/nope)"
eq "missing base ref → 0" "0" "$(bv_count_commits_ahead "$R" refs/heads/nope develop)"

echo "---"
echo "release-flow: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
