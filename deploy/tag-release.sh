#!/usr/bin/env bash
#
# Byværkstederne — release tagger.
#
# Cuts an annotated release tag for one component, after verifying the
# tree is in a releasable state. Pairs with the production release gate
# in deploy/lib/release-gate.sh: prod refuses to deploy unless HEAD
# carries the tag this script creates.
#
# Usage:
#   deploy/tag-release.sh [grav|landing] [--push]
#
#   grav     (default)  tag  v<config/www/VERSION>     — the Grav site
#   landing             tag  landing-v<apex/VERSION>   — the apex landing page
#   --push              also push the tag to origin (default: local only,
#                       prints the push command)
#
# The two components version independently, so each gets its own tag
# namespace. Always creates ANNOTATED tags (never lightweight) — the prod
# gate's `git describe` only honours annotated tags.
#
# Refusals (each is the kind of mistake that silently ships the wrong
# bits to production):
#   * not on main          — override: ALLOW_TAG_OFF_MAIN=1 (emergency hotfix)
#   * dirty working tree    — hard (tagging a dirty tree tags the last
#                             commit, NOT the uncommitted changes)
#   * local main behind/ahead of origin/main — override: SKIP_REMOTE_CHECK=1
#   * VERSION not valid semver
#   * tag already exists    — you forgot to bump the VERSION file
#
# Env overrides (for tests / emergencies):
#   BV_RELEASE_REPO     repo root to operate on (default: this checkout)
#   ALLOW_TAG_OFF_MAIN  =1 to tag from a branch other than main
#   SKIP_REMOTE_CHECK   =1 to skip the origin/main sync comparison

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${BV_RELEASE_REPO:-$(dirname "$SCRIPT_DIR")}"

# ── Parse args ──────────────────────────────────────────────
COMPONENT="grav"
PUSH=0
for arg in "$@"; do
    case "$arg" in
        --push)          PUSH=1 ;;
        grav|landing)    COMPONENT="$arg" ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "❌  Unknown argument '$arg' (usage: tag-release.sh [grav|landing] [--push])" >&2
            exit 1 ;;
    esac
done

# ── Component → VERSION file + tag prefix ───────────────────
case "$COMPONENT" in
    grav)
        VERSION_FILE="$REPO/config/www/VERSION"
        TAG_PREFIX="v" ;;
    landing)
        VERSION_FILE="$REPO/apex/VERSION"
        TAG_PREFIX="landing-v" ;;
esac

if [ ! -f "$VERSION_FILE" ]; then
    echo "❌  VERSION file not found for component '$COMPONENT': $VERSION_FILE" >&2
    exit 1
fi

# ── Must be a git repo ──────────────────────────────────────
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    echo "❌  $REPO is not a git repository." >&2
    exit 1
fi

BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

# ── (1) Branch must be main ─────────────────────────────────
if [ "$BRANCH" != "main" ]; then
    if [ "${ALLOW_TAG_OFF_MAIN:-}" = "1" ]; then
        echo "⚠️   Tagging from branch '$BRANCH' (not main) — ALLOW_TAG_OFF_MAIN=1 override in effect." >&2
    else
        echo "❌  Refusing to tag a release from branch '$BRANCH'." >&2
        echo "    Releases are tagged on main, after the release PR is merged." >&2
        echo "    Emergency override:  ALLOW_TAG_OFF_MAIN=1 make tag-release" >&2
        exit 1
    fi
fi

# ── (2) Working tree must be clean ──────────────────────────
if [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
    echo "❌  Refusing to tag a dirty working tree (uncommitted changes present)." >&2
    echo "    A tag points at the last commit, not your uncommitted changes." >&2
    echo "    Commit or stash first." >&2
    exit 1
fi

# ── (3) Local main in sync with origin/main ─────────────────
# Best-effort: if there is no origin, or --skip, we don't block. When
# there is one, refuse to tag a stale or unpushed main so the tag always
# lands on the canonical commit everyone else sees.
if [ "${SKIP_REMOTE_CHECK:-}" != "1" ] && git -C "$REPO" remote get-url origin >/dev/null 2>&1; then
    git -C "$REPO" fetch --quiet origin main 2>/dev/null || \
        echo "⚠️   Could not fetch origin/main — comparing against last-known state." >&2
    if git -C "$REPO" rev-parse --verify --quiet origin/main >/dev/null; then
        LOCAL="$(git -C "$REPO" rev-parse HEAD)"
        REMOTE="$(git -C "$REPO" rev-parse origin/main)"
        if [ "$LOCAL" != "$REMOTE" ] && [ "$BRANCH" = "main" ]; then
            echo "❌  Local main ($(git -C "$REPO" rev-parse --short HEAD)) differs from origin/main ($(git -C "$REPO" rev-parse --short origin/main))." >&2
            echo "    Pull/push so the tag lands on the canonical commit, or set SKIP_REMOTE_CHECK=1." >&2
            exit 1
        fi
    fi
fi

# ── (4) VERSION must be valid semver ────────────────────────
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'; then
    echo "❌  $VERSION_FILE does not contain a valid semver version (got: '$VERSION')." >&2
    exit 1
fi

TAG="${TAG_PREFIX}${VERSION}"

# ── (5) Tag must not already exist ──────────────────────────
if git -C "$REPO" rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    echo "❌  Tag '${TAG}' already exists." >&2
    echo "    Bump ${VERSION_FILE#"$REPO"/} to a new version before tagging a release." >&2
    exit 1
fi

# ── Create the annotated tag ────────────────────────────────
SHORT="$(git -C "$REPO" rev-parse --short HEAD)"
git -C "$REPO" tag -a "$TAG" -m "Release ${TAG} (${COMPONENT})"
echo "✓ Created annotated tag '${TAG}' at ${SHORT} (${COMPONENT})."

# ── Push (opt-in) ───────────────────────────────────────────
if [ "$PUSH" = "1" ]; then
    git -C "$REPO" push origin "$TAG"
    echo "✓ Pushed '${TAG}' to origin."
else
    echo ""
    echo "  Tag is local only. Push it with:"
    echo "      git push origin ${TAG}"
    echo "  or re-run with --push (make tag-release push=1)."
fi
