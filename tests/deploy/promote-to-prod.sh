#!/usr/bin/env bash
# =============================================================================
# Probe for deploy/promote-to-prod.sh (local-mode orchestration).
#
# Exercises the PRODUCTION promote orchestrator in LOCAL mode
# (PROMOTE_PROD_LOCAL_TIER_DIR set), with NO network, NO real tier, NO
# SSH, and NO Docker. To keep migrate.sh (Docker PHP) out of the picture,
# the fixture "prod" Grav root is stamped at the SAME data version as the
# repo's config/www/user/data-version.yaml — a no-bump scenario, so step 5
# short-circuits the migration entirely (same trick as the staging test).
#
# Coverage:
#   Branch gate (run via a throwaway git repo holding a copy of deploy/,
#   so the script's PROJECT_DIR is a branch we control):
#     * on develop / main  → refuse, non-zero, release-branch message
#     * on release/v9.9.9   → proceeds PAST the branch check
#   Blessing gate (local mode, injected stand-ins):
#     * PASS: matching commit + data_version + staging-features sha +
#       prod-features-no-drift → proceeds past the gate
#     * FAIL: commit mismatch → "you're trying to promote" + non-zero
#     * FAIL: data_version mismatch → "data version mismatch" + non-zero
#     * FAIL: features sha mismatch → "features.yaml SHA mismatch" + non-zero
#     * FAIL: prod-flag drift → "drifted from git" + non-zero
#   Bypass --reason length validation:
#     * missing → refuse; <50 → refuse; >500 → refuse
#   Bypass-log append (local mode, --bypass with a valid reason, y on the
#   interactive prompt fed via /dev/tty stand-in):
#     * prod-bypass-log.yaml gains a `---`-separated entry with the reason
#   Build+activate success path (NO-BUMP):
#     * complete v_<target> built via cp -a inheriting a seeded secret
#     * overlay applied (accounts present, stale removed)
#     * proddata/current repointed at v_<target>
#     * flag-sync committed on the release branch (in the throwaway repo)
#     * promotion-log.jsonl appended
#
# Reuses the age-key + backup-fixture env-var setup from the staging probe.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMOTE_SH="$REPO_ROOT/deploy/promote-to-prod.sh"
BACKUP_SH="$REPO_ROOT/deploy/backup.sh"

[ -x "$PROMOTE_SH" ] || { echo "FATAL: $PROMOTE_SH not found / not executable" >&2; exit 1; }
[ -x "$BACKUP_SH" ]  || { echo "FATAL: $BACKUP_SH not found / not executable"  >&2; exit 1; }

for bin in age age-keygen tar rsync shasum awk git; do
    command -v "$bin" >/dev/null 2>&1 || { echo "FATAL: required binary '$bin' missing" >&2; exit 1; }
done

PASS_COUNT=0
FAIL_COUNT=0
report_pass() { printf '  PASS  %s\n' "$1"; PASS_COUNT=$((PASS_COUNT + 1)); }
report_fail() { printf '  FAIL  %s\n' "$1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bv-promote-prod-test.XXXXXXXX")"
cleanup() { [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Target data version from the repo's code marker — the fixture matches it
# so no migration runs (Docker-free).
TARGET_DV="$(awk '
    /^[[:space:]]*#/ { next }
    /^data_version:[[:space:]]*/ {
        v=$0; sub(/^data_version:[[:space:]]*/,"",v); gsub(/^["'\'']|["'\'']$/,"",v);
        sub(/[[:space:]]+#.*$/,"",v); gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit
    }' "$REPO_ROOT/config/www/user/data-version.yaml")"
[ -n "$TARGET_DV" ] || { echo "FATAL: could not read target data_version from repo marker" >&2; exit 1; }
EXPECT_VDIR="v_${TARGET_DV//./_}"

# sha256 helper (matches the script's portable behaviour).
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}';
    else sha256sum "$1" | awk '{print $1}'; fi
}

echo "→ promote-to-prod: local-mode orchestration probe (target data_version=$TARGET_DV, vdir=$EXPECT_VDIR)"

# =============================================================================
# Build a SELF-CONTAINED throwaway git repo whose deploy/ is a copy of the
# real one, so the script's PROJECT_DIR (= dirname of SCRIPT_DIR) is a
# checkout we can put on any branch. The libs + sibling scripts + markers +
# features files are all copied in so backup/restore/migrate resolve too.
# =============================================================================
WORK_REPO="$TMP/repo"
mkdir -p "$WORK_REPO/deploy/lib" \
         "$WORK_REPO/config/www/user/env/staging.hackersbychoice.dk/config" \
         "$WORK_REPO/config/www/user/env/www.byvaerkstederne.dk/config"

# Copy the deploy scripts + libs verbatim from the real repo.
cp "$REPO_ROOT/deploy/promote-to-prod.sh" "$WORK_REPO/deploy/"
cp "$REPO_ROOT/deploy/backup.sh"          "$WORK_REPO/deploy/"
cp "$REPO_ROOT/deploy/restore.sh"         "$WORK_REPO/deploy/"
cp "$REPO_ROOT/deploy/migrate.sh"         "$WORK_REPO/deploy/"
cp "$REPO_ROOT/deploy/backup-paths.txt"   "$WORK_REPO/deploy/"
cp -R "$REPO_ROOT/deploy/lib/." "$WORK_REPO/deploy/lib/"
chmod +x "$WORK_REPO/deploy/"*.sh

# Markers + features files. data-version.yaml at TARGET_DV (no-bump).
printf 'data_version: "%s"\n' "$TARGET_DV" > "$WORK_REPO/config/www/user/data-version.yaml"
echo '0.1.0' > "$WORK_REPO/config/www/VERSION"
# Distinct staging vs prod features so the blessing/drift logic is real.
printf 'features:\n  staging_flag: "true"\n' > "$WORK_REPO/config/www/user/env/staging.hackersbychoice.dk/config/features.yaml"
printf 'features:\n  prod_flag: "false"\n'   > "$WORK_REPO/config/www/user/env/www.byvaerkstederne.dk/config/features.yaml"

WR_STAGING_FEATURES="$WORK_REPO/config/www/user/env/staging.hackersbychoice.dk/config/features.yaml"
WR_PROD_FEATURES="$WORK_REPO/config/www/user/env/www.byvaerkstederne.dk/config/features.yaml"
PROMOTE_WR="$WORK_REPO/deploy/promote-to-prod.sh"

# Init the throwaway repo + an initial commit on a release branch.
(
    cd "$WORK_REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test Harness"
    git add -A
    git commit -q -m "initial"
    git checkout -q -b release/v9.9.9
) || { echo "FATAL: could not init throwaway repo" >&2; exit 1; }

WR_HEAD="$(git -C "$WORK_REPO" rev-parse --short HEAD)"
WR_STAGING_SHA="$(sha256_of "$WR_STAGING_FEATURES")"
WR_PROD_SHA="$(sha256_of "$WR_PROD_FEATURES")"

# A correct, matching blessing stand-in (used by the PASS + build tests).
GOOD_BLESS="$TMP/good-bless.yaml"
cat > "$GOOD_BLESS" <<EOF
blessed_at: "2026-06-14T00:00:00Z"
code_commit: "$WR_HEAD"
code_version: "0.1.0"
code_build: "1"
data_version: "$TARGET_DV"
features_yaml_sha256: "$WR_STAGING_SHA"
source_backup_id: "prod-2026-06-14T00-00Z-v0.1.0-b1.tar.gz.age"
EOF
# Prod live-features stand-in matching git (no drift) for the PASS case.
PROD_LIVE_NODRIFT="$TMP/prod-live-nodrift.yaml"
cp "$WR_PROD_FEATURES" "$PROD_LIVE_NODRIFT"

# =============================================================================
# Shared backup/age fixture env (consumed by backup.sh + restore.sh).
# =============================================================================
FIXTURE="$TMP/fixture"
mkdir -p "$FIXTURE/user/accounts" \
         "$FIXTURE/user/data/flex" \
         "$FIXTURE/user/pages/01.home" \
         "$FIXTURE/user/uploads/2026/06" \
         "$FIXTURE/user/cache"
echo 'username: alice' > "$FIXTURE/user/accounts/alice.yaml"
echo 'username: bob'   > "$FIXTURE/user/accounts/bob.yaml"
echo 'task: hello'     > "$FIXTURE/user/data/flex/tasks.yaml"
echo 'title: Home'     > "$FIXTURE/user/pages/01.home/default.md"
echo 'avatar-bytes'    > "$FIXTURE/user/uploads/2026/06/avatar.png"
echo 'noise'           > "$FIXTURE/user/cache/noise"
echo '0.1.0' > "$FIXTURE/VERSION"
echo '247'   > "$FIXTURE/BUILD"
printf 'version: "%s"\n' "$TARGET_DV" > "$FIXTURE/user/data-version.yaml"

KEYDIR="$TMP/keys"; mkdir -p "$KEYDIR"
age-keygen -o "$KEYDIR/identity.txt" 2>"$KEYDIR/keygen.stderr"
PUBKEY="$(awk '/^# public key:/ {print $4; exit}' "$KEYDIR/identity.txt")"
[ -n "$PUBKEY" ] || { echo "FATAL: age-keygen produced no pubkey" >&2; exit 1; }
RECIPIENTS="$TMP/recipients.txt"
printf '# test recipient\n%s\n' "$PUBKEY" > "$RECIPIENTS"
STORE="$TMP/store"; mkdir -p "$STORE"

export BACKUP_RECIPIENTS_FILE="$RECIPIENTS"
export BACKUP_LOCAL_STORE_DIR="$STORE"
export BACKUP_FIXTURE_DIR="$FIXTURE"
export BACKUP_SOURCE_HOST="fixture.local"
export AGE_IDENTITY_FILE="$KEYDIR/identity.txt"
export BACKUP_FAKE_NOW_EPOCH="1781136840"
export XDG_CONFIG_HOME="$TMP/xdg-config"; mkdir -p "$XDG_CONFIG_HOME"
export BV_KEEP_LOCAL_DIR="$TMP/keep-local"; mkdir -p "$BV_KEEP_LOCAL_DIR"
export BACKUP_ENV_FILE="$TMP/no-such-env-file"
export RESTORE_ENV_FILE="$TMP/no-such-env-file"
export PROMOTE_PROD_ENV_FILE="$TMP/no-such-env-file"

# Every full (gate-passing) promote run COMMITS a flag-sync on the release
# branch, moving HEAD. So before each gate-passing test we must rebuild the
# matching blessing (code_commit == current HEAD, features sha == current
# staging) and refresh the no-drift prod stand-in (prod features may have
# just been synced). Call regen_good_bless on release/v9.9.9 right before
# any run we expect to pass the gate.
regen_good_bless() {
    WR_HEAD="$(git -C "$WORK_REPO" rev-parse --short HEAD)"
    WR_STAGING_SHA="$(sha256_of "$WR_STAGING_FEATURES")"
    cat > "$GOOD_BLESS" <<EOF
blessed_at: "2026-06-14T00:00:00Z"
code_commit: "$WR_HEAD"
code_version: "0.1.0"
code_build: "1"
data_version: "$TARGET_DV"
features_yaml_sha256: "$WR_STAGING_SHA"
source_backup_id: "prod-2026-06-14T00-00Z-v0.1.0-b1.tar.gz.age"
EOF
    cp "$WR_PROD_FEATURES" "$PROD_LIVE_NODRIFT"
}

# Helper: fresh local prod-tier dir seeded with a CURRENT (v0) dir holding
# a per-tier secret (cp -a must inherit it) + a stale account (overlay
# rsync --delete must remove it).
make_tier() {
    local d="$1"
    mkdir -p "$d/proddata/v0/user/config" "$d/proddata/v0/user/accounts"
    echo 'salt: keep-me'  > "$d/proddata/v0/user/config/security.yaml"
    echo 'username: stale' > "$d/proddata/v0/user/accounts/stale.yaml"
    ln -sfn v0 "$d/proddata/current"
}

# ──────────────────────────────────────────────────────────────────────
# BRANCH GATE
# ──────────────────────────────────────────────────────────────────────
echo "→ branch gate"
# Build a blessing for the current init HEAD (used by branch-gate cases,
# which die at step 0 before the gate, so the exact contents don't matter —
# but keep them valid for cleanliness).
git -C "$WORK_REPO" checkout -q release/v9.9.9
regen_good_bless
for badbranch in develop main; do
    git -C "$WORK_REPO" checkout -q "$badbranch" 2>/dev/null || git -C "$WORK_REPO" checkout -q -b "$badbranch"
    TIER_BG="$TMP/tier-bg-$badbranch"; mkdir -p "$TIER_BG"; make_tier "$TIER_BG"
    set +e
    out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_BG" \
        PROMOTE_PROD_LOCAL_BLESSING_FILE="$GOOD_BLESS" \
        PROMOTE_PROD_LOCAL_PROD_FEATURES="$PROD_LIVE_NODRIFT" \
        PROMOTE_PROD_LOG_FILE="$TMP/jrnl-bg.jsonl" \
        "$PROMOTE_WR" --reason "branch gate test run" 2>&1)"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "release/\* or hotfix/\* branch"; then
        report_pass "branch gate refuses on $badbranch (release-branch message, non-zero)"
    else
        report_fail "branch gate did not refuse on $badbranch (rc=$rc)"
        printf '%s\n' "$out" | tail -5 >&2
    fi
done

# release/* proceeds past the branch check (we assert it reaches step 1).
# Use a deliberately empty blessing stand-in so the run reaches the gate
# and then refuses — this proves "proceeds past the branch check" WITHOUT
# committing a flag-sync that would move HEAD for downstream tests.
git -C "$WORK_REPO" checkout -q release/v9.9.9
TIER_REL="$TMP/tier-rel"; mkdir -p "$TIER_REL"; make_tier "$TIER_REL"
EMPTY_BLESS="$TMP/empty-bless.yaml"; : > "$EMPTY_BLESS"
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_REL" \
    PROMOTE_PROD_LOCAL_BLESSING_FILE="$EMPTY_BLESS" \
    PROMOTE_PROD_LOCAL_PROD_FEATURES="$PROD_LIVE_NODRIFT" \
    PROMOTE_PROD_LOG_FILE="$TMP/jrnl-rel.jsonl" \
    "$PROMOTE_WR" --reason "release branch proceeds" 2>&1)"
rc=$?
set -e
if printf '%s' "$out" | grep -q "Step 1/11: staging-blessing gate"; then
    report_pass "release/* branch proceeds past the branch check (reaches blessing gate)"
else
    report_fail "release/* branch did not proceed to the blessing gate (rc=$rc)"
    printf '%s\n' "$out" | tail -8 >&2
fi

# ──────────────────────────────────────────────────────────────────────
# BLESSING GATE — PASS + FAIL cases. All on release/v9.9.9.
# Each uses a fresh tier so the build step of a passing run never leaks.
# ──────────────────────────────────────────────────────────────────────
echo "→ blessing gate"
git -C "$WORK_REPO" checkout -q release/v9.9.9
regen_good_bless

# PASS: a full clean run that gets PAST the gate (we assert the gate-passed
# line; the full success path is asserted in the build+activate section).
TIER_PASS="$TMP/tier-pass"; mkdir -p "$TIER_PASS"; make_tier "$TIER_PASS"
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_PASS" \
    PROMOTE_PROD_LOCAL_BLESSING_FILE="$GOOD_BLESS" \
    PROMOTE_PROD_LOCAL_PROD_FEATURES="$PROD_LIVE_NODRIFT" \
    PROMOTE_PROD_LOG_FILE="$TMP/jrnl-pass.jsonl" \
    "$PROMOTE_WR" --reason "clean pass run" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "staging-blessing gate passed"; then
    report_pass "blessing gate PASSES with matching commit/data_version/features/no-drift"
else
    report_fail "blessing gate did not pass on the matching stand-ins (rc=$rc)"
    printf '%s\n' "$out" | tail -12 >&2
fi
# The PASS run committed a flag sync (HEAD moved); regenerate the matching
# blessing so the FAIL stand-ins below mutate a CURRENTLY-valid baseline.
regen_good_bless

# FAIL: commit mismatch.
BLESS_BADCOMMIT="$TMP/bless-badcommit.yaml"
sed "s/code_commit: \"$WR_HEAD\"/code_commit: \"deadbee\"/" "$GOOD_BLESS" > "$BLESS_BADCOMMIT"
TIER_FC="$TMP/tier-fc"; mkdir -p "$TIER_FC"; make_tier "$TIER_FC"
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_FC" \
    PROMOTE_PROD_LOCAL_BLESSING_FILE="$BLESS_BADCOMMIT" \
    PROMOTE_PROD_LOCAL_PROD_FEATURES="$PROD_LIVE_NODRIFT" \
    PROMOTE_PROD_LOG_FILE="$TMP/jrnl-fc.jsonl" \
    "$PROMOTE_WR" --reason "commit mismatch test" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "you're trying to promote"; then
    report_pass "blessing gate FAILS on commit mismatch (specific message, non-zero)"
else
    report_fail "commit-mismatch case did not refuse as expected (rc=$rc)"
    printf '%s\n' "$out" | tail -6 >&2
fi
# No build should have happened on the refused run.
if [ ! -d "$TIER_FC/proddata/$EXPECT_VDIR" ]; then
    report_pass "commit-mismatch refusal left proddata untouched (no $EXPECT_VDIR built)"
else
    report_fail "commit-mismatch refusal still built $EXPECT_VDIR"
fi

# FAIL: data_version mismatch.
BLESS_BADDV="$TMP/bless-baddv.yaml"
sed "s/data_version: \"$TARGET_DV\"/data_version: \"9.9.9\"/" "$GOOD_BLESS" > "$BLESS_BADDV"
TIER_FDV="$TMP/tier-fdv"; mkdir -p "$TIER_FDV"; make_tier "$TIER_FDV"
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_FDV" \
    PROMOTE_PROD_LOCAL_BLESSING_FILE="$BLESS_BADDV" \
    PROMOTE_PROD_LOCAL_PROD_FEATURES="$PROD_LIVE_NODRIFT" \
    PROMOTE_PROD_LOG_FILE="$TMP/jrnl-fdv.jsonl" \
    "$PROMOTE_WR" --reason "data version mismatch test" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "data version mismatch"; then
    report_pass "blessing gate FAILS on data_version mismatch (specific message, non-zero)"
else
    report_fail "data_version-mismatch case did not refuse as expected (rc=$rc)"
    printf '%s\n' "$out" | tail -6 >&2
fi

# FAIL: features sha mismatch.
BLESS_BADSHA="$TMP/bless-badsha.yaml"
sed "s/features_yaml_sha256: \"$WR_STAGING_SHA\"/features_yaml_sha256: \"0000000000000000000000000000000000000000000000000000000000000000\"/" "$GOOD_BLESS" > "$BLESS_BADSHA"
TIER_FSHA="$TMP/tier-fsha"; mkdir -p "$TIER_FSHA"; make_tier "$TIER_FSHA"
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_FSHA" \
    PROMOTE_PROD_LOCAL_BLESSING_FILE="$BLESS_BADSHA" \
    PROMOTE_PROD_LOCAL_PROD_FEATURES="$PROD_LIVE_NODRIFT" \
    PROMOTE_PROD_LOG_FILE="$TMP/jrnl-fsha.jsonl" \
    "$PROMOTE_WR" --reason "features sha mismatch test" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "features.yaml SHA mismatch"; then
    report_pass "blessing gate FAILS on features sha mismatch (specific message, non-zero)"
else
    report_fail "features-sha-mismatch case did not refuse as expected (rc=$rc)"
    printf '%s\n' "$out" | tail -6 >&2
fi

# FAIL: prod-flag drift (prod live features differ from git copy).
PROD_LIVE_DRIFT="$TMP/prod-live-drift.yaml"
printf 'features:\n  prod_flag: "DRIFTED-BY-HAND"\n' > "$PROD_LIVE_DRIFT"
TIER_FDRIFT="$TMP/tier-fdrift"; mkdir -p "$TIER_FDRIFT"; make_tier "$TIER_FDRIFT"
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_FDRIFT" \
    PROMOTE_PROD_LOCAL_BLESSING_FILE="$GOOD_BLESS" \
    PROMOTE_PROD_LOCAL_PROD_FEATURES="$PROD_LIVE_DRIFT" \
    PROMOTE_PROD_LOG_FILE="$TMP/jrnl-fdrift.jsonl" \
    "$PROMOTE_WR" --reason "prod drift test" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "drifted from git"; then
    report_pass "blessing gate FAILS on prod-flag drift (specific message, non-zero)"
else
    report_fail "prod-flag-drift case did not refuse as expected (rc=$rc)"
    printf '%s\n' "$out" | tail -6 >&2
fi

# ──────────────────────────────────────────────────────────────────────
# BYPASS --reason length validation. The branch is release/* so the gate
# is reached; bypass refuses on the reason BEFORE any prompt/tier write.
# ──────────────────────────────────────────────────────────────────────
echo "→ bypass --reason validation"
git -C "$WORK_REPO" checkout -q release/v9.9.9
TIER_BP="$TMP/tier-bypass"; mkdir -p "$TIER_BP"; make_tier "$TIER_BP"

# missing --reason
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_BP" "$PROMOTE_WR" --bypass-staging-gate 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "requires --reason"; then
    report_pass "bypass without --reason refuses"
else
    report_fail "bypass without --reason did not refuse (rc=$rc)"
fi

# <50 chars
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_BP" "$PROMOTE_WR" --bypass-staging-gate --reason "too short" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "at least 50"; then
    report_pass "bypass with <50-char --reason refuses"
else
    report_fail "bypass with short --reason did not refuse (rc=$rc)"
fi

# >500 chars
LONG_REASON="$(printf 'x%.0s' $(seq 1 501))"
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_BP" "$PROMOTE_WR" --bypass-staging-gate --reason "$LONG_REASON" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "caps it at 500"; then
    report_pass "bypass with >500-char --reason refuses"
else
    report_fail "bypass with long --reason did not refuse (rc=$rc)"
fi

# ──────────────────────────────────────────────────────────────────────
# BYPASS-LOG APPEND. The script reads the y/N confirmation from /dev/tty
# (NOT stdin) so it cannot be answered by a flag or a plain pipe — the
# spec's "interactive; cannot be --bypass-staging-gate --yes scripted"
# requirement. To drive that read deterministically we allocate a PTY via
# `script(1)` and feed it 'y'. A wrapper script carries the env so no
# quoting lands on script's command line. If no PTY tool is available we
# still assert the graceful no-tty abort + that NO entry was written
# without confirmation.
# ──────────────────────────────────────────────────────────────────────
echo "→ bypass-log append"
git -C "$WORK_REPO" checkout -q release/v9.9.9
TIER_BLOG="$TMP/tier-blog"; mkdir -p "$TIER_BLOG"; make_tier "$TIER_BLOG"
VALID_REASON="prod 500ing on /login since 02:13Z; staging blocked on an unrelated flaky migration test we will fix next week"

# Negative half (always runs, deterministic): without a confirmation the
# bypass must NOT write an entry. We feed stdin (which the script ignores
# for the prompt — it reads /dev/tty) and a closed /dev/tty so the read
# fails and the run aborts. This proves the prompt is reached AND that
# nothing is logged absent an affirmative 'y'.
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_BLOG" \
    PROMOTE_PROD_LOG_FILE="$TMP/jrnl-blog.jsonl" \
    "$PROMOTE_WR" --bypass-staging-gate --reason "$VALID_REASON" </dev/null 2>&1)"
rc=$?
set -e
if printf '%s' "$out" | grep -q "BYPASSING STAGING GATE"; then
    report_pass "bypass reaches the interactive y/N prompt (validated reason, not scriptable)"
else
    report_fail "bypass did not reach the interactive prompt (rc=$rc)"
    printf '%s\n' "$out" | tail -6 >&2
fi
if [ ! -f "$TIER_BLOG/prod-bypass-log.yaml" ]; then
    report_pass "no bypass entry written without an affirmative confirmation"
else
    report_fail "bypass entry written without operator confirmation"
fi

# Positive half: drive the /dev/tty read via a PTY and assert the append.
# Wrapper carries the env so script(1)'s argv stays clean.
BLOG_WRAP="$TMP/blog-wrap.sh"
cat > "$BLOG_WRAP" <<WRAP
#!/usr/bin/env bash
export PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_BLOG"
export PROMOTE_PROD_LOG_FILE="$TMP/jrnl-blog.jsonl"
export PROMOTE_PROD_ENV_FILE="$TMP/no-such-env-file"
exec "$PROMOTE_WR" --bypass-staging-gate --reason "$VALID_REASON"
WRAP
chmod +x "$BLOG_WRAP"

drove_pty=0
# Prefer expect: it waits for the prompt before sending, so it's immune to
# the read-before-flush race that bites `script` stdin forwarding.
if command -v expect >/dev/null 2>&1; then
    set +e
    expect -c "
        spawn $BLOG_WRAP
        expect -re {proceed .y/N.}
        send \"y\r\"
        expect eof
    " >"$TMP/blog-pty.out" 2>&1
    set -e
    drove_pty=1
elif command -v script >/dev/null 2>&1; then
    set +e
    # util-linux: script -q -e -c "cmd" file  (forwards stdin to the PTY).
    if script -q -e -c "true" /dev/null >/dev/null 2>&1; then
        printf 'y\n' | script -q -e -c "$BLOG_WRAP" /dev/null >"$TMP/blog-pty.out" 2>&1
        drove_pty=1
    # BSD/macOS: script [-q] file command [args...].
    elif script -q /dev/null /usr/bin/true >/dev/null 2>&1 || script -q /dev/null true >/dev/null 2>&1; then
        printf 'y\n' | script -q /dev/null "$BLOG_WRAP" >"$TMP/blog-pty.out" 2>&1
        drove_pty=1
    fi
    set -e
fi

if [ "$drove_pty" = "1" ]; then
    if [ -f "$TIER_BLOG/prod-bypass-log.yaml" ] \
        && grep -q "reason: \"$VALID_REASON\"" "$TIER_BLOG/prod-bypass-log.yaml"; then
        report_pass "confirmed bypass appends an entry to prod-bypass-log.yaml with the reason"
    else
        report_fail "confirmed bypass did not append the expected entry"
        [ -f "$TMP/blog-pty.out" ] && tail -8 "$TMP/blog-pty.out" >&2
    fi
    if grep -q '^---$' "$TIER_BLOG/prod-bypass-log.yaml" 2>/dev/null; then
        report_pass "bypass-log entry is a '---'-separated YAML doc"
    else
        report_fail "bypass-log entry is not '---'-separated"
    fi
else
    echo "  NOTE  no 'script' or 'expect' PTY tool — confirmed-bypass append asserted only where a PTY driver exists" >&2
fi

# ──────────────────────────────────────────────────────────────────────
# BUILD + ACTIVATE success path (NO-BUMP). Re-run a clean promote on a
# fresh tier and assert the full data-dir build + flag-sync commit +
# journal append.
# ──────────────────────────────────────────────────────────────────────
echo "→ build + activate success path"
git -C "$WORK_REPO" checkout -q release/v9.9.9
# Reset the prod features in git to a known value DIFFERENT from staging so
# the flag-sync commit actually fires this run, then regen the matching
# blessing against the resulting HEAD.
printf 'features:\n  prod_flag: "false"\n' > "$WR_PROD_FEATURES"
if [ -n "$(git -C "$WORK_REPO" status --porcelain)" ]; then
    git -C "$WORK_REPO" add -A && git -C "$WORK_REPO" commit -q -m "reset prod features for build test"
fi
regen_good_bless

TIER_BUILD="$TMP/tier-build"; mkdir -p "$TIER_BUILD"; make_tier "$TIER_BUILD"
JRNL_BUILD="$TMP/jrnl-build.jsonl"
COMMITS_BEFORE="$(git -C "$WORK_REPO" rev-list --count HEAD)"
set +e
out="$(PROMOTE_PROD_LOCAL_TIER_DIR="$TIER_BUILD" \
    PROMOTE_PROD_LOCAL_BLESSING_FILE="$GOOD_BLESS" \
    PROMOTE_PROD_LOCAL_PROD_FEATURES="$PROD_LIVE_NODRIFT" \
    PROMOTE_PROD_LOG_FILE="$JRNL_BUILD" \
    "$PROMOTE_WR" --reason "the build success path" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    report_pass "promote exits 0 on a clean local-mode run"
else
    report_fail "promote exited $rc (expected 0)"
    printf '%s\n' "$out" | tail -25 >&2
fi

# Complete v_<target> built (cp -a carried user/config in).
if [ -d "$TIER_BUILD/proddata/$EXPECT_VDIR/user/config" ]; then
    report_pass "complete v_<target> data dir built ($EXPECT_VDIR with user/config inherited)"
else
    report_fail "v_<target> data dir incomplete (no user/config in $EXPECT_VDIR)"
fi
# Per-tier secret inherited via cp -a.
SEC="$TIER_BUILD/proddata/$EXPECT_VDIR/user/config/security.yaml"
if [ -f "$SEC" ] && grep -q 'keep-me' "$SEC"; then
    report_pass "per-tier secret inherited into $EXPECT_VDIR via cp -a"
else
    report_fail "per-tier secret NOT inherited into $EXPECT_VDIR"
fi
# Overlay applied: accounts present + byte-identical.
ACCT="$TIER_BUILD/proddata/$EXPECT_VDIR/user/accounts"
if [ -f "$ACCT/alice.yaml" ] && diff -q "$FIXTURE/user/accounts/alice.yaml" "$ACCT/alice.yaml" >/dev/null; then
    report_pass "accounts overlaid + byte-identical at $EXPECT_VDIR/user/accounts/"
else
    report_fail "accounts overlay missing/mismatched at $ACCT"
fi
# Stale account removed by the overlay rsync --delete.
if [ ! -e "$ACCT/stale.yaml" ]; then
    report_pass "stale account removed from $EXPECT_VDIR (overlay rsync --delete won over cp -a)"
else
    report_fail "stale account survived in $EXPECT_VDIR"
fi
# Deny-listed cache did not ship.
if [ ! -e "$TIER_BUILD/proddata/$EXPECT_VDIR/user/cache" ]; then
    report_pass "deny-listed user/cache did not ship to the prod data dir"
else
    report_fail "deny-listed user/cache leaked into the prod data dir"
fi
# current repointed.
CUR="$(readlink "$TIER_BUILD/proddata/current" 2>/dev/null || echo "")"
if [ "$CUR" = "$EXPECT_VDIR" ]; then
    report_pass "proddata/current → $EXPECT_VDIR (activated before code deploy)"
else
    report_fail "proddata/current → '$CUR' (expected '$EXPECT_VDIR')"
fi
# Flag-sync commit landed on the release branch.
COMMITS_AFTER="$(git -C "$WORK_REPO" rev-list --count HEAD)"
LAST_MSG="$(git -C "$WORK_REPO" log -1 --pretty=%s)"
if [ "$COMMITS_AFTER" -gt "$COMMITS_BEFORE" ] && printf '%s' "$LAST_MSG" | grep -q "sync staging flags to prod"; then
    report_pass "flag-sync commit landed on the release branch ('$LAST_MSG')"
else
    report_fail "flag-sync commit not observed (before=$COMMITS_BEFORE after=$COMMITS_AFTER msg='$LAST_MSG')"
fi
# Prod features now byte-identical to staging.
if diff -q "$WR_STAGING_FEATURES" "$WR_PROD_FEATURES" >/dev/null; then
    report_pass "prod features.yaml now byte-identical to staging features.yaml"
else
    report_fail "prod features.yaml not synced to staging"
fi
# Promotion journal appended (valid JSON line with the reason).
if [ -f "$JRNL_BUILD" ] && grep -q '"reason":"the build success path"' "$JRNL_BUILD"; then
    report_pass "promotion-log.jsonl appended with the operator reason"
else
    report_fail "promotion-log.jsonl missing or lacks the reason"
fi
# Scratch removed on success.
if printf '%s' "$out" | grep -q "scratch removed"; then
    report_pass "scratch dir removed on success"
else
    report_fail "scratch dir not reported removed on success"
fi

# ──────────────────────────────────────────────────────────────────────
# ROLLBACK-PROD — refuse-without-flag + local-mode restore (wipe+replace).
# Reuses the throwaway repo's deploy/ and the backup fixture in $STORE.
# The build run above produced at least one prod-*.tar.gz.age archive; we
# roll back TO it.
# ──────────────────────────────────────────────────────────────────────
echo "→ rollback-prod"
ROLLBACK_WR="$WORK_REPO/deploy/rollback-prod.sh"
cp "$REPO_ROOT/deploy/rollback-prod.sh" "$ROLLBACK_WR"
chmod +x "$ROLLBACK_WR"
[ -x "$ROLLBACK_WR" ] || { echo "FATAL: rollback-prod.sh not copied/executable" >&2; exit 1; }

# Pick a real backup id from the managed store (the build run + earlier
# fail runs all produced tagged backups; any prod-* archive works).
RB_BACKUP="$(ls "$STORE"/prod-*.tar.gz.age 2>/dev/null | head -n1 | xargs -I{} basename {} || true)"
[ -n "$RB_BACKUP" ] || { echo "FATAL: no prod backup archive in $STORE to roll back to" >&2; exit 1; }

# (a) Refuse without --yes-i-mean-it.
set +e
out="$(ROLLBACK_PROD_LOCAL_TIER_DIR="$TMP/rb-tier-refuse" "$ROLLBACK_WR" --to-backup "$RB_BACKUP" 2>&1)"
rc=$?
set -e
# The local-tier dir must exist for the absolute-path check to pass before
# the safety gate; create it and retry to isolate the gate behaviour.
mkdir -p "$TMP/rb-tier-refuse"
set +e
out="$(ROLLBACK_PROD_LOCAL_TIER_DIR="$TMP/rb-tier-refuse" "$ROLLBACK_WR" --to-backup "$RB_BACKUP" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "without --yes-i-mean-it"; then
    report_pass "rollback-prod refuses without --yes-i-mean-it"
else
    report_fail "rollback-prod did not refuse without --yes-i-mean-it (rc=$rc)"
    printf '%s\n' "$out" | tail -6 >&2
fi

# (b) Local-mode restore: seed a tier with STALE accounts; rollback must
# wipe + replace them with the backup's content (alice/bob from the fixture)
# and remove the stale file. A pre-rollback backup must also be taken.
RB_TIER="$TMP/rb-tier"; mkdir -p "$RB_TIER/user/accounts"
echo 'username: WILL-BE-WIPED' > "$RB_TIER/user/accounts/ghost.yaml"
set +e
out="$(ROLLBACK_PROD_LOCAL_TIER_DIR="$RB_TIER" \
    "$ROLLBACK_WR" --to-backup "$RB_BACKUP" --yes-i-mean-it 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
    report_pass "rollback-prod local restore exits 0"
else
    report_fail "rollback-prod local restore exited $rc"
    printf '%s\n' "$out" | tail -15 >&2
fi
# Backup content (alice) landed; stale ghost removed by rsync --delete.
if [ -f "$RB_TIER/user/accounts/alice.yaml" ] && [ ! -e "$RB_TIER/user/accounts/ghost.yaml" ]; then
    report_pass "rollback-prod wiped stale state and restored the backup's accounts"
else
    report_fail "rollback-prod did not wipe+replace the tier accounts as expected"
fi
# A pre-rollback safety backup was taken: a tag marker reading
# pre-rollback-<ts> must exist in the store. (With the fixed fake epoch the
# archive name is stable, so the .tag content — not the file count — is the
# reliable signal that backup.sh ran with the pre-rollback tag.)
if ls "$STORE"/*.tag >/dev/null 2>&1 \
    && cat "$STORE"/*.tag 2>/dev/null | grep -q '^pre-rollback-' \
    && printf '%s' "$out" | grep -q "pre-rollback backup id:"; then
    report_pass "rollback-prod took a tagged pre-rollback safety backup"
else
    report_fail "rollback-prod did not take a tagged pre-rollback backup"
    printf '%s\n' "$out" | tail -8 >&2
fi

# ─── Summary ──────────────────────────────────────────────────────────
echo ""
echo "promote-to-prod: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
