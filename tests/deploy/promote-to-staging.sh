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
# Coverage:
#   Success path:
#     * accounts content lands at stagingdata/<VDIR>/user/accounts/
#     * stagingdata/current resolves to <VDIR>
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
# Expected versioned-dir name: 0.1.0 → v_0_1_0.
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

# current symlink resolves to the versioned dir.
CUR="$TIER_DIR/stagingdata/current"
if [ -L "$CUR" ] && [ "$(readlink "$CUR")" = "$EXPECT_VDIR" ]; then
    report_pass "stagingdata/current → $EXPECT_VDIR (relative symlink)"
else
    report_fail "stagingdata/current does not resolve to $EXPECT_VDIR (got: $(readlink "$CUR" 2>/dev/null || echo '<none>'))"
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

# No versioned data dir should have been created by the aborted run.
if [ ! -d "$TIER_FAIL/stagingdata/$EXPECT_VDIR" ]; then
    report_pass "no versioned data dir created by the aborted run"
else
    report_fail "aborted run created a versioned data dir"
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

# ─── Summary ──────────────────────────────────────────────────────────
echo ""
echo "promote-to-staging: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
