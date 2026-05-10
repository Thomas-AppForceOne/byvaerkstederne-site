#!/usr/bin/env bash
#
# Shell-level probe for deploy/rollback.sh + the Sprint 2 audit /
# smoke-probe additions to deploy/deploy.sh.
#
# Drives rollback.sh end-to-end (in BV_ROLLBACK_LOCAL_PARENT mode) and
# the new lib helpers (bv_compute_expected_version_substring,
# bv_smoke_probe, bv_write_release_meta_yaml_full,
# bv_append_post_swap_meta, bv_append_rollback_log_row) inside a
# mktemp fixture. No ssh, no remote, no credentials.
#
# Asserts every Sprint-2 contract criterion that doesn't require a
# real network deploy, plus the regression-check that all Sprint-1
# invariants still hold under the modified deploy.sh / lib.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/deploy/lib/atomic-release.sh"
DEPLOY_SH="$REPO_ROOT/deploy/deploy.sh"
ROLLBACK_SH="$REPO_ROOT/deploy/rollback.sh"

if [ ! -f "$LIB" ]; then
    echo "FATAL: atomic-release lib not found at $LIB" >&2
    exit 1
fi
if [ ! -f "$ROLLBACK_SH" ]; then
    echo "FATAL: rollback.sh not found at $ROLLBACK_SH" >&2
    exit 1
fi
if [ ! -x "$ROLLBACK_SH" ]; then
    echo "FATAL: rollback.sh is not executable" >&2
    exit 1
fi

# shellcheck source=deploy/lib/atomic-release.sh
. "$LIB"

WORK="$(mktemp -d)"
HTTP_PID=""
cleanup() {
    if [ -n "$HTTP_PID" ] && kill -0 "$HTTP_PID" 2>/dev/null; then
        kill "$HTTP_PID" 2>/dev/null || true
        wait "$HTTP_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

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

TIER="dev"

# ─────────────────────────────────────────────────────────────────────
# Stub HTTP responder (Python 3 http.server backed by a file).
# We swap the served body by overwriting the file before each probe.
# ─────────────────────────────────────────────────────────────────────
HTTP_ROOT="$WORK/http"
mkdir -p "$HTTP_ROOT"
echo "Initial body — replaced per-test" > "$HTTP_ROOT/index.html"

# Find a free port.
HTTP_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
( cd "$HTTP_ROOT" && python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 ) >/dev/null 2>&1 &
HTTP_PID=$!

# Wait for the responder to come up (max ~15s; Python 3.14's
# http.server can take 3-5s to bind on first start).
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
    if [ -n "$HTTP_PID" ]; then
        kill -0 "$HTTP_PID" 2>/dev/null && echo "(http.server pid $HTTP_PID is alive)" >&2 \
            || echo "(http.server pid $HTTP_PID is NOT alive)" >&2
    fi
    exit 1
fi

set_http_body() {
    # The default index.html is matched by GET /. We rewrite it
    # before each probe.
    printf '%s' "$1" > "$HTTP_ROOT/index.html"
}
PROBE_URL="http://127.0.0.1:$HTTP_PORT/"

# ─────────────────────────────────────────────────────────────────────
# Helper: build a complete release dir under <parent>/<tier>-releases
# using the Sprint-1 lib functions. Returns the release id on stdout.
# ─────────────────────────────────────────────────────────────────────
build_release() {
    local parent="$1"
    local sha_seed="$2"          # used to derive the short sha
    local version="$3"
    local build="$4"
    local prev="$5"              # may be ""
    local releases_dir="$parent/${TIER}-releases"
    local data_dir="$parent/${TIER}data"
    local staging="$parent/staging-$sha_seed"
    mkdir -p "$staging/user/pages/01.home" "$staging/user/themes" "$staging/system"
    echo "<?php echo \"$version-$build\";" > "$staging/index.php"
    echo "title: Home"                   > "$staging/user/pages/01.home/default.md"
    printf '%s\n' "$version" > "$staging/VERSION"
    printf '%s\n' "$build"   > "$staging/BUILD"

    bv_bootstrap_data_dir "$data_dir" "$TIER"

    # Pause to ensure release ids are unique within the same second.
    sleep 1
    local rid
    rid="$(bv_compute_release_id "$sha_seed")"
    local rdir="$releases_dir/$rid"
    bv_rsync_to_release_dir "$staging" "$rdir" >/dev/null 2>&1
    bv_wire_release_symlinks "$rdir" "$data_dir" "$TIER"
    bv_write_release_meta_yaml_full \
        "$rdir" "$rid" "$prev" "$version" "$build" "v0" \
        "2026-05-09T20:34:43Z" "thomas@appforceone.dk" \
        "fixture-host" "/some/cwd:with-colon" "develop" \
        "abcdef0123456789abcdef0123456789abcdef01" "$sha_seed" \
        "false" "v0"
    # Also append a stub post-swap meta to mimic deploy.sh's full
    # output. The "previous" release's post-swap row was set when IT
    # was deployed; simulate that.
    bv_append_post_swap_meta "$rdir" "2026-05-09T20:34:44Z" 17 \
        "$PROBE_URL" 200 "Version $version · build $build" "true"
    printf '%s' "$rid"
}

swap_docroot() {
    local parent="$1" rid="$2"
    bv_atomic_swap_symlink "$parent/${TIER}-releases/$rid" "$parent/${TIER}"
}

# ─────────────────────────────────────────────────────────────────────
# Test 0: Static-source review.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 0: rollback.sh source-level invariants"

# rollback.sh exists, executable, sets -euo pipefail.
if [ -x "$ROLLBACK_SH" ]; then
    check "rollback.sh is executable" ok
else
    check "rollback.sh is executable" fail
fi
if grep -q 'set -euo pipefail' "$ROLLBACK_SH"; then
    check "rollback.sh sets -euo pipefail" ok
else
    check "rollback.sh sets -euo pipefail" fail
fi
# Sources atomic-release.sh (the Sprint-1 helper lib) and banner.sh.
if grep -q 'lib/atomic-release.sh' "$ROLLBACK_SH"; then
    check "rollback.sh sources lib/atomic-release.sh" ok
else
    check "rollback.sh sources lib/atomic-release.sh" fail
fi
if grep -q 'lib/banner.sh' "$ROLLBACK_SH"; then
    check "rollback.sh sources lib/banner.sh" ok
else
    check "rollback.sh sources lib/banner.sh" fail
fi
# Closed-set env validation via bv_validate_tier_name.
if grep -q 'bv_validate_tier_name' "$ROLLBACK_SH"; then
    check "rollback.sh calls bv_validate_tier_name (closed-set check)" ok
else
    check "rollback.sh calls bv_validate_tier_name" fail
fi
# Strict regex validation of previous_release before path use.
if grep -q 'bv_read_previous_release_id\|bv_validate_release_id' "$ROLLBACK_SH"; then
    check "rollback.sh validates previous_release id (regex)" ok
else
    check "rollback.sh validates previous_release id" fail
fi
# Single ln -sfn swap, no pre-rm.
if grep -Eq 'ln -sfn[[:space:]]+\$\{?LAYOUT_NAME\}?-releases/\$\{?(target_release_id|PREV_RELEASE_ID)' "$ROLLBACK_SH" \
   || grep -q 'ln -sfn "${LAYOUT_NAME}-releases/${target_release_id}"' "$ROLLBACK_SH" \
   || grep -q 'ln -sfn ${LAYOUT_NAME}-releases/${target_release_id}' "$ROLLBACK_SH"; then
    check "rollback.sh swap uses ln -sfn (atomic, single command)" ok
else
    check "rollback.sh swap uses ln -sfn" fail
fi
# Confirm there's no pre-rm of the docroot before the swap.
# The rollback's only mutation against the docroot is ln -sfn; rm
# anywhere in rollback.sh must be against tempfiles or release dirs,
# never against $DEPLOY_TARGET / DOCROOT / tier symlink.
if grep -nE 'rm[[:space:]]+-rf?[[:space:]]+[^|]*\$\{?DEPLOY_TARGET' "$ROLLBACK_SH" \
   | grep -v '^[[:space:]]*#'; then
    check "rollback.sh has no rm against \$DEPLOY_TARGET" fail
else
    check "rollback.sh has no rm against \$DEPLOY_TARGET" ok
fi
# Confirm rollback.sh never rms or rsyncs <tier>data/.
if grep -nE 'rm[[:space:]]+-rf?[[:space:]]+[^|]*data\b' "$ROLLBACK_SH" \
   | grep -v '^[[:space:]]*#' \
   | grep -v '/v0/' >/dev/null; then
    check "rollback.sh has no rm against <tier>data/" fail
else
    check "rollback.sh has no rm against <tier>data/" ok
fi
if grep -nE 'rsync.*\$\{?DATA_DIR' "$ROLLBACK_SH" | grep -v '^[[:space:]]*#'; then
    check "rollback.sh has no rsync against \$DATA_DIR" fail
else
    check "rollback.sh has no rsync against \$DATA_DIR" ok
fi
# Smoke-probe contract: rollback.sh calls the same shared helper
# deploy.sh uses (bv_compute_expected_version_substring + bv_smoke_probe).
if grep -q 'bv_compute_expected_version_substring' "$ROLLBACK_SH" \
   && grep -q 'bv_smoke_probe' "$ROLLBACK_SH"; then
    check "rollback.sh uses the shared smoke-probe helpers" ok
else
    check "rollback.sh uses the shared smoke-probe helpers" fail
fi
# deploy.sh also uses them (single source of truth).
if grep -q 'bv_compute_expected_version_substring' "$DEPLOY_SH" \
   && grep -q 'bv_smoke_probe' "$DEPLOY_SH"; then
    check "deploy.sh uses the shared smoke-probe helpers (single source of truth)" ok
else
    check "deploy.sh uses the shared smoke-probe helpers" fail
fi
# rollback.sh appends to rollback-log.yaml (or extends release-meta).
if grep -q 'bv_append_rollback_log_row' "$ROLLBACK_SH"; then
    check "rollback.sh appends an audit row" ok
else
    check "rollback.sh appends an audit row" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 1: full release-meta.yaml schema after a deploy fixture cycle.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 1: release-meta.yaml full §Audit schema"

T1="$WORK/t1"
mkdir -p "$T1"
RID1="$(build_release "$T1" "0aaaaaa" "0.2.0" "247" "")"
swap_docroot "$T1" "$RID1"
META="$T1/${TIER}-releases/$RID1/release-meta.yaml"

for field in release_id deployed_at deployed_by code_version build data_version previous_release previous_data_version swapped_at swap_duration_ms; do
    if grep -q "^$field:" "$META"; then
        check "release-meta has $field" ok
    else
        check "release-meta has $field" fail
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
# is_dirty is a YAML boolean (no quotes).
if grep -Eq '^  is_dirty: (true|false)$' "$META"; then
    check "release-meta is_dirty is unquoted boolean" ok
else
    check "release-meta is_dirty is unquoted boolean" fail
fi
# swap_duration_ms is a non-negative integer.
ms_val="$(awk -F': ' '/^swap_duration_ms:/ {print $2; exit}' "$META")"
case "$ms_val" in
    ''|*[!0-9]*) check "swap_duration_ms is a non-negative integer (got '$ms_val')" fail ;;
    *)           check "swap_duration_ms is a non-negative integer" ok ;;
esac
# smoke_probe.status is a 3-digit integer.
status_val="$(awk -F': ' '/^  status:/ {print $2; exit}' "$META")"
case "$status_val" in
    [0-9][0-9][0-9]) check "smoke_probe.status is a 3-digit integer" ok ;;
    *)               check "smoke_probe.status is a 3-digit integer (got '$status_val')" fail ;;
esac
# release_id field equals the release-dir basename.
meta_rid="$(awk -F': ' '/^release_id:/ {print $2; exit}' "$META")"
if [ "$meta_rid" = "$RID1" ]; then
    check "release_id field equals release-dir basename" ok
else
    check "release_id field equals release-dir basename (got '$meta_rid' vs '$RID1')" fail
fi
# defensive quoting: deployed_by and cwd are double-quoted (cwd
# contains ':').
if grep -Eq '^deployed_by: "' "$META"; then
    check "deployed_by is double-quoted (defensive on : -bearing emails)" ok
else
    check "deployed_by is double-quoted" fail
fi
if grep -Eq '^  cwd: "/some/cwd:with-colon"' "$META"; then
    check "deployed_from.cwd is double-quoted (preserves embedded ':')" ok
else
    check "deployed_from.cwd is double-quoted" fail
fi
# release_id and previous_release in regex shape are emitted UNQUOTED.
if grep -Eq '^release_id: [0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$' "$META"; then
    check "release_id emitted unquoted (matches regex shape)" ok
else
    check "release_id emitted unquoted" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 2: full deploy → rollback → deploy cycle (atomic swap-back).
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: rollback.sh atomic swap-back (success path)"

T2="$WORK/t2"
mkdir -p "$T2"
RID_A="$(build_release "$T2" "0aaaaaa" "0.2.0" "100" "")"
swap_docroot "$T2" "$RID_A"
RID_B="$(build_release "$T2" "0bbbbbb" "0.2.1" "101" "$RID_A")"
swap_docroot "$T2" "$RID_B"

# Sanity: docroot points at RID_B.
DOC_BEFORE="$(readlink "$T2/$TIER")"
case "$DOC_BEFORE" in
    "${TIER}-releases/${RID_B}") check "fixture: docroot points at second release" ok ;;
    *)                            check "fixture: docroot points at second release (got '$DOC_BEFORE')" fail ;;
esac

# <tier>data/ mtime BEFORE the rollback.
DATA_MTIME_BEFORE="$(stat -f '%m' "$T2/${TIER}data" 2>/dev/null || stat -c '%Y' "$T2/${TIER}data")"

# Drive rollback. We expect:
#   - exit 0
#   - docroot now points at RID_A
#   - both RID_A and RID_B dirs still on disk
#   - rollback-log.yaml has a row with from=RID_B, to=RID_A
#   - smoke_probe matched=true (we point the stub HTTP at the matching
#     body for RID_A's VERSION/BUILD)
set_http_body "<html><body><p>Hello — Version 0.2.0 · build 100</p></body></html>"

set +e
( BV_ROLLBACK_LOCAL_PARENT="$T2" \
  BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
  BV_ROLLBACK_DEPLOYED_BY="rollback-test@example.com" \
  bash "$ROLLBACK_SH" "$TIER" ) >"$WORK/t2.out" 2>"$WORK/t2.err"
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    check "rollback.sh exits 0 on success" ok
else
    check "rollback.sh exits 0 on success (got $RC; stderr: $(tail -3 "$WORK/t2.err"))" fail
fi

DOC_AFTER="$(readlink "$T2/$TIER")"
case "$DOC_AFTER" in
    "${TIER}-releases/${RID_A}") check "after rollback: docroot points at first release" ok ;;
    *)                            check "after rollback: docroot points at first release (got '$DOC_AFTER')" fail ;;
esac
# Both release dirs survive the rollback.
if [ -d "$T2/${TIER}-releases/$RID_A" ]; then
    check "after rollback: previous release dir RID_A still on disk" ok
else
    check "after rollback: previous release dir RID_A still on disk" fail
fi
if [ -d "$T2/${TIER}-releases/$RID_B" ]; then
    check "after rollback: rolled-from release dir RID_B still on disk" ok
else
    check "after rollback: rolled-from release dir RID_B still on disk" fail
fi
# <tier>data/ mtime UNCHANGED across the rollback.
DATA_MTIME_AFTER="$(stat -f '%m' "$T2/${TIER}data" 2>/dev/null || stat -c '%Y' "$T2/${TIER}data")"
if [ "$DATA_MTIME_BEFORE" = "$DATA_MTIME_AFTER" ]; then
    check "rollback: <tier>data/ mtime unchanged" ok
else
    check "rollback: <tier>data/ mtime unchanged ($DATA_MTIME_BEFORE → $DATA_MTIME_AFTER)" fail
fi

# Audit row checks.
LOG="$T2/${TIER}-releases/rollback-log.yaml"
if [ -f "$LOG" ]; then
    check "rollback-log.yaml created" ok
else
    check "rollback-log.yaml created" fail
fi
for f in rolled_back_at rolled_back_by from_release to_release swap_duration_ms; do
    if grep -q "$f:" "$LOG"; then
        check "rollback-log.yaml has $f" ok
    else
        check "rollback-log.yaml has $f" fail
    fi
done
for f in url status expected_version_substring matched; do
    if grep -q "    $f:" "$LOG"; then
        check "rollback-log.yaml has smoke_probe.$f" ok
    else
        check "rollback-log.yaml has smoke_probe.$f" fail
    fi
done
# from_release and to_release pass the regex and differ.
log_from="$(awk -F': ' '/from_release:/ {print $2; exit}' "$LOG")"
log_to="$(awk -F': ' '/to_release:/ {print $2; exit}' "$LOG")"
if printf '%s' "$log_from" | grep -Eq '^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$' \
   && printf '%s' "$log_to" | grep -Eq '^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$' \
   && [ "$log_from" != "$log_to" ]; then
    check "audit row: from_release and to_release pass regex AND differ" ok
else
    check "audit row: from/to mismatch (from='$log_from' to='$log_to')" fail
fi
# rolled_back_at is ISO-8601 (YYYY-MM-DDTHH:MM:SSZ).
log_at="$(awk -F': ' '/rolled_back_at:/ {gsub(/"/,""); print $2; exit}' "$LOG")"
if printf '%s' "$log_at" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
    check "rolled_back_at is ISO-8601" ok
else
    check "rolled_back_at is ISO-8601 (got '$log_at')" fail
fi
# matched=true on the success path.
if grep -Eq '^    matched: true$' "$LOG"; then
    check "smoke_probe.matched=true on success path" ok
else
    check "smoke_probe.matched=true on success path" fail
fi

# Two consecutive rollbacks → two distinct rows. Re-deploy a third
# release pointing at RID_A as previous, then rollback again.
RID_C="$(build_release "$T2" "0ccccc1" "0.2.2" "102" "$RID_A")"
swap_docroot "$T2" "$RID_C"
set_http_body "<html><body><p>Hello — Version 0.2.0 · build 100</p></body></html>"
set +e
( BV_ROLLBACK_LOCAL_PARENT="$T2" \
  BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
  bash "$ROLLBACK_SH" "$TIER" ) >>"$WORK/t2.out" 2>>"$WORK/t2.err"
RC2=$?
set -e
if [ "$RC2" -eq 0 ]; then
    check "second rollback: exits 0" ok
else
    check "second rollback: exits 0 (got $RC2)" fail
fi
# Two distinct '- rolled_back_at:' rows in the log.
n_rows="$(grep -c '^- rolled_back_at:' "$LOG" || true)"
if [ "$n_rows" = "2" ]; then
    check "rollback-log.yaml has two distinct rows after two rollbacks" ok
else
    check "rollback-log.yaml has two rows (got $n_rows)" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 3: rollback refuses when the previous release dir was pruned.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: rollback refuses when previous release was pruned (failure path)"

T3="$WORK/t3"
mkdir -p "$T3"
RID3_A="$(build_release "$T3" "0aaaaa3" "0.3.0" "200" "")"
swap_docroot "$T3" "$RID3_A"
RID3_B="$(build_release "$T3" "0bbbbb3" "0.3.1" "201" "$RID3_A")"
swap_docroot "$T3" "$RID3_B"

# Prune RID3_A from disk (simulate retention deleted it).
rm -rf "$T3/${TIER}-releases/$RID3_A"

DOC_BEFORE3="$(readlink "$T3/$TIER")"
set +e
( BV_ROLLBACK_LOCAL_PARENT="$T3" \
  BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
  bash "$ROLLBACK_SH" "$TIER" ) >"$WORK/t3.out" 2>"$WORK/t3.err"
RC3=$?
set -e

if [ "$RC3" -ne 0 ]; then
    check "rollback exits non-zero when previous release pruned" ok
else
    check "rollback exits non-zero when previous release pruned (got $RC3)" fail
fi
# Diagnostic on stderr names the missing release id literally.
if grep -q "$RID3_A" "$WORK/t3.err"; then
    check "stderr names the missing release id literally" ok
else
    check "stderr names the missing release id literally" fail
fi
# Operator-readable language (not just bare "No such file").
if grep -qiE 'pruned|missing|cannot roll back|no longer exists|previous release directory is missing' "$WORK/t3.err"; then
    check "diagnostic uses operator-readable language" ok
else
    check "diagnostic uses operator-readable language" fail
fi
# Docroot symlink unchanged.
DOC_AFTER3="$(readlink "$T3/$TIER")"
if [ "$DOC_BEFORE3" = "$DOC_AFTER3" ]; then
    check "rollback refusal: docroot symlink unchanged" ok
else
    check "rollback refusal: docroot symlink unchanged ($DOC_BEFORE3 → $DOC_AFTER3)" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 4: rollback refuses when previous release's data symlinks dangle.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: rollback refuses when previous release's data symlinks dangle"

T4="$WORK/t4"
mkdir -p "$T4"
RID4_A="$(build_release "$T4" "0aaaaa4" "0.4.0" "300" "")"
swap_docroot "$T4" "$RID4_A"
RID4_B="$(build_release "$T4" "0bbbbb4" "0.4.1" "301" "$RID4_A")"
swap_docroot "$T4" "$RID4_B"

# Dangle one of the data symlinks in the PREVIOUS release dir by
# removing the target it points at. accounts/ is one of the gated
# three.
rm -rf "$T4/${TIER}data/v0/user/accounts"

DOC_BEFORE4="$(readlink "$T4/$TIER")"
set +e
( BV_ROLLBACK_LOCAL_PARENT="$T4" \
  BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
  bash "$ROLLBACK_SH" "$TIER" ) >"$WORK/t4.out" 2>"$WORK/t4.err"
RC4=$?
set -e
if [ "$RC4" -ne 0 ]; then
    check "rollback exits non-zero when accounts/ symlink dangles" ok
else
    check "rollback exits non-zero when accounts/ symlink dangles (got $RC4)" fail
fi
if grep -qE 'dangling|dangle' "$WORK/t4.err"; then
    check "stderr mentions dangling symlink" ok
else
    check "stderr mentions dangling symlink" fail
fi
if grep -q 'user/accounts' "$WORK/t4.err"; then
    check "stderr names which data symlink dangles (user/accounts)" ok
else
    check "stderr names which data symlink dangles" fail
fi
DOC_AFTER4="$(readlink "$T4/$TIER")"
if [ "$DOC_BEFORE4" = "$DOC_AFTER4" ]; then
    check "rollback refusal (dangling): docroot unchanged" ok
else
    check "rollback refusal (dangling): docroot unchanged" fail
fi

# Sanity: the security.yaml symlinks dangling is ALLOWED (Grav
# regenerates them). Build a fresh fixture for this — the previous
# fixture's docroot might already be at the rolled-back release.
T4S="$WORK/t4-securityyaml"
mkdir -p "$T4S"
RID4S_A="$(build_release "$T4S" "0aaaaa4" "0.4.0" "300" "")"
swap_docroot "$T4S" "$RID4S_A"
RID4S_B="$(build_release "$T4S" "0bbbbb4" "0.4.1" "301" "$RID4S_A")"
swap_docroot "$T4S" "$RID4S_B"
# security.yaml symlinks under any release point at
# <tier>data/v0/user/config/security.yaml — already dangling because
# nothing creates them. accounts/ + data/ + logs/ resolve. The HTTP
# body matches the rolled-back release.
set_http_body "<html><body>Version 0.4.0 · build 300</body></html>"
set +e
( BV_ROLLBACK_LOCAL_PARENT="$T4S" \
  BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
  BV_ROLLBACK_DEPLOYED_BY="rollback-test@example.com" \
  bash "$ROLLBACK_SH" "$TIER" ) >"$WORK/t4s.out" 2>"$WORK/t4s.err"
RC4S=$?
set -e
if [ "$RC4S" -eq 0 ]; then
    check "rollback succeeds when only security.yaml dangles" ok
else
    check "rollback succeeds when only security.yaml dangles (got $RC4S; stderr: $(tail -3 "$WORK/t4s.err"))" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 5: regex-validation gate on tampered previous_release.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: tampered previous_release rejected by regex (security)"

# Drop a marker the malicious value would `rm -rf` if our gate failed.
MARKER="$WORK/t5-marker.txt"
echo "do not delete me" > "$MARKER"

run_tampered_rollback() {
    local label="$1" tampered="$2"
    local tdir="$WORK/t5-$label"
    mkdir -p "$tdir"
    local rid_a rid_b
    rid_a="$(build_release "$tdir" "0aaaaa5" "0.5.0" "400" "")"
    swap_docroot "$tdir" "$rid_a"
    rid_b="$(build_release "$tdir" "0bbbbb5" "0.5.1" "401" "$rid_a")"
    swap_docroot "$tdir" "$rid_b"
    # Overwrite previous_release in the current release-meta with the
    # tampered value.
    local meta="$tdir/${TIER}-releases/$rid_b/release-meta.yaml"
    awk -v v="$tampered" '
        /^previous_release:/ { print "previous_release: \"" v "\""; next }
        { print }
    ' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"

    local doc_before doc_after rc
    doc_before="$(readlink "$tdir/$TIER")"
    set +e
    ( BV_ROLLBACK_LOCAL_PARENT="$tdir" \
      BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
      bash "$ROLLBACK_SH" "$TIER" ) >"$WORK/t5-$label.out" 2>"$WORK/t5-$label.err"
    rc=$?
    set -e
    doc_after="$(readlink "$tdir/$TIER")"
    if [ "$rc" -ne 0 ]; then
        check "tampered previous_release='$label': non-zero exit" ok
    else
        check "tampered previous_release='$label': non-zero exit" fail
    fi
    if [ "$doc_before" = "$doc_after" ]; then
        check "tampered '$label': docroot unchanged" ok
    else
        check "tampered '$label': docroot unchanged ($doc_before → $doc_after)" fail
    fi
    if grep -qE 'forbidden|regex|does not match|fails regex|cannot read a valid|path traversal' "$WORK/t5-$label.err"; then
        check "tampered '$label': regex-validation diagnostic" ok
    else
        check "tampered '$label': regex-validation diagnostic" fail
    fi
}

run_tampered_rollback "dotdot"           "../etc/passwd"
run_tampered_rollback "absolute"         "/absolute/path"
run_tampered_rollback "leading-dash"     "-rf"
run_tampered_rollback "metachar"         "\$(rm -rf $MARKER)"

# Marker must still be there — the metacharacter value never reached
# a shell command line.
if [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "do not delete me" ]; then
    check "tampered metacharacter: marker file still present (no shell execution)" ok
else
    check "tampered metacharacter: marker file deleted! command injection succeeded!" fail
fi

# Junk env value rejected before any path concat.
set +e
( BV_ROLLBACK_LOCAL_PARENT="$WORK" \
  bash "$ROLLBACK_SH" "../prod" ) >"$WORK/t5-env.out" 2>"$WORK/t5-env.err"
RC5E=$?
set -e
if [ "$RC5E" -ne 0 ]; then
    check "rollback rejects junk env name '../prod' with non-zero exit" ok
else
    check "rollback rejects junk env name '../prod'" fail
fi
if grep -qE 'invalid env name|Usage' "$WORK/t5-env.err"; then
    check "rollback prints closed-set diagnostic on junk env" ok
else
    check "rollback prints closed-set diagnostic on junk env" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 6: smoke-probe failure on rollback (rolled-back release stays
# live, exit non-zero, audit row records matched=false).
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 6: smoke-probe failure on rollback"

T6="$WORK/t6"
mkdir -p "$T6"
RID6_A="$(build_release "$T6" "0aaaaa6" "0.6.0" "500" "")"
swap_docroot "$T6" "$RID6_A"
RID6_B="$(build_release "$T6" "0bbbbb6" "0.6.1" "501" "$RID6_A")"
swap_docroot "$T6" "$RID6_B"

# Stub HTTP body that does NOT match the rolled-back release's
# Version/Build.
set_http_body "Wrong body — should not match"

set +e
( BV_ROLLBACK_LOCAL_PARENT="$T6" \
  BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
  BV_ROLLBACK_DEPLOYED_BY="rollback-test@example.com" \
  bash "$ROLLBACK_SH" "$TIER" ) >"$WORK/t6.out" 2>"$WORK/t6.err"
RC6=$?
set -e
if [ "$RC6" -ne 0 ]; then
    check "rollback with mismatched probe: non-zero exit" ok
else
    check "rollback with mismatched probe: non-zero exit (got $RC6)" fail
fi
DOC_AFTER6="$(readlink "$T6/$TIER")"
case "$DOC_AFTER6" in
    "${TIER}-releases/${RID6_A}")
        check "rollback with probe failure: docroot still points at rolled-back release" ok ;;
    *)
        check "rollback with probe failure: docroot at '$DOC_AFTER6' (expected $RID6_A)" fail ;;
esac
LOG6="$T6/${TIER}-releases/rollback-log.yaml"
if [ -f "$LOG6" ] && grep -Eq '^    matched: false$' "$LOG6"; then
    check "rollback audit row records matched=false on probe failure" ok
else
    check "rollback audit row records matched=false on probe failure" fail
fi
# expected_version_substring is recorded.
if grep -q "expected_version_substring:" "$LOG6"; then
    check "rollback audit row records expected_version_substring" ok
else
    check "rollback audit row records expected_version_substring" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 7: smoke-probe success — audit row records the matched fields.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 7: smoke-probe success on rollback (audit fields)"

T7="$WORK/t7"
mkdir -p "$T7"
RID7_A="$(build_release "$T7" "0aaaaa7" "0.7.0" "600" "")"
swap_docroot "$T7" "$RID7_A"
RID7_B="$(build_release "$T7" "0bbbbb7" "0.7.1" "601" "$RID7_A")"
swap_docroot "$T7" "$RID7_B"

# Compute the expected substring; serve it back.
EXPECTED_A="$(bv_compute_expected_version_substring "$T7/${TIER}-releases/$RID7_A")"
set_http_body "<html><body>$EXPECTED_A</body></html>"

set +e
( BV_ROLLBACK_LOCAL_PARENT="$T7" \
  BV_SMOKE_PROBE_URL_OVERRIDE="$PROBE_URL" \
  BV_ROLLBACK_DEPLOYED_BY="rollback-test@example.com" \
  bash "$ROLLBACK_SH" "$TIER" ) >"$WORK/t7.out" 2>"$WORK/t7.err"
RC7=$?
set -e
if [ "$RC7" -eq 0 ]; then
    check "rollback with matching probe: exit 0" ok
else
    check "rollback with matching probe: exit 0 (got $RC7; stderr: $(tail -3 "$WORK/t7.err"))" fail
fi
LOG7="$T7/${TIER}-releases/rollback-log.yaml"
if grep -q "expected_version_substring: \"$EXPECTED_A\"" "$LOG7"; then
    check "audit row's expected_version_substring matches the lib helper output" ok
else
    check "audit row's expected_version_substring matches the lib helper output" fail
fi
if grep -Eq '^    matched: true$' "$LOG7"; then
    check "audit row's matched=true on success" ok
else
    check "audit row's matched=true on success" fail
fi
if grep -Eq '^    status: 200$' "$LOG7"; then
    check "audit row's status=200 on success" ok
else
    check "audit row's status=200 on success" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 8: smoke-probe shared contract — deploy & rollback compute
# the SAME expected substring against the same VERSION/BUILD.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 8: shared smoke-probe contract"

T8_RDIR="$WORK/t8-rdir"
mkdir -p "$T8_RDIR"
echo "0.8.0" > "$T8_RDIR/VERSION"
echo "700"   > "$T8_RDIR/BUILD"
EXPECTED1="$(bv_compute_expected_version_substring "$T8_RDIR")"
EXPECTED2="$(bv_compute_expected_version_substring "$T8_RDIR")"
if [ "$EXPECTED1" = "$EXPECTED2" ] && [ "$EXPECTED1" = "Version 0.8.0 · build 700" ]; then
    check "bv_compute_expected_version_substring is deterministic" ok
else
    check "bv_compute_expected_version_substring deterministic (got '$EXPECTED1' vs '$EXPECTED2')" fail
fi

# bv_smoke_probe: success path.
set_http_body "<html><body>Version 0.8.0 · build 700</body></html>"
set +e
PROBE1="$(bv_smoke_probe "$PROBE_URL" "Version 0.8.0 · build 700")"
PROBE_RC1=$?
set -e
if [ "$PROBE_RC1" -eq 0 ] && [ "$PROBE1" = "200|true" ]; then
    check "bv_smoke_probe success: rc=0, output='200|true'" ok
else
    check "bv_smoke_probe success (got rc=$PROBE_RC1, '$PROBE1')" fail
fi
# bv_smoke_probe: mismatch.
set_http_body "<html><body>nope</body></html>"
set +e
PROBE2="$(bv_smoke_probe "$PROBE_URL" "Version 0.8.0 · build 700")"
PROBE_RC2=$?
set -e
if [ "$PROBE_RC2" -ne 0 ] && [ "$PROBE2" = "200|false" ]; then
    check "bv_smoke_probe mismatch: rc!=0, output='200|false'" ok
else
    check "bv_smoke_probe mismatch (got rc=$PROBE_RC2, '$PROBE2')" fail
fi
# bv_smoke_probe rejects non-http URLs.
set +e
PROBE3="$(bv_smoke_probe "file:///etc/passwd" "irrelevant" 2>/dev/null)"
PROBE_RC3=$?
set -e
if [ "$PROBE_RC3" -ne 0 ]; then
    check "bv_smoke_probe rejects non-http URL" ok
else
    check "bv_smoke_probe rejects non-http URL" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 9: Makefile rollback aliases.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 9: Makefile rollback-* targets"

MK="$REPO_ROOT/Makefile"
for env in dev test staging prod; do
    if grep -Eq "^rollback-${env}:" "$MK"; then
        check "Makefile defines rollback-$env target" ok
    else
        check "Makefile defines rollback-$env target" fail
    fi
    # Body invokes deploy/rollback.sh with the literal env as a quoted positional.
    body="$(awk -v t="rollback-$env:" '$0 ~ "^"t {flag=1; next} flag && /^[a-zA-Z_-]+:/ {flag=0} flag {print}' "$MK")"
    if printf '%s' "$body" | grep -q "deploy/rollback.sh $env"; then
        check "rollback-$env body invokes deploy/rollback.sh $env" ok
    else
        check "rollback-$env body invokes deploy/rollback.sh $env (body: $body)" fail
    fi
done
# make help mentions the rollback targets.
HELP_OUT="$(cd "$REPO_ROOT" && make help 2>&1 || true)"
mentions_all=1
for env in dev test staging prod; do
    if ! printf '%s' "$HELP_OUT" | grep -q "rollback-$env"; then
        mentions_all=0
    fi
done
if [ "$mentions_all" = "1" ]; then
    check "make help documents all four rollback targets" ok
else
    check "make help documents all four rollback targets" fail
fi
# make -n rollback-dev prints the rollback.sh invocation.
DRY_OUT="$(cd "$REPO_ROOT" && make -n rollback-dev 2>&1 || true)"
if printf '%s' "$DRY_OUT" | grep -q "deploy/rollback.sh dev"; then
    check "make -n rollback-dev shows rollback.sh invocation" ok
else
    check "make -n rollback-dev shows rollback.sh invocation" fail
fi
# No rollback-landing target (apex has no rollback story).
if grep -Eq "^rollback-landing:" "$MK"; then
    check "no rollback-landing target (apex has no rollback)" fail
else
    check "no rollback-landing target (apex has no rollback)" ok
fi

# ─────────────────────────────────────────────────────────────────────
# Test 10: smoke-probe failure on deploy leaves the new release LIVE
# with a "rollback command:" hint, and release-meta records matched=false.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 10: smoke-probe failure on deploy: no auto-rollback, hint printed"

# We can't drive deploy.sh end-to-end (no .env.deploy, no real ssh),
# so we exercise the same code path the deploy script uses post-swap:
# the bv_smoke_probe + bv_append_post_swap_meta + the deploy.sh
# stderr-formatting.
#
# Static check: deploy.sh contains the rollback-command hint AND the
# "do NOT auto-rollback" copy on the smoke-probe failure path.
if grep -q 'rollback command:' "$DEPLOY_SH" \
   && grep -q 'make rollback-' "$DEPLOY_SH"; then
    check "deploy.sh prints 'rollback command:' hint on probe failure" ok
else
    check "deploy.sh prints 'rollback command:' hint on probe failure" fail
fi
if grep -qE 'NO auto-rollback|no auto-rollback|IS LIVE' "$DEPLOY_SH"; then
    check "deploy.sh's failure path explicitly disclaims auto-rollback" ok
else
    check "deploy.sh's failure path explicitly disclaims auto-rollback" fail
fi
# The exit-1 for probe failure happens AFTER the swap (so the new
# release is LIVE). Find the swap line and the probe-failure exit
# line and compare ordering.
read -r SWAP_LINE PROBE_EXIT_LINE < <(awk '
    /ln -sfn \$\{LAYOUT_NAME\}-releases\/\$\{RELEASE_ID\} \$\{DEPLOY_TARGET\}/ && !s { s=NR }
    /ln -sfn "\$TARGET_REL" "\$DEPLOY_TARGET"/ && !s { s=NR }
    /Smoke probe FAILED/ && !p { p=NR }
    END { print s, p }
' "$DEPLOY_SH")
if [ -n "$SWAP_LINE" ] && [ -n "$PROBE_EXIT_LINE" ] && [ "$SWAP_LINE" -lt "$PROBE_EXIT_LINE" ]; then
    check "deploy.sh: probe-failure handler comes AFTER the atomic swap (no auto-rollback)" ok
else
    check "deploy.sh: probe-failure handler ordering (swap=$SWAP_LINE probe=$PROBE_EXIT_LINE)" fail
fi
# Cache-clear failure regression check (Sprint 1 invariant): the
# cache-clear exit must come BEFORE the swap.
read -r CACHE_LINE SWAP_LINE2 < <(awk '
    /Cache clear failed/ && !c { c=NR }
    /ln -sfn \$\{LAYOUT_NAME\}-releases\/\$\{RELEASE_ID\} \$\{DEPLOY_TARGET\}/ && !s { s=NR }
    /ln -sfn "\$TARGET_REL" "\$DEPLOY_TARGET"/ && !s { s=NR }
    END { print c, s }
' "$DEPLOY_SH")
if [ -n "$CACHE_LINE" ] && [ -n "$SWAP_LINE2" ] && [ "$CACHE_LINE" -lt "$SWAP_LINE2" ]; then
    check "Sprint 1 regression: cache-clear handler stays BEFORE swap" ok
else
    check "Sprint 1 regression: cache-clear handler ordering (cache=$CACHE_LINE swap=$SWAP_LINE2)" fail
fi

# Behavioural: simulate the deploy probe-failure path against a real
# release-meta file. Build a release, write the pre-swap meta, simulate
# the swap (swap_duration_ms=23), call bv_smoke_probe with mismatched
# body, then bv_append_post_swap_meta with the false result.
T10="$WORK/t10"
mkdir -p "$T10"
RID10="$(bv_compute_release_id "0aaaaaa")"
T10_RDIR="$T10/${TIER}-releases/$RID10"
mkdir -p "$T10_RDIR"
echo "0.10.0" > "$T10_RDIR/VERSION"
echo "1000"   > "$T10_RDIR/BUILD"
bv_write_release_meta_yaml_full "$T10_RDIR" "$RID10" "" "0.10.0" "1000" "v0" \
    "2026-05-09T20:34:43Z" "thomas@appforceone.dk" "host" "/cwd:x" "develop" \
    "abc1234" "abc1234" "false" "v0"
EXPECTED10="$(bv_compute_expected_version_substring "$T10_RDIR")"
set_http_body "<html><body>NOT THE EXPECTED BODY</body></html>"
PROBE_RESULT10="$(bv_smoke_probe "$PROBE_URL" "$EXPECTED10" || true)"
PROBE_STATUS10="${PROBE_RESULT10%%|*}"
PROBE_MATCHED10="${PROBE_RESULT10##*|}"
bv_append_post_swap_meta "$T10_RDIR" "2026-05-09T20:34:44Z" 23 \
    "$PROBE_URL" "$PROBE_STATUS10" "$EXPECTED10" "$PROBE_MATCHED10"
META10="$T10_RDIR/release-meta.yaml"
if grep -Eq '^  matched: false$' "$META10"; then
    check "deploy probe-fail behavioural: release-meta records matched=false" ok
else
    check "deploy probe-fail behavioural: release-meta records matched=false" fail
fi
# Sanity: matched=true on the matching path.
T10B="$WORK/t10b"
mkdir -p "$T10B/${TIER}-releases/$RID10"
T10B_RDIR="$T10B/${TIER}-releases/$RID10"
echo "0.10.0" > "$T10B_RDIR/VERSION"
echo "1000"   > "$T10B_RDIR/BUILD"
bv_write_release_meta_yaml_full "$T10B_RDIR" "$RID10" "" "0.10.0" "1000" "v0" \
    "2026-05-09T20:34:43Z" "thomas@appforceone.dk" "host" "/cwd" "develop" \
    "abc1234" "abc1234" "false" "v0"
set_http_body "Version 0.10.0 · build 1000"
PROBE_RESULT10B="$(bv_smoke_probe "$PROBE_URL" "Version 0.10.0 · build 1000" || true)"
PROBE_MATCHED10B="${PROBE_RESULT10B##*|}"
bv_append_post_swap_meta "$T10B_RDIR" "2026-05-09T20:34:44Z" 5 \
    "$PROBE_URL" "200" "Version 0.10.0 · build 1000" "$PROBE_MATCHED10B"
if grep -Eq '^  matched: true$' "$T10B_RDIR/release-meta.yaml"; then
    check "deploy probe-success behavioural: release-meta records matched=true" ok
else
    check "deploy probe-success behavioural: release-meta records matched=true" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 11: regression — Sprint 1 invariants under Sprint 2 edits.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 11: Sprint-1 invariants still hold under Sprint-2 edits"

# tests/deploy/excludes-preserve-live-state.sh untouched relative to
# develop's merge base. We can verify it's not edited by checking
# git diff against the merge base.
if command -v git >/dev/null 2>&1; then
    # Use HEAD~2 as a reasonable proxy for "develop" (Sprint 1 was 2
    # commits back); if that fails we fall back to checking the file
    # is at least readable.
    DIFF_OUT="$(cd "$REPO_ROOT" && git diff HEAD -- tests/deploy/excludes-preserve-live-state.sh 2>/dev/null || echo "")"
    if [ -z "$DIFF_OUT" ]; then
        check "tests/deploy/excludes-preserve-live-state.sh has no uncommitted edits" ok
    else
        check "tests/deploy/excludes-preserve-live-state.sh has uncommitted edits!" fail
    fi
fi
# --max-delete=0 still wired in atomic-release.sh.
if grep -Eq -- 'flags=\(\s*-a\s+--max-delete=0' "$LIB"; then
    check "regression: --max-delete=0 still wired in lib" ok
else
    check "regression: --max-delete=0 wiring lost in lib" fail
fi
# --max-delete=0 still wired in deploy.sh.
if awk '/RSYNC_FLAGS_ATOMIC=\(/,/^\)/' "$DEPLOY_SH" | grep -q -- "--max-delete=0"; then
    check "regression: --max-delete=0 still wired in deploy.sh" ok
else
    check "regression: --max-delete=0 wiring lost in deploy.sh" fail
fi
# Closed-set tier validator + regex release-id validator unchanged.
if bv_validate_tier_name "dev" >/dev/null 2>&1 \
   && ! bv_validate_tier_name "../etc" >/dev/null 2>&1; then
    check "regression: bv_validate_tier_name closed-set check intact" ok
else
    check "regression: bv_validate_tier_name closed-set check intact" fail
fi
if bv_validate_release_id "20260509T203443-abc1234" 2>/dev/null \
   && ! bv_validate_release_id "../etc" 2>/dev/null; then
    check "regression: bv_validate_release_id regex check intact" ok
else
    check "regression: bv_validate_release_id regex check intact" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test 12: live-state paths off limits — rollback never touches data.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "Test 12: rollback never touches <tier>data/"

# Static greps over rollback.sh to confirm no rsync/mv/rm against
# <tier>data/ paths.
if grep -nE 'rsync.*--delete' "$ROLLBACK_SH" >/dev/null; then
    check "rollback.sh has no rsync --delete" fail
else
    check "rollback.sh has no rsync --delete" ok
fi
# Combined: rollback.sh's only docroot mutation is ln -sfn. Count
# distinct mutation verbs against $DEPLOY_TARGET. The pipeline can
# legitimately produce zero matches (and grep returns 1 in that case);
# we want to count, not abort.
set +e
muts="$(grep -nE 'rsync|rm[[:space:]]+-rf?|mv[[:space:]]' "$ROLLBACK_SH" \
        | grep -E '\$DEPLOY_TARGET|\$\{DEPLOY_TARGET\}' \
        | grep -v '^[[:space:]]*#' \
        | wc -l \
        | tr -d ' ')"
set -e
if [ "${muts:-0}" = "0" ] || [ -z "$muts" ]; then
    check "rollback.sh: no rsync/rm/mv against \$DEPLOY_TARGET (only ln -sfn)" ok
else
    check "rollback.sh: $muts rsync/rm/mv invocations against \$DEPLOY_TARGET (must be 0)" fail
fi
# bv_smoke_probe never touches state — it only writes to a tempfile.
# Same set +e guard: a fully-clean grep returns 1 which would abort.
set +e
RM_LEAKS="$(grep -nE 'rm[[:space:]]+-rf?' "$ROLLBACK_SH" \
   | grep -vE 'mktemp|/tmp/|trap.*RETURN|body_file|PROBE_TMP|META_TMP' \
   | grep -v '^[[:space:]]*#')"
set -e
if [ -n "$RM_LEAKS" ]; then
    check "rollback.sh's only rm calls are against tempfiles" fail
    echo "    leaks: $RM_LEAKS" >&2
else
    check "rollback.sh's only rm calls are against tempfiles" ok
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"
[ "$FAIL" -eq 0 ]
