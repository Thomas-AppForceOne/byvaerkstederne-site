#!/usr/bin/env bash
#
# Shell-level probe for deploy/tag-release.sh.
#
# Runs entirely locally inside mktemp git fixtures (no ssh, no remote, no
# credentials). SKIP_REMOTE_CHECK=1 throughout so the absence of an origin
# never blocks; BV_RELEASE_REPO points the script at each fixture.
#
# Coverage (success + every failure path, per CLAUDE.md testing discipline):
#   Success:
#     * grav    → creates ANNOTATED tag v<config/www/VERSION>
#     * landing → creates ANNOTATED tag landing-v<apex/VERSION>
#     * off main + ALLOW_TAG_OFF_MAIN=1 → creates the tag
#   Failure:
#     * tag already exists (unbumped VERSION) → refuse
#     * dirty working tree → refuse
#     * off main without override → refuse
#     * VERSION not valid semver → refuse
#     * unknown component argument → refuse

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG_SH="$PROJECT_ROOT/deploy/tag-release.sh"

PASS=0
FAIL=0

check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then
        echo "  ✓ $name"
        PASS=$((PASS+1))
    else
        echo "  ✗ $name" >&2
        FAIL=$((FAIL+1))
    fi
}

echo "Probe: tag-release.sh"
echo "---"

STUB_PREFIX="bv-tag-release."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
STUB_DIR="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

# mk_repo <dir> <grav-version> <landing-version> — fresh repo on clean main.
mk_repo() {
    local dir="$1" gravver="$2" landingver="$3"
    rm -rf "$dir"
    git init -q "$dir"
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name Test
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config tag.gpgsign false
    mkdir -p "$dir/config/www" "$dir/apex"
    printf '%s\n' "$gravver"    > "$dir/config/www/VERSION"
    printf '%s\n' "$landingver" > "$dir/apex/VERSION"
    git -C "$dir" add -A
    git -C "$dir" commit -qm "init"
    git -C "$dir" branch -M main
}

# run_tag <repo> <args...> — invoke the script; echoes nothing, returns rc.
run_tag() {
    local repo="$1"; shift
    local rc=0
    BV_RELEASE_REPO="$repo" SKIP_REMOTE_CHECK=1 \
        bash "$TAG_SH" "$@" >/dev/null 2>&1 || rc=$?
    return "$rc"
}

# tag_type <repo> <tag> — "tag" for annotated, "commit" for lightweight, "" if absent.
tag_type() { git -C "$1" cat-file -t "$2" 2>/dev/null || echo ""; }

# ── grav success → annotated v1.0.0 ─────────────────────────
R="$STUB_DIR/grav-ok"; mk_repo "$R" "1.0.0" "0.2.0"
if run_tag "$R" grav; then
    [ "$(tag_type "$R" v1.0.0)" = "tag" ] \
        && check "grav: creates annotated tag v1.0.0" ok \
        || check "grav: tag v1.0.0 exists but is not annotated" fail
else
    check "grav: script should succeed on clean main" fail
fi

# ── landing success → annotated landing-v0.2.0 ──────────────
R="$STUB_DIR/landing-ok"; mk_repo "$R" "1.0.0" "0.2.0"
if run_tag "$R" landing; then
    [ "$(tag_type "$R" landing-v0.2.0)" = "tag" ] \
        && check "landing: creates annotated tag landing-v0.2.0" ok \
        || check "landing: tag landing-v0.2.0 missing/not annotated" fail
    # grav tag must NOT have been created by a landing run
    [ -z "$(tag_type "$R" v1.0.0)" ] \
        && check "landing: does not create the grav tag" ok \
        || check "landing: unexpectedly created grav tag" fail
else
    check "landing: script should succeed on clean main" fail
fi

# ── existing tag (unbumped VERSION) → refuse ────────────────
R="$STUB_DIR/grav-dup"; mk_repo "$R" "1.0.0" "0.2.0"
run_tag "$R" grav   # first one succeeds
if run_tag "$R" grav; then
    check "grav: second tag of same VERSION should be refused" fail
else
    check "grav: existing tag → refuse" ok
fi

# ── dirty tree → refuse ─────────────────────────────────────
R="$STUB_DIR/grav-dirty"; mk_repo "$R" "1.2.0" "0.2.0"
echo "uncommitted" > "$R/config/www/VERSION"
if run_tag "$R" grav; then
    check "grav: dirty tree should be refused" fail
else
    check "grav: dirty tree → refuse" ok
fi

# ── off main without override → refuse; with override → tag ─
R="$STUB_DIR/grav-branch"; mk_repo "$R" "1.3.0" "0.2.0"
git -C "$R" checkout -q -b feature/x
if run_tag "$R" grav; then
    check "grav: off-main without override should be refused" fail
else
    check "grav: off main → refuse" ok
fi
if ALLOW_TAG_OFF_MAIN=1 run_tag "$R" grav; then
    [ "$(tag_type "$R" v1.3.0)" = "tag" ] \
        && check "grav: off main + ALLOW_TAG_OFF_MAIN=1 → creates annotated tag" ok \
        || check "grav: override ran but tag missing/not annotated" fail
else
    check "grav: off main + override should succeed" fail
fi

# ── invalid semver → refuse ─────────────────────────────────
R="$STUB_DIR/grav-bad-semver"; mk_repo "$R" "not-a-version" "0.2.0"
if run_tag "$R" grav; then
    check "grav: non-semver VERSION should be refused" fail
else
    check "grav: invalid semver → refuse" ok
fi

# ── unknown component → refuse ──────────────────────────────
R="$STUB_DIR/grav-badcomp"; mk_repo "$R" "1.0.0" "0.2.0"
if run_tag "$R" bogus; then
    check "unknown component should be refused" fail
else
    check "unknown component → refuse" ok
fi

echo "---"
echo "tag-release: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
