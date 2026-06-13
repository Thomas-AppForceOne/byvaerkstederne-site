#!/usr/bin/env bash
#
# Byværkstederne — start a release.
#
# Enforces the first leg of the release branch strategy:
#
#     develop → release/* → main → develop
#     ^^^^^^^^^^^^^^^^^^^^
#
# Creates a release branch off develop, bumps the component VERSION
# file on it, and commits. The release branch is where the develop→main
# PR is staged; prod ships from main once that PR merges (see the prod
# gate in deploy/lib/release-gate.sh).
#
# Usage:
#   deploy/release-start.sh <version> [grav|landing]
#
#   grav    (default)  branch release/v<version>,         bumps config/www/VERSION
#   landing            branch release/landing-v<version>, bumps apex/VERSION
#
# Refusals (each is a way the flow silently breaks):
#   * dirty working tree              — commit/stash first
#   * develop out of sync with origin — override: SKIP_REMOTE_CHECK=1
#   * main → develop back-merge pending (main has commits develop lacks)
#                                     — override: ALLOW_PENDING_BACKMERGE=1
#   * the release tag already exists  — that version already shipped
#   * VERSION already at <version>    — nothing to bump
#   * the release branch already exists
#
# Env overrides (tests / emergencies):
#   BV_RELEASE_REPO          repo root to operate on (default: this checkout)
#   SKIP_REMOTE_CHECK        =1 skip the origin fetch + sync comparison
#   ALLOW_PENDING_BACKMERGE  =1 cut a release despite a pending back-merge

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${BV_RELEASE_REPO:-$(dirname "$SCRIPT_DIR")}"
# shellcheck source=deploy/lib/release-flow.sh
. "$SCRIPT_DIR/lib/release-flow.sh"

VERSION="${1:-}"
COMPONENT="${2:-grav}"

if [ -z "$VERSION" ]; then
    echo "❌  Usage: release-start.sh <version> [grav|landing]" >&2
    exit 1
fi
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
    echo "❌  '$VERSION' is not a valid semver version (expected MAJOR.MINOR.PATCH)." >&2
    exit 1
fi

case "$COMPONENT" in
    grav)
        VERSION_FILE="$REPO/config/www/VERSION"
        TAG="v${VERSION}"
        BRANCH="release/v${VERSION}" ;;
    landing)
        VERSION_FILE="$REPO/apex/VERSION"
        TAG="landing-v${VERSION}"
        BRANCH="release/landing-v${VERSION}" ;;
    *)
        echo "❌  Unknown component '$COMPONENT' (allowed: grav|landing)." >&2
        exit 1 ;;
esac

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "❌  $REPO is not a git repository." >&2
    exit 1
fi
if [ ! -f "$VERSION_FILE" ]; then
    echo "❌  VERSION file not found for component '$COMPONENT': $VERSION_FILE" >&2
    exit 1
fi

# ── (1) Clean working tree ──────────────────────────────────
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    echo "❌  Refusing to start a release with a dirty working tree." >&2
    echo "    Commit or stash your changes first." >&2
    exit 1
fi

# ── Resolve the develop/main refs (origin when available) ───
DEV_REF="develop"
MAIN_REF="main"
if [ "${SKIP_REMOTE_CHECK:-}" != "1" ] && git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO" fetch --quiet origin develop main 2>/dev/null || \
        echo "⚠️   Could not fetch origin — comparing against last-known state." >&2
    git -C "$REPO" rev-parse --verify --quiet origin/develop >/dev/null && DEV_REF="origin/develop"
    git -C "$REPO" rev-parse --verify --quiet origin/main    >/dev/null && MAIN_REF="origin/main"
fi

if ! git -C "$REPO" rev-parse --verify --quiet "$DEV_REF" >/dev/null; then
    echo "❌  No '$DEV_REF' branch — releases branch off develop." >&2
    exit 1
fi

# ── (2) develop in sync with origin/develop ─────────────────
if [ "${SKIP_REMOTE_CHECK:-}" != "1" ] && [ "$DEV_REF" = "origin/develop" ]; then
    if git -C "$REPO" rev-parse --verify --quiet develop >/dev/null; then
        if [ "$(git -C "$REPO" rev-parse develop)" != "$(git -C "$REPO" rev-parse origin/develop)" ]; then
            echo "❌  Local develop differs from origin/develop." >&2
            echo "    Pull/push so the release branches off the canonical develop, or set SKIP_REMOTE_CHECK=1." >&2
            exit 1
        fi
    fi
fi

# ── (3) Back-merge guard: main must not be ahead of develop ─
PENDING="$(bv_count_commits_ahead "$REPO" "$DEV_REF" "$MAIN_REF")"
if [ "$PENDING" -gt 0 ] 2>/dev/null; then
    if [ "${ALLOW_PENDING_BACKMERGE:-}" = "1" ]; then
        echo "⚠️   $MAIN_REF is $PENDING commit(s) ahead of $DEV_REF (back-merge pending) — ALLOW_PENDING_BACKMERGE=1 override." >&2
    else
        echo "❌  Refusing to start a release: $MAIN_REF is $PENDING commit(s) ahead of $DEV_REF." >&2
        echo "    A prior release on main was never merged back to develop. Complete the" >&2
        echo "    main → develop back-merge first (see: make release-status), or override" >&2
        echo "    with ALLOW_PENDING_BACKMERGE=1." >&2
        exit 1
    fi
fi

# ── (4) Tag / version / branch collisions ───────────────────
if git -C "$REPO" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "❌  Tag '${TAG}' already exists — version ${VERSION} has already shipped. Pick a higher version." >&2
    exit 1
fi
CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [ "$CURRENT" = "$VERSION" ]; then
    echo "❌  ${VERSION_FILE#"$REPO"/} is already at ${VERSION} — nothing to bump." >&2
    exit 1
fi
if git -C "$REPO" rev-parse -q --verify "refs/heads/${BRANCH}" >/dev/null; then
    echo "❌  Branch '${BRANCH}' already exists." >&2
    exit 1
fi

# ── Create the release branch off develop, bump, commit ─────
git -C "$REPO" checkout -q -b "$BRANCH" --no-track "$DEV_REF"
printf '%s\n' "$VERSION" > "$VERSION_FILE"
git -C "$REPO" add -- "$VERSION_FILE"
git -C "$REPO" commit -q -m "chore(release): ${COMPONENT} ${VERSION}"

echo "✓ Started ${BRANCH} off ${DEV_REF}; bumped ${VERSION_FILE#"$REPO"/} ${CURRENT} → ${VERSION}."
echo ""
echo "  Next steps in the flow (develop → release → main → develop):"
echo "    1. git push -u origin ${BRANCH} && gh pr create --base main"
echo "    2. after the PR merges to main:  make tag-release${COMPONENT:+ component=$COMPONENT} push=1"
echo "    3. ship it:                       make deploy tier=prod"
echo "    4. back-merge:                    open a PR  main → develop"
