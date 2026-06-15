# =============================================================================
# Byvaerkstederne — deploy/migrate.sh integration helpers
#
# Sourced by deploy.sh between the cache-clear step (step 7) and the
# atomic swap step (step 8). The deploy script delegates to the
# functions below so the integration is unit-testable in isolation.
#
# Public functions:
#   bv_remote_read_data_version <data_dir_root_var_name>
#       Echoes the data_version field from <data_dir>/v<N>/user/
#       data-version.yaml where v<N> is the current symlink target of
#       <data_dir>/current. Defaults to "0.1.0" (pre-spec convention)
#       when the file is missing.
#
#   bv_remote_run_migration_step <bundle_data_version> <data_dir>
#       Reads the live tier's current data version. If it differs
#       from <bundle_data_version>:
#         - Picks a new dir name v<bundle_data_version> (with dots
#           replaced by _ so the path is filesystem-safe).
#         - `cp -a <data_dir>/<current> <data_dir>/<new>/`
#         - Invokes `deploy/migrate.sh <data_dir>/<new>` over SSH.
#         - Repoints <data_dir>/current to <new> on success.
#         - Aborts with non-zero on any failure (caller decides
#           whether to halt the deploy).
#       If they match, prints "no schema bump; runner skipped" and
#       returns 0 immediately.
#
# Test-harness affordances:
#   BV_MIGRATE_LOCAL_MODE=1  — run all the helper logic in-process,
#                              using local `bash` and the local
#                              filesystem instead of `bv_remote_run`.
#                              See tests/deploy/migrate-integration.sh.
# =============================================================================

# Pure-bash YAML-field extractor (mirrors deploy/migrate.sh's
# extract_data_version). Local-mode only — the remote-mode path runs
# the equivalent inline via bv_remote_run, which uses awk on the
# remote shell.
bv_local_extract_data_version() {
    local path="$1"
    if [ ! -f "$path" ]; then
        printf ''
        return 0
    fi
    awk '
        /^[[:space:]]*#/ { next }
        /^data_version:[[:space:]]*/ {
            v = $0
            sub(/^data_version:[[:space:]]*/, "", v)
            gsub(/^["'\'']|["'\'']$/, "", v)
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print v
            exit
        }
    ' "$path"
}

# Sanitise a SemVer for use as a path component: 0.2.0 → v_0_2_0.
# Keeping the v_ prefix avoids any collision with the legacy v0/ dir.
bv_version_to_dirname() {
    local v="$1"
    printf 'v_%s' "${v//./_}"
}

# Inspect the live tier's <data_dir>/current symlink and read the
# data_version from its target. Echoes the version string or "0.1.0"
# (pre-spec fallback) if the marker is missing.
bv_remote_read_data_version() {
    local data_dir="$1"
    local mode="${BV_MIGRATE_LOCAL_MODE:-0}"
    if [ "$mode" = "1" ]; then
        local marker="$data_dir/current/user/data-version.yaml"
        local v
        v="$(bv_local_extract_data_version "$marker")"
        if [ -z "$v" ]; then v="0.1.0"; fi
        printf '%s\n' "$v"
        return 0
    fi
    # Remote mode: defer to bv_remote_run (defined in atomic-release.sh
    # alongside this file). We use grep + sed to keep the embedded
    # script free of nested quote/escape gymnastics — the awk-based
    # version parser used in local mode is too quote-heavy to embed
    # in a bv_remote_run heredoc without bash parser issues.
    bv_remote_run '
        marker="$DD/current/user/data-version.yaml"
        if [ -f "$marker" ]; then
            v=$(grep -E "^data_version:" "$marker" \
                | head -n1 \
                | sed -E "s/^data_version:[[:space:]]*//; s/^[\"'\'']//; s/[\"'\'']$//; s/[[:space:]]+#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//")
            if [ -z "$v" ]; then v="0.1.0"; fi
            printf "%s\n" "$v"
        else
            printf "0.1.0\n"
        fi
    ' DD="$data_dir"
}

# Run the migration step. Returns 0 on success (whether a bump was
# applied or it was a no-op), non-zero on any failure.
bv_remote_run_migration_step() {
    local bundle_data_version="$1"
    local data_dir="$2"
    local mode="${BV_MIGRATE_LOCAL_MODE:-0}"

    if [ -z "$bundle_data_version" ]; then
        echo "❌  bv_remote_run_migration_step: bundle data version required" >&2
        return 2
    fi
    if [ -z "$data_dir" ]; then
        echo "❌  bv_remote_run_migration_step: data dir required" >&2
        return 2
    fi

    local live_version
    live_version="$(bv_remote_read_data_version "$data_dir")"
    if [ -z "$live_version" ]; then
        echo "❌  could not read live data version" >&2
        return 3
    fi

    if [ "$live_version" = "$bundle_data_version" ]; then
        echo "  ✓ data version already at ${bundle_data_version} on live tier; no schema bump"
        return 0
    fi

    echo "  → schema bump: ${live_version} → ${bundle_data_version}"
    local new_dirname
    new_dirname="$(bv_version_to_dirname "$bundle_data_version")"

    if [ "$mode" = "1" ]; then
        # Local-mode integration: we run the steps inline against the
        # local filesystem. This is what the test harness uses.
        local current_target
        current_target="$(readlink "$data_dir/current" || true)"
        if [ -z "$current_target" ]; then
            echo "❌  $data_dir/current is not a symlink" >&2
            return 4
        fi
        local src="$data_dir/$current_target"
        local dst="$data_dir/$new_dirname"
        if [ -e "$dst" ]; then
            echo "❌  destination data dir already exists: $dst" >&2
            return 5
        fi
        cp -a "$src" "$dst"

        # Run the local migrate.sh against the new dir. The caller is
        # expected to have set $BV_MIGRATE_SH to point at the runner;
        # default to the repo's deploy/migrate.sh.
        local runner="${BV_MIGRATE_SH:-$(cd "$(dirname "${BASH_SOURCE[0]}")"/.. && pwd)/migrate.sh}"
        if [ ! -x "$runner" ]; then
            echo "❌  migrate.sh runner not found or not executable: $runner" >&2
            return 6
        fi
        if ! BV_BUNDLE_DATA_VERSION_YAML="${BV_BUNDLE_DATA_VERSION_YAML:-}" \
            "$runner" "$dst" --to "$bundle_data_version"; then
            echo "❌  migrate.sh failed against $dst — aborting BEFORE symlink swap" >&2
            return 7
        fi

        # Advance <data_dir>/current to point at the new version dir.
        # The caller (deploy.sh) advances the docroot symlink AFTER
        # this returns; if we abort, the docroot stays pointed at the
        # old release dir (which still uses the old data dir via its
        # own symlinks).
        ln -sfn "$new_dirname" "$data_dir/current"
        echo "  ✓ ${data_dir}/current → ${new_dirname}"
        return 0
    fi

    # Remote-mode placeholder: production-grade remote integration
    # (SSH-invoked cp -a + migrate.sh against the remote tier) is its
    # own sprint and requires composer install on the remote. Until
    # that lands we MUST refuse a schema-bump deploy — silently
    # advancing the docroot symlink while data stays on the old
    # schema is exactly the failure class this spec was written to
    # prevent. The no-op case (live version == bundle version) was
    # already short-circuited above with return 0; reaching this
    # point means a real schema bump is requested.
    echo "❌  schema-bump deploys against a real SSH tier are not yet wired." >&2
    echo "    Refusing to advance the docroot symlink against unmigrated data." >&2
    echo "    Workaround until the SSH branch ships:" >&2
    echo "      1. Take a fresh backup of the live tier via deploy/backup.sh." >&2
    echo "      2. Restore it locally and run deploy/migrate.sh --to ${bundle_data_version} against the snapshot." >&2
    echo "      3. Push the migrated snapshot to the live tier's <tier>data/$(bv_version_to_dirname "$bundle_data_version")/ dir by hand and repoint <tier>data/current at it." >&2
    echo "      4. Re-run this deploy; the no-op branch will then proceed." >&2
    echo "    (Tracking: deploy_sh_invokes_migration_runner_on_schema_bump — remote-mode follow-up.)" >&2
    return 1
}
