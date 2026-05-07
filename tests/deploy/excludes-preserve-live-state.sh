#!/usr/bin/env bash
#
# Regression test for the April 2026 accounts wipe and the May 2026
# dev re-wipe. Verifies that the rsync flag set used by deploy/deploy.sh:
#
#   1. preserves live-state paths (user/accounts, user/data, security.yaml)
#      when the local staging dir doesn't ship them, and
#   2. refuses to proceed when --max-delete=25 would be exceeded.
#
# Runs locally with rsync — no ssh, no remote, no credentials. The test
# extracts the RSYNC_FLAGS=(...) array literal directly from deploy.sh
# so this stays a single source of truth: any drift in the deploy script
# automatically reflects here. If deploy.sh weakens the excludes, this
# test fails.
#
# Idempotent — runs in a fresh mktemp dir and cleans up on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SH="$REPO_ROOT/deploy/deploy.sh"

if [ ! -f "$DEPLOY_SH" ]; then
    echo "FATAL: deploy.sh not found at $DEPLOY_SH" >&2
    exit 1
fi

# Extract the RSYNC_FLAGS=( … ) literal block. Using awk to walk the
# range so adding lines inside the array (more excludes) doesn't break
# this. Pull it into the current shell via eval.
FLAGS_BLOCK="$(awk '
    /^RSYNC_FLAGS=\(/ { in_block=1 }
    in_block { print }
    in_block && /^\)/ { exit }
' "$DEPLOY_SH")"
if [ -z "$FLAGS_BLOCK" ]; then
    echo "FATAL: could not locate RSYNC_FLAGS=(...) in $DEPLOY_SH" >&2
    exit 1
fi
# shellcheck disable=SC2294
eval "$FLAGS_BLOCK"
if [ "${#RSYNC_FLAGS[@]}" -lt 5 ]; then
    echo "FATAL: RSYNC_FLAGS extracted but suspiciously short (${#RSYNC_FLAGS[@]} entries)" >&2
    exit 1
fi

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

# ── Test 1: live-state preservation ──────────────────────────────────
#
# Set up a fake "remote" with the four live-state paths populated, and
# a fake "package" that contains only the application code. After
# rsync, the live-state files must still exist on the remote.
echo ""
echo "Test 1: live-state preservation across deploy"
SRC="$WORK/pkg"
TGT="$WORK/remote"
mkdir -p "$SRC"
mkdir -p "$TGT/user/accounts" \
         "$TGT/user/data/flex/indexes" \
         "$TGT/user/data/scheduler/queue/pending" \
         "$TGT/user/config" \
         "$TGT/user/env/dev.hackersbychoice.dk/config"
echo 'username: bobo' > "$TGT/user/accounts/bobo.yaml"
echo 'username: admin' > "$TGT/user/accounts/admin.yaml"
echo 'data: flex' > "$TGT/user/data/flex/indexes/accounts.yaml"
echo 'job: queued' > "$TGT/user/data/scheduler/queue/pending/job-1.yaml"
echo 'salt: root-env-salt' > "$TGT/user/config/security.yaml"
echo 'salt: dev-env-salt' > "$TGT/user/env/dev.hackersbychoice.dk/config/security.yaml"
# The "package" carries application files only.
echo '<?php echo "ok";' > "$SRC/index.php"
mkdir -p "$SRC/user/pages/01.home"
echo 'title: Home' > "$SRC/user/pages/01.home/default.md"

if ! rsync "${RSYNC_FLAGS[@]}" "$SRC/" "$TGT/" >/dev/null 2>&1; then
    check "rsync should succeed under a normal deploy" fail
else
    check "rsync succeeds under a normal deploy" ok
fi

for f in \
    "$TGT/user/accounts/bobo.yaml" \
    "$TGT/user/accounts/admin.yaml" \
    "$TGT/user/data/flex/indexes/accounts.yaml" \
    "$TGT/user/data/scheduler/queue/pending/job-1.yaml" \
    "$TGT/user/config/security.yaml" \
    "$TGT/user/env/dev.hackersbychoice.dk/config/security.yaml"
do
    rel="${f#"$TGT"/}"
    if [ -f "$f" ]; then
        check "$rel preserved" ok
    else
        check "$rel preserved (file was deleted!)" fail
    fi
done

# Application files should have been deployed.
if [ -f "$TGT/index.php" ] && [ -f "$TGT/user/pages/01.home/default.md" ]; then
    check "application code uploaded normally" ok
else
    check "application code uploaded normally" fail
fi

# ── Test 2: --max-delete cap fires on a runaway ──────────────────────
#
# Create a fake remote with 50 stale files in a non-excluded path, and
# an empty source. The rsync should ABORT (non-zero exit) because
# --max-delete=25 is set in RSYNC_FLAGS. Without that cap a config
# accident could nuke an arbitrary number of files.
echo ""
echo "Test 2: --max-delete cap fires on a runaway"
SRC2="$WORK/pkg2"
TGT2="$WORK/remote2"
mkdir -p "$SRC2" "$TGT2/assets"
for i in $(seq 1 50); do
    echo "stale-$i" > "$TGT2/assets/stale-${i}.css"
done
echo '<?php echo "ok";' > "$SRC2/index.php"

set +e
rsync "${RSYNC_FLAGS[@]}" "$SRC2/" "$TGT2/" >/dev/null 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    check "rsync aborts (exit $RC) when --max-delete=25 would be exceeded" ok
else
    check "rsync should have aborted at the --max-delete cap" fail
fi
remaining=$(find "$TGT2/assets" -name 'stale-*.css' | wc -l | tr -d ' ')
# rsync deletes incrementally up to the cap, then bails. So we expect
# AT LEAST some files left (specifically: 50 - max_delete = at least 25).
if [ "$remaining" -ge 25 ]; then
    check "≥25 files remain after the abort (got $remaining)" ok
else
    check "≥25 files remain after the abort (got $remaining — too many deleted)" fail
fi

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"
[ "$FAIL" -eq 0 ]
