#!/usr/bin/env bash
# =============================================================================
# Shell-level probe for the deploy.sh ↔ migrate.sh integration.
#
# Runs entirely locally inside a mktemp fixture (no SSH, no remote, no
# credentials). Exercises:
#
#   * No-op path — live data_version equals bundle data_version. The
#     helper short-circuits with the documented "no schema bump"
#     diagnostic; no new versioned dir is created.
#   * Schema-bump path — live data_version differs from bundle. The
#     helper cp -a's the current data dir, runs migrate.sh against
#     the copy, repoints <data_dir>/current at the new dir.
#   * Failure-abort path — migrate.sh exits non-zero (deliberately-
#     throwing migration). The helper propagates non-zero; the test
#     asserts <data_dir>/current was NOT advanced (i.e. the symlink
#     still points at the OLD versioned dir).
#
# This is the test referenced by the
# deploy_sh_invokes_migration_runner_on_schema_bump acceptance
# criterion. It does not require Docker for the no-op case; for the
# schema-bump and abort cases it shells out to deploy/migrate.sh,
# which has its own PHP-resolver (system php → Docker → fail-loud).
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/deploy/lib/migrate-integration.sh"
ATOMIC_LIB="$REPO_ROOT/deploy/lib/atomic-release.sh"
MIGRATE_SH="$REPO_ROOT/deploy/migrate.sh"

if [ ! -f "$LIB" ]; then
    echo "FATAL: $LIB not found" >&2
    exit 1
fi
if [ ! -x "$MIGRATE_SH" ]; then
    echo "FATAL: $MIGRATE_SH not executable" >&2
    exit 1
fi

# shellcheck source=deploy/lib/atomic-release.sh
. "$ATOMIC_LIB"
# shellcheck source=deploy/lib/migrate-integration.sh
. "$LIB"

# Ensure vendor/ is installed for migrate.sh runs. The composer install
# happens via Docker so the host can be PHP-less.
if [ ! -d "$REPO_ROOT/migrations/vendor" ]; then
    echo "→ installing migrations/ vendor (one-time)"
    if command -v composer >/dev/null 2>&1; then
        ( cd "$REPO_ROOT/migrations" && composer install --no-interaction --no-progress --prefer-dist )
    elif command -v docker >/dev/null 2>&1; then
        docker run --rm -u "$(id -u):$(id -g)" \
            -v "$REPO_ROOT/migrations:/app" -w /app \
            composer:2 install --no-interaction --no-progress --prefer-dist
    else
        echo "FATAL: need composer or docker to install vendor" >&2
        exit 1
    fi
fi

PASS_COUNT=0
FAIL_COUNT=0
FAIL_NAMES=()
report_pass() {
    printf '  PASS  %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}
report_fail() {
    printf '  FAIL  %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
    FAIL_NAMES+=("$1")
}

export BV_MIGRATE_LOCAL_MODE=1
export BV_MIGRATE_SH="$MIGRATE_SH"

# Test fixtures: build a fake <data_dir> shaped like the live tier.
build_fixture() {
    local data_dir="$1"
    local live_version="$2"
    mkdir -p "$data_dir/v0/config/www/user"
    printf 'data_version: "%s"\n' "$live_version" \
        > "$data_dir/v0/config/www/user/data-version.yaml"
    if [ -n "${3:-}" ]; then
        printf '%s\n' "$3" > "$data_dir/v0/.migrated-at-seed"
    fi
    if [ -n "${4:-}" ]; then
        printf '%s\n' "$4" > "$data_dir/v0/.marker-label-seed"
    fi
    ln -sfn v0 "$data_dir/current"
}

# =============================================================================
# Test 1 — no-op path
# =============================================================================
echo "→ test: no-op when live version == bundle version"
DATA="$(mktemp -d)"
build_fixture "$DATA" "0.1.0"
log="$(mktemp)"
if bv_remote_run_migration_step "0.1.0" "$DATA" >"$log" 2>&1; then
    if grep -q "no schema bump" "$log"; then
        # Verify no new versioned dir was created.
        if [ "$(ls -1 "$DATA" | grep -c '^v_')" -eq 0 ]; then
            report_pass "no-op: diagnostic emitted, no new versioned dir"
        else
            report_fail "no-op: a new versioned dir was unexpectedly created"
        fi
    else
        echo "  --- log ---" >&2
        cat "$log" >&2
        report_fail "no-op: 'no schema bump' diagnostic missing"
    fi
else
    cat "$log" >&2
    report_fail "no-op: returned non-zero"
fi
rm -rf "$DATA" "$log"

# =============================================================================
# Test 2 — schema-bump path (0.1.0 → 0.2.0)
# =============================================================================
echo "→ test: schema bump 0.1.0 → 0.2.0 cp -a + migrate + repoint current"
DATA="$(mktemp -d)"
build_fixture "$DATA" "0.1.0" "2026-05-12T10:00:34Z" "sprint-1-baseline"
log="$(mktemp)"
if bv_remote_run_migration_step "0.2.0" "$DATA" >"$log" 2>&1; then
    cat "$log"
    # current symlink should now point at v_0_2_0
    cur="$(readlink "$DATA/current")"
    if [ "$cur" != "v_0_2_0" ]; then
        report_fail "schema-bump: current → $cur (expected v_0_2_0)"
    elif [ ! -d "$DATA/v_0_2_0" ]; then
        report_fail "schema-bump: v_0_2_0 dir not created"
    else
        # The new dir's data_version should be 0.2.0
        post="$(awk -F'"' '/^data_version:/ {print $2; exit}' \
            "$DATA/v_0_2_0/config/www/user/data-version.yaml")"
        if [ "$post" = "0.2.0" ]; then
            report_pass "schema-bump: current advanced, data_version = 0.2.0"
        else
            report_fail "schema-bump: data_version = $post (expected 0.2.0)"
        fi
        # The OLD dir's data_version should still be 0.1.0 — the
        # cp -a preserves it as a rollback target.
        old="$(awk -F'"' '/^data_version:/ {print $2; exit}' \
            "$DATA/v0/config/www/user/data-version.yaml")"
        if [ "$old" = "0.1.0" ]; then
            report_pass "schema-bump: v0 (rollback target) untouched"
        else
            report_fail "schema-bump: v0 was mutated (now ${old})"
        fi
    fi
else
    cat "$log" >&2
    report_fail "schema-bump: helper returned non-zero"
fi
rm -rf "$DATA" "$log"

# =============================================================================
# Test 3 — failure-abort path: migrate.sh exits non-zero
# =============================================================================
echo "→ test: migrate.sh failure aborts; current symlink NOT advanced"
DATA="$(mktemp -d)"
build_fixture "$DATA" "0.1.0"
# Synthetic migrations dir whose 0.2.0 migration deliberately throws.
BAD_MIG="$(mktemp -d)"
cat > "$BAD_MIG/0.2.0_bad.php" <<'PHP'
<?php
return function (string $dataDir): void {
    throw new RuntimeException('deliberate test failure (deploy integration)');
};
PHP
log="$(mktemp)"
# Point the helper's migrate.sh at the same script but force its
# migrations dir to the synthetic one.
if BV_MIGRATIONS_DIR="$BAD_MIG" bv_remote_run_migration_step "0.2.0" "$DATA" >"$log" 2>&1; then
    cat "$log" >&2
    report_fail "abort: helper returned 0 on a throwing migration"
else
    # Per spec, the new versioned dir IS expected to exist (the cp -a
    # ran and left partial state for debugging) but the `current`
    # symlink must NOT have been advanced.
    cur="$(readlink "$DATA/current")"
    if [ "$cur" = "v0" ]; then
        report_pass "abort: current still → v0 (symlink not advanced)"
    else
        report_fail "abort: current → $cur (expected v0)"
    fi
fi
rm -rf "$DATA" "$BAD_MIG" "$log"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "─────────────────────────────────────────"
echo "PASSED: ${PASS_COUNT}"
echo "FAILED: ${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for n in "${FAIL_NAMES[@]}"; do
        echo "  - $n"
    done
    exit 1
fi
echo ""
echo "all green"
exit 0
