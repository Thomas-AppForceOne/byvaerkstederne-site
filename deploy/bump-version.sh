#!/usr/bin/env bash
#
# Byværkstederne — bump a component's version number (no tag).
#
# The lightweight, dev-side counterpart to release-start.sh / tag-release.sh:
# it edits the VERSION file and commits, nothing more. No release branch,
# no git tag. Use it to advance the version that dev/test/staging report
# (the prod release ceremony is `make release-start` → `make tag-release`).
#
# Usage:
#   deploy/bump-version.sh <major|minor|patch> [grav|landing] [--no-commit]
#
#   grav    (default)  bumps config/www/VERSION
#   landing            bumps apex/VERSION
#   --no-commit        only edit the file (don't commit)
#   --pre=<label>      append a pre-release suffix (e.g. --pre=dev → X.Y.Z-dev),
#                      for opening the next development iteration on develop
#
# Increments the numeric core and drops any existing pre-release/build
# suffix (1.3.0-dev --patch--> 1.3.1); pass --pre to re-apply one
# (1.1.0 --minor --pre=dev--> 1.2.0-dev). Refuses to commit on
# develop/main — those branches are protected; branch first (or use
# --no-commit to only edit).
#
# Env: BV_RELEASE_REPO (default: this checkout).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${BV_RELEASE_REPO:-$(dirname "$SCRIPT_DIR")}"
# shellcheck source=deploy/lib/version-bump.sh
. "$SCRIPT_DIR/lib/version-bump.sh"

PART=""
COMPONENT="grav"
DO_COMMIT=1
PRE=""
for arg in "$@"; do
    case "$arg" in
        major|minor|patch) PART="$arg" ;;
        grav|landing)      COMPONENT="$arg" ;;
        --no-commit)       DO_COMMIT=0 ;;
        --pre=*)           PRE="${arg#--pre=}" ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            echo "❌  Unknown argument '$arg' (usage: bump-version.sh <major|minor|patch> [grav|landing] [--pre=<label>] [--no-commit])" >&2
            exit 1 ;;
    esac
done

if [ -z "$PART" ]; then
    echo "❌  Usage: bump-version.sh <major|minor|patch> [grav|landing] [--no-commit]" >&2
    exit 1
fi

case "$COMPONENT" in
    grav)    VERSION_FILE="$REPO/config/www/VERSION" ;;
    landing) VERSION_FILE="$REPO/apex/VERSION" ;;
esac

if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "❌  $REPO is not a git repository." >&2
    exit 1
fi
if [ ! -f "$VERSION_FILE" ]; then
    echo "❌  VERSION file not found for component '$COMPONENT': $VERSION_FILE" >&2
    exit 1
fi

# Protected-branch guard — only relevant when we're about to commit.
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [ "$DO_COMMIT" = "1" ] && { [ "$BRANCH" = "develop" ] || [ "$BRANCH" = "main" ]; }; then
    echo "❌  Refusing to commit a version bump on '$BRANCH' — develop/main are protected." >&2
    echo "    Branch first (git checkout -b feature/<slug>), or pass --no-commit to only edit the file." >&2
    exit 1
fi

CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! NEW="$(bv_bump_semver "$CURRENT" "$PART" "$PRE" 2>/dev/null)"; then
    echo "❌  Cannot bump ${VERSION_FILE#"$REPO"/}: check version core ('$CURRENT')${PRE:+ and pre-release label ('$PRE')}." >&2
    exit 1
fi

printf '%s\n' "$NEW" > "$VERSION_FILE"
echo "✓ Bumped ${COMPONENT} (${VERSION_FILE#"$REPO"/}) ${CURRENT} → ${NEW}."

if [ "$DO_COMMIT" = "1" ]; then
    git -C "$REPO" add -- "$VERSION_FILE"
    git -C "$REPO" commit -q -m "chore: bump ${COMPONENT} version ${CURRENT} → ${NEW}"
    echo "  committed on ${BRANCH}."
else
    echo "  (edited only — not committed)"
fi
echo "  Deploy it:  make deploy tier=dev"
