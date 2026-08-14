#!/usr/bin/env bash
# =============================================================================
# Probe for deploy/promote-to-staging.sh (local-mode orchestration).
#
# Exercises the promote-to-staging orchestrator end-to-end in LOCAL mode
# (PROMOTE_LOCAL_TIER_DIR set), with NO network, NO real tier, and NO
# Docker. To keep migrate.sh (Docker PHP) out of the picture, the fixture
# "prod" Grav root is stamped at the SAME data version as the repo's
# config/www/user/data-version.yaml — a no-bump scenario, so step 5
# short-circuits the migration entirely.
#
# Coverage (versioned-data-dir SERVING model — ADR-005):
#   Success path:
#     * promote BUILDS a COMPLETE v_<target> data dir (cp -a of the
#       current dir + overlay of the migrated snapshot) and repoints
#       stagingdata/current → v_<target> BEFORE the code deploy
#     * accounts/data/pages/uploads overlaid into v_<target>/user/...,
#       deny-listed cache/ excluded
#     * a pre-existing per-tier secret (v0/user/config/security.yaml) is
#       INHERITED into v_<target>/user/config/security.yaml via cp -a,
#       never overwritten by the overlay
#     * stale staging data does not leak into v_<target>'s accounts dir
#       (the per-subdir rsync --delete overlay wins over the cp -a copy)
#     * staging-blessed.yaml exists with all seven fields populated,
#       data_version == target, source_backup_id == the produced backup id
#     * exit 0
#   Failure paths:
#     * --from-backup <nonexistent-id> → non-zero, no blessing written,
#       and a pre-existing stale blessing is removed (not left as a
#       false positive)
#     * a relative / traversal PROMOTE_LOCAL_TIER_DIR is rejected
#
# Reuses the age-key + backup-fixture env-var setup from
# tests/deploy/backup-restore.bats setup().
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMOTE_SH="$REPO_ROOT/deploy/promote-to-staging.sh"
BACKUP_SH="$REPO_ROOT/deploy/backup.sh"

[ -x "$PROMOTE_SH" ] || { echo "FATAL: $PROMOTE_SH not found / not executable" >&2; exit 1; }
[ -x "$BACKUP_SH" ]  || { echo "FATAL: $BACKUP_SH not found / not executable"  >&2; exit 1; }

# Dependencies the local-mode path needs (no Docker, no ssh).
for bin in age age-keygen tar rsync shasum awk; do
    command -v "$bin" >/dev/null 2>&1 || { echo "FATAL: required binary '$bin' missing" >&2; exit 1; }
done

PASS_COUNT=0
FAIL_COUNT=0
report_pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
report_fail() { printf '  FAIL  %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# ─── Shared temp workspace ────────────────────────────────────────────
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bv-promote-test.XXXXXXXX")"
cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Target data version from the repo's code marker — the fixture matches
# it so no migration runs (Docker-free).
TARGET_DV="$(awk '
    /^[[:space:]]*#/ { next }
    /^data_version:[[:space:]]*/ {
        v=$0; sub(/^data_version:[[:space:]]*/,"",v); gsub(/^["'\'']|["'\'']$/,"",v);
        sub(/[[:space:]]+#.*$/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit
    }' "$REPO_ROOT/config/www/user/data-version.yaml")"
[ -n "$TARGET_DV" ] || { echo "FATAL: could not read target data_version from repo marker" >&2; exit 1; }
# Versioned-data-dir SERVING model: promote builds a COMPLETE v_<target>
# dir and repoints stagingdata/current at it. The vdir name is
# bv_version_to_dirname(TARGET_DV) — 0.1.0 → v_0_1_0. Computed inline here
# (same transform the lib uses) so the test has no extra source dependency.
EXPECT_VDIR="v_${TARGET_DV//./_}"

echo "→ promote-to-staging: local-mode orchestration probe (target data_version=$TARGET_DV, vdir=$EXPECT_VDIR)"

# ─── Build the "prod" fixture Grav root ───────────────────────────────
FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE/user/accounts" \
         "$FIXTURE/user/data/flex" \
         "$FIXTURE/user/pages/01.home" \
         "$FIXTURE/user/uploads/2026/04" \
         "$FIXTURE/user/cache"
echo 'username: alice' > "$FIXTURE/user/accounts/alice.yaml"
echo 'username: bob'   > "$FIXTURE/user/accounts/bob.yaml"
echo 'task: hello'     > "$FIXTURE/user/data/flex/tasks.yaml"
echo 'title: Home'     > "$FIXTURE/user/pages/01.home/default.md"
echo 'avatar-bytes'    > "$FIXTURE/user/uploads/2026/04/avatar.png"
echo 'noise'           > "$FIXTURE/user/cache/noise"   # deny-listed; must not ship
echo '0.1.0' > "$FIXTURE/VERSION"
echo '247'   > "$FIXTURE/BUILD"
# No-bump: stamp the fixture at the same data version as the code marker.
printf 'version: "%s"\n' "$TARGET_DV" > "$FIXTURE/user/data-version.yaml"

# ─── Throwaway age keypair + managed-store + isolation env ────────────
KEYDIR="$TMP/keys"; mkdir -p "$KEYDIR"
age-keygen -o "$KEYDIR/identity.txt" 2>"$KEYDIR/keygen.stderr"
PUBKEY="$(awk '/^# public key:/ {print $4; exit}' "$KEYDIR/identity.txt")"
[ -n "$PUBKEY" ] || { echo "FATAL: age-keygen produced no pubkey" >&2; cat "$KEYDIR/identity.txt" >&2; exit 1; }

RECIPIENTS="$TMP/recipients.txt"
printf '# test recipient\n%s\n' "$PUBKEY" > "$RECIPIENTS"

STORE="$TMP/store"; mkdir -p "$STORE"

# These env vars are consumed by backup.sh (invoked by step 2) and
# restore.sh (invoked by step 3) — both inherit our environment.
export BACKUP_RECIPIENTS_FILE="$RECIPIENTS"
export BACKUP_LOCAL_STORE_DIR="$STORE"
export BACKUP_FIXTURE_DIR="$FIXTURE"
export BACKUP_SOURCE_HOST="fixture.local"
export AGE_IDENTITY_FILE="$KEYDIR/identity.txt"
export BACKUP_FAKE_NOW_EPOCH="1777466040"   # 2026-04-29T12:34:00Z
export XDG_CONFIG_HOME="$TMP/xdg-config"; mkdir -p "$XDG_CONFIG_HOME"
export BV_KEEP_LOCAL_DIR="$TMP/keep-local"; mkdir -p "$BV_KEEP_LOCAL_DIR"
# Stop both scripts from sourcing the operator's real .env.deploy.
export BACKUP_ENV_FILE="$TMP/no-such-env-file"
export RESTORE_ENV_FILE="$TMP/no-such-env-file"
export PROMOTE_ENV_FILE="$TMP/no-such-env-file"

# ──────────────────────────────────────────────────────────────────────
# SUCCESS PATH
# ──────────────────────────────────────────────────────────────────────
echo "→ success path: clean local-mode promote"
TIER_DIR="$TMP/tier"; mkdir -p "$TIER_DIR"

# Pre-seed the CURRENT data-version dir (v0) with:
#   * a per-tier SECRET that cp -a must INHERIT into the new v_<target> dir
#   * STALE data that the per-subdir rsync --delete overlay must remove
#     from v_<target>/user/accounts (cp -a copies it in, the overlay
#     deletes it).
# v0 is the CURRENT_VDIR the promote reads from stagingdata/current.
mkdir -p "$TIER_DIR/stagingdata/v0/user/config" \
         "$TIER_DIR/stagingdata/v0/user/accounts"
echo 'salt: keep-me'  > "$TIER_DIR/stagingdata/v0/user/config/security.yaml"
echo 'username: stale' > "$TIER_DIR/stagingdata/v0/user/accounts/stale.yaml"
# Bootstrap the current pointer the promote reads (existing tiers have it).
ln -sfn v0 "$TIER_DIR/stagingdata/current"

OUT_LOG="$TMP/promote-success.out"
set +e
PROMOTE_LOCAL_TIER_DIR="$TIER_DIR" "$PROMOTE_SH" --yes >"$OUT_LOG" 2>&1
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
    report_pass "promote exits 0 on clean local-mode run"
else
    report_fail "promote exited $RC (expected 0)"
    echo "--- promote output (tail) ---" >&2
    tail -40 "$OUT_LOG" >&2
fi

# Capture the backup id the run produced (one archive in the store).
PRODUCED_ARCHIVE="$(ls "$STORE"/prod-*.tar.gz.age 2>/dev/null | head -n1 || true)"
PRODUCED_ID=""
[ -n "$PRODUCED_ARCHIVE" ] && PRODUCED_ID="$(basename "$PRODUCED_ARCHIVE")"

# accounts content landed in the versioned data dir.
ACCT_DST="$TIER_DIR/stagingdata/$EXPECT_VDIR/user/accounts"
if [ -f "$ACCT_DST/alice.yaml" ] && [ -f "$ACCT_DST/bob.yaml" ] \
    && diff -q "$FIXTURE/user/accounts/alice.yaml" "$ACCT_DST/alice.yaml" >/dev/null; then
    report_pass "accounts content present + byte-identical at stagingdata/$EXPECT_VDIR/user/accounts/"
else
    report_fail "accounts content missing or mismatched at $ACCT_DST"
fi

# Other state subdirs also populated (pages/data/uploads).
if [ -f "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/pages/01.home/default.md" ] \
    && [ -f "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/uploads/2026/04/avatar.png" ]; then
    report_pass "pages + uploads also populated in versioned data dir"
else
    report_fail "pages/uploads not populated in versioned data dir"
fi

# Deny-listed content did NOT ship (cache/ was pruned by backup.sh).
if [ ! -e "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/cache" ]; then
    report_pass "deny-listed user/cache did not ship to staging data dir"
else
    report_fail "deny-listed user/cache leaked into staging data dir"
fi

# data-version.yaml copied into the versioned dir at the target version.
DVDST="$TIER_DIR/stagingdata/$EXPECT_VDIR/user/data-version.yaml"
if [ -f "$DVDST" ] && grep -q "\"$TARGET_DV\"" "$DVDST"; then
    report_pass "versioned data dir's data-version.yaml == target ($TARGET_DV)"
else
    report_fail "versioned data dir's data-version.yaml missing or wrong"
fi

# A COMPLETE v_<target> dir was built (cp -a of the current dir, so it
# carries the inherited config/ tree alongside the overlaid state).
if [ -d "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/config" ]; then
    report_pass "complete v_<target> data dir built ($EXPECT_VDIR exists with user/config inherited)"
else
    report_fail "v_<target> data dir incomplete (no user/config in $EXPECT_VDIR)"
fi

# Per-tier secret is INHERITED into v_<target>/user/config/ via cp -a from
# the current (v0) dir — the overlay touches only accounts/data/pages/uploads,
# never user/config, so the secret survives in the NEW served dir.
SEC="$TIER_DIR/stagingdata/$EXPECT_VDIR/user/config/security.yaml"
if [ -f "$SEC" ] && grep -q 'keep-me' "$SEC"; then
    report_pass "per-tier secret inherited into $EXPECT_VDIR/user/config/security.yaml via cp -a"
else
    report_fail "per-tier secret was NOT inherited into $EXPECT_VDIR (cp -a / overlay clobbered it)"
fi

# stagingdata/current was repointed at v_<target> (so the next code deploy
# binds its release symlinks to this dir).
CUR_LINK="$(readlink "$TIER_DIR/stagingdata/current" 2>/dev/null || echo "")"
if [ "$CUR_LINK" = "$EXPECT_VDIR" ]; then
    report_pass "stagingdata/current → $EXPECT_VDIR (versioned dir activated before code deploy)"
else
    report_fail "stagingdata/current → '$CUR_LINK' (expected '$EXPECT_VDIR')"
fi

# Stale pre-existing account is GONE from v_<target>: cp -a copied it in,
# then the per-subdir rsync --delete overlay of accounts/ removed it.
if [ ! -e "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/accounts/stale.yaml" ]; then
    report_pass "stale account removed from $EXPECT_VDIR (overlay rsync --delete won over cp -a)"
else
    report_fail "stale account survived in $EXPECT_VDIR (overlay did not --delete it)"
fi

# Blessing marker exists with all seven fields populated.
BLESS="$TIER_DIR/staging-blessed.yaml"
if [ -f "$BLESS" ]; then
    report_pass "staging-blessed.yaml written at tier Grav root (outside user/, outside stagingdata/)"

    all_fields_ok=1
    for field in blessed_at code_commit code_version code_build data_version features_yaml_sha256 source_backup_id; do
        # Field present AND non-empty (value between the quotes).
        val="$(awk -F'"' -v k="$field" '$0 ~ "^"k": " {print $2; exit}' "$BLESS")"
        if [ -z "$val" ]; then
            report_fail "blessing field '$field' missing or empty"
            all_fields_ok=0
        fi
    done
    [ "$all_fields_ok" -eq 1 ] && report_pass "all seven blessing fields present and non-empty"

    # data_version field == target.
    bdv="$(awk -F'"' '$0 ~ /^data_version: / {print $2; exit}' "$BLESS")"
    if [ "$bdv" = "$TARGET_DV" ]; then
        report_pass "blessing data_version == target ($TARGET_DV)"
    else
        report_fail "blessing data_version='$bdv', expected '$TARGET_DV'"
    fi

    # source_backup_id == the archive the run produced.
    bsid="$(awk -F'"' '$0 ~ /^source_backup_id: / {print $2; exit}' "$BLESS")"
    if [ -n "$PRODUCED_ID" ] && [ "$bsid" = "$PRODUCED_ID" ]; then
        report_pass "blessing source_backup_id == produced backup id ($PRODUCED_ID)"
    else
        report_fail "blessing source_backup_id='$bsid', expected produced id '$PRODUCED_ID'"
    fi
else
    report_fail "staging-blessed.yaml not written on success"
fi

# Scratch removed on success (no leftover bv-promote dirs we created).
if printf '%s' "$(cat "$OUT_LOG")" | grep -q "scratch removed"; then
    report_pass "scratch dir removed on success"
else
    report_fail "scratch dir not reported removed on success"
fi

# ──────────────────────────────────────────────────────────────────────
# REGRESSION (CURRENT_VDIR == VDIR): a re-promote at the SAME data_version
# — the steady-state code-only release — must NOT destroy the per-tier
# secret. The success-path run above left stagingdata/current → $EXPECT_VDIR,
# so a second promote now resolves CURRENT_VDIR == VDIR. The pre-fix code did
# `rm -rf <VDIR>` (the LIVE dir) and, with no cp -a source left, rebuilt an
# empty skeleton — silently dropping user/config/security.yaml. The fix
# refreshes the dir IN PLACE. A fresh fake-clock epoch gives the second run
# its own backup archive (full pipeline, no --from-backup shortcut).
# ──────────────────────────────────────────────────────────────────────
echo "→ regression: re-promote at same data_version (CURRENT_VDIR == VDIR) preserves secrets"
# Stamp a distinct sentinel into the LIVE served dir's secret and plant a new
# stale account, so we prove run 2 preserved THIS dir's user/config and still
# ran the overlay --delete over accounts/.
echo 'salt: survive-round-2' > "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/config/security.yaml"
echo 'username: stale2'       > "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/accounts/stale2.yaml"

OUT_LOG2="$TMP/promote-success-2.out"
set +e
BACKUP_FAKE_NOW_EPOCH="1777466100" PROMOTE_LOCAL_TIER_DIR="$TIER_DIR" \
    "$PROMOTE_SH" --yes >"$OUT_LOG2" 2>&1
RC2=$?
set -e
if [ "$RC2" -eq 0 ]; then
    report_pass "second promote (same data_version) exits 0"
else
    report_fail "second promote exited $RC2 (expected 0)"
    tail -40 "$OUT_LOG2" >&2
fi
# The in-place refresh path was taken (no rm -rf of the live dir).
if grep -q "is already current — refreshing in place" "$OUT_LOG2"; then
    report_pass "second promote took the in-place refresh path (CURRENT_VDIR == VDIR)"
else
    report_fail "second promote did not report the in-place refresh path"
fi
# THE BUG CATCHER: the per-tier secret in the live served dir survived.
SEC2="$TIER_DIR/stagingdata/$EXPECT_VDIR/user/config/security.yaml"
if [ -f "$SEC2" ] && grep -q 'survive-round-2' "$SEC2"; then
    report_pass "per-tier secret preserved across a same-version re-promote"
else
    report_fail "per-tier secret DESTROYED by the same-version re-promote (regression)"
fi
# Data still refreshed: real accounts present, the planted stale account gone.
if [ -f "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/accounts/alice.yaml" ] \
    && [ ! -e "$TIER_DIR/stagingdata/$EXPECT_VDIR/user/accounts/stale2.yaml" ]; then
    report_pass "in-place overlay still refreshes state (alice present, planted stale removed)"
else
    report_fail "in-place overlay did not refresh accounts as expected"
fi
# current still points at the target dir.
CUR_LINK2="$(readlink "$TIER_DIR/stagingdata/current" 2>/dev/null || echo "")"
if [ "$CUR_LINK2" = "$EXPECT_VDIR" ]; then
    report_pass "stagingdata/current still → $EXPECT_VDIR after the re-promote"
else
    report_fail "stagingdata/current → '$CUR_LINK2' after re-promote (expected '$EXPECT_VDIR')"
fi

# ──────────────────────────────────────────────────────────────────────
# FAILURE PATH (a): --from-backup <nonexistent> → non-zero, no blessing,
# and a pre-existing stale blessing is removed (no false positive).
# ──────────────────────────────────────────────────────────────────────
echo "→ failure path (a): nonexistent --from-backup id; stale blessing must not survive"
TIER_FAIL="$TMP/tier-fail"; mkdir -p "$TIER_FAIL"
# Plant a STALE blessing that a failed run must remove at step 1.
cat > "$TIER_FAIL/staging-blessed.yaml" <<'EOF'
blessed_at: "1999-01-01T00:00:00Z"
code_commit: "deadbee"
code_version: "0.0.1"
code_build: "1"
data_version: "0.0.1"
features_yaml_sha256: "stale"
source_backup_id: "prod-1999-01-01T00-00Z-v0.0.1-b1.tar.gz.age"
EOF

OUT_FAIL="$TMP/promote-fail.out"
set +e
PROMOTE_LOCAL_TIER_DIR="$TIER_FAIL" \
    "$PROMOTE_SH" --from-backup "prod-1999-12-31T23-59Z-v9.9.9-b99999.tar.gz.age" --yes \
    >"$OUT_FAIL" 2>&1
RC_FAIL=$?
set -e

if [ "$RC_FAIL" -ne 0 ]; then
    report_pass "nonexistent --from-backup id → non-zero exit ($RC_FAIL)"
else
    report_fail "nonexistent --from-backup id unexpectedly exited 0"
fi

# The stale blessing must have been removed at step 1 and NOT re-written
# (the run failed at restore, well before step 9).
if [ ! -f "$TIER_FAIL/staging-blessed.yaml" ]; then
    report_pass "stale blessing removed and not re-written on failed promote"
else
    # If it still exists, it must at least not be the freshly-written one —
    # but per spec it should be gone. Treat presence as a failure.
    report_fail "stale blessing survived a failed promote (false-positive risk)"
fi

# No served data dir should have been written by the aborted run (it fails at
# restore, well before the step-7 data refresh).
if [ ! -d "$TIER_FAIL/stagingdata/$EXPECT_VDIR" ]; then
    report_pass "no served data dir written by the aborted run"
else
    report_fail "aborted run wrote to the served data dir"
fi

# ──────────────────────────────────────────────────────────────────────
# FAILURE PATH (b): invalid PROMOTE_LOCAL_TIER_DIR (relative + traversal).
# ──────────────────────────────────────────────────────────────────────
echo "→ failure path (b): invalid PROMOTE_LOCAL_TIER_DIR is rejected"
set +e
PROMOTE_LOCAL_TIER_DIR="relative/path" "$PROMOTE_SH" --yes >"$TMP/rel.out" 2>&1
RC_REL=$?
set -e
if [ "$RC_REL" -ne 0 ] && grep -q "absolute path" "$TMP/rel.out"; then
    report_pass "relative PROMOTE_LOCAL_TIER_DIR rejected with 'absolute path' error"
else
    report_fail "relative PROMOTE_LOCAL_TIER_DIR not rejected as expected (rc=$RC_REL)"
fi

set +e
PROMOTE_LOCAL_TIER_DIR="/tmp/../etc/promote-trav" "$PROMOTE_SH" --yes >"$TMP/trav.out" 2>&1
RC_TRAV=$?
set -e
if [ "$RC_TRAV" -ne 0 ] && grep -q "\.\." "$TMP/trav.out"; then
    report_pass "traversal PROMOTE_LOCAL_TIER_DIR rejected"
else
    report_fail "traversal PROMOTE_LOCAL_TIER_DIR not rejected as expected (rc=$RC_TRAV)"
fi

# ──────────────────────────────────────────────────────────────────────
# SUCCESS PATH: --from-backup <existing id> reuses the named archive and
# SKIPS the fresh prod backup. The clean success run at the top of this
# file already produced exactly one archive ($PRODUCED_ID) in $STORE; we
# now promote a FRESH tier --from-backup that id and assert:
#   * exit 0
#   * step 2 reports "using existing backup id (--from-backup)" and NOT
#     "taking a fresh prod backup" (the fresh-backup branch is skipped)
#   * NO new archive was created in the store (file count unchanged)
#   * the blessing's source_backup_id == the reused id
# (Previously only the bad-id failure was covered.)
# ──────────────────────────────────────────────────────────────────────
echo "→ success path: --from-backup <existing id> reuses the archive (no fresh backup)"
if [ -z "$PRODUCED_ID" ]; then
    report_fail "--from-backup success: no produced archive id from the earlier success run to reuse"
else
    STORE_COUNT_BEFORE="$(ls "$STORE"/*.tar.gz.age 2>/dev/null | wc -l | tr -d ' ')"
    TIER_FB="$TMP/tier-frombackup"; mkdir -p "$TIER_FB"
    # Seed a CURRENT (v0) dir so the build step has a cp -a source (parity
    # with the main success path's tier layout).
    mkdir -p "$TIER_FB/stagingdata/v0/user/config"
    echo 'salt: keep-me' > "$TIER_FB/stagingdata/v0/user/config/security.yaml"
    ln -sfn v0 "$TIER_FB/stagingdata/current"

    OUT_FB="$TMP/promote-frombackup.out"
    set +e
    PROMOTE_LOCAL_TIER_DIR="$TIER_FB" \
        "$PROMOTE_SH" --from-backup "$PRODUCED_ID" --yes >"$OUT_FB" 2>&1
    RC_FB=$?
    set -e

    if [ "$RC_FB" -eq 0 ]; then
        report_pass "--from-backup success: promote exits 0 reusing $PRODUCED_ID"
    else
        report_fail "--from-backup success: exited $RC_FB (expected 0)"
        tail -30 "$OUT_FB" >&2
    fi

    if grep -q "using existing backup id (--from-backup)" "$OUT_FB" \
        && ! grep -q "taking a fresh prod backup" "$OUT_FB"; then
        report_pass "--from-backup success: skipped the fresh backup (used the existing archive)"
    else
        report_fail "--from-backup success: did not take the existing-archive branch at step 2"
        tail -20 "$OUT_FB" >&2
    fi

    STORE_COUNT_AFTER="$(ls "$STORE"/*.tar.gz.age 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$STORE_COUNT_AFTER" = "$STORE_COUNT_BEFORE" ]; then
        report_pass "--from-backup success: no new archive created (count stayed $STORE_COUNT_BEFORE)"
    else
        report_fail "--from-backup success: archive count changed ($STORE_COUNT_BEFORE → $STORE_COUNT_AFTER); a fresh backup was taken"
    fi

    BLESS_FB="$TIER_FB/staging-blessed.yaml"
    bsid_fb="$(awk -F'"' '$0 ~ /^source_backup_id: / {print $2; exit}' "$BLESS_FB" 2>/dev/null || true)"
    if [ "$bsid_fb" = "$PRODUCED_ID" ]; then
        report_pass "--from-backup success: blessing source_backup_id == reused id ($PRODUCED_ID)"
    else
        report_fail "--from-backup success: blessing source_backup_id='$bsid_fb', expected '$PRODUCED_ID'"
    fi
fi

# ──────────────────────────────────────────────────────────────────────
# MIGRATION BUMP (success + missing-migration abort).
#
# The TARGET data version is read by promote-to-staging.sh from its OWN
# PROJECT_DIR's config/www/user/data-version.yaml (no env override exists),
# and the real repo's marker is 0.1.0 — the floor — so a same-repo run can
# never exercise a forward migration. To drive a real bump we run a
# WORK_REPO copy of deploy/ (+ a copy of the real migrations/ so the PHP
# bootstrap + vendor resolve) whose code marker we stamp at the target.
# This is the same self-contained-checkout trick promote-to-prod's test
# uses; it is test-only and touches no product code.
#
# The migration itself is provided as a synthetic <semver>_<slug>.php under
# a throwaway BV_MIGRATIONS_DIR — the canonical fixture mechanism from
# migrations/run-tests.sh. migrate.sh resolves PHP via system `php`, else
# the Docker php:8.3-cli fallback, so this needs one of those.
# ──────────────────────────────────────────────────────────────────────
echo "→ migration bump (success + missing-migration abort)"

# migrate.sh needs a PHP toolchain (system php or Docker). Without either,
# fail loudly rather than silently skipping (CLAUDE.md: no silent skips).
if command -v php >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
    MIG_TARGET_DV="0.2.0"
    MIG_VDIR="v_${MIG_TARGET_DV//./_}"

    # Self-contained WORK_REPO: deploy/ + migrations/ copied verbatim, a
    # code marker stamped at MIG_TARGET_DV, plus the staging env/features
    # + VERSION that step 9's blessing write reads. Git-init it so the
    # blessing's code_commit/code_build (git rev-parse / rev-list) resolve.
    WR="$TMP/wr-staging-mig"
    mkdir -p "$WR/deploy/lib" \
             "$WR/config/www/user" \
             "$WR/config/www/user/env/staging.hackersbychoice.dk/config"
    cp "$REPO_ROOT/deploy/promote-to-staging.sh" "$WR/deploy/"
    cp "$REPO_ROOT/deploy/backup.sh"             "$WR/deploy/"
    cp "$REPO_ROOT/deploy/restore.sh"            "$WR/deploy/"
    cp "$REPO_ROOT/deploy/migrate.sh"            "$WR/deploy/"
    cp "$REPO_ROOT/deploy/backup-paths.txt"      "$WR/deploy/"
    cp -R "$REPO_ROOT/deploy/lib/." "$WR/deploy/lib/"
    cp -R "$REPO_ROOT/migrations" "$WR/migrations"
    chmod +x "$WR/deploy/"*.sh
    printf 'data_version: "%s"\n' "$MIG_TARGET_DV" > "$WR/config/www/user/data-version.yaml"
    echo '0.1.0' > "$WR/config/www/VERSION"
    printf 'features:\n  staging_flag: "true"\n' \
        > "$WR/config/www/user/env/staging.hackersbychoice.dk/config/features.yaml"
    (
        cd "$WR"
        git init -q
        git config user.email "test@example.com"
        git config user.name "Test Harness"
        git add -A
        git commit -q -m "wr-staging-mig initial"
    ) || { echo "FATAL: could not init WORK_REPO for staging migration test" >&2; exit 1; }
    PROMOTE_WR="$WR/deploy/promote-to-staging.sh"

    # Backup fixture stamped BELOW the target so step 4 sees SOURCE=0.1.0,
    # TARGET=0.2.0 → a forward migration is required. backup.sh reads the
    # source data_version from $BACKUP_FIXTURE_DIR/user/data-version.yaml.
    MIG_FIXTURE="$TMP/mig-fixture"
    mkdir -p "$MIG_FIXTURE/user/accounts" "$MIG_FIXTURE/user/data/flex"
    echo 'username: alice' > "$MIG_FIXTURE/user/accounts/alice.yaml"
    echo 'task: hello'     > "$MIG_FIXTURE/user/data/flex/tasks.yaml"
    echo '0.1.0' > "$MIG_FIXTURE/VERSION"
    echo '247'   > "$MIG_FIXTURE/BUILD"
    printf 'version: "0.1.0"\n' > "$MIG_FIXTURE/user/data-version.yaml"

    # ── SUCCESS: synthetic migrations dir holds a real 0.2.0 migration. ──
    MIG_DIR_OK="$TMP/migdir-ok"; mkdir -p "$MIG_DIR_OK"
    cat > "$MIG_DIR_OK/0.2.0_wi6_staging_bump.php" <<'PHP'
<?php
// WI-6 fixture migration: advance 0.1.0 → 0.2.0 and stamp a sentinel so
// the test can prove the migration actually RAN (vs being skipped).
return function (string $dataDir): void {
    file_put_contents(
        $dataDir . '/user/data-version.yaml',
        "data_version: \"0.2.0\"\nwi6_staging_migration_ran: \"yes\"\n"
    );
};
PHP

    TIER_MIG="$TMP/tier-mig"; mkdir -p "$TIER_MIG"
    mkdir -p "$TIER_MIG/stagingdata/v0/user/config"
    echo 'salt: keep-me' > "$TIER_MIG/stagingdata/v0/user/config/security.yaml"
    ln -sfn v0 "$TIER_MIG/stagingdata/current"

    OUT_MIG="$TMP/promote-mig.out"
    set +e
    BACKUP_FIXTURE_DIR="$MIG_FIXTURE" \
    BV_MIGRATIONS_DIR="$MIG_DIR_OK" \
    BACKUP_FAKE_NOW_EPOCH="1777466200" \
    PROMOTE_LOCAL_TIER_DIR="$TIER_MIG" \
        "$PROMOTE_WR" --yes >"$OUT_MIG" 2>&1
    RC_MIG=$?
    set -e

    if [ "$RC_MIG" -eq 0 ]; then
        report_pass "migration bump: promote exits 0 (0.1.0 → $MIG_TARGET_DV)"
    else
        report_fail "migration bump: exited $RC_MIG (expected 0)"
        tail -40 "$OUT_MIG" >&2
    fi
    # Prove a migration was actually APPLIED (not the same-version skip).
    if grep -q "migration required: 0.1.0 → $MIG_TARGET_DV" "$OUT_MIG" \
        && grep -q "applying 0.2.0_wi6_staging_bump.php" "$OUT_MIG"; then
        report_pass "migration bump: a migration was applied (not short-circuited)"
    else
        report_fail "migration bump: migration was NOT applied (still on the skip branch?)"
        tail -25 "$OUT_MIG" >&2
    fi
    # Served data dir lands at the TARGET version, carrying the sentinel the
    # migration wrote — proof the migrated snapshot reached the tier.
    DV_MIG="$TIER_MIG/stagingdata/$MIG_VDIR/user/data-version.yaml"
    if [ -f "$DV_MIG" ] && grep -q '"0.2.0"' "$DV_MIG" && grep -q 'wi6_staging_migration_ran' "$DV_MIG"; then
        report_pass "migration bump: served data dir at $MIG_VDIR is at $MIG_TARGET_DV with the migration's sentinel"
    else
        report_fail "migration bump: served data-version.yaml missing/wrong at $MIG_VDIR"
        [ -f "$DV_MIG" ] && cat "$DV_MIG" >&2
    fi
    # current repointed at the migrated target dir + blessing stamps target.
    CUR_MIG="$(readlink "$TIER_MIG/stagingdata/current" 2>/dev/null || echo "")"
    bdv_mig="$(awk -F'"' '$0 ~ /^data_version: / {print $2; exit}' "$TIER_MIG/staging-blessed.yaml" 2>/dev/null || true)"
    if [ "$CUR_MIG" = "$MIG_VDIR" ] && [ "$bdv_mig" = "$MIG_TARGET_DV" ]; then
        report_pass "migration bump: current → $MIG_VDIR and blessing data_version == $MIG_TARGET_DV"
    else
        report_fail "migration bump: current='$CUR_MIG' (want $MIG_VDIR), blessing data_version='$bdv_mig' (want $MIG_TARGET_DV)"
    fi

    # ── FAILURE: required migration missing → abort BEFORE any tier push. ──
    # Empty synthetic migrations dir: nothing satisfies --to 0.2.0, so
    # migrate.sh refuses ("no migration to 0.2.0 found", exit 5) and
    # promote aborts at step 5 — BEFORE the step-6 build+activate and the
    # step-9 blessing. We assert: non-zero, the migrate.sh diagnostic, AND
    # that NONE of the tier-push artifacts exist (no served $MIG_VDIR dir,
    # current NOT repointed, no blessing). Removing the step-5 abort guard
    # (the `fail_with_scratch` on migrate.sh failure) would let the run
    # proceed to build $MIG_VDIR and write the blessing — flipping these
    # absence assertions to failures.
    MIG_DIR_MISSING="$TMP/migdir-missing"; mkdir -p "$MIG_DIR_MISSING"  # deliberately empty

    TIER_MIGF="$TMP/tier-mig-fail"; mkdir -p "$TIER_MIGF"
    mkdir -p "$TIER_MIGF/stagingdata/v0/user/config"
    echo 'salt: keep-me' > "$TIER_MIGF/stagingdata/v0/user/config/security.yaml"
    ln -sfn v0 "$TIER_MIGF/stagingdata/current"

    OUT_MIGF="$TMP/promote-mig-fail.out"
    set +e
    BACKUP_FIXTURE_DIR="$MIG_FIXTURE" \
    BV_MIGRATIONS_DIR="$MIG_DIR_MISSING" \
    BACKUP_FAKE_NOW_EPOCH="1777466260" \
    PROMOTE_LOCAL_TIER_DIR="$TIER_MIGF" \
        "$PROMOTE_WR" --yes >"$OUT_MIGF" 2>&1
    RC_MIGF=$?
    set -e

    if [ "$RC_MIGF" -ne 0 ]; then
        report_pass "missing-migration: promote exits non-zero ($RC_MIGF)"
    else
        report_fail "missing-migration: promote unexpectedly exited 0"
        tail -30 "$OUT_MIGF" >&2
    fi
    if grep -q "no migration to $MIG_TARGET_DV found" "$OUT_MIGF"; then
        report_pass "missing-migration: migrate.sh 'no migration found' diagnostic present"
    else
        report_fail "missing-migration: expected migrate.sh 'no migration found' diagnostic, not seen"
        tail -25 "$OUT_MIGF" >&2
    fi
    # ABORT-BEFORE-PUSH proof: none of the tier-push/activate artifacts exist.
    if [ ! -d "$TIER_MIGF/stagingdata/$MIG_VDIR" ]; then
        report_pass "missing-migration: aborted BEFORE build — no served $MIG_VDIR dir"
    else
        report_fail "missing-migration: served $MIG_VDIR dir was built despite the abort"
    fi
    CUR_MIGF="$(readlink "$TIER_MIGF/stagingdata/current" 2>/dev/null || echo "")"
    if [ "$CUR_MIGF" = "v0" ]; then
        report_pass "missing-migration: current NOT repointed (still → v0)"
    else
        report_fail "missing-migration: current was repointed to '$CUR_MIGF' despite the abort"
    fi
    if [ ! -f "$TIER_MIGF/staging-blessed.yaml" ]; then
        report_pass "missing-migration: no blessing written (abort before step 9)"
    else
        report_fail "missing-migration: blessing was written despite the abort"
    fi
else
    echo "FATAL: migration-bump cases require a PHP toolchain (system php or Docker) and neither is present" >&2
    report_fail "migration-bump cases could not run — no PHP toolchain (install php or Docker; do not silently skip)"
fi

# ─── Summary ──────────────────────────────────────────────────────────
echo ""
echo "promote-to-staging: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
