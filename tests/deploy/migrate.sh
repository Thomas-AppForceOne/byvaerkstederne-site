#!/usr/bin/env bash
#
# Shell-level probe for deploy/migrate-to-atomic-layout.sh.
#
# Runs entirely locally inside a mktemp fixture (no ssh, no remote, no
# credentials). Exercises the seven-step migration sequence and every
# refusal path the Sprint-3 contract names:
#
# Success path:
#   * Build a fixture with the legacy in-place layout (a fake live tree
#     containing user/accounts/, user/data/flex-objects/, the two
#     security.yaml files, cache/, logs/, system/, themes, plugins).
#   * Snapshot every live-state file into a sibling shadow dir BEFORE
#     the migration (cp -a, then chmod -w on the snapshot so any later
#     accidental mutation is caught).
#   * Run the migration with BV_MIGRATE_LOCAL_PARENT, BV_MIGRATE_BACKUP_FAKE=1,
#     BV_MIGRATE_BACKUP_INVOKED_MARKER, BV_MIGRATE_STEP_6_TIMESTAMP_FILE,
#     and BV_SMOKE_PROBE_URL_OVERRIDE pointing at a stub HTTP responder
#     serving the matching `Version <X> · build <N>` body.
#   * Assert: every state file is bit-identical via cmp -s; <tier> is
#     a symlink; <tier>data/v0/{user/accounts,user/data,…}/ exist and
#     contain content; <tier>-releases/migrate-bootstrap-<ts>/ contains
#     the rest of the tree; release-meta.yaml carries the §Audit
#     schema with previous_release/previous_data_version empty;
#     smoke probe is green; offline window is bounded.
#
# Failure paths (CLAUDE.md testing discipline — at least three):
#   * Re-run on the resulting atomic layout exits non-zero with the
#     "already" diagnostic; no on-disk corruption.
#   * `migrate-to-atomic-layout.sh prod` without --i-mean-it refuses
#     with the "--i-mean-it" diagnostic; fixture untouched.
#   * Tier-name validator rejects bogus values before any path
#     construction.
#   * Pre-flight backup failure (BV_MIGRATE_BACKUP_FAKE_FAIL=1) aborts
#     the migration BEFORE any state move; <tier>data/ never created;
#     state files unchanged.
#   * Smoke-probe failure on a fresh migration exits non-zero with
#     the "restore from backup" hint (we configure the stub HTTP to
#     serve a body that doesn't match the expected substring).
#
# Real-mode end-to-end (asserts schema validation):
#   * One probe also runs the migration without BV_MIGRATE_BACKUP_FAKE,
#     using a stub backup.sh shimmed via PATH to validate the produced
#     backup-meta.yaml against deploy/schemas/backup-meta.schema.yaml.
#     [Implementer's note: the existing backup.sh has its own fixture
#     mode (BACKUP_FIXTURE_DIR + BACKUP_LOCAL_STORE_DIR + sample VERSION/
#     BUILD/data-version markers); we drive THAT path so we exercise
#     real backup.sh end-to-end and validate its backup-meta.yaml output
#     against the schema.]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/deploy/lib/atomic-release.sh"
MIGRATE_SH="$REPO_ROOT/deploy/migrate-to-atomic-layout.sh"
BACKUP_SH="$REPO_ROOT/deploy/backup.sh"
BACKUP_SCHEMA="$REPO_ROOT/deploy/schemas/backup-meta.schema.yaml"

if [ ! -f "$MIGRATE_SH" ]; then
    echo "FATAL: migrate-to-atomic-layout.sh not found at $MIGRATE_SH" >&2
    exit 1
fi
if [ ! -x "$MIGRATE_SH" ]; then
    echo "FATAL: migrate-to-atomic-layout.sh is not executable" >&2
    exit 1
fi
# shellcheck source=deploy/lib/atomic-release.sh
. "$LIB"

WORK="$(mktemp -d)"

# Stub HTTP responder (Python http.server backed by a file, matching
# the rollback.sh test fixture pattern).
HTTP_ROOT="$WORK/http"
mkdir -p "$HTTP_ROOT"
echo "Initial body — replaced per-test" > "$HTTP_ROOT/index.html"

HTTP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
( cd "$HTTP_ROOT" && python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
HTTP_PID=$!

# trap: kill stub HTTP, restore any write-protected snapshot dirs, rm tempdir.
cleanup() {
    if [ -n "${HTTP_PID:-}" ]; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    # Test 7 chmods the shadow snapshot read-only to catch silent
    # mutation; restore write perms so rm can clean up. Suppress
    # errors so the trap never fails noisily.
    if [ -n "${WORK:-}" ] && [ -d "$WORK" ]; then
        chmod -R u+w "$WORK" 2>/dev/null || true
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

HTTP_READY=0
for _ in $(seq 1 60); do
    if curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:$HTTP_PORT/" 2>/dev/null; then
        HTTP_READY=1
        break
    fi
    sleep 0.25
done
if [ "$HTTP_READY" != "1" ]; then
    echo "FATAL: stub HTTP responder failed to come up on 127.0.0.1:$HTTP_PORT" >&2
    exit 1
fi

set_http_body() {
    printf '%s' "$1" > "$HTTP_ROOT/index.html"
}
PROBE_URL="http://127.0.0.1:$HTTP_PORT/"

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

# ─────────────────────────────────────────────────────────────────────
# Helper: build a legacy-layout fixture under <parent>/<tier>/.
# Returns nothing; mutates the parent dir.
# ─────────────────────────────────────────────────────────────────────
TIER="dev"
build_legacy_fixture() {
    local parent="$1" env="$2"
    local tier_dir="$parent/$env"
    mkdir -p "$tier_dir/user/accounts"
    mkdir -p "$tier_dir/user/data/flex-objects"
    mkdir -p "$tier_dir/user/data/some-cache"
    mkdir -p "$tier_dir/user/config"
    mkdir -p "$tier_dir/user/env/${env}/config"
    mkdir -p "$tier_dir/user/themes/byvaerkstederne/templates"
    mkdir -p "$tier_dir/user/plugins/example"
    mkdir -p "$tier_dir/cache/twig"
    mkdir -p "$tier_dir/logs"
    mkdir -p "$tier_dir/system"

    # Live state — bit-identity must hold.
    cat > "$tier_dir/user/accounts/alice.yaml" <<'YAML'
email: alice@example.com
hashed_password: $2y$10$abcdefghijklmnopqrstuv
fullname: Alice Example
state: enabled
access:
  site:
    login: true
YAML
    cat > "$tier_dir/user/accounts/bob.yaml" <<'YAML'
email: bob@example.com
hashed_password: $2y$10$ZZZZZZZZZZZZZZZZZZZZZZ
fullname: Bob Example
state: enabled
YAML
    cat > "$tier_dir/user/data/flex-objects/feature-1.json" <<'JSON'
{"id": "feature-1", "title": "Atomic deploy", "votes": 17}
JSON
    cat > "$tier_dir/user/data/flex-objects/feature-2.json" <<'JSON'
{"id": "feature-2", "title": "Versioned data dirs", "votes": 5}
JSON
    cat > "$tier_dir/user/data/some-cache/state.json" <<'JSON'
{"counter": 42}
JSON
    cat > "$tier_dir/user/config/security.yaml" <<'YAML'
salt: 9876543210abcdef
YAML
    cat > "$tier_dir/user/env/${env}/config/security.yaml" <<'YAML'
salt: env-specific-salt-9999
YAML
    cat > "$tier_dir/logs/grav.log" <<'LOG'
[2026-04-01 12:00:00] grav.INFO: hello
[2026-04-01 12:01:00] grav.INFO: world
LOG

    # Code (the bit that moves into the bootstrap release).
    echo '<?php echo "hello";' > "$tier_dir/index.php"
    echo '0.2.0' > "$tier_dir/VERSION"
    echo '247' > "$tier_dir/BUILD"
    echo 'theme content' > "$tier_dir/user/themes/byvaerkstederne/templates/default.html.twig"
    echo 'plugin content' > "$tier_dir/user/plugins/example/example.php"
    echo 'system content' > "$tier_dir/system/blueprints.yaml"
    echo 'cache content (should land in bootstrap, not state)' > "$tier_dir/cache/twig/cache.tmp"
    echo 'dotfile content' > "$tier_dir/.htaccess"
}

# Snapshot every live-state file (regular files only) into a sibling
# shadow dir, preserving relative paths. Used to assert bit-identity
# pre/post.
snapshot_live_state() {
    local tier_dir="$1" shadow="$2"
    mkdir -p "$shadow"
    # Five categories: accounts, data, both security.yamls, logs.
    for sub in user/accounts user/data logs; do
        if [ -d "$tier_dir/$sub" ]; then
            mkdir -p "$shadow/$sub"
            cp -a "$tier_dir/$sub/." "$shadow/$sub/"
        fi
    done
    if [ -f "$tier_dir/user/config/security.yaml" ]; then
        mkdir -p "$shadow/user/config"
        cp -a "$tier_dir/user/config/security.yaml" "$shadow/user/config/security.yaml"
    fi
    if [ -f "$tier_dir/user/env/${TIER}/config/security.yaml" ]; then
        mkdir -p "$shadow/user/env/${TIER}/config"
        cp -a "$tier_dir/user/env/${TIER}/config/security.yaml" "$shadow/user/env/${TIER}/config/security.yaml"
    fi
}

# Run cmp -s on every regular file under the snapshot, comparing it
# to the live-resolution-via-symlinks counterpart. Returns the number
# of mismatches. The post-migration <tier>/ symlink resolves to
# <bootstrap>, so accounts at <tier>/user/accounts/<file> follow the
# release-dir symlink into <tier>data/v0/user/accounts/<file>.
cmp_live_state() {
    local shadow="$1" tier_dir="$2"
    local mismatches=0
    while IFS= read -r -d '' f; do
        local rel="${f#"$shadow/"}"
        local live="$tier_dir/$rel"
        if [ ! -e "$live" ]; then
            echo "    MISSING in live: $rel" >&2
            mismatches=$((mismatches+1))
            continue
        fi
        if ! cmp -s "$f" "$live"; then
            echo "    MISMATCH: $rel" >&2
            mismatches=$((mismatches+1))
        fi
    done < <(find "$shadow" -type f -print0)
    printf '%s' "$mismatches"
}

# ═════════════════════════════════════════════════════════════════════
# Test 0: static review of the migration script.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 0: deploy/migrate-to-atomic-layout.sh source-level invariants"

# Executable, set -euo pipefail, sources both libs.
if [ -x "$MIGRATE_SH" ]; then
    check "migrate-to-atomic-layout.sh is executable" ok
else
    check "migrate-to-atomic-layout.sh is executable" fail
fi
if grep -q 'set -euo pipefail' "$MIGRATE_SH"; then
    check "migrate-to-atomic-layout.sh sets -euo pipefail" ok
else
    check "migrate-to-atomic-layout.sh sets -euo pipefail" fail
fi
if grep -q 'lib/atomic-release.sh' "$MIGRATE_SH"; then
    check "migrate-to-atomic-layout.sh sources lib/atomic-release.sh" ok
else
    check "migrate-to-atomic-layout.sh sources lib/atomic-release.sh" fail
fi
if grep -q 'lib/banner.sh' "$MIGRATE_SH"; then
    check "migrate-to-atomic-layout.sh sources lib/banner.sh" ok
else
    check "migrate-to-atomic-layout.sh sources lib/banner.sh" fail
fi
# Closed-set env validator BEFORE any path construction.
if grep -q 'bv_validate_tier_name' "$MIGRATE_SH"; then
    check "migrate-to-atomic-layout.sh calls bv_validate_tier_name" ok
else
    check "migrate-to-atomic-layout.sh calls bv_validate_tier_name" fail
fi
# Calls the shared symlink-wiring helper (single source of truth).
if grep -q 'bv_wire_release_symlinks' "$MIGRATE_SH"; then
    check "migrate-to-atomic-layout.sh calls bv_wire_release_symlinks (single source of truth)" ok
else
    check "migrate-to-atomic-layout.sh calls bv_wire_release_symlinks" fail
fi
# Calls the shared atomic-swap helper.
if grep -q 'bv_atomic_swap_symlink' "$MIGRATE_SH"; then
    check "migrate-to-atomic-layout.sh calls bv_atomic_swap_symlink" ok
else
    check "migrate-to-atomic-layout.sh calls bv_atomic_swap_symlink" fail
fi
# Calls the shared smoke-probe helper.
if grep -q 'bv_smoke_probe' "$MIGRATE_SH"; then
    check "migrate-to-atomic-layout.sh calls bv_smoke_probe" ok
else
    check "migrate-to-atomic-layout.sh calls bv_smoke_probe" fail
fi
# Live state moved via mv only — never rsync, cp, tar, rm -rf.
if grep -nE 'rsync[[:space:]].*--delete' "$MIGRATE_SH" | grep -v '^[[:space:]]*#' >/dev/null; then
    check "migrate-to-atomic-layout.sh has no rsync --delete" fail
else
    check "migrate-to-atomic-layout.sh has no rsync --delete" ok
fi
# No rsync at all — migration uses mv exclusively.
if grep -nE '^[[:space:]]*rsync\b' "$MIGRATE_SH" >/dev/null; then
    check "migrate-to-atomic-layout.sh has no rsync invocation" fail
else
    check "migrate-to-atomic-layout.sh has no rsync invocation" ok
fi
# No tar.
if grep -nE '^[[:space:]]*tar\b' "$MIGRATE_SH" >/dev/null; then
    check "migrate-to-atomic-layout.sh has no tar invocation" fail
else
    check "migrate-to-atomic-layout.sh has no tar invocation" ok
fi
# No cp -r against live state. (We do allow `cp -a` in test fixtures
# but the production script must NOT cp live-state paths.)
if grep -nE '^[[:space:]]*cp[[:space:]]+-[ra]' "$MIGRATE_SH" >/dev/null; then
    check "migrate-to-atomic-layout.sh has no cp -r/-a against live state" fail
else
    check "migrate-to-atomic-layout.sh has no cp -r/-a against live state" ok
fi
# No rm -rf against live-state paths or the docroot.
if grep -nE 'rm[[:space:]]+-rf?[[:space:]]+[^|]*(DATA_DIR|DOCROOT|accounts|user/data|logs)' "$MIGRATE_SH" \
   | grep -v '^[[:space:]]*#' >/dev/null; then
    check "migrate-to-atomic-layout.sh has no rm -rf against live state / docroot" fail
else
    check "migrate-to-atomic-layout.sh has no rm -rf against live state / docroot" ok
fi
# Step 6 contains only mv/ln/rmdir — bound the offline window.
# We grep the step-6 region (between the step-6 banner line and
# step 7's banner).
STEP6_BLOCK="$(awk '/Step 6\/7:/,/Step 7\/7:/' "$MIGRATE_SH")"
if printf '%s' "$STEP6_BLOCK" | grep -E '^[[:space:]]*(rsync|cp|tar)\b' >/dev/null; then
    check "migrate-to-atomic-layout.sh step 6 contains no rsync/cp/tar" fail
else
    check "migrate-to-atomic-layout.sh step 6 contains no rsync/cp/tar" ok
fi
# Sanity check (step 1) appears BEFORE backup invocation (step 2).
STEP1_LINE=$(grep -n 'Step 1/7:' "$MIGRATE_SH" | head -1 | cut -d: -f1)
STEP2_LINE=$(grep -n 'Step 2/7:' "$MIGRATE_SH" | head -1 | cut -d: -f1)
STEP3_LINE=$(grep -n 'Step 3/7:' "$MIGRATE_SH" | head -1 | cut -d: -f1)
STEP4_LINE=$(grep -n 'Step 4/7:' "$MIGRATE_SH" | head -1 | cut -d: -f1)
STEP5_LINE=$(grep -n 'Step 5/7:' "$MIGRATE_SH" | head -1 | cut -d: -f1)
STEP6_LINE=$(grep -n 'Step 6/7:' "$MIGRATE_SH" | head -1 | cut -d: -f1)
STEP7_LINE=$(grep -n 'Step 7/7:' "$MIGRATE_SH" | head -1 | cut -d: -f1)
if [ -n "$STEP1_LINE" ] && [ -n "$STEP2_LINE" ] && [ -n "$STEP3_LINE" ] \
   && [ -n "$STEP4_LINE" ] && [ -n "$STEP5_LINE" ] && [ -n "$STEP6_LINE" ] \
   && [ -n "$STEP7_LINE" ] \
   && [ "$STEP1_LINE" -lt "$STEP2_LINE" ] \
   && [ "$STEP2_LINE" -lt "$STEP3_LINE" ] \
   && [ "$STEP3_LINE" -lt "$STEP4_LINE" ] \
   && [ "$STEP4_LINE" -lt "$STEP5_LINE" ] \
   && [ "$STEP5_LINE" -lt "$STEP6_LINE" ] \
   && [ "$STEP6_LINE" -lt "$STEP7_LINE" ]; then
    check "all seven step markers appear in order in the script" ok
else
    check "all seven step markers appear in order in the script" fail
fi
# Sanity check (step 1) does its three signal checks BEFORE deploy/backup.sh
# is invoked (step 2).
if [ -n "$STEP1_LINE" ] && [ -n "$STEP2_LINE" ]; then
    if grep -nE 'BACKUP_SH=|backup.sh.*"\$ENV"|"\$BACKUP_SH"' "$MIGRATE_SH" \
       | awk -F: '{print $1}' | head -1 | xargs -I{} test {} -gt "$STEP1_LINE"; then
        check "step 1 sanity check appears BEFORE backup.sh invocation" ok
    else
        check "step 1 sanity check appears BEFORE backup.sh invocation" fail
    fi
fi

# ═════════════════════════════════════════════════════════════════════
# Test 1: --help prints usage, exits 0, stderr is empty.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 1: --help output"

HELP_STDOUT="$WORK/help.stdout"
HELP_STDERR="$WORK/help.stderr"
if "$MIGRATE_SH" --help >"$HELP_STDOUT" 2>"$HELP_STDERR"; then
    check "--help exits 0" ok
else
    check "--help exits 0" fail
fi
if [ ! -s "$HELP_STDERR" ]; then
    check "--help writes nothing to stderr" ok
else
    check "--help writes nothing to stderr" fail
fi
# Required literals.
for needle in "--i-mean-it" "one-time" "offline" "backup" "dev" "test" "staging" "prod"; do
    if grep -q -- "$needle" "$HELP_STDOUT"; then
        check "--help mentions '$needle'" ok
    else
        check "--help mentions '$needle'" fail
    fi
done
# All seven step labels present in --help.
for n in 1 2 3 4 5 6 7; do
    if grep -Eq "^[[:space:]]*${n}\." "$HELP_STDOUT"; then
        check "--help lists step ${n}" ok
    else
        check "--help lists step ${n}" fail
    fi
done

# ═════════════════════════════════════════════════════════════════════
# Test 2: tier-name validator rejects bogus values BEFORE any path
# is constructed (path-traversal defence). No mutation must be left
# behind in any case.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 2: tier-name validator (path-traversal defence)"

T_VAL_PARENT="$WORK/t-validator"
mkdir -p "$T_VAL_PARENT"
MARKER="$WORK/t-validator-marker"

for bogus in "../etc" "/absolute/path" "-rf" '$(touch '"$MARKER"')'; do
    rm -f "$MARKER"
    if BV_MIGRATE_LOCAL_PARENT="$T_VAL_PARENT" \
       "$MIGRATE_SH" "$bogus" 2>/dev/null; then
        check "validator rejects '$bogus'" fail
    else
        check "validator rejects '$bogus'" ok
    fi
    if [ -e "$MARKER" ]; then
        check "no shell-substitution side effect for '$bogus'" fail
    else
        check "no shell-substitution side effect for '$bogus'" ok
    fi
done

# ═════════════════════════════════════════════════════════════════════
# Test 3: prod gate — without --i-mean-it, refuse with diagnostic
# naming the flag. With --i-mean-it, the migration proceeds.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 3: prod gate (--i-mean-it required)"

T_PROD_PARENT="$WORK/t-prod"
mkdir -p "$T_PROD_PARENT"
build_legacy_fixture "$T_PROD_PARENT" "prod"

# Snapshot tree-state before the refused run; assert nothing changed.
PROD_PRE_SHA="$(find "$T_PROD_PARENT" -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null | shasum)"

PROD_REFUSE_OUT="$WORK/t-prod-refuse.out"
PROD_REFUSE_ERR="$WORK/t-prod-refuse.err"
if BV_MIGRATE_LOCAL_PARENT="$T_PROD_PARENT" \
   BV_MIGRATE_BACKUP_FAKE=1 \
   "$MIGRATE_SH" prod >"$PROD_REFUSE_OUT" 2>"$PROD_REFUSE_ERR"; then
    check "prod without --i-mean-it returns non-zero" fail
else
    check "prod without --i-mean-it returns non-zero" ok
fi
if grep -q -- "--i-mean-it" "$PROD_REFUSE_ERR"; then
    check "prod refusal mentions --i-mean-it on stderr" ok
else
    check "prod refusal mentions --i-mean-it on stderr" fail
fi
PROD_POST_SHA="$(find "$T_PROD_PARENT" -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null | shasum)"
if [ "$PROD_PRE_SHA" = "$PROD_POST_SHA" ]; then
    check "prod refusal left fixture unchanged" ok
else
    check "prod refusal left fixture unchanged" fail
fi
# <tier>data/ and <tier>-releases/ MUST NOT have been created.
if [ ! -d "$T_PROD_PARENT/proddata" ] && [ ! -d "$T_PROD_PARENT/prod-releases" ]; then
    check "prod refusal: no <tier>data/ or <tier>-releases/ created" ok
else
    check "prod refusal: no <tier>data/ or <tier>-releases/ created" fail
fi

# Now with --i-mean-it: should proceed (we use the fake-backup hook
# so we don't need a remote). Use a stub HTTP body matching the
# release-meta's expected substring.
set_http_body "<html><body>Version 0.2.0 · build 247</body></html>"
if BV_MIGRATE_LOCAL_PARENT="$T_PROD_PARENT" \
   BV_MIGRATE_BACKUP_FAKE=1 \
   BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
   "$MIGRATE_SH" prod --i-mean-it >"$WORK/t-prod-go.out" 2>"$WORK/t-prod-go.err"; then
    check "prod --i-mean-it proceeds end-to-end" ok
else
    check "prod --i-mean-it proceeds end-to-end (stderr in $WORK/t-prod-go.err)" fail
fi
if [ -L "$T_PROD_PARENT/prod" ]; then
    check "prod docroot is a symlink after --i-mean-it run" ok
else
    check "prod docroot is a symlink after --i-mean-it run" fail
fi

# ═════════════════════════════════════════════════════════════════════
# Test 4: Make-target prod refusal (the wrapper itself).
# `make migrate-atomic-prod` must refuse with a directive naming the
# direct invocation. (We pin option (b) — the Make target refuses
# entirely.)
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 4: make migrate-atomic-prod refuses with directive"

MAKE_OUT="$WORK/t-make.out"
if (cd "$REPO_ROOT" && make -s migrate-atomic-prod) >"$MAKE_OUT" 2>&1; then
    check "make migrate-atomic-prod returns non-zero" fail
else
    check "make migrate-atomic-prod returns non-zero" ok
fi
if grep -q -- "--i-mean-it" "$MAKE_OUT"; then
    check "make migrate-atomic-prod directive names --i-mean-it" ok
else
    check "make migrate-atomic-prod directive names --i-mean-it" fail
fi
if grep -q "deploy/migrate-to-atomic-layout.sh prod" "$MAKE_OUT"; then
    check "make migrate-atomic-prod directive shows direct invocation" ok
else
    check "make migrate-atomic-prod directive shows direct invocation" fail
fi
# make -n on the dev target prints the script invocation (dry-run).
DRY_OUT="$(cd "$REPO_ROOT" && make -n migrate-atomic-dev)"
if printf '%s' "$DRY_OUT" | grep -q "deploy/migrate-to-atomic-layout.sh dev"; then
    check "make -n migrate-atomic-dev prints script invocation with hardcoded env" ok
else
    check "make -n migrate-atomic-dev prints script invocation" fail
fi

# `make help` mentions the migrate targets and the one-time note.
HELP_OUT="$(cd "$REPO_ROOT" && make help)"
for t in migrate-atomic-dev migrate-atomic-test migrate-atomic-staging migrate-atomic-prod; do
    if printf '%s' "$HELP_OUT" | grep -q "$t"; then
        check "make help lists $t" ok
    else
        check "make help lists $t" fail
    fi
done
if printf '%s' "$HELP_OUT" | grep -qi "one-time"; then
    check "make help mentions 'one-time' note for migrate targets" ok
else
    check "make help mentions 'one-time' note" fail
fi

# ═════════════════════════════════════════════════════════════════════
# Test 5: Backup-failure abort BEFORE any state move.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 5: backup-failure aborts before any state move"

T_BAK_PARENT="$WORK/t-bak"
mkdir -p "$T_BAK_PARENT"
build_legacy_fixture "$T_BAK_PARENT" "$TIER"
PRE_BAK_SHA="$(find "$T_BAK_PARENT" -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null | shasum)"

if BV_MIGRATE_LOCAL_PARENT="$T_BAK_PARENT" \
   BV_MIGRATE_BACKUP_FAKE=1 \
   BV_MIGRATE_BACKUP_FAKE_FAIL=1 \
   "$MIGRATE_SH" "$TIER" >"$WORK/t-bak.out" 2>"$WORK/t-bak.err"; then
    check "backup failure causes non-zero migration exit" fail
else
    check "backup failure causes non-zero migration exit" ok
fi
# <tier>data/ MUST NOT have been created (= state move never started).
if [ ! -d "$T_BAK_PARENT/${TIER}data" ]; then
    check "backup failure: <tier>data/ not created (no state move)" ok
else
    check "backup failure: <tier>data/ not created" fail
fi
# Original tree fingerprint unchanged.
POST_BAK_SHA="$(find "$T_BAK_PARENT" -type f -print0 | sort -z | xargs -0 shasum 2>/dev/null | shasum)"
if [ "$PRE_BAK_SHA" = "$POST_BAK_SHA" ]; then
    check "backup failure: live tree unchanged" ok
else
    check "backup failure: live tree unchanged" fail
fi

# ═════════════════════════════════════════════════════════════════════
# Test 6: Smoke-probe failure on a fresh migration exits non-zero
# with a "restore from backup" hint.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 6: smoke-probe failure → exit non-zero + restore-from-backup hint"

T_SMK_PARENT="$WORK/t-smk"
mkdir -p "$T_SMK_PARENT"
build_legacy_fixture "$T_SMK_PARENT" "$TIER"

# Stub HTTP body that does NOT match the expected substring.
set_http_body "<html><body>Some other content</body></html>"

T_SMK_ERR="$WORK/t-smk.err"
if BV_MIGRATE_LOCAL_PARENT="$T_SMK_PARENT" \
   BV_MIGRATE_BACKUP_FAKE=1 \
   BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
   "$MIGRATE_SH" "$TIER" >"$WORK/t-smk.out" 2>"$T_SMK_ERR"; then
    check "smoke-probe mismatch causes non-zero exit" fail
else
    check "smoke-probe mismatch causes non-zero exit" ok
fi
if grep -qi 'restore' "$T_SMK_ERR" && grep -q 'backup' "$T_SMK_ERR"; then
    check "smoke-probe failure: stderr names 'restore' and 'backup' as recovery" ok
else
    check "smoke-probe failure: hint mentions restore/backup" fail
fi
# The migrated layout should still be live (no auto-rollback).
if [ -L "$T_SMK_PARENT/${TIER}" ]; then
    check "smoke-probe failure: docroot stays as a symlink (no auto-rollback)" ok
else
    check "smoke-probe failure: docroot stays as a symlink" fail
fi

# ═════════════════════════════════════════════════════════════════════
# Test 7: Full success path on a legacy fixture — bit-identity, layout
# shape, release-meta schema, offline-window budget, idempotence-on-
# rerun, backup invocation marker.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 7: full success path (bit-identity, schema, offline window)"

T_OK_PARENT="$WORK/t-ok"
mkdir -p "$T_OK_PARENT"
build_legacy_fixture "$T_OK_PARENT" "$TIER"

SHADOW="$WORK/t-ok-shadow"
snapshot_live_state "$T_OK_PARENT/${TIER}" "$SHADOW"
# Make the shadow read-only: any later mutation = test failure visible
# at next run rather than a silent data drift.
chmod -R a-w "$SHADOW"

# Stub HTTP body matches the expected substring.
set_http_body "<html><body>Version 0.2.0 · build 247</body></html>"

OK_BAK_MARKER="$WORK/t-ok-backup-invoked"
OK_TS_FILE="$WORK/t-ok-step6-ts"

T_OK_OUT="$WORK/t-ok.out"
T_OK_ERR="$WORK/t-ok.err"
if BV_MIGRATE_LOCAL_PARENT="$T_OK_PARENT" \
   BV_MIGRATE_BACKUP_FAKE=1 \
   BV_MIGRATE_BACKUP_INVOKED_MARKER="$OK_BAK_MARKER" \
   BV_MIGRATE_STEP_6_TIMESTAMP_FILE="$OK_TS_FILE" \
   BV_MIGRATE_DEPLOYED_BY="thomas@appforceone.dk" \
   BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
   "$MIGRATE_SH" "$TIER" >"$T_OK_OUT" 2>"$T_OK_ERR"; then
    check "migration exits 0 on success path" ok
else
    echo "    --- stderr ---" >&2
    cat "$T_OK_ERR" >&2 || true
    echo "    --- stdout ---" >&2
    cat "$T_OK_OUT" >&2 || true
    check "migration exits 0 on success path" fail
fi

# Backup invocation marker exists (proves step 2 ran).
if [ -e "$OK_BAK_MARKER" ]; then
    check "step 2: backup invocation marker created" ok
else
    check "step 2: backup invocation marker created" fail
fi

# Step-6 timestamp file exists with start/end/duration.
if grep -q '^start ' "$OK_TS_FILE" \
   && grep -q '^end ' "$OK_TS_FILE" \
   && grep -q '^duration_ms ' "$OK_TS_FILE"; then
    check "step 6: start/end/duration markers emitted" ok
else
    check "step 6: start/end/duration markers emitted" fail
fi
# Offline window bounded — < 10s on the fixture (the spec aims for
# single-digit-second).
DURATION_MS="$(awk '/^duration_ms / {print $2; exit}' "$OK_TS_FILE")"
case "$DURATION_MS" in
    ''|*[!0-9]*) DURATION_MS=99999 ;;
esac
if [ "$DURATION_MS" -lt 10000 ]; then
    check "step 6 offline window bounded (<10s, was ${DURATION_MS} ms)" ok
else
    check "step 6 offline window bounded (was ${DURATION_MS} ms)" fail
fi

# Layout assertions.
DOCROOT="$T_OK_PARENT/${TIER}"
DATA_DIR="$T_OK_PARENT/${TIER}data"
RELEASES_DIR="$T_OK_PARENT/${TIER}-releases"

if [ -L "$DOCROOT" ]; then
    check "<tier> is a symlink" ok
else
    check "<tier> is a symlink" fail
fi
if [ -d "$DATA_DIR/v0/user/accounts" ] \
   && [ -d "$DATA_DIR/v0/user/data" ] \
   && [ -d "$DATA_DIR/v0/user/config" ] \
   && [ -d "$DATA_DIR/v0/user/env/${TIER}/config" ] \
   && [ -d "$DATA_DIR/logs" ]; then
    check "<tier>data/v0/{user/accounts,data,config,env/<env>/config} + logs all exist" ok
else
    check "<tier>data/v0 subtree shape" fail
fi

# Bootstrap release dir exists, with shape `migrate-bootstrap-<ts>`.
BOOTSTRAP_DIR="$(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -name 'migrate-bootstrap-*' | head -1)"
if [ -n "$BOOTSTRAP_DIR" ] && [ -d "$BOOTSTRAP_DIR" ]; then
    check "bootstrap release dir exists with 'migrate-bootstrap-' prefix" ok
else
    check "bootstrap release dir exists" fail
fi
# Bootstrap id matches the strict shape.
BOOTSTRAP_ID="$(basename "$BOOTSTRAP_DIR")"
if printf '%s' "$BOOTSTRAP_ID" | grep -Eq '^migrate-bootstrap-[0-9]{8}T[0-9]{6}$'; then
    check "bootstrap id matches ^migrate-bootstrap-[0-9]{8}T[0-9]{6}$" ok
else
    check "bootstrap id shape ($BOOTSTRAP_ID)" fail
fi

# The bootstrap release contains the rest of the tree (code, themes,
# plugins, system, BUILD/VERSION, .htaccess) but NOT the live state
# (state moved to <tier>data/v0/, reachable only via symlinks).
for entry in index.php VERSION BUILD .htaccess system user/themes user/plugins cache; do
    if [ -e "$BOOTSTRAP_DIR/$entry" ]; then
        check "bootstrap contains '$entry'" ok
    else
        check "bootstrap contains '$entry'" fail
    fi
done
# State subtrees in the bootstrap dir are SYMLINKS, not real dirs.
for sym in user/accounts user/data logs user/config/security.yaml "user/env/${TIER}/config/security.yaml"; do
    if [ -L "$BOOTSTRAP_DIR/$sym" ]; then
        check "bootstrap '$sym' is a symlink (not a real entry)" ok
    else
        check "bootstrap '$sym' is a symlink" fail
    fi
done
# Symlink targets are relative (begin with '../').
for sym in user/accounts user/data logs user/config/security.yaml "user/env/${TIER}/config/security.yaml"; do
    target="$(readlink "$BOOTSTRAP_DIR/$sym" 2>/dev/null || echo "")"
    case "$target" in
        ../*) check "bootstrap '$sym' target is relative ('$target')" ok ;;
        *)    check "bootstrap '$sym' target relative (got '$target')" fail ;;
    esac
done
# Symlink targets do not contain the absolute fixture-root prefix.
for sym in user/accounts user/data logs user/config/security.yaml "user/env/${TIER}/config/security.yaml"; do
    target="$(readlink "$BOOTSTRAP_DIR/$sym" 2>/dev/null || echo "")"
    case "$target" in
        "$T_OK_PARENT"*|/*)
            check "bootstrap '$sym' target has no absolute prefix" fail ;;
        *)
            check "bootstrap '$sym' target has no absolute prefix" ok ;;
    esac
done

# release-meta.yaml exists with full §Audit schema; previous_release
# / previous_data_version are empty strings (this is the first
# release on the tier).
META="$BOOTSTRAP_DIR/release-meta.yaml"
if [ -f "$META" ]; then
    check "release-meta.yaml exists in bootstrap dir" ok
else
    check "release-meta.yaml exists in bootstrap dir" fail
fi
for field in release_id deployed_at deployed_by code_version build data_version previous_release previous_data_version swapped_at swap_duration_ms; do
    if grep -q "^$field:" "$META"; then
        check "release-meta has $field" ok
    else
        check "release-meta has $field" fail
    fi
done

# Value assertion for fields that should NOT be empty post-migration.
# (Test gap from earlier: a corrupted bv_yaml_quote_escape call would
# silently produce 'deployed_by: ""' and only the key-presence check
# above would fire ok — landed as `bvbv_yaml_quote_escape_escape: command
# not found` in production output. Now we assert non-empty values.)
for field in deployed_at deployed_by code_version build swapped_at; do
    val="$(awk -F': ' -v f="^$field:" '$0 ~ f {sub(/^[^:]+:[[:space:]]*/, ""); print; exit}' "$META")"
    # strip surrounding double-quotes if present
    val="${val#\"}"
    val="${val%\"}"
    if [ -n "$val" ]; then
        check "release-meta $field has a non-empty value (got: '$val')" ok
    else
        check "release-meta $field is empty — quoting helper may be broken" fail
    fi
done
# deployed_from sub-fields (host/cwd/branch/sha/sha_short) likewise.
for sub_field in host cwd branch sha sha_short; do
    val="$(awk -F': ' -v f="^  $sub_field:" '$0 ~ f {sub(/^[^:]+:[[:space:]]*/, ""); print; exit}' "$META")"
    val="${val#\"}"
    val="${val%\"}"
    if [ -n "$val" ]; then
        check "release-meta deployed_from.$sub_field has a non-empty value" ok
    else
        check "release-meta deployed_from.$sub_field is empty — quoting helper may be broken" fail
    fi
done
for sub in "  host:" "  cwd:" "  branch:" "  sha:" "  sha_short:" "  is_dirty:"; do
    if grep -q "^$sub" "$META"; then
        check "release-meta has deployed_from.$(echo "$sub" | tr -d ' :')" ok
    else
        check "release-meta has deployed_from.$(echo "$sub" | tr -d ' :')" fail
    fi
done
for sub in "  url:" "  status:" "  expected_version_substring:" "  matched:"; do
    if grep -q "^$sub" "$META"; then
        check "release-meta has smoke_probe.$(echo "$sub" | tr -d ' :')" ok
    else
        check "release-meta has smoke_probe.$(echo "$sub" | tr -d ' :')" fail
    fi
done
# previous_release and previous_data_version are empty strings.
if grep -Eq '^previous_release: ""$' "$META"; then
    check "release-meta previous_release is empty string" ok
else
    check "release-meta previous_release is empty string" fail
fi
if grep -Eq '^previous_data_version: ""$' "$META"; then
    check "release-meta previous_data_version is empty string" ok
else
    check "release-meta previous_data_version is empty string" fail
fi
# data_version = v0
if grep -Eq '^data_version: "v0"$' "$META"; then
    check "release-meta data_version is 'v0'" ok
else
    check "release-meta data_version is 'v0'" fail
fi
# release_id matches the bootstrap regex.
if grep -Eq "^release_id: ${BOOTSTRAP_ID}$" "$META"; then
    check "release-meta release_id matches bootstrap dir name" ok
else
    check "release-meta release_id matches bootstrap dir name" fail
fi
# is_dirty is unquoted boolean.
if grep -Eq '^  is_dirty: (true|false)$' "$META"; then
    check "release-meta is_dirty is unquoted YAML boolean" ok
else
    check "release-meta is_dirty is unquoted boolean" fail
fi
# swap_duration_ms is unquoted integer.
if grep -Eq '^swap_duration_ms: [0-9]+$' "$META"; then
    check "release-meta swap_duration_ms is unquoted integer" ok
else
    check "release-meta swap_duration_ms is unquoted integer" fail
fi
# smoke_probe.status is a 3-digit integer (or 0; here 200 since we
# stubbed the HTTP body to match).
status_val="$(awk '/^  status: / {print $2; exit}' "$META")"
case "$status_val" in
    [0-9][0-9][0-9]) check "release-meta smoke_probe.status is a 3-digit integer" ok ;;
    *)               check "smoke_probe.status is a 3-digit integer (got '$status_val')" fail ;;
esac
# matched: true on the success path (HTTP body matched the substring).
matched_val="$(awk '/^  matched: / {print $2; exit}' "$META")"
if [ "$matched_val" = "true" ]; then
    check "release-meta smoke_probe.matched=true on success path" ok
else
    check "smoke_probe.matched=true (got '$matched_val')" fail
fi

# release-meta.yaml mtime predates the swap-completion (i.e. it was
# written BEFORE step 6's atomic swap touched the docroot).
META_MTIME="$(stat -f %m "$META" 2>/dev/null || stat -c %Y "$META" 2>/dev/null)"
DOCROOT_MTIME="$(stat -f %m "$DOCROOT" 2>/dev/null || stat -c %Y "$DOCROOT" 2>/dev/null)"
# The check is "META_MTIME <= DOCROOT_MTIME" — they may be equal at
# fixture speed, but META must never come AFTER DOCROOT.
if [ -n "$META_MTIME" ] && [ -n "$DOCROOT_MTIME" ] && [ "$META_MTIME" -le "$DOCROOT_MTIME" ]; then
    check "release-meta.yaml mtime is <= docroot symlink mtime (writer ran before swap)" ok
else
    check "release-meta mtime ordering (meta=$META_MTIME, docroot=$DOCROOT_MTIME)" fail
fi

# ─── BIT-IDENTITY ─────────────────────────────────────────────────
# Resolve every shadowed file via the wired symlink chain (i.e. read
# them through <tier>/, which symlinks to <bootstrap>, whose state
# symlinks point into <tier>data/v0/).
#
# The cmp_live_state helper walks the shadow snapshot and asserts
# every file matches via cmp -s. A single mismatch breaks the run.
echo ""
echo "  → bit-identity check (cmp -s on every live-state file)..."
mismatch_count="$(cmp_live_state "$SHADOW" "$DOCROOT")"
if [ "$mismatch_count" = "0" ]; then
    check "every live-state file is bit-identical pre/post (cmp -s)" ok
else
    check "live-state bit-identity (${mismatch_count} mismatches)" fail
fi

# ═════════════════════════════════════════════════════════════════════
# Test 8: Idempotence guard — re-run on the now-atomic tier exits
# non-zero with the "already" / "atomic" diagnostic. No on-disk
# corruption. backup.sh is NOT invoked on the failed re-run (the
# guard fires BEFORE step 2).
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 8: idempotence guard — re-run refused, backup not called"

PRE_RERUN_SHA="$(find "$T_OK_PARENT/${TIER}-releases" "$T_OK_PARENT/${TIER}data" -type f -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null | shasum)"
PRE_RERUN_DATA_MTIME="$(stat -f %m "$T_OK_PARENT/${TIER}data" 2>/dev/null || stat -c %Y "$T_OK_PARENT/${TIER}data" 2>/dev/null)"

RERUN_BAK_MARKER="$WORK/t-rerun-backup-invoked"
T_RERUN_ERR="$WORK/t-rerun.err"
if BV_MIGRATE_LOCAL_PARENT="$T_OK_PARENT" \
   BV_MIGRATE_BACKUP_FAKE=1 \
   BV_MIGRATE_BACKUP_INVOKED_MARKER="$RERUN_BAK_MARKER" \
   BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
   "$MIGRATE_SH" "$TIER" >"$WORK/t-rerun.out" 2>"$T_RERUN_ERR"; then
    check "re-run on atomic tier returns non-zero" fail
else
    check "re-run on atomic tier returns non-zero" ok
fi
# Diagnostic mentions 'already' or 'atomic'.
if grep -qiE 'already|atomic' "$T_RERUN_ERR"; then
    check "re-run diagnostic mentions 'already' or 'atomic'" ok
else
    check "re-run diagnostic mentions 'already'/'atomic'" fail
fi
# Backup was NOT invoked on the re-run (idempotence guard fires before step 2).
if [ ! -e "$RERUN_BAK_MARKER" ]; then
    check "re-run did not invoke backup.sh (guard fires before step 2)" ok
else
    check "re-run invoked backup.sh" fail
fi
# On-disk fingerprint unchanged.
POST_RERUN_SHA="$(find "$T_OK_PARENT/${TIER}-releases" "$T_OK_PARENT/${TIER}data" -type f -print0 2>/dev/null | sort -z | xargs -0 shasum 2>/dev/null | shasum)"
if [ "$PRE_RERUN_SHA" = "$POST_RERUN_SHA" ]; then
    check "re-run did not corrupt on-disk content" ok
else
    check "re-run did not corrupt on-disk content" fail
fi
POST_RERUN_DATA_MTIME="$(stat -f %m "$T_OK_PARENT/${TIER}data" 2>/dev/null || stat -c %Y "$T_OK_PARENT/${TIER}data" 2>/dev/null)"
if [ "$PRE_RERUN_DATA_MTIME" = "$POST_RERUN_DATA_MTIME" ]; then
    check "re-run did not change <tier>data/ mtime" ok
else
    check "re-run did not change <tier>data/ mtime" fail
fi

# ═════════════════════════════════════════════════════════════════════
# Test 9: Mixed-signal state (broken/partial migration) gets a
# distinct diagnostic.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 9: mixed-signal state (partial migration) is refused with distinct diagnostic"

T_MIX_PARENT="$WORK/t-mix"
mkdir -p "$T_MIX_PARENT/${TIER}"           # docroot is a real dir
mkdir -p "$T_MIX_PARENT/${TIER}data/v0/user/accounts"   # but <tier>data/ already exists

T_MIX_ERR="$WORK/t-mix.err"
if BV_MIGRATE_LOCAL_PARENT="$T_MIX_PARENT" \
   BV_MIGRATE_BACKUP_FAKE=1 \
   "$MIGRATE_SH" "$TIER" >"$WORK/t-mix.out" 2>"$T_MIX_ERR"; then
    check "mixed-signal state returns non-zero" fail
else
    check "mixed-signal state returns non-zero" ok
fi
if grep -qi 'mixed' "$T_MIX_ERR" || grep -qi 'partial' "$T_MIX_ERR" || grep -qi 'inconsist' "$T_MIX_ERR"; then
    check "mixed-signal diagnostic distinct from clean 'already migrated'" ok
else
    check "mixed-signal diagnostic distinct from 'already migrated'" fail
fi

# ═════════════════════════════════════════════════════════════════════
# Test 10: Real-mode integration — the existing deploy/backup.sh
# fixture path produces a backup-meta.yaml; assert it validates
# against deploy/schemas/backup-meta.schema.yaml. (We exercise the
# schema validation end-to-end via the same code path the bats test
# uses: the lightweight required-key check from
# tests/deploy/backup-restore.bats's "schema sanity" block.)
#
# We don't drive backup.sh THROUGH the migration script in real mode
# (the migration would also need a real ssh remote which we don't
# have); instead we drive backup.sh directly with its existing
# fixture knobs and validate the meta. This satisfies the contract's
# "backup.sh integration" criterion: the existing entry point is
# unchanged and produces a schema-valid backup-meta.yaml.
# ═════════════════════════════════════════════════════════════════════
echo ""
echo "Test 10: real-mode backup.sh produces schema-valid backup-meta.yaml"

T_BAK_REAL="$WORK/t-bak-real"
mkdir -p "$T_BAK_REAL/source/user/accounts" \
         "$T_BAK_REAL/source/user/data/flex-objects" \
         "$T_BAK_REAL/source/user/config" \
         "$T_BAK_REAL/store"
echo '0.1.0' > "$T_BAK_REAL/source/VERSION"
echo '247'   > "$T_BAK_REAL/source/BUILD"
cat > "$T_BAK_REAL/source/user/config/data-version.yaml" <<'YAML'
data_version: "0.1.0"
YAML
echo "alice" > "$T_BAK_REAL/source/user/accounts/alice.yaml"
echo '{"votes":1}' > "$T_BAK_REAL/source/user/data/flex-objects/feature-1.json"

# Generate a one-shot age recipient pair so backup.sh's encryption
# step works. Test the public key only — private key is created and
# discarded inline.
AGE_KEYFILE="$T_BAK_REAL/age-key.txt"
if command -v age-keygen >/dev/null 2>&1; then
    age-keygen -o "$AGE_KEYFILE" 2>/dev/null
    AGE_PUB="$(awk '/^# public key:/ {print $4}' "$AGE_KEYFILE")"
fi

if [ -z "${AGE_PUB:-}" ]; then
    check "real backup.sh test: age-keygen present (skipping if not)" fail
else
    AGE_RECIPIENTS="$T_BAK_REAL/age-recipients.txt"
    printf '%s\n' "$AGE_PUB" > "$AGE_RECIPIENTS"

    # Run backup.sh in fixture mode.
    SCHEMA_TMP_OUT="$WORK/t-bak-real.out"
    SCHEMA_TMP_ERR="$WORK/t-bak-real.err"
    if BACKUP_FIXTURE_DIR="$T_BAK_REAL/source" \
       BACKUP_LOCAL_STORE_DIR="$T_BAK_REAL/store" \
       BACKUP_RECIPIENTS_FILE="$AGE_RECIPIENTS" \
       BACKUP_FAKE_NOW_EPOCH=1714392840 \
       BACKUP_SOURCE_HOST="fixture.local" \
       "$BACKUP_SH" dev >"$SCHEMA_TMP_OUT" 2>"$SCHEMA_TMP_ERR"; then
        check "real backup.sh produces an archive in fixture mode" ok
    else
        echo "    --- backup.sh stderr ---" >&2
        cat "$SCHEMA_TMP_ERR" >&2 || true
        check "real backup.sh produces an archive in fixture mode" fail
    fi

    # Decrypt the produced archive, extract backup-meta.yaml, validate
    # against the schema's required-keys list (same lightweight
    # validation the bats test uses).
    ARCHIVE="$(find "$T_BAK_REAL/store" -maxdepth 1 -type f -name '*.tar.gz.age' | head -1)"
    if [ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ]; then
        check "backup archive landed in BACKUP_LOCAL_STORE_DIR" ok
        SCRATCH="$WORK/t-bak-scratch"
        mkdir -p "$SCRATCH"
        # Decrypt with the test private key.
        if age -d -i "$AGE_KEYFILE" -o "$SCRATCH/archive.tar.gz" "$ARCHIVE" 2>/dev/null \
           && tar -xzf "$SCRATCH/archive.tar.gz" -C "$SCRATCH"; then
            META_BAK="$SCRATCH/backup-meta.yaml"
            if [ -f "$META_BAK" ]; then
                check "backup-meta.yaml present at archive root" ok
                # Extract required keys from the schema.
                REQ_KEYS="$(awk '
                    /^required:/ { in_req=1; next }
                    /^[a-zA-Z]/  { in_req=0 }
                    in_req && /^  - / { sub(/^  - /, ""); print }
                ' "$BACKUP_SCHEMA")"
                missing=0
                for key in $REQ_KEYS; do
                    if grep -qE "^${key}: " "$META_BAK"; then
                        :
                    else
                        echo "    missing required key '$key' in backup-meta.yaml" >&2
                        missing=$((missing+1))
                    fi
                done
                if [ "$missing" = "0" ]; then
                    check "backup-meta.yaml contains every required schema key" ok
                else
                    check "backup-meta.yaml schema validation (missing $missing key(s))" fail
                fi
                # producer must be deploy/backup.sh per the const in
                # the schema.
                if grep -qE '^producer: "deploy/backup\.sh"$' "$META_BAK"; then
                    check "backup-meta.yaml producer == 'deploy/backup.sh'" ok
                else
                    check "backup-meta.yaml producer matches schema const" fail
                fi
            else
                check "backup-meta.yaml present at archive root" fail
            fi
        else
            check "decrypt + extract backup archive" fail
        fi
    else
        check "backup archive landed in BACKUP_LOCAL_STORE_DIR" fail
    fi
fi

# Restore write permissions on the shadow so the trap can rm it.
chmod -R u+w "$SHADOW" 2>/dev/null || true

# ═════════════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────"
echo "  Pass: ${PASS}    Fail: ${FAIL}"
echo "─────────────────────────────────────"

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
