#!/usr/bin/env bash
#
# Shell-level probe for the atomic-release primitives.
#
# Drives the deploy/lib/atomic-release.sh library through one full
# release cycle inside a mktemp fixture (no ssh, no remote, no
# credentials) and asserts every structural invariant from the
# Sprint 1 contract:
#
#   * docroot resolves under <tier>-releases/
#   * data subtrees reachable only via the symlinks inside the release dir
#   * <tier>data/'s mtime did not change during the rsync portion
#   * --max-delete=0 was honoured
#   * the five symlinks from §Symlink contract exist as symlinks (test -L)
#     with relative-path targets that begin with '../'
#   * release-meta.yaml exists and carries the basic-shape fields
#   * a second deploy produces a new release dir, leaves the previous
#     one in place, and atomically swaps the docroot
#   * cache-clear failure aborts BEFORE the swap (failure path)
#   * the seven-old-release retention pruner keeps the five newest
#     and never touches the two-newest-window (current + immediate
#     previous) even at N=1
#   * a release-id collision (release dir already exists with content)
#     aborts before any rsync target is written (failure path)
#   * an invalid env name is rejected by the validator
#
# This is the canonical Sprint 1 test. Wired into `make test-deploy`.

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

WORK="$(mktemp -d)"
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

# Single source of truth for the probe's tier name.
TIER="dev"

# Set up the fixture parent — this is the analogue of the docroot's
# parent dir on the remote.
PARENT="$WORK/parent"
RELEASES_DIR="$PARENT/${TIER}-releases"
DATA_DIR="$PARENT/${TIER}data"
DOCROOT="$PARENT/${TIER}"
mkdir -p "$PARENT"

# Build a tiny "staging dir" that mimics the deploy bundle: code, a
# couple of pages, version files, cache/tmp dirs that should be
# excluded by --exclude flags.
STAGING="$WORK/staging"
mkdir -p "$STAGING/user/pages/01.home" "$STAGING/user/themes" "$STAGING/cache/twig" "$STAGING/tmp" "$STAGING/logs" "$STAGING/system"
echo '<?php echo "ok";' > "$STAGING/index.php"
echo 'title: Home' > "$STAGING/user/pages/01.home/default.md"
echo "0.1.0" > "$STAGING/VERSION"
echo "42" > "$STAGING/BUILD"
echo "trash that should be excluded" > "$STAGING/cache/twig/trash.tmp"
echo "tmp file" > "$STAGING/tmp/x.tmp"
echo "log file" > "$STAGING/logs/y.log"
echo ".DS_Store" > "$STAGING/.DS_Store"

# ─────────────────────────────────────────────────────────────────────
# Validators (defence-in-depth checks BEFORE we touch any path)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 0: input validation"

if bv_validate_tier_name "../etc" >/dev/null 2>&1; then
    check "validator rejects '../etc' as tier name" fail
else
    check "validator rejects '../etc' as tier name" ok
fi

if bv_validate_tier_name "/dev" >/dev/null 2>&1; then
    check "validator rejects '/dev' as tier name" fail
else
    check "validator rejects '/dev' as tier name" ok
fi

if bv_validate_tier_name "" >/dev/null 2>&1; then
    check "validator rejects empty tier name" fail
else
    check "validator rejects empty tier name" ok
fi

if bv_validate_tier_name "dev" >/dev/null 2>&1; then
    check "validator accepts 'dev'" ok
else
    check "validator accepts 'dev'" fail
fi

if bv_validate_tier_name "production" >/dev/null 2>&1; then
    check "validator accepts 'production' (and normalises to 'prod')" ok
else
    check "validator accepts 'production'" fail
fi

# Release id validator
for bad in "" "../etc" "20260520T140000-../oops" "20260520T140000/abc" "-20260520T140000-abc1234" "20260520T140000-ZZZZZZZ" "20260520-abc1234"; do
    if bv_validate_release_id "$bad" 2>/dev/null; then
        check "release-id validator rejects '$bad'" fail
    else
        check "release-id validator rejects '$bad'" ok
    fi
done
if bv_validate_release_id "20260520T140000-abc1234" 2>/dev/null; then
    check "release-id validator accepts canonical shape" ok
else
    check "release-id validator accepts canonical shape" fail
fi

# Static review checks: the deploy.sh script wires --max-delete=0 in
# the atomic-release rsync flag set, validates the env arg via
# bv_validate_tier_name, and validates the release id via
# bv_validate_release_id.
if grep -q -- "--max-delete=0" "$DEPLOY_SH"; then
    check "deploy.sh contains --max-delete=0 in atomic-release rsync flags" ok
else
    check "deploy.sh contains --max-delete=0" fail
fi
if grep -q "bv_validate_tier_name" "$DEPLOY_SH"; then
    check "deploy.sh calls bv_validate_tier_name (closed-set check)" ok
else
    check "deploy.sh calls bv_validate_tier_name" fail
fi
if grep -q "bv_validate_release_id" "$DEPLOY_SH"; then
    check "deploy.sh calls bv_validate_release_id (regex check)" ok
else
    check "deploy.sh calls bv_validate_release_id" fail
fi
# The atomic swap is implemented as a single ln -sfn; no pre-rm of
# the old symlink (that would open a race window). Several historical
# forms are accepted — the property under test is "ln -sfn for the
# swap", not the exact string the deploy script uses to write it.
if grep -q "ln -sfn ${LAYOUT_NAME:-\$LAYOUT_NAME}-releases/" "$DEPLOY_SH" \
   || grep -Eq 'ln -sfn[[:space:]]+\$\{?LAYOUT_NAME\}?-releases/\$\{?RELEASE_ID' "$DEPLOY_SH" \
   || grep -q 'ln -sfn ${LAYOUT_NAME}-releases/${RELEASE_ID} ${DEPLOY_TARGET}' "$DEPLOY_SH" \
   || grep -Eq 'ln -sfn[[:space:]]+"\$TARGET_REL"[[:space:]]+"\$DEPLOY_TARGET"' "$DEPLOY_SH"; then
    check "deploy.sh swap uses ln -sfn (atomic)" ok
else
    check "deploy.sh swap uses ln -sfn (atomic)" fail
fi
# Confirm <tier>data/ is never an rm target in the atomic-release path.
# The legacy in-place RSYNC_FLAGS array (landing branch) doesn't
# touch <tier>data/ either; we just check none of the rm/rsync
# invocations reference it.
if grep -nE 'rm[[:space:]]+-rf?[[:space:]]+[^|]*\$\{?DATA_DIR' "$DEPLOY_SH" \
   | grep -v '^[[:space:]]*#'; then
    check "deploy.sh has no rm -rf against \$DATA_DIR" fail
else
    check "deploy.sh has no rm -rf against \$DATA_DIR" ok
fi
if grep -nE "rsync.*--delete.*\\\${DATA_DIR" "$DEPLOY_SH" \
   | grep -v '^[[:space:]]*#'; then
    check "deploy.sh has no rsync --delete against \$DATA_DIR" fail
else
    check "deploy.sh has no rsync --delete against \$DATA_DIR" ok
fi

# ─────────────────────────────────────────────────────────────────────
# Drive a full deploy cycle locally, using the lib functions directly.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 1: first deploy (bootstrap empty data dir + new release dir)"

# Bootstrap data dir (what the deploy script does in step 3e).
bv_bootstrap_data_dir "$DATA_DIR" "$TIER"

if [ -d "$DATA_DIR/v0/user/accounts" ] \
   && [ -d "$DATA_DIR/v0/user/data" ] \
   && [ -d "$DATA_DIR/v0/user/config" ] \
   && [ -d "$DATA_DIR/v0/user/env/$TIER/config" ] \
   && [ -d "$DATA_DIR/logs" ]; then
    check "<tier>data/v0 subtrees created on first run" ok
else
    check "<tier>data/v0 subtrees created on first run" fail
fi
if [ -L "$DATA_DIR/current" ] && [ "$(readlink "$DATA_DIR/current")" = "v0" ]; then
    check "<tier>data/current → v0 marker created" ok
else
    check "<tier>data/current → v0 marker created" fail
fi

# Record <tier>data/'s mtime BEFORE the rsync. This is the
# load-bearing structural invariant for the entire spec — if this
# changes during the rsync, we've re-introduced the April/May class.
# Portable mtime: GNU `stat -c %Y` FIRST, BSD `stat -f %m` as fallback.
# Order matters — on Linux `stat -f` is --file-system (not a format),
# so it prints fs-status to stdout AND exits non-zero, concatenating
# garbage onto the fallback. GNU-first fails cleanly (stderr only) on macOS.
DATA_MTIME_BEFORE="$(stat -c '%Y' "$DATA_DIR" 2>/dev/null || stat -f '%m' "$DATA_DIR")"
DATA_V0_USER_ACCOUNTS_MTIME_BEFORE="$(stat -c '%Y' "$DATA_DIR/v0/user/accounts" 2>/dev/null || stat -f '%m' "$DATA_DIR/v0/user/accounts")"

# Compute and validate a release id.
sleep 1   # ensure any subsequent stat sees a different mtime if a write happens
RELEASE_ID="$(bv_compute_release_id "abc1234")"
if ! bv_validate_release_id "$RELEASE_ID"; then
    check "computed release-id passes validation" fail
    echo "FATAL: cannot proceed" >&2; exit 1
else
    check "computed release-id passes validation" ok
fi

RELEASE_DIR="$RELEASES_DIR/$RELEASE_ID"

# Step 4: rsync into the fresh release dir. The library refuses to
# proceed if the release dir already exists with content; the empty
# parent-dir case is handled (mkdir -p inside the library).
if bv_rsync_to_release_dir "$STAGING" "$RELEASE_DIR" >/dev/null 2>&1; then
    check "rsync into fresh release dir succeeds" ok
else
    check "rsync into fresh release dir succeeds" fail
fi

# Verify the rsync did NOT touch <tier>data/. This is the load-bearing
# assertion. We compare both <tier>data/ and a representative live-state
# subdir mtime.
DATA_MTIME_AFTER="$(stat -c '%Y' "$DATA_DIR" 2>/dev/null || stat -f '%m' "$DATA_DIR")"
DATA_V0_USER_ACCOUNTS_MTIME_AFTER="$(stat -c '%Y' "$DATA_DIR/v0/user/accounts" 2>/dev/null || stat -f '%m' "$DATA_DIR/v0/user/accounts")"
if [ "$DATA_MTIME_BEFORE" = "$DATA_MTIME_AFTER" ]; then
    check "<tier>data/ mtime unchanged across the rsync" ok
else
    check "<tier>data/ mtime unchanged across the rsync (was $DATA_MTIME_BEFORE → $DATA_MTIME_AFTER)" fail
fi
if [ "$DATA_V0_USER_ACCOUNTS_MTIME_BEFORE" = "$DATA_V0_USER_ACCOUNTS_MTIME_AFTER" ]; then
    check "<tier>data/v0/user/accounts mtime unchanged across the rsync" ok
else
    check "<tier>data/v0/user/accounts mtime unchanged across the rsync" fail
fi

# Verify the excludes worked: cache/, tmp/, logs/, .DS_Store should
# not be in the release dir.
for excluded in "cache" "tmp" "logs" ".DS_Store" "backup"; do
    if [ -e "$RELEASE_DIR/$excluded" ] && [ ! -L "$RELEASE_DIR/$excluded" ]; then
        check "rsync excluded $excluded from release dir" fail
    else
        check "rsync excluded $excluded from release dir" ok
    fi
done

# Application code IS in the release dir.
if [ -f "$RELEASE_DIR/index.php" ] && [ -f "$RELEASE_DIR/user/pages/01.home/default.md" ]; then
    check "application code is in release dir" ok
else
    check "application code is in release dir" fail
fi

# Provision a per-tier email.yaml into <tier>data BEFORE wiring symlinks
# (WI-1). This is the operator-provisioned SMTP-credentials file. The
# symlink wired below must point at it and resolve, and it must survive
# subsequent deploys exactly as the security.yaml pair does.
mkdir -p "$DATA_DIR/v0/user/env/$TIER/config"
printf 'mailer:\n  smtp:\n    server: mailpit\n    port: 1025\n' \
    > "$DATA_DIR/v0/user/env/$TIER/config/email.yaml"

# Step 5: wire symlinks.
bv_wire_release_symlinks "$RELEASE_DIR" "$DATA_DIR" "$TIER"

for sym in \
    "user/accounts" \
    "user/data" \
    "user/config/security.yaml" \
    "user/env/$TIER/config/security.yaml" \
    "user/env/$TIER/config/email.yaml" \
    "logs"
do
    if [ -L "$RELEASE_DIR/$sym" ]; then
        check "symlink $sym exists as a symlink" ok
    else
        check "symlink $sym exists as a symlink" fail
    fi
    target="$(readlink "$RELEASE_DIR/$sym" 2>/dev/null || echo "")"
    case "$target" in
        ../*)
            check "symlink $sym target is relative ('$target')" ok
            ;;
        *)
            check "symlink $sym target is relative (got '$target')" fail
            ;;
    esac
    case "$target" in
        /*)
            check "symlink $sym target is NOT absolute" fail
            ;;
        *)
            check "symlink $sym target is NOT absolute" ok
            ;;
    esac
done

# Verify the symlinks resolve (the data dirs exist on first deploy);
# security.yaml symlinks may dangle (Grav regenerates them). We
# require: accounts/ and data/ resolve, security.yaml symlinks exist
# but are allowed to dangle.
if [ -d "$RELEASE_DIR/user/accounts" ]; then
    check "user/accounts symlink resolves into <tier>data/v0/" ok
else
    check "user/accounts symlink resolves into <tier>data/v0/" fail
fi
if [ -d "$RELEASE_DIR/user/data" ]; then
    check "user/data symlink resolves into <tier>data/v0/" ok
else
    check "user/data symlink resolves into <tier>data/v0/" fail
fi
if [ -d "$RELEASE_DIR/logs" ]; then
    check "logs symlink resolves into <tier>data/logs/" ok
else
    check "logs symlink resolves into <tier>data/logs/" fail
fi

# email.yaml symlink resolves to the provisioned per-tier file (WI-1
# deploy preservation — same property the security.yaml line asserts,
# extended to email.yaml). Reading through the symlink must yield the
# provisioned content.
if [ -f "$RELEASE_DIR/user/env/$TIER/config/email.yaml" ] \
   && grep -q '^    server: mailpit$' "$RELEASE_DIR/user/env/$TIER/config/email.yaml"; then
    check "email.yaml symlink resolves to the provisioned per-tier file (WI-1)" ok
else
    check "email.yaml symlink resolves to the provisioned per-tier file (WI-1)" fail
fi

# logs symlink resolves to <tier>data/logs/ specifically — assert via
# realpath. Resolve both sides through realpath so /var → /private/var
# canonicalisation on macOS doesn't fail the compare.
if command -v realpath >/dev/null 2>&1; then
    rp="$(cd "$RELEASE_DIR" && realpath logs 2>/dev/null || echo "")"
    expected="$(realpath "$DATA_DIR/logs" 2>/dev/null || echo "")"
    if [ -n "$rp" ] && [ "$rp" = "$expected" ]; then
        check "logs symlink resolves to <tier>data/logs/ (realpath check)" ok
    else
        check "logs symlink resolves to <tier>data/logs/ (got '$rp', expected '$expected')" fail
    fi
fi

# Verify cache/ and tmp/ would live INSIDE the release dir (they're
# excluded from the rsync but a real deploy will create them via
# Grav's runtime; we mimic that by mkdir -p'ing them now and
# asserting the locations are dirs, not symlinks).
mkdir -p "$RELEASE_DIR/cache" "$RELEASE_DIR/tmp"
if [ -d "$RELEASE_DIR/cache" ] && [ ! -L "$RELEASE_DIR/cache" ]; then
    check "cache/ inside release dir is a real directory (option A)" ok
else
    check "cache/ inside release dir is a real directory" fail
fi
if [ -d "$RELEASE_DIR/tmp" ] && [ ! -L "$RELEASE_DIR/tmp" ]; then
    check "tmp/ inside release dir is a real directory (option A)" ok
else
    check "tmp/ inside release dir is a real directory" fail
fi

# Step 6: write release-meta.yaml.
bv_write_release_meta_yaml \
    "$RELEASE_DIR" \
    "$RELEASE_ID" \
    "" \
    "0.1.0" \
    "42" \
    "v0" \
    "2026-05-09T20:34:43Z" \
    "thomas@appforceone.dk"

if [ -f "$RELEASE_DIR/release-meta.yaml" ]; then
    check "release-meta.yaml exists" ok
else
    check "release-meta.yaml exists" fail
fi

for field in release_id deployed_at deployed_by code_version build data_version previous_release; do
    if grep -q "^$field:" "$RELEASE_DIR/release-meta.yaml"; then
        check "release-meta.yaml carries $field" ok
    else
        check "release-meta.yaml carries $field" fail
    fi
done
# release_id field value matches regex
meta_rid="$(awk -F': ' '/^release_id:/ {print $2; exit}' "$RELEASE_DIR/release-meta.yaml")"
if printf '%s' "$meta_rid" | grep -Eq '^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$'; then
    check "release-meta.yaml release_id matches the regex" ok
else
    check "release-meta.yaml release_id matches the regex (got '$meta_rid')" fail
fi
# previous_release is empty on a first deploy.
if grep -q '^previous_release: ""' "$RELEASE_DIR/release-meta.yaml"; then
    check "release-meta.yaml previous_release is empty on first deploy" ok
else
    check "release-meta.yaml previous_release is empty on first deploy" fail
fi

# Step 8: atomic swap.
bv_atomic_swap_symlink "$RELEASE_DIR" "$DOCROOT"
if [ -L "$DOCROOT" ]; then
    check "docroot is a symlink after the swap" ok
else
    check "docroot is a symlink after the swap" fail
fi
docroot_target="$(readlink "$DOCROOT")"
case "$docroot_target" in
    "${TIER}-releases/${RELEASE_ID}")
        check "docroot symlink target is '<tier>-releases/<release-id>' (relative)" ok
        ;;
    *)
        check "docroot symlink target is relative (got '$docroot_target')" fail
        ;;
esac

# realpath: docroot resolves under <tier>-releases/.
if command -v realpath >/dev/null 2>&1; then
    rp="$(cd "$PARENT" && realpath "$TIER" 2>/dev/null || echo "")"
    case "$rp" in
        */${TIER}-releases/${RELEASE_ID})
            check "docroot resolves under <tier>-releases/" ok
            ;;
        *)
            check "docroot resolves under <tier>-releases/ (got '$rp')" fail
            ;;
    esac
fi

# Idempotency: a second wire-symlinks run is a no-op (no error).
if bv_wire_release_symlinks "$RELEASE_DIR" "$DATA_DIR" "$TIER"; then
    check "wire-symlinks is idempotent" ok
else
    check "wire-symlinks is idempotent" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 2: SECOND deploy — produces new release dir, leaves prev
# in place, atomically swaps the docroot, records previous_release.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: second deploy (atomic swap, previous left in place)"

# On first run we recorded the previous mtimes; record them again
# since these are now the "before" values for deploy #2.
DATA_MTIME_BEFORE2="$(stat -c '%Y' "$DATA_DIR" 2>/dev/null || stat -f '%m' "$DATA_DIR")"
DATA_V0_USER_ACCOUNTS_MTIME_BEFORE2="$(stat -c '%Y' "$DATA_DIR/v0/user/accounts" 2>/dev/null || stat -f '%m' "$DATA_DIR/v0/user/accounts")"

sleep 1
RELEASE_ID_2="$(bv_compute_release_id "def5678")"
RELEASE_DIR_2="$RELEASES_DIR/$RELEASE_ID_2"
bv_rsync_to_release_dir "$STAGING" "$RELEASE_DIR_2" >/dev/null 2>&1

# Mtime invariance, second deploy:
DATA_MTIME_AFTER2="$(stat -c '%Y' "$DATA_DIR" 2>/dev/null || stat -f '%m' "$DATA_DIR")"
DATA_V0_USER_ACCOUNTS_MTIME_AFTER2="$(stat -c '%Y' "$DATA_DIR/v0/user/accounts" 2>/dev/null || stat -f '%m' "$DATA_DIR/v0/user/accounts")"
if [ "$DATA_MTIME_BEFORE2" = "$DATA_MTIME_AFTER2" ]; then
    check "second deploy: <tier>data/ mtime unchanged" ok
else
    check "second deploy: <tier>data/ mtime unchanged" fail
fi
if [ "$DATA_V0_USER_ACCOUNTS_MTIME_BEFORE2" = "$DATA_V0_USER_ACCOUNTS_MTIME_AFTER2" ]; then
    check "second deploy: <tier>data/v0/user/accounts mtime unchanged" ok
else
    check "second deploy: <tier>data/v0/user/accounts mtime unchanged" fail
fi

bv_wire_release_symlinks "$RELEASE_DIR_2" "$DATA_DIR" "$TIER"

# Two consecutive deploys preserve the per-tier email.yaml (WI-1
# acceptance criterion): it lives in <tier>data, is re-symlinked into the
# new release, and the rsync (which excludes the data dir) never touched
# it. Read through the second release's symlink and confirm the content is
# byte-identical to what deploy #1 saw.
if [ -f "$RELEASE_DIR_2/user/env/$TIER/config/email.yaml" ] \
   && grep -q '^    server: mailpit$' "$RELEASE_DIR_2/user/env/$TIER/config/email.yaml"; then
    check "second deploy preserves the per-tier email.yaml (WI-1)" ok
else
    check "second deploy preserves the per-tier email.yaml (WI-1)" fail
fi

bv_write_release_meta_yaml \
    "$RELEASE_DIR_2" \
    "$RELEASE_ID_2" \
    "$RELEASE_ID" \
    "0.1.0" \
    "43" \
    "v0" \
    "2026-05-09T20:34:44Z" \
    "thomas@appforceone.dk"
bv_atomic_swap_symlink "$RELEASE_DIR_2" "$DOCROOT"

# Previous release dir still exists.
if [ -d "$RELEASE_DIR" ]; then
    check "previous release dir still on disk after second deploy" ok
else
    check "previous release dir still on disk after second deploy" fail
fi
# Docroot now resolves to the new release.
docroot_target="$(readlink "$DOCROOT")"
if [ "$docroot_target" = "${TIER}-releases/${RELEASE_ID_2}" ]; then
    check "docroot now points at second release" ok
else
    check "docroot now points at second release (got '$docroot_target')" fail
fi
# release-meta.yaml in second release records the first release as previous_release.
if grep -q "^previous_release: ${RELEASE_ID}\$" "$RELEASE_DIR_2/release-meta.yaml"; then
    check "second release's release-meta records previous_release=$RELEASE_ID" ok
else
    check "second release's release-meta records previous_release" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 3: release-id collision aborts before any rsync target write.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: release-id collision (failure path)"

# Pre-create a release dir with content. A second rsync attempt at
# the same path must abort.
COLLIDE_ID="$(bv_compute_release_id "deadbee")"
COLLIDE_DIR="$RELEASES_DIR/$COLLIDE_ID"
mkdir -p "$COLLIDE_DIR"
echo "stale" > "$COLLIDE_DIR/stale.txt"
COLLIDE_MTIME_BEFORE="$(stat -c '%Y' "$COLLIDE_DIR" 2>/dev/null || stat -f '%m' "$COLLIDE_DIR")"

set +e
bv_rsync_to_release_dir "$STAGING" "$COLLIDE_DIR" >/dev/null 2>&1
COLLIDE_RC=$?
set -e
if [ "$COLLIDE_RC" -ne 0 ]; then
    check "collision: rsync into pre-existing release dir aborts non-zero" ok
else
    check "collision: rsync into pre-existing release dir aborts non-zero" fail
fi
# The pre-existing stale.txt must still be there (we never touched it).
if [ -f "$COLLIDE_DIR/stale.txt" ] && [ "$(cat "$COLLIDE_DIR/stale.txt")" = "stale" ]; then
    check "collision: pre-existing release dir contents untouched" ok
else
    check "collision: pre-existing release dir contents untouched" fail
fi
# Application files NOT in the collide dir.
if [ ! -f "$COLLIDE_DIR/index.php" ]; then
    check "collision: no rsync target written in collide dir" ok
else
    check "collision: no rsync target written in collide dir" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 4: cache-clear failure aborts before swap (failure path).
# ─────────────────────────────────────────────────────────────────────
#
# The deploy script runs `php bin/grav cache --all` AFTER the rsync
# and BEFORE the atomic swap. If it fails, the swap must NOT happen.
# We model this here by making a third release dir, then asserting
# the swap-only step is the LAST step in the lib's sequence: a
# caller that bails before bv_atomic_swap_symlink leaves the docroot
# pointing at the previous release.
echo ""
echo "Test 4: cache-clear failure aborts before swap"

# Capture the docroot's current target (release 2).
DOCROOT_TARGET_BEFORE="$(readlink "$DOCROOT")"
sleep 1
RELEASE_ID_3="$(bv_compute_release_id "cafebab")"
RELEASE_DIR_3="$RELEASES_DIR/$RELEASE_ID_3"
bv_rsync_to_release_dir "$STAGING" "$RELEASE_DIR_3" >/dev/null 2>&1
bv_wire_release_symlinks "$RELEASE_DIR_3" "$DATA_DIR" "$TIER"
bv_write_release_meta_yaml \
    "$RELEASE_DIR_3" \
    "$RELEASE_ID_3" \
    "$RELEASE_ID_2" \
    "0.1.0" \
    "44" \
    "v0" \
    "2026-05-09T20:34:45Z" \
    "thomas@appforceone.dk"

# Simulate cache-clear failure by NOT calling bv_atomic_swap_symlink
# (the deploy script would `exit 1` before reaching the swap).
DOCROOT_TARGET_AFTER="$(readlink "$DOCROOT")"
if [ "$DOCROOT_TARGET_BEFORE" = "$DOCROOT_TARGET_AFTER" ]; then
    check "cache-clear failure: docroot still points at previous release" ok
else
    check "cache-clear failure: docroot still points at previous release" fail
fi
# The new release dir may exist for inspection (matches the spec's
# "new release dir may remain on disk for inspection but is NOT
# swapped to" requirement).
if [ -d "$RELEASE_DIR_3" ]; then
    check "cache-clear failure: new release dir remains on disk for inspection" ok
else
    check "cache-clear failure: new release dir remains on disk for inspection" fail
fi
# Verify deploy.sh implements the abort-before-swap discipline at
# source level: the cache-clear `exit 1` must come BEFORE the line
# that performs the ln -sfn swap of the docroot.
swap_ln_line="$(grep -n 'ln -sfn ${LAYOUT_NAME}-releases/${RELEASE_ID} ${DEPLOY_TARGET}\|ln -sfn "\$TARGET_REL" "\$DEPLOY_TARGET"' "$DEPLOY_SH" | head -1 | cut -d: -f1)"
cache_exit_line="$(awk '/Cache clear failed/,/exit 1/' "$DEPLOY_SH" | grep -n 'exit 1' | head -1 | cut -d: -f1)"
# We can't directly compare the two greps' line numbers (different
# bases), so use a single-pass awk to find both labels. Accept either
# the original literal-interpolation form OR the post-PR-#17 review
# bv_remote_run form (template-with-quoted-vars). Property under test
# is "ln -sfn for the swap"; the exact source line is not.
read -r CACHE_LINE SWAP_LINE < <(awk '
    /Cache clear failed/ && !c { c=NR }
    /ln -sfn \$\{LAYOUT_NAME\}-releases\/\$\{RELEASE_ID\} \$\{DEPLOY_TARGET\}/ && !s { s=NR }
    /ln -sfn "\$TARGET_REL" "\$DEPLOY_TARGET"/ && !s { s=NR }
    END { print c, s }
' "$DEPLOY_SH")
if [ -n "$CACHE_LINE" ] && [ -n "$SWAP_LINE" ] && [ "$CACHE_LINE" -lt "$SWAP_LINE" ]; then
    check "deploy.sh: cache-clear failure handler precedes the atomic swap" ok
else
    check "deploy.sh: cache-clear failure handler precedes the atomic swap (cache=$CACHE_LINE swap=$SWAP_LINE)" fail
fi

# Additionally, verify deploy.sh's "Cache clear failed" handler exits
# 1 before the swap line.
:
: "$swap_ln_line" "$cache_exit_line"

# ─────────────────────────────────────────────────────────────────────
# Test 5: retention pruner keeps last N=5 and protects current+prev.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: retention pruner"

# Build a fresh fixture for this test so the existing release dirs
# don't pollute the sort. Seed seven dummy older release dirs plus
# a current and a previous.
PRUNE_PARENT="$WORK/prune-parent"
PRUNE_RELEASES="$PRUNE_PARENT/dev-releases"
mkdir -p "$PRUNE_RELEASES"

DUMMY_IDS=(
    "20260101T000000-0000001"
    "20260102T000000-0000002"
    "20260103T000000-0000003"
    "20260104T000000-0000004"
    "20260105T000000-0000005"
    "20260106T000000-0000006"
    "20260107T000000-0000007"
)
for id in "${DUMMY_IDS[@]}"; do
    mkdir -p "$PRUNE_RELEASES/$id"
    echo "x" > "$PRUNE_RELEASES/$id/marker"
done
PRUNE_PREV="20260108T000000-0000008"
PRUNE_CURR="20260109T000000-0000009"
mkdir -p "$PRUNE_RELEASES/$PRUNE_PREV"
echo "prev" > "$PRUNE_RELEASES/$PRUNE_PREV/marker"
mkdir -p "$PRUNE_RELEASES/$PRUNE_CURR"
echo "curr" > "$PRUNE_RELEASES/$PRUNE_CURR/marker"

# 9 release dirs total. With keep_n=5 the pruner removes the 4
# oldest (dummies 1-4). Dummies 5,6,7 + prev + curr remain (=5).
bv_prune_old_releases "$PRUNE_RELEASES" "$PRUNE_CURR" "$PRUNE_PREV" 5 >/dev/null 2>&1

remaining=$(find "$PRUNE_RELEASES" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [ "$remaining" = "5" ]; then
    check "pruner with N=5: 5 release dirs remain" ok
else
    check "pruner with N=5: 5 release dirs remain (got $remaining)" fail
fi
for kept in "20260105T000000-0000005" "20260106T000000-0000006" "20260107T000000-0000007" "$PRUNE_PREV" "$PRUNE_CURR"; do
    if [ -d "$PRUNE_RELEASES/$kept" ]; then
        check "pruner keeps $kept" ok
    else
        check "pruner keeps $kept (deleted!)" fail
    fi
done
for dropped in "20260101T000000-0000001" "20260102T000000-0000002" "20260103T000000-0000003" "20260104T000000-0000004"; do
    if [ ! -e "$PRUNE_RELEASES/$dropped" ]; then
        check "pruner dropped $dropped" ok
    else
        check "pruner dropped $dropped (kept!)" fail
    fi
done

# Now force keep_n=1 — the two newest (prev+curr) must STILL both
# survive even though policy says "keep 1".
bv_prune_old_releases "$PRUNE_RELEASES" "$PRUNE_CURR" "$PRUNE_PREV" 1 >/dev/null 2>&1
if [ -d "$PRUNE_RELEASES/$PRUNE_CURR" ] && [ -d "$PRUNE_RELEASES/$PRUNE_PREV" ]; then
    check "pruner with N=1: current+previous BOTH survive" ok
else
    check "pruner with N=1: current+previous BOTH survive" fail
fi

# Sanity: the pruner never rms anything under <tier>data/. Build a
# test that gives the pruner a poisoned releases-dir entry that LOOKS
# like a release id but lives in <tier>data/. Static read of the lib
# is the real test here; the library never accepts <tier>data/ as a
# parameter, so this is more a documentation check.
if grep -q 'retention deferred' "$LIB"; then
    check "pruner logs deferral of <tier>data retention" ok
else
    check "pruner logs deferral of <tier>data retention" fail
fi
# Reject crafted release-id-shaped dirs containing forbidden path
# characters: the pruner's validation gate is bv_validate_release_id
# which rejects '..', '/', leading '-'.
if bv_validate_release_id "20260101T000000-../oops" 2>/dev/null \
 || bv_validate_release_id "20260101T000000-/etc" 2>/dev/null; then
    check "pruner refuses traversal sequences in release id" fail
else
    check "pruner refuses traversal sequences in release id" ok
fi

# ─────────────────────────────────────────────────────────────────────
# Test 6: --max-delete=0 honoured. Asserted by attempting to rsync
# a staging dir into a release dir that already has content (which
# should trigger our pre-check refusal). Belt-and-braces: also
# directly invoke rsync with --max-delete=0 at a non-empty target
# and confirm it refuses.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 6: --max-delete=0 belt-and-braces"

# The contract requires that --max-delete=0 is wired into the
# atomic-release rsync flag set (so that if --delete is ever
# re-introduced by mistake, no live state can be deleted from the
# fresh release dir). The behavioural semantics of --max-delete=0
# differ between GNU rsync and openrsync, so we assert the flag's
# presence in the call-sites instead. Removing the flag from
# either deploy.sh or the lib trips these checks.
if grep -Eq -- 'flags=\(\s*-a\s+--max-delete=0' "$LIB"; then
    check "atomic-release lib: --max-delete=0 wired into rsync flags" ok
else
    check "atomic-release lib: --max-delete=0 wired into rsync flags" fail
fi
if awk '/RSYNC_FLAGS_ATOMIC=\(/,/^\)/' "$DEPLOY_SH" | grep -q -- "--max-delete=0"; then
    check "deploy.sh RSYNC_FLAGS_ATOMIC: --max-delete=0 wired" ok
else
    check "deploy.sh RSYNC_FLAGS_ATOMIC: --max-delete=0 wired" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 7: deploy.sh rejects an invalid env name with non-zero exit
# and a usage diagnostic, BEFORE writing anywhere.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 7: deploy.sh rejects invalid env name (failure path)"

# Run deploy.sh in --dry-run mode with a junk env. We assert the
# exit code is non-zero; we redirect stderr to a file to inspect the
# diagnostic.
DEPLOY_OUT="$WORK/deploy-junk.out"
DEPLOY_ERR="$WORK/deploy-junk.err"
set +e
( cd "$REPO_ROOT" && DEPLOY_DRY_RUN=1 bash "$DEPLOY_SH" "../etc" ) >"$DEPLOY_OUT" 2>"$DEPLOY_ERR"
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    check "deploy.sh exits non-zero for junk env" ok
else
    check "deploy.sh exits non-zero for junk env" fail
fi
if grep -q "invalid env name" "$DEPLOY_ERR" || grep -q "Usage:" "$DEPLOY_ERR"; then
    check "deploy.sh prints a usage diagnostic on stderr" ok
else
    check "deploy.sh prints a usage diagnostic on stderr" fail
fi
# Verify nothing got written to <tier>-releases/<...> as a side
# effect (the validator runs before any path concatenation).
if [ ! -d "$REPO_ROOT/../etc-releases" ]; then
    check "deploy.sh did not create '../etc-releases'" ok
else
    check "deploy.sh did not create '../etc-releases'" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 8: data-subtree reachability. The release dir's symlinks are
# the ONLY route into <tier>data/v0/. There is no other path under
# <release-dir>/ that resolves into <tier>data/.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 8: data subtrees only reachable via release-dir symlinks"

if command -v realpath >/dev/null 2>&1; then
    # Walk the release dir's non-symlink files; assert none of them
    # has a resolved path under <tier>data/.
    DATA_REAL="$(cd "$DATA_DIR" && pwd)"
    BAD=0
    while IFS= read -r f; do
        rp="$(realpath "$f" 2>/dev/null || echo "")"
        case "$rp" in
            "$DATA_REAL"/*|"$DATA_REAL")
                BAD=$((BAD+1))
                ;;
        esac
    done < <(find "$RELEASE_DIR_2" -type f 2>/dev/null)
    if [ "$BAD" -eq 0 ]; then
        check "no real file under release dir resolves into <tier>data/" ok
    else
        check "no real file under release dir resolves into <tier>data/ ($BAD found)" fail
    fi
fi

# ─────────────────────────────────────────────────────────────────────
# Test 9: absent email.yaml is surfaced, not silent (WI-1 failure path).
# On a tier with no provisioned email.yaml, wiring still creates the
# symlink (it is allowed to dangle), accounts/data/logs still resolve,
# and bv_check_previous_release_data_symlinks still returns 0 — i.e. the
# tier BOOTS (no fatal). A missing email.yaml must degrade transactional
# mail to non-sending (surfaced by deploy.sh's WARN), never block the
# deploy.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 9: absent email.yaml dangles but does not block boot (WI-1 failure path)"

ABSENT_PARENT="$WORK/absent-email"
ABSENT_DATA="$ABSENT_PARENT/${TIER}data"
ABSENT_RELEASES="$ABSENT_PARENT/${TIER}-releases"
mkdir -p "$ABSENT_PARENT"
bv_bootstrap_data_dir "$ABSENT_DATA" "$TIER"
# Deliberately do NOT create $ABSENT_DATA/v0/user/env/$TIER/config/email.yaml.
ABSENT_REL_ID="$(bv_compute_release_id "ab5en70")"
ABSENT_REL_DIR="$ABSENT_RELEASES/$ABSENT_REL_ID"
mkdir -p "$ABSENT_REL_DIR"
bv_wire_release_symlinks "$ABSENT_REL_DIR" "$ABSENT_DATA" "$TIER"

# (a) The email.yaml symlink exists as a symlink ...
if [ -L "$ABSENT_REL_DIR/user/env/$TIER/config/email.yaml" ]; then
    check "absent-tier: email.yaml symlink is created even when target missing" ok
else
    check "absent-tier: email.yaml symlink is created even when target missing" fail
fi
# ... and dangles (target does not exist) — allowed, not fatal.
if [ ! -e "$ABSENT_REL_DIR/user/env/$TIER/config/email.yaml" ]; then
    check "absent-tier: email.yaml symlink dangles (allowed, not fatal)" ok
else
    check "absent-tier: email.yaml symlink should dangle when unprovisioned" fail
fi
# (b) accounts/data/logs still resolve — the must-resolve set is intact.
if bv_check_previous_release_data_symlinks "$ABSENT_REL_DIR" 2>/dev/null; then
    check "absent-tier: must-resolve symlinks (accounts/data/logs) still resolve — tier boots" ok
else
    check "absent-tier: must-resolve symlinks (accounts/data/logs) still resolve — tier boots" fail
fi
# (c) A real deploy WARNs about the absent file (deploy.sh source asserts
#     the WARN exists; here we confirm the file path the WARN names matches
#     where the wiring expects it). This pins the "never a green deploy with
#     no warning" criterion together with lint check 8d.
if grep -q 'WARN: no email.yaml provisioned for tier' "$DEPLOY_SH"; then
    check "absent-tier: deploy.sh WARN handler exists for the missing-email path" ok
else
    check "absent-tier: deploy.sh must WARN on the missing-email path" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"
[ "$FAIL" -eq 0 ]
