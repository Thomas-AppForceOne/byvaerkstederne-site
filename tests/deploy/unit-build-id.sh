#!/usr/bin/env bash
#
# Unit test for deploy/lib/build-id.sh — bv_compute_git_describe and
# bv_compute_semver against fixture git repos in a mktemp dir.
#
# Same shape as unit-release-gate.sh / unit-ssh-auth.sh.
#
# Coverage:
#   bv_compute_git_describe:
#     * exact annotated tag → the tag verbatim
#     * N commits past the tag → tag-N-g<sha>
#     * only a LIGHTWEIGHT tag matches → falls back to bare sha (annotated-only)
#     * landing glob picks the landing tag, grav glob picks the grav tag
#     * dirty tree → -dirty suffix
#   bv_compute_semver:
#     * clean → <version>+<build>.g<sha>
#     * dirty → trailing .dirty
#     * is_dirty defaulting to false when omitted

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/build-id.sh
. "$PROJECT_ROOT/deploy/lib/build-id.sh"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}
eq()    { [ "$2" = "$3" ] && check "$1" ok || check "$1 (want '$2', got '$3')" fail; }
match() { [[ "$3" =~ $2 ]] && check "$1" ok || check "$1 (got '$3', want ~ $2)" fail; }

echo "Unit test: build-id.sh"
echo "---"

STUB_PREFIX="bv-unit-build-id."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
STUB_DIR="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

git_init() {
    git init -q "$1"
    git -C "$1" config user.email t@example.com
    git -C "$1" config user.name Test
    git -C "$1" config commit.gpgsign false
    git -C "$1" config tag.gpgsign false
}
commit() { echo "$2" >> "$1/f.txt"; git -C "$1" add -A; git -C "$1" commit -qm "$2"; }

# ── REPO_A: annotated v1.0.0 at HEAD ────────────────────────
A="$STUB_DIR/a"; git_init "$A"; commit "$A" one
git -C "$A" tag -a v1.0.0 -m "Release v1.0.0"
eq "git_describe: exact annotated tag → v1.0.0" \
    "v1.0.0" "$(bv_compute_git_describe "$A" 'v[0-9]*')"

# ── one commit past the tag ─────────────────────────────────
commit "$A" two
match "git_describe: 1 commit past tag → v1.0.0-1-g<sha>" \
    '^v1\.0\.0-1-g[0-9a-f]+$' "$(bv_compute_git_describe "$A" 'v[0-9]*')"

# ── dirty tree → -dirty suffix ──────────────────────────────
git -C "$A" tag -a v1.1.0 -m "Release v1.1.0"     # tag the current HEAD clean
echo "uncommitted" >> "$A/f.txt"
match "git_describe: dirty tree → -dirty suffix" \
    '^v1\.1\.0-dirty$' "$(bv_compute_git_describe "$A" 'v[0-9]*')"

# ── REPO_LW: only a LIGHTWEIGHT v-tag at HEAD ───────────────
LW="$STUB_DIR/lw"; git_init "$LW"; commit "$LW" one
git -C "$LW" tag v2.0.0                            # lightweight, not annotated
DESC_LW="$(bv_compute_git_describe "$LW" 'v[0-9]*')"
[ "$DESC_LW" != "v2.0.0" ] \
    && check "git_describe: ignores lightweight tag" ok \
    || check "git_describe: wrongly used lightweight tag" fail
match "git_describe: lightweight-only → bare sha fallback" \
    '^[0-9a-f]{4,}$' "$DESC_LW"

# ── REPO_LAND: annotated grav AND landing tags at HEAD ──────
L="$STUB_DIR/land"; git_init "$L"; commit "$L" one
git -C "$L" tag -a v1.0.0 -m "grav"
git -C "$L" tag -a landing-v0.2.0 -m "landing"
eq "git_describe: landing glob → landing-v0.2.0" \
    "landing-v0.2.0" "$(bv_compute_git_describe "$L" 'landing-v[0-9]*')"
eq "git_describe: grav glob → v1.0.0 (not the landing tag)" \
    "v1.0.0" "$(bv_compute_git_describe "$L" 'v[0-9]*')"

# ── bv_compute_semver ───────────────────────────────────────
eq "semver: clean → version+build.gsha" \
    "1.0.1+247.gda85dfb" "$(bv_compute_semver 1.0.1 247 da85dfb false)"
eq "semver: dirty → trailing .dirty" \
    "1.0.1+247.gda85dfb.dirty" "$(bv_compute_semver 1.0.1 247 da85dfb true)"
eq "semver: is_dirty defaults to false when omitted" \
    "0.2.0+12.gabcdef0" "$(bv_compute_semver 0.2.0 12 abcdef0)"

echo "---"
echo "build-id: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
