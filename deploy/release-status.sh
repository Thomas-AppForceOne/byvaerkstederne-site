#!/usr/bin/env bash
#
# Byværkstederne — release status.
#
# Read-only view of the develop ↔ main relationship in the release flow
# (develop → release/* → main → develop). Surfaces the two divergences
# that matter:
#
#   * main ahead of develop  → the main → develop back-merge is PENDING
#     (this is the drift release-start.sh refuses to build on top of).
#   * develop ahead of main  → unreleased work waiting for a release.
#
# Env: BV_RELEASE_REPO (default: this checkout), SKIP_REMOTE_CHECK=1.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${BV_RELEASE_REPO:-$(dirname "$SCRIPT_DIR")}"
# shellcheck source=deploy/lib/release-flow.sh
. "$SCRIPT_DIR/lib/release-flow.sh"

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "❌  $REPO is not a git repository." >&2
    exit 1
fi

DEV_REF="develop"
MAIN_REF="main"
if [ "${SKIP_REMOTE_CHECK:-}" != "1" ] && git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO" fetch --quiet origin develop main 2>/dev/null || \
        echo "⚠️   Could not fetch origin — comparing against last-known state." >&2
    git -C "$REPO" rev-parse --verify --quiet origin/develop >/dev/null && DEV_REF="origin/develop"
    git -C "$REPO" rev-parse --verify --quiet origin/main    >/dev/null && MAIN_REF="origin/main"
fi

PENDING_BACKMERGE="$(bv_count_commits_ahead "$REPO" "$DEV_REF" "$MAIN_REF")"
UNRELEASED="$(bv_count_commits_ahead "$REPO" "$MAIN_REF" "$DEV_REF")"

echo "Release status (${DEV_REF} ↔ ${MAIN_REF})"
echo "  main ahead of develop : ${PENDING_BACKMERGE}  (pending back-merge)"
echo "  develop ahead of main : ${UNRELEASED}  (unreleased commits)"

if [ "$PENDING_BACKMERGE" -gt 0 ] 2>/dev/null; then
    echo ""
    echo "⚠️   main → develop back-merge is PENDING."
    echo "    A release on main has not been merged back to develop, so develop is"
    echo "    behind the released code. Open a PR  main → develop  to reconcile."
    echo "    (release-start refuses to cut a new release until this is resolved.)"
fi
