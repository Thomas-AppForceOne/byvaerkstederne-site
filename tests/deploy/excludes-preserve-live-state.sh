#!/usr/bin/env bash
#
# Regression test for the April 2026 accounts wipe and the May 2026
# dev re-wipe — adapted for the atomic-release layout.
#
# Pre-atomic, this test extracted the RSYNC_FLAGS=(…) array literal
# out of deploy/deploy.sh and verified the excludes preserved live-
# state paths under `--delete`. The history is preserved here (this
# file is the same path it has always been; the assertions are
# rewritten in-place).
#
# Under the atomic-release layout the property the test asserts is
# now STRUCTURAL rather than EXCLUDE-LIST-BASED:
#
#   * the rsync target is, by construction, a fresh empty release
#     dir under <tier>-releases/;
#   * <tier>data/ is a SIBLING of <tier>-releases/, NOT a child;
#   * therefore live state (user/accounts, user/data, security.yaml,
#     logs) is not in the rsync's path tree at all — no exclude is
#     load-bearing for safety, only for hygiene (don't ship local-dev
#     cache state).
#
# This test asserts the structural invariant by:
#
#   1. invoking bv_rsync_to_release_dir against a fixture that mimics
#      the on-disk layout. <tier>data/ is populated with live state
#      at the same depth as the spec lays out;
#   2. asserting <tier>data/'s mtime is unchanged across the rsync;
#   3. asserting every file under <tier>data/ is bit-identical pre/post;
#   4. asserting --max-delete=0 is honoured by the rsync invocation;
#   5. asserting no path under <tier>-releases/<id>/ resolves (via
#      realpath) into <tier>data/ — the release dir is structurally
#      isolated from the data dir BEFORE symlink wiring runs.
#
# The legacy test asserted item 1 indirectly (through excludes); the
# new test asserts the underlying property directly.
#
# Runs locally with rsync — no ssh, no remote, no credentials.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/deploy/lib/atomic-release.sh"
DEPLOY_SH="$REPO_ROOT/deploy/deploy.sh"

if [ ! -f "$LIB" ]; then
    echo "FATAL: atomic-release lib not found at $LIB" >&2
    exit 1
fi
if [ ! -f "$DEPLOY_SH" ]; then
    echo "FATAL: deploy.sh not found at $DEPLOY_SH" >&2
    exit 1
fi

# shellcheck source=deploy/lib/atomic-release.sh
. "$LIB"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then
        echo "  ✓ $name"
        PASS=$((PASS+1))
    else
        echo "  ✗ $name"
        FAIL=$((FAIL+1))
    fi
}

# ── Test 1: structural live-state isolation across an atomic deploy ──
echo ""
echo "Test 1: live-state isolation across atomic deploy (structural)"

PARENT="$WORK/parent"
TIER="dev"
DATA_DIR="$PARENT/${TIER}data"
RELEASES_DIR="$PARENT/${TIER}-releases"

mkdir -p "$DATA_DIR/v0/user/accounts" \
         "$DATA_DIR/v0/user/data/flex/indexes" \
         "$DATA_DIR/v0/user/data/scheduler/queue/pending" \
         "$DATA_DIR/v0/user/config" \
         "$DATA_DIR/v0/user/env/$TIER/config" \
         "$DATA_DIR/logs"
echo 'username: bobo'    > "$DATA_DIR/v0/user/accounts/bobo.yaml"
echo 'username: admin'   > "$DATA_DIR/v0/user/accounts/admin.yaml"
echo 'data: flex'        > "$DATA_DIR/v0/user/data/flex/indexes/accounts.yaml"
echo 'job: queued'       > "$DATA_DIR/v0/user/data/scheduler/queue/pending/job-1.yaml"
echo 'salt: root-salt'   > "$DATA_DIR/v0/user/config/security.yaml"
echo 'salt: env-salt'    > "$DATA_DIR/v0/user/env/$TIER/config/security.yaml"
echo 'app log line'      > "$DATA_DIR/logs/app.log"

# Snapshot the live-state files via cmp later.
LIVE_FILES=(
    "v0/user/accounts/bobo.yaml"
    "v0/user/accounts/admin.yaml"
    "v0/user/data/flex/indexes/accounts.yaml"
    "v0/user/data/scheduler/queue/pending/job-1.yaml"
    "v0/user/config/security.yaml"
    "v0/user/env/$TIER/config/security.yaml"
    "logs/app.log"
)
SNAPSHOT="$WORK/snapshot"
mkdir -p "$SNAPSHOT"
for f in "${LIVE_FILES[@]}"; do
    mkdir -p "$SNAPSHOT/$(dirname "$f")"
    cp -p "$DATA_DIR/$f" "$SNAPSHOT/$f"
done

# Portable mtime: GNU `stat -c %Y` FIRST, BSD `stat -f %m` as fallback.
# Order matters — on Linux `stat -f` is --file-system (not a format),
# so it prints fs-status to stdout AND exits non-zero, concatenating
# garbage onto the fallback. GNU-first fails cleanly (stderr only) on macOS.
DATA_MTIME_BEFORE="$(stat -c '%Y' "$DATA_DIR" 2>/dev/null || stat -f '%m' "$DATA_DIR")"

# Build the deploy package (mimics what deploy.sh assembles in
# $STAGING_DIR — application code only, no live state).
STAGING="$WORK/staging"
mkdir -p "$STAGING/user/pages/01.home" "$STAGING/user/themes/byvaerkstederne" "$STAGING/system" "$STAGING/cache" "$STAGING/tmp" "$STAGING/logs"
echo '<?php echo "ok";'      > "$STAGING/index.php"
echo 'title: Home'           > "$STAGING/user/pages/01.home/default.md"
echo 'theme contents'        > "$STAGING/user/themes/byvaerkstederne/theme.yaml"
echo 'system contents'       > "$STAGING/system/defines.php"
echo 'local cache trash'     > "$STAGING/cache/trash.tmp"
echo 'local tmp trash'       > "$STAGING/tmp/trash.tmp"
echo 'local log trash'       > "$STAGING/logs/trash.log"

# Sleep so any subsequent mtime change would be detectable.
sleep 1

RELEASE_ID="$(bv_compute_release_id "abc1234")"
RELEASE_DIR="$RELEASES_DIR/$RELEASE_ID"

if bv_rsync_to_release_dir "$STAGING" "$RELEASE_DIR" >/dev/null 2>&1; then
    check "atomic rsync into fresh release dir succeeds" ok
else
    check "atomic rsync into fresh release dir succeeds" fail
fi

DATA_MTIME_AFTER="$(stat -c '%Y' "$DATA_DIR" 2>/dev/null || stat -f '%m' "$DATA_DIR")"
if [ "$DATA_MTIME_BEFORE" = "$DATA_MTIME_AFTER" ]; then
    check "<tier>data/ mtime unchanged across rsync (structural invariant)" ok
else
    check "<tier>data/ mtime unchanged across rsync (was $DATA_MTIME_BEFORE → $DATA_MTIME_AFTER)" fail
fi

# Every live-state file must be bit-identical to its snapshot.
for f in "${LIVE_FILES[@]}"; do
    if cmp -s "$SNAPSHOT/$f" "$DATA_DIR/$f"; then
        check "$f preserved bit-identically" ok
    else
        check "$f preserved bit-identically" fail
    fi
done

# Application files must be in the release dir (the rsync's actual
# target), NOT in the data dir.
if [ -f "$RELEASE_DIR/index.php" ] && [ -f "$RELEASE_DIR/user/pages/01.home/default.md" ]; then
    check "application code uploaded to release dir" ok
else
    check "application code uploaded to release dir" fail
fi
# … and absent from the data dir.
if [ ! -e "$DATA_DIR/index.php" ] && [ ! -e "$DATA_DIR/v0/index.php" ]; then
    check "application code did NOT leak into <tier>data/" ok
else
    check "application code did NOT leak into <tier>data/" fail
fi

# Local-dev cache/tmp/logs trash from the staging dir was excluded.
for excluded in "cache" "tmp" "logs"; do
    if [ -e "$RELEASE_DIR/$excluded" ] && [ -d "$RELEASE_DIR/$excluded" ] && [ ! -L "$RELEASE_DIR/$excluded" ] && [ -n "$(ls -A "$RELEASE_DIR/$excluded" 2>/dev/null || true)" ]; then
        check "local-dev $excluded trash NOT shipped to release dir" fail
    else
        check "local-dev $excluded trash NOT shipped to release dir" ok
    fi
done

# Structural reachability: BEFORE symlink wiring, no path under the
# release dir resolves into <tier>data/. The release dir is
# physically a sibling of <tier>data/, so this should be trivially
# true — but we check it explicitly because that triviality IS the
# safety property the spec relies on.
if command -v realpath >/dev/null 2>&1; then
    DATA_REAL="$(cd "$DATA_DIR" && pwd)"
    BAD=0
    while IFS= read -r path; do
        rp="$(realpath "$path" 2>/dev/null || echo "")"
        case "$rp" in
            "$DATA_REAL"|"$DATA_REAL"/*)
                BAD=$((BAD+1))
                ;;
        esac
    done < <(find "$RELEASE_DIR" \( -type f -o -type d \) 2>/dev/null)
    if [ "$BAD" -eq 0 ]; then
        check "no path under release dir resolves into <tier>data/ (pre-wire structural)" ok
    else
        check "no path under release dir resolves into <tier>data/ ($BAD found)" fail
    fi
fi

# ── Test 2: --max-delete=0 is honoured by the atomic rsync flags ─────
echo ""
echo "Test 2: --max-delete=0 belt-and-braces"

# The atomic rsync flag set is part of bv_atomic_release_excludes +
# the literal `-a --max-delete=0` in bv_rsync_to_release_dir. Verify
# the literal is present in the lib (single source of truth).
if grep -Eq -- 'flags=\(\s*-a\s+--max-delete=0' "$LIB"; then
    check "atomic-release lib uses --max-delete=0 in rsync flags" ok
else
    check "atomic-release lib uses --max-delete=0 in rsync flags" fail
fi
# Also verify deploy.sh's atomic-release rsync flag set has it (the
# real path used against the remote).
if grep -Eq 'RSYNC_FLAGS_ATOMIC=\(' "$DEPLOY_SH" \
   && awk '/RSYNC_FLAGS_ATOMIC=\(/,/^\)/' "$DEPLOY_SH" | grep -q -- "--max-delete=0"; then
    check "deploy.sh's RSYNC_FLAGS_ATOMIC contains --max-delete=0" ok
else
    check "deploy.sh's RSYNC_FLAGS_ATOMIC contains --max-delete=0" fail
fi

# Behavioural smoke check is omitted: rsync's --max-delete=0
# semantics differ between GNU rsync (treats 0 as a hard "no
# deletes") and openrsync / older Apple rsync (treats 0 as
# "feature disabled"). The structural assertions above (the flag
# is present in both bv_rsync_to_release_dir and
# RSYNC_FLAGS_ATOMIC) are what the contract requires; weakening
# the deploy script by removing --max-delete=0 trips them.

# ── Test 3: deploy.sh's RSYNC_FLAGS_ATOMIC carries no live-state ─────
# ────────────  paths in any source/target/exclude form.    ──────────
echo ""
echo "Test 3: deploy.sh atomic flags don't reference live-state"

# Pull RSYNC_FLAGS_ATOMIC out of deploy.sh and assert no entry is a
# live-state path. (The legacy RSYNC_FLAGS array, used only by the
# landing branch, may still mention them as belt-and-braces; we
# assert separately that the atomic path doesn't.)
ATOMIC_BLOCK="$(awk '
    /^RSYNC_FLAGS_ATOMIC=\(/ { in_block=1 }
    in_block { print }
    in_block && /^\)/ { exit }
' "$DEPLOY_SH")"
if [ -z "$ATOMIC_BLOCK" ]; then
    check "RSYNC_FLAGS_ATOMIC=(...) located in deploy.sh" fail
else
    check "RSYNC_FLAGS_ATOMIC=(...) located in deploy.sh" ok
    if printf '%s\n' "$ATOMIC_BLOCK" | grep -Eq 'user/accounts|user/data|security\.yaml'; then
        check "RSYNC_FLAGS_ATOMIC has no live-state path entries" fail
    else
        check "RSYNC_FLAGS_ATOMIC has no live-state path entries" ok
    fi
fi

# Lastly, assert the atomic-release path NEVER passes <tier>data/ as
# an rsync source or destination. The deploy script's only references
# to DATA_DIR are mkdir-bootstraps and remote ssh into the data dir
# to (in step 3e) create the v0 subtree. We grep for any rsync line
# that mentions DATA_DIR — it should not exist.
if grep -nE 'rsync[^|]*\$\{?DATA_DIR' "$DEPLOY_SH" \
   | grep -v '^[[:space:]]*#' >/dev/null; then
    check "deploy.sh has no rsync against \$DATA_DIR" fail
else
    check "deploy.sh has no rsync against \$DATA_DIR" ok
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"
[ "$FAIL" -eq 0 ]
