#!/usr/bin/env bash
#
# Unit test: bv_check_no_lfs_pointers must reject any staging dir that
# still contains git-lfs pointer files, and must accept a clean one.
#
# Background: on Jun 4 2026, two consecutive prod deploys shipped
# 131-byte LFS pointers verbatim because the worktree's checkout had
# not materialised LFS objects. The smoke probe passed both times
# (HTTP 200 on a 131-byte "JPEG"), so the regression was silent until
# the operator visually inspected the site. This guard fails BEFORE
# the SSH pre-flight, with an operator-readable recovery hint, so
# that failure mode is impossible to ship again.
#
# Cases covered:
#   A. happy path: a staging dir with one real binary + one normal
#      text file → returns 0, no stderr noise.
#   B. one pointer: returns 1, prints recovery hint, names the file.
#   C. multiple pointers: returns 1, every pointer is named.
#   D. pointer larger than the 200-byte scan window (impossible per
#      LFS spec but worth confirming the bound is intentional): not
#      detected — documented limitation.
#   E. missing/bad arg: rc=2 with FATAL diagnostic.
#
# All paths run against a mktemp dir; no repo state is touched.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/atomic-release.sh
. "$PROJECT_ROOT/deploy/lib/atomic-release.sh"

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

echo "Unit test: bv_check_no_lfs_pointers"
echo "---"

STAGE_PREFIX="bv-unit-lfs-guard."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STAGE_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
STAGE_DIR="$(mktemp -d -t "${STAGE_PREFIX}XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT

# ─────────────────────────────────────────────────────────────────────
# A. happy path — clean bundle
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "A. clean bundle"

CLEAN_DIR="$STAGE_DIR/clean"
mkdir -p "$CLEAN_DIR/user/pages"
# A real (small) "binary" — magic bytes don't matter; what matters is
# that grep treats it as non-text and skips it (or that it doesn't
# contain the magic string).
printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x01' > "$CLEAN_DIR/user/pages/photo.jpeg"
# A small text file that isn't an LFS pointer.
printf 'title: hello\n' > "$CLEAN_DIR/user/pages/page.md"
# A large text file just to make sure the size bound doesn't reject
# big legitimate text files. Built with a bash loop (not `yes | head`)
# because `yes` is killed by SIGPIPE when the consumer closes, which
# under pipefail flips the pipeline's exit to 141 and trips errexit.
printf 'this is fine\n%.0s' {1..200} > "$CLEAN_DIR/user/pages/big.md"

rc=0; err="$(bv_check_no_lfs_pointers "$CLEAN_DIR" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" = 0 ] && [ -z "$err" ]; then
    check "clean staging dir returns 0 with no stderr noise" ok
else
    check "clean staging dir returns 0 (got rc=$rc, stderr='$err')" fail
fi

# ─────────────────────────────────────────────────────────────────────
# B. single pointer — must reject + name the file
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "B. one LFS pointer"

ONE_DIR="$STAGE_DIR/one"
mkdir -p "$ONE_DIR/user/pages/krea"
cat > "$ONE_DIR/user/pages/krea/section-b-03.jpeg" <<'POINTER'
version https://git-lfs.github.com/spec/v1
oid sha256:165b0ff149a585abbc671ef5e04940801950deebaf24b4fd23b877d5c397a77a
size 248008
POINTER
# Plus a real file to confirm the helper distinguishes them.
printf 'title: ok\n' > "$ONE_DIR/user/pages/krea/page.md"

rc=0; err="$(bv_check_no_lfs_pointers "$ONE_DIR" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" = 1 ]; then
    check "one pointer → rc=1" ok
else
    check "one pointer → rc=1 (got rc=$rc)" fail
fi
case "$err" in
    *"git lfs checkout"*) check "stderr includes 'git lfs checkout' recovery hint" ok ;;
    *) check "stderr must include 'git lfs checkout' (got: $(printf %q "$err"))" fail ;;
esac
case "$err" in
    *"section-b-03.jpeg"*) check "stderr names the offending file" ok ;;
    *) check "stderr must name 'section-b-03.jpeg'" fail ;;
esac
case "$err" in
    *"page.md"*) check "stderr must NOT name unrelated files" fail ;;
    *) check "stderr does not name unrelated files" ok ;;
esac

# ─────────────────────────────────────────────────────────────────────
# C. multiple pointers — every one must be listed
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "C. multiple LFS pointers"

MULTI_DIR="$STAGE_DIR/multi"
mkdir -p "$MULTI_DIR/a" "$MULTI_DIR/b/nested"
for path in a/one.jpeg a/two.png b/three.svg b/nested/four.webp; do
    cat > "$MULTI_DIR/$path" <<'POINTER'
version https://git-lfs.github.com/spec/v1
oid sha256:deadbeef
size 1
POINTER
done

rc=0; err="$(bv_check_no_lfs_pointers "$MULTI_DIR" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" = 1 ]; then
    check "four pointers → rc=1" ok
else
    check "four pointers → rc=1 (got rc=$rc)" fail
fi
for name in one.jpeg two.png three.svg four.webp; do
    case "$err" in
        *"$name"*) check "stderr names '$name'" ok ;;
        *) check "stderr must name '$name'" fail ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────
# D. pointer larger than the 200-byte scan window — documented gap
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "D. oversized pointer (documented limitation)"

BIG_DIR="$STAGE_DIR/big"
mkdir -p "$BIG_DIR"
{
    printf 'version https://git-lfs.github.com/spec/v1\n'
    printf 'oid sha256:%.0sX' {1..300}
    printf '\nsize 1\n'
} > "$BIG_DIR/over.jpeg"
# Real LFS pointers max out around 200 bytes (sha256 hex = 64 chars +
# fixed framing). An "over.jpeg" of >200 bytes is not a real LFS shape;
# the check intentionally won't flag it. If the LFS spec ever extends
# the framing past 200 bytes this test starts failing — that's the
# signal to widen the find -size bound.
rc=0; err="$(bv_check_no_lfs_pointers "$BIG_DIR" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" = 0 ]; then
    check "oversized 'pointer' is not detected (intentional bound)" ok
else
    check "oversized 'pointer' triggered the check (LFS spec may have grown — review bv_check_no_lfs_pointers find -size bound)" fail
fi

# ─────────────────────────────────────────────────────────────────────
# E. failure paths: missing / non-existent argument
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "E. argument validation"

rc=0; err="$(bv_check_no_lfs_pointers 2>&1 >/dev/null)" || rc=$?
if [ "$rc" = 2 ]; then
    check "missing arg → rc=2" ok
else
    check "missing arg → rc=2 (got rc=$rc)" fail
fi
case "$err" in
    *"FATAL"*) check "missing arg stderr starts FATAL" ok ;;
    *) check "missing arg stderr must include FATAL (got: $(printf %q "$err"))" fail ;;
esac

rc=0; err="$(bv_check_no_lfs_pointers "$STAGE_DIR/does-not-exist" 2>&1 >/dev/null)" || rc=$?
if [ "$rc" = 2 ]; then
    check "non-existent dir arg → rc=2" ok
else
    check "non-existent dir arg → rc=2 (got rc=$rc)" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"

[ "$FAIL" -eq 0 ]
