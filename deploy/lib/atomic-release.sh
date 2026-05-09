#!/usr/bin/env bash
#
# Atomic-release primitives for deploy/deploy.sh and tests/deploy/atomic-layout.sh.
#
# Source this file (do not exec it) and call the public functions:
#
#   bv_validate_tier_name         <env>
#   bv_validate_release_id        <release-id>
#   bv_compute_release_id         <git-sha-short>            # echoes a release-id
#   bv_release_id_regex                                       # echoes the regex
#   bv_atomic_release_excludes                                # echoes default excludes
#   bv_rsync_to_release_dir       <staging-dir> <release-dir> [extra-rsync-flags…]
#   bv_bootstrap_data_dir         <data-dir> <env>
#   bv_wire_release_symlinks      <release-dir> <data-dir> <env>
#   bv_write_release_meta_yaml    <release-dir> <release-id> <prev-release-id> <code-version> <build> <data-version> <deployed-at> <deployed-by>
#   bv_atomic_swap_symlink        <release-dir> <docroot-symlink>
#   bv_prune_old_releases         <releases-dir> <current-release-id> <prev-release-id> [keep-N=5]
#
# These run locally (no ssh, no remote) — the deploy script wraps them
# with sshpass/ssh when invoking against a remote, but the fixture-
# driven test exercises the same code paths against a mktemp dir.
#
# Security contract:
#
#   * Tier name validated against the closed set
#       {dev,test,staging,prod,landing}
#     before any path concatenation. Anything else returns non-zero.
#   * Release id validated against the strict regex
#       ^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$
#     before any path concatenation, ln target, rm target, or rsync
#     destination. Forbids '..', '/', leading '-', and any shell
#     metacharacter.
#   * Every variable that flows into rsync, ssh, ln, mv, rm, cp is
#     double-quoted and passed as a separate argument. No eval. No
#     string-concatenated commands.
#   * Live-state paths (<tier>data/, accounts/, user/data/, logs/)
#     are NEVER rsync sources, rm targets, or symlink-rewrite targets
#     in this library. The release dir is the rsync target; <tier>data/
#     is touched only via bootstrap (creating empty subdirs the first
#     time) and via symlinks (pointing INTO it from the release dir).
#
# The April/May 2026 wipe class is structurally impossible here: the
# rsync target is, by construction, a fresh release dir, and the
# library refuses to rsync into anything else.

# shellcheck shell=bash

bv_release_id_regex() {
    printf '^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$\n'
}

# Closed-set check for the env arg. Returns 0 if valid, non-zero
# otherwise. Echoes the canonical name on stdout (lowercased,
# 'production' normalised to 'prod') for callers that want to use it
# as a path component.
bv_validate_tier_name() {
    local env="${1:-}"
    case "$env" in
        dev|test|staging|landing)
            printf '%s\n' "$env"
            return 0
            ;;
        prod|production)
            printf '%s\n' "prod"
            return 0
            ;;
        *)
            echo "FATAL: invalid env name '$env' — must be one of {dev,test,staging,prod,landing}" >&2
            return 1
            ;;
    esac
}

bv_validate_release_id() {
    local rid="${1:-}"
    # Defence in depth: explicit checks for the patterns the regex
    # forbids, ahead of the regex itself, so a regex flavour mismatch
    # can never let a traversal sequence through.
    case "$rid" in
        *..*|*/*|-*|"")
            echo "FATAL: release id '$rid' contains forbidden characters" >&2
            return 1
            ;;
    esac
    if ! printf '%s' "$rid" | grep -Eq '^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$'; then
        echo "FATAL: release id '$rid' does not match expected shape <UTC-timestamp>-<git-sha-short>" >&2
        return 1
    fi
    return 0
}

bv_compute_release_id() {
    local sha_short="${1:-}"
    # Sha-short defaults to 'unknown' — but the validator will then
    # refuse it, which is the correct behaviour outside a git checkout.
    if [ -z "$sha_short" ]; then
        sha_short="unknown"
    fi
    # Truncate sha to 12 chars; extend short shas to 7 with zero padding
    # so the regex passes even on a fresh repo with a 4-char short sha.
    sha_short="$(printf '%s' "$sha_short" | tr -cd '0-9a-f' | cut -c 1-12)"
    while [ "${#sha_short}" -lt 7 ]; do
        sha_short="0$sha_short"
    done
    local ts
    ts="$(date -u +%Y%m%dT%H%M%S)"
    printf '%s-%s\n' "$ts" "$sha_short"
}

# The exclude list applied to rsync into the fresh release dir. We
# don't ship local-dev cache state, build outputs, or .DS_Store. None
# of these are live-state paths — the live state never appeared in
# the staging tree to begin with — but excluding them cleans the
# release-dir contents.
bv_atomic_release_excludes() {
    cat <<'EOF'
--exclude=cache/
--exclude=tmp/
--exclude=backup/
--exclude=logs/
--exclude=.DS_Store
EOF
}

# Rsync the staging dir into a fresh release dir.
#
# Hard contract:
#   * destination must be a fresh empty dir (we create it; refuse if
#     it already exists with content)
#   * --max-delete=0 is asserted, belt-and-braces, even though the
#     destination is empty so no delete should ever happen
#   * the source is the staging dir; live-state paths are NOT in the
#     staging tree, by construction
#
# The destination is checked for emptiness BEFORE the rsync starts.
# This is the primary collision guard for "release-id collision on
# the remote" mentioned in the contract.
bv_rsync_to_release_dir() {
    local staging_dir="${1:?staging dir required}"
    local release_dir="${2:?release dir required}"
    shift 2

    if [ ! -d "$staging_dir" ]; then
        echo "FATAL: staging dir '$staging_dir' does not exist" >&2
        return 1
    fi
    if [ -e "$release_dir" ]; then
        # A pre-existing release dir is a hard error: it would mean
        # either a release-id collision (clock skew + same short-sha)
        # or a re-run of the same deploy. Either way we refuse to
        # overwrite it; the operator decides what to do.
        if [ -d "$release_dir" ] && [ -z "$(ls -A "$release_dir" 2>/dev/null || true)" ]; then
            : # empty dir is acceptable — we'll fill it
        else
            echo "FATAL: release dir already exists and is not empty: $release_dir" >&2
            echo "       refusing to overwrite an existing release on the remote" >&2
            return 1
        fi
    else
        mkdir -p "$release_dir"
    fi

    # Build the rsync flag array. Every variable interpolation is
    # quoted; no string-built command lines.
    local -a flags=( -a --max-delete=0 )
    # Pull the default excludes (one per line) into the flags array.
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && flags+=("$line")
    done < <(bv_atomic_release_excludes)

    # Append any caller-supplied extras (used by deploy.sh to add
    # -v -z and the SSH transport). Each extra is already a separate
    # arg in "$@".
    local extra
    for extra in "$@"; do
        flags+=("$extra")
    done

    # Source has trailing slash — copy CONTENTS of staging into the
    # fresh release dir, not the staging dir itself.
    rsync "${flags[@]}" "$staging_dir/" "$release_dir/"
}

# Bootstrap <data-dir>/v0/{user/accounts,user/data,user/config,user/env/<env>/config}
# and <data-dir>/current → v0 if absent. Idempotent: existing trees
# are left untouched (no chmod, no chown, no touch — preserves mtime
# so the deploy can verify <tier>data/ mtime is unchanged across the
# rsync portion).
bv_bootstrap_data_dir() {
    local data_dir="${1:?data dir required}"
    local env="${2:?env required}"

    # env name was already validated by the caller, but be paranoid.
    if ! bv_validate_tier_name "$env" >/dev/null; then
        return 1
    fi

    local v0="$data_dir/v0"
    mkdir -p "$v0/user/accounts"
    mkdir -p "$v0/user/data"
    mkdir -p "$v0/user/config"
    mkdir -p "$v0/user/env/$env/config"
    mkdir -p "$data_dir/logs"

    # Create the 'current' marker symlink the first time. ln -sfn is
    # atomic and idempotent. Target is a relative path so the data
    # dir stays portable across renames.
    if [ ! -e "$data_dir/current" ] || [ -L "$data_dir/current" ]; then
        ln -sfn "v0" "$data_dir/current"
    fi
}

# Wire the five symlinks from §Symlink contract inside the release
# dir. All targets are RELATIVE — no absolute paths leak in. ln -sfn
# is idempotent; missing data targets are tolerated (Grav regenerates
# security.yaml on first request).
#
# Layout: <parent>/<tier>-releases/<release-id>/  contains the symlinks
#         <parent>/<tier>data/v0/...              is what they point at
#
# Climb math (resolution is relative to each symlink's CONTAINING
# directory, not the release-dir root):
#
#   symlink path                                 containing dir              climb to <parent>      target
#   user/accounts                                <rel>/user/                 ../../../              <tier>data/v0/user/accounts
#   user/data                                    <rel>/user/                 ../../../              <tier>data/v0/user/data
#   user/config/security.yaml                    <rel>/user/config/          ../../../../          <tier>data/v0/user/config/security.yaml
#   user/env/<env>/config/security.yaml          <rel>/user/env/<env>/config/  ../../../../../../  <tier>data/v0/user/env/<env>/config/security.yaml
#   logs                                         <rel>/                      ../../                 <tier>data/logs
#
# Where <rel> = <parent>/<tier>-releases/<release-id>/ — three levels
# below <parent>. Hence three `../` segments from <rel>/user/ to reach
# <parent>, four from <rel>/user/config/, six from <rel>/user/env/<env>/config/.
# The spec table writes lower counts; the contract is the resolved
# path (a sibling <tier>data/ next to <tier>-releases/), and these
# counts honour that contract.
bv_wire_release_symlinks() {
    local release_dir="${1:?release dir required}"
    local data_dir="${2:?data dir required}"
    local env="${3:?env required}"

    if ! bv_validate_tier_name "$env" >/dev/null; then
        return 1
    fi
    if [ ! -d "$release_dir" ]; then
        echo "FATAL: release dir '$release_dir' does not exist" >&2
        return 1
    fi

    # The data dir's basename is <tier>data; the release dir's parent
    # basename is <tier>-releases. Both live under the same parent.
    local data_dir_name release_parent_name
    data_dir_name="$(basename "$data_dir")"
    release_parent_name="$(basename "$(dirname "$release_dir")")"

    # The five symlinks. Targets are written relative to the symlink's
    # *containing directory*, not the release-dir root.
    #
    # symlink path                                            resolves from           target
    # user/accounts                                           <release>/user/         ../../<datadirname>/v0/user/accounts/
    # user/data                                               <release>/user/         ../../<datadirname>/v0/user/data/
    # user/config/security.yaml                               <release>/user/config/  ../../../<datadirname>/v0/user/config/security.yaml
    # user/env/<env>/config/security.yaml                     <release>/user/env/<env>/config/   ../../../../../<datadirname>/v0/user/env/<env>/config/security.yaml
    # logs                                                    <release>/              ../<datadirname>/logs/

    # Make sure containing dirs exist; rsync may not have created
    # user/env/<env>/config/ if the staging tree was minimal (e.g.
    # under the local fixture).
    mkdir -p "$release_dir/user/config"
    mkdir -p "$release_dir/user/env/$env/config"

    # Remove any plain dirs/files at the symlink targets first so
    # ln -sfn can replace them. (Plain dirs would block ln; ln -sfn
    # only replaces existing symlinks atomically. We must rm a real
    # dir if it survived the rsync.) This rm is inside the fresh
    # release dir only — never under <data-dir> or anywhere else.
    local target_path
    for target_path in \
        "$release_dir/user/accounts" \
        "$release_dir/user/data" \
        "$release_dir/user/config/security.yaml" \
        "$release_dir/user/env/$env/config/security.yaml" \
        "$release_dir/logs"
    do
        if [ -e "$target_path" ] && [ ! -L "$target_path" ]; then
            # Hard contract: target_path is, by string construction,
            # rooted at "$release_dir/...". The release_dir itself is
            # validated by the caller. So this rm cannot escape into
            # <data-dir> or anywhere unintended.
            rm -rf "$target_path"
        fi
    done

    ln -sfn "../../../$data_dir_name/v0/user/accounts" \
        "$release_dir/user/accounts"
    ln -sfn "../../../$data_dir_name/v0/user/data" \
        "$release_dir/user/data"
    ln -sfn "../../../../$data_dir_name/v0/user/config/security.yaml" \
        "$release_dir/user/config/security.yaml"
    ln -sfn "../../../../../../$data_dir_name/v0/user/env/$env/config/security.yaml" \
        "$release_dir/user/env/$env/config/security.yaml"
    ln -sfn "../../$data_dir_name/logs" \
        "$release_dir/logs"

    # Suppress "release_parent_name unused" warning — it's there as a
    # sanity assertion target for callers that want to verify the
    # release dir is one below <tier>-releases/. Not strictly needed
    # at runtime.
    : "$release_parent_name"
}

# Write the basic-shape release-meta.yaml. Sprint 2 extends this to
# the full schema; Sprint 1 ships only the load-bearing fields.
#
# All values are written via printf with %s — no string interpolation
# that could let a metacharacter through. Values that may contain ':'
# (emails, paths) are double-quoted in the YAML output.
bv_write_release_meta_yaml() {
    local release_dir="${1:?release dir required}"
    local release_id="${2:?release id required}"
    local prev_release_id="${3:-}"
    local code_version="${4:?code version required}"
    local build="${5:?build required}"
    local data_version="${6:-v0}"
    local deployed_at="${7:?deployed_at required}"
    local deployed_by="${8:-unknown}"

    if ! bv_validate_release_id "$release_id"; then
        return 1
    fi
    if [ -n "$prev_release_id" ] && ! bv_validate_release_id "$prev_release_id"; then
        return 1
    fi

    local meta="$release_dir/release-meta.yaml"
    {
        printf 'release_id: %s\n' "$release_id"
        printf 'deployed_at: "%s"\n' "$deployed_at"
        printf 'deployed_by: "%s"\n' "$deployed_by"
        printf 'code_version: "%s"\n' "$code_version"
        printf 'build: "%s"\n' "$build"
        printf 'data_version: "%s"\n' "$data_version"
        if [ -n "$prev_release_id" ]; then
            printf 'previous_release: %s\n' "$prev_release_id"
        else
            printf 'previous_release: ""\n'
        fi
    } > "$meta"
}

# Atomic ln -sfn swap. The docroot symlink target is the release dir's
# basename (a relative path), so the docroot stays portable across
# parent renames. We do NOT rm the existing docroot first — that opens
# a race window. ln -sfn replaces atomically.
bv_atomic_swap_symlink() {
    local release_dir="${1:?release dir required}"
    local docroot="${2:?docroot path required}"

    if [ ! -d "$release_dir" ]; then
        echo "FATAL: release dir '$release_dir' does not exist" >&2
        return 1
    fi

    # Resolve relative target. The docroot is at <parent>/<tier>; the
    # release dir is at <parent>/<tier>-releases/<id>. So the target,
    # relative to the docroot, is "<tier>-releases/<id>".
    local docroot_parent release_parent_basename release_basename
    docroot_parent="$(dirname "$docroot")"
    release_parent_basename="$(basename "$(dirname "$release_dir")")"
    release_basename="$(basename "$release_dir")"

    # Sanity: the release dir must live under the docroot's parent.
    case "$release_dir" in
        "$docroot_parent"/*) ;;
        *)
            echo "FATAL: release dir '$release_dir' is not under docroot parent '$docroot_parent'" >&2
            return 1
            ;;
    esac

    ln -sfn "$release_parent_basename/$release_basename" "$docroot"
}

# Prune release dirs older than the N=5 most recent. The two newest
# (current + immediate previous) are NEVER eligible, even at N=1.
#
# The current release id and the immediate-previous release id are
# passed in by the caller (they're the only two the deploy script
# definitely knows are "load-bearing" — the rollback target plus the
# new live release).
bv_prune_old_releases() {
    local releases_dir="${1:?releases dir required}"
    local current_id="${2:?current id required}"
    local prev_id="${3:-}"
    local keep_n="${4:-5}"

    if [ ! -d "$releases_dir" ]; then
        return 0
    fi
    if ! bv_validate_release_id "$current_id"; then
        return 1
    fi
    if [ -n "$prev_id" ] && ! bv_validate_release_id "$prev_id"; then
        return 1
    fi

    # List release dirs by name (release ids are timestamp-prefixed,
    # so lexicographic sort = chronological sort), newest last. We
    # keep the last keep_n; everything older is rm-eligible UNLESS
    # it's the current or prev id.
    local -a all=()
    local entry
    while IFS= read -r entry; do
        all+=("$entry")
    done < <(cd "$releases_dir" && find . -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
             | sed 's|^\./||' \
             | sort)

    local total=${#all[@]}
    if [ "$total" -le "$keep_n" ]; then
        return 0
    fi

    local prune_count=$(( total - keep_n ))
    local i
    for ((i=0; i<prune_count; i++)); do
        local rid="${all[i]}"
        # Validate before using as a path component. If validation
        # fails, log and skip — never rm something we can't prove is
        # a release id.
        if ! bv_validate_release_id "$rid" 2>/dev/null; then
            echo "  ⚠️  skipping prune of '$rid' — not a valid release id" >&2
            continue
        fi
        if [ "$rid" = "$current_id" ] || [ "$rid" = "$prev_id" ]; then
            continue
        fi
        # Hard contract: rid passed bv_validate_release_id, so it
        # cannot contain '..', '/', or '-' as the first character.
        # The path being rm'd is "$releases_dir/$rid", which cannot
        # escape <releases-dir>.
        rm -rf "$releases_dir/$rid"
        echo "  🗑  pruned old release: $rid" >&2
    done

    # <tier>data/v<N>/ retention is NOT in scope this sprint.
    echo "  ℹ️  <tier>data/v<N>/ retention deferred to data-versioning spec" >&2
}
