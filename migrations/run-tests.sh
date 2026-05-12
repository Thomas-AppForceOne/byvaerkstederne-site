#!/usr/bin/env bash
# =============================================================================
# Byvaerkstederne — Migration test harness
#
# Runs the four test classes the spec demands plus the duplicate-target
# peer check:
#
#   1. Duplicate-target check: fails if two files in migrations/ declare
#      the same target version.
#   2. Per-migration test: for every fixture under migrations/tests/,
#      copy before/ to a tmp dir, run the migration, diff against after/.
#   3. Idempotence test: run the same migration AGAIN in the same tmp
#      dir, diff against after/ a second time.
#   4. Compose-chain test: start from the lowest-version fixture's
#      before/, apply every migration in SemVer order through to the
#      highest target, diff against the highest fixture's after/.
#   5. Failure-path tests (CLAUDE.md testing discipline):
#        a) Missing migration: fixture at 0.2.0, ask for 0.4.0, only
#           0.3.0_*.php present in a synthetic dir → runner refuses.
#        b) SemVer-sort: 0.2.0 and 0.10.0 in a synthetic dir, fixture at
#           0.1.0 → applied in 0.2.0 then 0.10.0 order, observable in
#           the `applying <name>` lines.
#        c) Throwing migration: deliberately-throwing closure → runner
#           exits non-zero, data dir left in post-throw state.
#
# The harness uses Docker (image php:8.3-cli) to invoke PHP so it works
# on machines without a local PHP toolchain. CI overrides BV_MIGRATE_PHP
# to point at the runner-installed PHP.
# =============================================================================
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MIGRATE_SH="$REPO_ROOT/deploy/migrate.sh"
MIGRATIONS_DIR="$SCRIPT_DIR"
TESTS_ROOT="$SCRIPT_DIR/tests"
BUNDLE_MARKER="$REPO_ROOT/config/www/user/data-version.yaml"

# PHP invocation: the runner has its own resolver (system php first,
# then Docker). Letting it own that responsibility means the runner —
# which knows the data-dir and any synthetic migrations dir — mounts
# everything it needs. The harness only resolves PHP_CMD for its own
# direct-invoke idempotence-test path.
if [ -n "${BV_MIGRATE_PHP:-}" ]; then
    PHP_CMD="$BV_MIGRATE_PHP"
elif command -v php >/dev/null 2>&1; then
    PHP_CMD="php"
elif command -v docker >/dev/null 2>&1; then
    PHP_CMD="docker run --rm -i -u $(id -u):$(id -g) -v $REPO_ROOT:$REPO_ROOT -w $REPO_ROOT php:8.3-cli php"
else
    echo "FATAL: no PHP found — set BV_MIGRATE_PHP, install php, or install Docker." >&2
    exit 1
fi
# Do NOT export BV_MIGRATE_PHP — let the runner re-resolve so it can
# mount the data dir and the synthetic BV_MIGRATIONS_DIR.

# Bootstrap composer install once. Use the same PHP we resolved above;
# fall back to a Docker-based composer if the host lacks one.
ensure_vendor() {
    if [ -d "$MIGRATIONS_DIR/vendor" ] && [ -f "$MIGRATIONS_DIR/vendor/autoload.php" ]; then
        return 0
    fi
    echo "→ installing migrations/ composer dependencies..."
    if command -v composer >/dev/null 2>&1; then
        ( cd "$MIGRATIONS_DIR" && composer install --no-interaction --no-progress --prefer-dist )
        return 0
    fi
    if command -v docker >/dev/null 2>&1; then
        docker run --rm \
            -u "$(id -u):$(id -g)" \
            -v "$MIGRATIONS_DIR:/app" \
            -w /app \
            composer:2 \
            install --no-interaction --no-progress --prefer-dist
        return 0
    fi
    echo "FATAL: cannot install composer dependencies — install composer or Docker." >&2
    return 1
}

# Coloured PASS/FAIL helpers. Use plain text so the harness output is
# greppable in CI logs without ANSI artefacts.
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

# Diff two directories, ignoring no-ops; emit context on mismatch.
diff_tree() {
    local a="$1" b="$2" label="$3"
    if diff -r "$a" "$b" >/tmp/migration-diff.$$ 2>&1; then
        rm -f /tmp/migration-diff.$$
        return 0
    fi
    echo "  --- diff (${label}) ---" >&2
    cat /tmp/migration-diff.$$ >&2 || true
    rm -f /tmp/migration-diff.$$
    return 1
}

# Copy fixture before/ into a clean tmp dir.
prepare_tmp_from_fixture() {
    local fixture_before="$1"
    local tmp
    tmp="$(mktemp -d)"
    # Preserve the .keep files but skip them in the diff later via
    # diff's default behaviour (no special handling needed — .keep
    # files exist in both before/ and after/ side by side).
    if [ -d "$fixture_before" ]; then
        (cd "$fixture_before" && tar -cf - .) | (cd "$tmp" && tar -xf -)
    fi
    printf '%s' "$tmp"
}

# =============================================================================
# Test class 1 — Duplicate-target check
# =============================================================================
echo "→ test: no duplicate migration targets"
# Peer scan: a duplicate would mean two files share the same SemVer
# prefix before the first underscore. The runner itself enforces the
# same rule (exit 4) up-front; we run the scan here as a fast CI signal
# that doesn't depend on having a data dir to migrate against.
DUP_OUT="$(ls -1 "$MIGRATIONS_DIR"/*.php 2>/dev/null \
    | awk -F/ '{print $NF}' \
    | awk -F_ '/^[0-9]+\.[0-9]+\.[0-9]+_/ {print $1}' \
    | sort | uniq -d || true)"
if [ -n "$DUP_OUT" ]; then
    report_fail "duplicate targets: $DUP_OUT"
else
    report_pass "no duplicate targets in migrations/"
fi

# =============================================================================
# Bootstrap composer + sanity-check the runner
# =============================================================================
ensure_vendor

# =============================================================================
# Test class 2 + 3 — Per-migration + Idempotence
# =============================================================================
echo "→ test: per-migration + idempotence"
if [ -d "$TESTS_ROOT" ]; then
    # Order fixtures by SemVer (componentwise numeric).
    fixtures=()
    while IFS= read -r d; do
        [ -d "$d" ] && fixtures+=("$d")
    done < <(
        find "$TESTS_ROOT" -mindepth 1 -maxdepth 1 -type d \
            | awk -F/ '{name=$NF; v=name; sub(/_.*$/, "", v); split(v, a, "."); printf "%s\t%s\t%s\t%s\n", a[1]+0, a[2]+0, a[3]+0, $0}' \
            | sort -k1,1n -k2,2n -k3,3n \
            | awk -F'\t' '{print $4}'
    )
    for fixture in "${fixtures[@]}"; do
        name="$(basename "$fixture")"
        before="$fixture/before"
        after="$fixture/after"
        if [ ! -d "$before" ] || [ ! -d "$after" ]; then
            report_fail "$name: missing before/ or after/"
            continue
        fi
        # Each fixture is for the migration whose filename starts with
        # the fixture's name. Find it.
        mig_file="$MIGRATIONS_DIR/${name}.php"
        if [ ! -f "$mig_file" ]; then
            report_fail "$name: no migration file matching $mig_file"
            continue
        fi
        # Resolve target version from the migration filename.
        target_version="${name%%_*}"

        tmp="$(prepare_tmp_from_fixture "$before")"
        # Run the migration ONCE via the runner. Targeting only this
        # migration's version isolates the per-migration check from
        # the compose-chain check.
        if ! bash "$MIGRATE_SH" "$tmp" --to "$target_version" >"$tmp.runlog" 2>&1; then
            cat "$tmp.runlog" >&2 || true
            report_fail "$name: runner exit non-zero on first apply"
            rm -rf "$tmp" "$tmp.runlog"
            continue
        fi
        # The migration should write data-version.yaml to the target
        # version; the runner verifies that, but we double-check.
        if ! diff_tree "$tmp" "$after" "${name}: first apply"; then
            report_fail "$name: first apply diff non-empty"
            rm -rf "$tmp" "$tmp.runlog"
            continue
        fi
        report_pass "$name: per-migration"

        # Idempotence: run again, diff again. The runner sees from==to
        # for the second run, so we'd hit the "already at <version>,
        # nothing to do" path. To actually re-invoke the migration's
        # closure (and prove the closure itself is idempotent), call
        # the PHP bootstrap directly, bypassing the runner's no-op
        # short-circuit.
        # Compose a PHP invocation that mounts both the repo and the
        # tmp data dir when running under Docker.
        if command -v php >/dev/null 2>&1; then
            idem_php=(php)
        elif command -v docker >/dev/null 2>&1; then
            idem_php=(
                docker run --rm -i
                -u "$(id -u):$(id -g)"
                -v "$REPO_ROOT:$REPO_ROOT"
                -v "$tmp:$tmp"
                -w "$REPO_ROOT"
                php:8.3-cli
                php
            )
        else
            report_fail "$name: idempotence requires php or docker"
            rm -rf "$tmp" "$tmp.runlog"
            continue
        fi
        if ! "${idem_php[@]}" \
            "$MIGRATIONS_DIR/run-migration.php" "$mig_file" "$tmp" >"$tmp.runlog2" 2>&1; then
            cat "$tmp.runlog2" >&2 || true
            report_fail "$name: re-running closure non-zero"
            rm -rf "$tmp" "$tmp.runlog" "$tmp.runlog2"
            continue
        fi
        if ! diff_tree "$tmp" "$after" "${name}: idempotence"; then
            report_fail "$name: idempotence diff non-empty"
            rm -rf "$tmp" "$tmp.runlog" "$tmp.runlog2"
            continue
        fi
        report_pass "$name: idempotence"
        rm -rf "$tmp" "$tmp.runlog" "$tmp.runlog2"
    done
else
    echo "  (no fixtures under $TESTS_ROOT — skipping per-migration tests)"
fi

# =============================================================================
# Test class 4 — Compose-chain
# =============================================================================
echo "→ test: compose-chain (lowest before/ → all migrations → highest after/)"
chain_fixtures=()
while IFS= read -r d; do
    [ -d "$d" ] && chain_fixtures+=("$d")
done < <(
    find "$TESTS_ROOT" -mindepth 1 -maxdepth 1 -type d \
        | awk -F/ '{name=$NF; v=name; sub(/_.*$/, "", v); split(v, a, "."); printf "%s\t%s\t%s\t%s\n", a[1]+0, a[2]+0, a[3]+0, $0}' \
        | sort -k1,1n -k2,2n -k3,3n \
        | awk -F'\t' '{print $4}'
)
if [ "${#chain_fixtures[@]}" -ge 2 ]; then
    lowest_before="${chain_fixtures[0]}/before"
    highest="${chain_fixtures[${#chain_fixtures[@]}-1]}"
    highest_after="$highest/after"
    highest_target="$(basename "$highest")"
    highest_target_version="${highest_target%%_*}"

    chain_tmp="$(prepare_tmp_from_fixture "$lowest_before")"
    # Walk forward via the runner, targeting the highest version. This
    # is exactly what the production runner would do — we're not just
    # iterating closures by hand.
    if bash "$MIGRATE_SH" "$chain_tmp" --to "$highest_target_version" >"$chain_tmp.log" 2>&1; then
        if diff_tree "$chain_tmp" "$highest_after" "compose-chain"; then
            report_pass "compose-chain: $(basename "${chain_fixtures[0]}") → $highest_target_version"
        else
            report_fail "compose-chain: diff non-empty against $highest_target/after"
        fi
    else
        cat "$chain_tmp.log" >&2 || true
        report_fail "compose-chain: runner exit non-zero"
    fi
    rm -rf "$chain_tmp" "$chain_tmp.log"
else
    echo "  (only ${#chain_fixtures[@]} fixture(s) present — compose-chain trivially passes)"
    report_pass "compose-chain: trivial (only ${#chain_fixtures[@]} fixture)"
fi

# =============================================================================
# Test class 5a — Missing migration refused
# =============================================================================
echo "→ test: missing migration in chain → runner refuses"
miss_tmp="$(mktemp -d)"
miss_migrations="$(mktemp -d)"
# Synthetic migrations dir contains ONLY 0.3.0_step.php — no 0.4.0
# script. Asking for --to 0.4.0 from a fixture at 0.2.0 must refuse.
mkdir -p "$miss_tmp/config/www/user"
printf 'data_version: "0.2.0"\n' > "$miss_tmp/config/www/user/data-version.yaml"
cat > "$miss_migrations/0.3.0_step.php" <<'PHP'
<?php
return function (string $dataDir): void {
    file_put_contents(
        $dataDir . '/config/www/user/data-version.yaml',
        "data_version: \"0.3.0\"\n"
    );
};
PHP
miss_log="$(mktemp)"
if BV_MIGRATIONS_DIR="$miss_migrations" bash "$MIGRATE_SH" "$miss_tmp" --to 0.4.0 >"$miss_log" 2>&1; then
    cat "$miss_log" >&2
    report_fail "missing-migration: runner exited 0 unexpectedly"
else
    if grep -q "no migration to 0.4.0 found" "$miss_log"; then
        # Per spec: data dir must be untouched on refusal. The synthetic
        # fixture was at 0.2.0; check the marker still says that.
        post="$(awk '/^data_version:/ {gsub(/"/,""); print $2}' "$miss_tmp/config/www/user/data-version.yaml")"
        if [ "$post" = "0.2.0" ]; then
            report_pass "missing-migration: runner refused with expected message; data dir untouched"
        else
            report_fail "missing-migration: data dir was mutated (now at ${post})"
        fi
    else
        echo "  --- runner output ---" >&2
        cat "$miss_log" >&2 || true
        report_fail "missing-migration: runner refused but with unexpected message"
    fi
fi
rm -rf "$miss_tmp" "$miss_migrations" "$miss_log"

# =============================================================================
# Test class 5b — SemVer sort: 0.2.0 applied before 0.10.0
# =============================================================================
echo "→ test: SemVer sort (0.2.0 before 0.10.0, not lex)"
sort_tmp="$(mktemp -d)"
sort_migrations="$(mktemp -d)"
mkdir -p "$sort_tmp/config/www/user"
printf 'data_version: "0.1.0"\n' > "$sort_tmp/config/www/user/data-version.yaml"
# The runner picks up run-migration.php + vendor/ from
# $BV_MIGRATE_BOOTSTRAP_DIR (default = the main migrations/ dir),
# so the synthetic dir only needs the migration .php files.
cat > "$sort_migrations/0.2.0_alpha.php" <<'PHP'
<?php
return function (string $dataDir): void {
    file_put_contents(
        $dataDir . '/config/www/user/data-version.yaml',
        "data_version: \"0.2.0\"\n"
    );
};
PHP
cat > "$sort_migrations/0.10.0_beta.php" <<'PHP'
<?php
return function (string $dataDir): void {
    file_put_contents(
        $dataDir . '/config/www/user/data-version.yaml',
        "data_version: \"0.10.0\"\n"
    );
};
PHP
sort_log="$(mktemp)"
if BV_MIGRATIONS_DIR="$sort_migrations" bash "$MIGRATE_SH" "$sort_tmp" --to 0.10.0 >"$sort_log" 2>&1; then
    # Order check: line "applying 0.2.0_alpha.php" must precede
    # "applying 0.10.0_beta.php".
    line_alpha="$(awk '/^applying 0\.2\.0_alpha\.php$/ {print NR; exit}' "$sort_log")"
    line_beta="$(awk '/^applying 0\.10\.0_beta\.php$/ {print NR; exit}' "$sort_log")"
    if [ -n "$line_alpha" ] && [ -n "$line_beta" ] && [ "$line_alpha" -lt "$line_beta" ]; then
        report_pass "SemVer-sort: 0.2.0 applied before 0.10.0"
    else
        echo "  --- runner output ---" >&2
        cat "$sort_log" >&2
        report_fail "SemVer-sort: ordering wrong (alpha line=${line_alpha:-?}, beta line=${line_beta:-?})"
    fi
else
    cat "$sort_log" >&2
    report_fail "SemVer-sort: runner exited non-zero"
fi
rm -rf "$sort_tmp" "$sort_migrations" "$sort_log"

# =============================================================================
# Test class 5c — Throwing migration halts the runner
# =============================================================================
echo "→ test: throwing migration → runner exits non-zero, dir left as-is"
throw_tmp="$(mktemp -d)"
throw_migrations="$(mktemp -d)"
mkdir -p "$throw_tmp/config/www/user"
printf 'data_version: "0.1.0"\n' > "$throw_tmp/config/www/user/data-version.yaml"
# Migration mutates the dir BEFORE throwing so we can verify the runner
# left the partial state in place.
cat > "$throw_migrations/0.2.0_bad.php" <<'PHP'
<?php
return function (string $dataDir): void {
    file_put_contents($dataDir . '/breadcrumb.txt', "i was here\n");
    throw new RuntimeException('deliberate test failure');
};
PHP
throw_log="$(mktemp)"
if BV_MIGRATIONS_DIR="$throw_migrations" bash "$MIGRATE_SH" "$throw_tmp" --to 0.2.0 >"$throw_log" 2>&1; then
    cat "$throw_log" >&2
    report_fail "throwing-migration: runner exited 0 unexpectedly"
else
    if [ -f "$throw_tmp/breadcrumb.txt" ]; then
        report_pass "throwing-migration: runner exited non-zero, partial state preserved"
    else
        echo "  --- runner output ---" >&2
        cat "$throw_log" >&2
        report_fail "throwing-migration: partial state NOT preserved (breadcrumb missing)"
    fi
fi
rm -rf "$throw_tmp" "$throw_migrations" "$throw_log"

# =============================================================================
# Test class 5d — No-op when already at target
# =============================================================================
echo "→ test: no-op when already at target"
noop_tmp="$(mktemp -d)"
mkdir -p "$noop_tmp/config/www/user"
printf 'data_version: "0.2.0"\n' > "$noop_tmp/config/www/user/data-version.yaml"
noop_log="$(mktemp)"
if BV_MIGRATIONS_DIR="$MIGRATIONS_DIR" bash "$MIGRATE_SH" "$noop_tmp" --to 0.2.0 >"$noop_log" 2>&1; then
    if grep -q "already at 0.2.0" "$noop_log"; then
        report_pass "no-op: 'already at 0.2.0' diagnostic printed"
    else
        echo "  --- runner output ---" >&2
        cat "$noop_log" >&2
        report_fail "no-op: diagnostic missing"
    fi
else
    cat "$noop_log" >&2
    report_fail "no-op: runner exited non-zero"
fi
rm -rf "$noop_tmp" "$noop_log"

# =============================================================================
# Test class 5e — Pre-spec convention warning fires
# =============================================================================
echo "→ test: pre-spec convention warning when marker is absent"
prespec_tmp="$(mktemp -d)"
prespec_log="$(mktemp)"
# Empty data dir — no data-version.yaml at all. Asking --to 0.1.0
# should hit the convention, warn, and then no-op (since the inferred
# from-version equals the target).
if BV_MIGRATIONS_DIR="$MIGRATIONS_DIR" bash "$MIGRATE_SH" "$prespec_tmp" --to 0.1.0 >"$prespec_log" 2>&1; then
    if grep -q "pre-spec backup convention" "$prespec_log"; then
        report_pass "pre-spec-convention: warning fired as expected"
    else
        echo "  --- runner output ---" >&2
        cat "$prespec_log" >&2
        report_fail "pre-spec-convention: warning missing"
    fi
else
    cat "$prespec_log" >&2
    report_fail "pre-spec-convention: runner exited non-zero on missing marker"
fi
rm -rf "$prespec_tmp" "$prespec_log"

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
