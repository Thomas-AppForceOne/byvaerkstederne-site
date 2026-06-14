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
#   bv_wire_release_symlinks      <release-dir> <data-dir> <env> [vdir=v0]
#   bv_write_release_meta_yaml    <release-dir> <release-id> <prev-release-id> <code-version> <build> <data-version> <deployed-at> <deployed-by>
#   bv_write_release_meta_yaml_full <release-dir> <release-id> <prev-release-id> <code-version> <build> <data-version> <deployed-at> <deployed-by> <host> <cwd> <branch> <sha> <sha-short> <is-dirty> <previous-data-version>
#   bv_append_post_swap_meta      <release-dir> <swapped-at> <swap-duration-ms> <probe-url> <probe-status> <probe-substring> <probe-matched>
#   bv_atomic_swap_symlink        <release-dir> <docroot-symlink>
#   bv_prune_old_releases         <releases-dir> <current-release-id> <prev-release-id> [keep-N=5]
#   bv_compute_expected_version_substring <release-dir>             # echoes "Version <X> · build <N>"
#   bv_smoke_probe                <url> <expected-substring>        # echoes "<status>|<matched>"; rc=0 on match, non-zero otherwise
#   bv_diagnose_probe_failure     <status> <final-url> <body-file> <expected>   # echoes a "Likely cause: ..." diagnostic to stdout; pure logic, no curl
#   bv_spinner_while              <pid> <label>                                  # animates a braille spinner + elapsed time on stderr while <pid> is alive
#   bv_check_previous_release_data_symlinks <release-dir>           # rc=0 if accounts/, user/data/, logs/ all resolve; non-zero + diagnostic otherwise
#   bv_rollback_local             <parent-dir> <env> <docroot-name>  # local-mode rollback (no ssh) — used by tests and rollback.sh's --local mode
#   bv_append_rollback_log_row    <releases-dir> <rolled-back-at> <rolled-back-by> <from-release> <to-release> <swap-duration-ms> <probe-url> <probe-status> <probe-substring> <probe-matched>
#   bv_yaml_quote_escape          <value>                                 # escape backslashes and double-quotes for inline-quoted YAML emission
#   bv_check_no_lfs_pointers      <staging-dir>                            # scan for git-lfs pointer files; rc=0 if none, rc=1 if any (with operator-readable list on stderr)
#   bv_remote_run                 "<bash-body>" KEY=VALUE...              # safe ssh dispatch (see security note below)
#
# These run locally (no ssh, no remote) — the deploy script wraps them
# with sshpass/ssh when invoking against a remote, but the fixture-
# driven test exercises the same code paths against a mktemp dir.
#
# bv_remote_run is the exception: it dispatches a bash body through ssh
# to the remote configured by the caller's DEPLOY_HOST/USER/PASS/PORT
# environment. Values are passed via printf %q + remote `export` (never
# string-interpolated into the body), so the remote shell parses each
# value as a single quoted token regardless of contained whitespace,
# globs, or shell metacharacters. Callers reference values inside the
# body via "$KEY" — the body itself never sees raw values.
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

# Single source of truth for the release-id regex. Consumed by
# bv_validate_release_id and by inline-on-remote regex literals in
# the deploy script (where bash variable expansion is awkward, the
# hard-coded literal must match this exactly — keep them in sync).
_BV_RELEASE_ID_REGEX_BARE='^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$'
bv_release_id_regex() {
    printf '%s\n' "$_BV_RELEASE_ID_REGEX_BARE"
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
    if ! printf '%s' "$rid" | grep -Eq "$_BV_RELEASE_ID_REGEX_BARE"; then
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
    # Anchor path-based excludes with a leading slash so they only
    # match the Grav runtime dirs at the release root — NOT nested
    # dirs of the same name elsewhere in the tree (notably
    # vendor/doctrine/cache, which is a real PHP library that Grav
    # depends on; an unanchored `cache/` exclude would skip it and
    # break `php bin/grav clearcache` with
    # "Class Doctrine\\Common\\Cache\\FilesystemCache not found").
    # `.DS_Store` stays unanchored — those can land at any depth.
    cat <<'EOF'
--exclude=/cache/
--exclude=/tmp/
--exclude=/backup/
--exclude=/logs/
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
# The four versioned symlinks (accounts, data, and the two
# security.yaml files) resolve into <tier>data/<vdir>/...; <vdir>
# defaults to v0 (legacy behaviour, byte-identical for every existing
# tier whose `current → v0`). A release binds to the data-version dir
# the deploy chose at wire time, so its symlinks stay pinned to that
# dir for the life of the release — this is what makes rollback safe
# under the versioned-data-dir SERVING model (see ADR-005). The `logs`
# symlink is UNVERSIONED — it always resolves to <tier>data/logs.
#
# Layout: <parent>/<tier>-releases/<release-id>/  contains the symlinks
#         <parent>/<tier>data/<vdir>/...          is what they point at
#
# Climb math (resolution is relative to each symlink's CONTAINING
# directory, not the release-dir root):
#
#   symlink path                                 containing dir              climb to <parent>      target
#   user/accounts                                <rel>/user/                 ../../../              <tier>data/<vdir>/user/accounts
#   user/data                                    <rel>/user/                 ../../../              <tier>data/<vdir>/user/data
#   user/config/security.yaml                    <rel>/user/config/          ../../../../          <tier>data/<vdir>/user/config/security.yaml
#   user/env/<env>/config/security.yaml          <rel>/user/env/<env>/config/  ../../../../../../  <tier>data/<vdir>/user/env/<env>/config/security.yaml
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
    # Optional 4th arg: the data-version dir the four versioned symlinks
    # resolve into. ${4-v0} (NOT ${4:-v0}) defaults to v0 ONLY when the
    # arg is UNSET — i.e. a 3-arg call — so existing callers are
    # unchanged, while an EXPLICIT empty-string 4th arg is preserved and
    # rejected by the validation below (empty is not a valid path
    # component).
    local vdir="${4-v0}"

    if ! bv_validate_tier_name "$env" >/dev/null; then
        return 1
    fi
    # vdir becomes a path component in every versioned symlink target.
    # Validate it is a single, safe path component BEFORE any path
    # concatenation: reject empty, any '/' (so it can't be a multi-
    # component path), and any '..' traversal sequence.
    case "$vdir" in
        ''|*/*|*..*)
            echo "FATAL: bv_wire_release_symlinks vdir '$vdir' must be a single path component (no '/', no '..', non-empty)" >&2
            return 1
            ;;
    esac
    if [ ! -d "$release_dir" ]; then
        echo "FATAL: release dir '$release_dir' does not exist" >&2
        return 1
    fi

    # The data dir's basename is <tier>data; that's the only name we
    # need for the relative-target construction below. (Earlier drafts
    # also computed the release-parent basename as a sanity-check
    # target, but it was never actually consumed — removed per PR-#17
    # review finding 9.)
    local data_dir_name
    data_dir_name="$(basename "$data_dir")"

    # The five symlinks. Targets are written relative to the symlink's
    # *containing directory*, not the release-dir root.
    #
    # symlink path                                            resolves from           target
    # user/accounts                                           <release>/user/         ../../<datadirname>/<vdir>/user/accounts/
    # user/data                                               <release>/user/         ../../<datadirname>/<vdir>/user/data/
    # user/config/security.yaml                               <release>/user/config/  ../../../<datadirname>/<vdir>/user/config/security.yaml
    # user/env/<env>/config/security.yaml                     <release>/user/env/<env>/config/   ../../../../../<datadirname>/<vdir>/user/env/<env>/config/security.yaml
    # logs                                                    <release>/              ../<datadirname>/logs/  (UNVERSIONED)

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

    ln -sfn "../../../$data_dir_name/$vdir/user/accounts" \
        "$release_dir/user/accounts"
    ln -sfn "../../../$data_dir_name/$vdir/user/data" \
        "$release_dir/user/data"
    ln -sfn "../../../../$data_dir_name/$vdir/user/config/security.yaml" \
        "$release_dir/user/config/security.yaml"
    ln -sfn "../../../../../../$data_dir_name/$vdir/user/env/$env/config/security.yaml" \
        "$release_dir/user/env/$env/config/security.yaml"
    ln -sfn "../../$data_dir_name/logs" \
        "$release_dir/logs"
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

# ─────────────────────────────────────────────────────────────────────
# Sprint 2 additions: full release-meta schema, smoke probe, rollback.
# ─────────────────────────────────────────────────────────────────────

# Write the FULL §Audit-schema release-meta.yaml — pre-swap fields only.
# Caller appends the post-swap fields via bv_append_post_swap_meta after
# the swap + probe complete.
#
# Quoting discipline:
#   * release_id and previous_release pass the strict regex; emitted
#     unquoted (matches §Audit example).
#   * deployed_at / swapped_at: ISO-8601, contain ':' — quoted.
#   * deployed_by (email): may contain unusual chars — quoted.
#   * deployed_from.host / cwd / branch: may contain ':' or spaces —
#     quoted, with embedded '"' and '\' escaped.
#   * sha / sha_short / code_version / build / data_version /
#     previous_data_version: quoted strings (matches §Audit example).
#   * is_dirty: YAML boolean (true/false) — UNQUOTED.
bv_write_release_meta_yaml_full() {
    local release_dir="${1:?release dir required}"
    local release_id="${2:?release id required}"
    local prev_release_id="${3:-}"
    local code_version="${4:?code version required}"
    local build="${5:?build required}"
    local data_version="${6:-v0}"
    local deployed_at="${7:?deployed_at required}"
    local deployed_by="${8:-unknown}"
    local host="${9:-unknown}"
    local cwd="${10:-unknown}"
    local branch="${11:-unknown}"
    local sha="${12:-unknown}"
    local sha_short="${13:-unknown}"
    local is_dirty="${14:-false}"
    local previous_data_version="${15:-v0}"

    if ! bv_validate_release_id "$release_id"; then
        return 1
    fi
    if [ -n "$prev_release_id" ] && ! bv_validate_release_id "$prev_release_id"; then
        return 1
    fi

    # Normalise is_dirty to a strict {true,false} — anything else is
    # rejected so the YAML always parses as a real boolean.
    case "$is_dirty" in
        true|false) ;;
        *)
            echo "FATAL: is_dirty must be 'true' or 'false' (got '$is_dirty')" >&2
            return 1
            ;;
    esac

    if [ ! -d "$release_dir" ]; then
        echo "FATAL: release dir '$release_dir' does not exist" >&2
        return 1
    fi

    local meta="$release_dir/release-meta.yaml"

    {
        printf 'release_id: %s\n' "$release_id"
        printf 'deployed_at: "%s"\n' "$(bv_yaml_quote_escape "$deployed_at")"
        printf 'deployed_by: "%s"\n' "$(bv_yaml_quote_escape "$deployed_by")"
        printf 'deployed_from:\n'
        printf '  host: "%s"\n'   "$(bv_yaml_quote_escape "$host")"
        printf '  cwd: "%s"\n'    "$(bv_yaml_quote_escape "$cwd")"
        printf '  branch: "%s"\n' "$(bv_yaml_quote_escape "$branch")"
        printf '  sha: "%s"\n'    "$(bv_yaml_quote_escape "$sha")"
        printf '  sha_short: "%s"\n' "$(bv_yaml_quote_escape "$sha_short")"
        printf '  is_dirty: %s\n' "$is_dirty"
        printf 'code_version: "%s"\n' "$(bv_yaml_quote_escape "$code_version")"
        printf 'build: "%s"\n' "$(bv_yaml_quote_escape "$build")"
        printf 'data_version: "%s"\n' "$(bv_yaml_quote_escape "$data_version")"
        if [ -n "$prev_release_id" ]; then
            printf 'previous_release: %s\n' "$prev_release_id"
        else
            printf 'previous_release: ""\n'
        fi
        printf 'previous_data_version: "%s"\n' "$(bv_yaml_quote_escape "$previous_data_version")"
    } > "$meta"
}

# Append the post-swap fields to release-meta.yaml. Caller has already
# written the pre-swap shape via bv_write_release_meta_yaml_full.
bv_append_post_swap_meta() {
    local release_dir="${1:?release dir required}"
    local swapped_at="${2:?swapped_at required}"
    local swap_duration_ms="${3:?swap_duration_ms required}"
    local probe_url="${4:-}"
    local probe_status="${5:-0}"
    local probe_substring="${6:-}"
    local probe_matched="${7:-false}"

    # swap_duration_ms must be a non-negative integer (YAML integer).
    case "$swap_duration_ms" in
        ''|*[!0-9]*)
            echo "FATAL: swap_duration_ms must be a non-negative integer (got '$swap_duration_ms')" >&2
            return 1
            ;;
    esac
    # probe_status must be a 3-digit integer (or 0 if probe didn't run
    # — but we require the caller to always run the probe in Sprint 2).
    case "$probe_status" in
        ''|*[!0-9]*)
            echo "FATAL: probe_status must be a non-negative integer (got '$probe_status')" >&2
            return 1
            ;;
    esac
    case "$probe_matched" in
        true|false) ;;
        *)
            echo "FATAL: probe_matched must be 'true' or 'false' (got '$probe_matched')" >&2
            return 1
            ;;
    esac

    if [ ! -d "$release_dir" ]; then
        echo "FATAL: release dir '$release_dir' does not exist" >&2
        return 1
    fi
    local meta="$release_dir/release-meta.yaml"
    if [ ! -f "$meta" ]; then
        echo "FATAL: release-meta.yaml not found at $meta" >&2
        return 1
    fi

    {
        printf 'swapped_at: "%s"\n' "$(bv_yaml_quote_escape "$swapped_at")"
        printf 'swap_duration_ms: %s\n' "$swap_duration_ms"
        printf 'smoke_probe:\n'
        printf '  url: "%s"\n' "$(bv_yaml_quote_escape "$probe_url")"
        printf '  status: %s\n' "$probe_status"
        printf '  expected_version_substring: "%s"\n' "$(bv_yaml_quote_escape "$probe_substring")"
        printf '  matched: %s\n' "$probe_matched"
    } >> "$meta"
}

# Compute the smoke-probe's expected version substring from the
# release dir's VERSION + BUILD files. Single source of truth, used by
# both deploy.sh and rollback.sh.
#
# Format: "Version <X> · build <N>" — that middle dot is U+00B7
# (MIDDLE DOT), the same character the §Audit example uses. The
# substring is what we grep the smoke-probed body for.
bv_compute_expected_version_substring() {
    local release_dir="${1:?release dir required}"
    local version_file="$release_dir/VERSION"
    local build_file="$release_dir/BUILD"

    if [ ! -f "$version_file" ]; then
        echo "FATAL: VERSION file missing at $version_file" >&2
        return 1
    fi
    if [ ! -f "$build_file" ]; then
        echo "FATAL: BUILD file missing at $build_file" >&2
        return 1
    fi

    local version build
    version="$(tr -d '[:space:]' < "$version_file")"
    build="$(tr -d '[:space:]' < "$build_file")"
    if [ -z "$version" ] || [ -z "$build" ]; then
        echo "FATAL: VERSION or BUILD is empty" >&2
        return 1
    fi
    printf 'Version %s · build %s\n' "$version" "$build"
}

# Run the smoke probe. Single source of truth used by deploy.sh and
# rollback.sh.
#
# Args:
#   $1 — full URL to probe (validated by curl, not by us — but we
#        refuse anything that doesn't start with http:// or https://
#        as a defensive check).
#   $2 — expected substring; must appear verbatim in the response body.
#
# Echoes a single line of the form "<status>|<matched>" to stdout
# where <status> is the HTTP status code (or 0 if curl failed to
# connect) and <matched> is 'true' or 'false'.
#
# Returns 0 if status==200 AND substring matched, non-zero otherwise.
#
# Curl is invoked with -sS -L so transient redirects are followed but
# no shell interpolation is performed; --max-time guards against
# hangs. The response body goes to a tempfile (we don't pipe through
# shell to avoid metacharacter interpretation in the body).
bv_smoke_probe() {
    local url="${1:?url required}"
    local expected="${2:?expected substring required}"

    case "$url" in
        http://*|https://*) ;;
        *)
            echo "FATAL: smoke probe URL must start with http:// or https:// (got '$url')" >&2
            printf '0|false\n'
            return 1
            ;;
    esac

    local body_file status
    body_file="$(mktemp)"
    # shellcheck disable=SC2064  # we want $body_file expanded now
    trap "rm -f \"$body_file\"" RETURN

    # -o body_file: write body to file (avoids piping arbitrary bytes
    #               through the shell)
    # -w '%{http_code}': write status code to stdout
    # --max-time 30: hard cap on the probe (don't hang the deploy)
    # -L: follow redirects
    # -sS: silent but show errors
    if ! status="$(curl -sSL --max-time 30 -o "$body_file" -w '%{http_code}' "$url" 2>/dev/null)"; then
        # Curl failed to connect / DNS / TLS / etc. Status 0.
        printf '0|false\n'
        rm -f "$body_file"
        trap - RETURN
        return 1
    fi
    # Sanitise status — only digits.
    case "$status" in
        ''|*[!0-9]*)
            status=0
            ;;
    esac

    local matched=false
    if [ "$status" = "200" ] && grep -F -q -- "$expected" "$body_file" 2>/dev/null; then
        matched=true
    fi

    printf '%s|%s\n' "$status" "$matched"
    rm -f "$body_file"
    trap - RETURN

    if [ "$matched" = "true" ]; then
        return 0
    fi
    return 1
}

# Diagnose a failed smoke probe and emit a human-readable hint.
#
# Pure logic — no network calls. The caller is expected to capture the
# raw signals (status code, final URL after redirects, body file path,
# expected substring) and pass them in. Keeps the helper trivially
# unit-testable.
#
# Recognised failure modes:
#   - status=0                       → connection / DNS / TLS failure
#   - status in 500..599             → Grav crashed (or webserver error)
#   - final URL ends with /admin     → Grav setup wizard (no admin user)
#   - 200, version prefix in body    → upstream cache serving stale release
#   - 200, version prefix absent     → template not rendering / wrong page
#   - status in 400..499             → auth/route/path issue
#   - anything else                  → unknown
#
# Echoes one or two lines starting with "Likely cause:" / "Fix:" to
# stdout. Always returns 0; the caller decides exit behaviour.
bv_diagnose_probe_failure() {
    local status="${1:-0}"
    local final_url="${2:-}"
    local body_file="${3:-}"
    local expected="${4:-}"

    # status=0 means curl never got a response (connection failure)
    if [ "$status" = "0" ]; then
        printf '%s\n' "Likely cause: could not connect — check DNS, network, or TLS certificate."
        return 0
    fi

    # 5xx — Grav (or the webserver) crashed
    if [ "$status" -ge 500 ] 2>/dev/null && [ "$status" -lt 600 ] 2>/dev/null; then
        printf '%s\n' "Likely cause: Grav returned HTTP ${status}."
        printf '%s\n' "Fix: inspect the remote logs under <datadir>/logs/ for the stack trace."
        return 0
    fi

    # Grav setup-wizard redirect (no admin user → Grav redirects to /admin)
    case "$final_url" in
        */admin|*/admin/|*/admin\?*|*/admin/\?*)
            printf '%s\n' "Likely cause: Grav redirected to ${final_url} — no admin account exists on this tier."
            printf '%s\n' "Fix: restore a backup ('make restore tier=<env> from=<id>') or seed an admin account."
            return 0
            ;;
    esac

    if [ "$status" = "200" ]; then
        # Strip the build suffix from the expected string (e.g.
        # "Version 0.2.0 · build 131" → "Version 0.2.0"). If the
        # prefix is on the page but the full string isn't, the
        # version number drifted — Varnish or browser cache is the
        # most common cause on this hosting.
        local ver_prefix="${expected%% · build*}"
        if [ -n "$ver_prefix" ] \
           && [ -f "$body_file" ] \
           && grep -F -q -- "$ver_prefix" "$body_file" 2>/dev/null; then
            printf '%s\n' "Likely cause: the page is being served from an upstream cache (Varnish or browser) showing an older release."
            printf '%s\n' "Fix: wait ~30s for upstream cache expiry and re-check ${final_url:-the URL}, or invalidate the cache."
            return 0
        fi
        printf '%s\n' "Likely cause: 200 OK but the version banner is absent from the body."
        printf '%s\n' "Fix: check the page template rendered, and that ${final_url:-the URL} is the homepage (not a redirected admin/setup page)."
        return 0
    fi

    # 4xx — auth, route, path
    if [ "$status" -ge 400 ] 2>/dev/null && [ "$status" -lt 500 ] 2>/dev/null; then
        printf '%s\n' "Likely cause: HTTP ${status} from ${final_url:-the URL}."
        printf '%s\n' "Fix: confirm the URL path is correct and reachable without authentication."
        return 0
    fi

    printf '%s\n' "Unknown failure mode (status=${status}); inspect ${final_url:-the URL} manually."
    return 0
}

# Animate a braille spinner on stderr while a background pid is running.
#
# Usage:
#   long_running_cmd &
#   bv_spinner_while $! "Uploading"
#   wait $!
#
# Renders a single overwriting line on stderr: `  ⠋ Uploading… 12s`
# When the watched pid exits, the line is cleared. The function itself
# never returns non-zero (the caller is responsible for `wait`-ing on
# the child and checking its exit code).
#
# Non-TTY stderr (CI, pipes) short-circuits to a no-op so log files
# don't fill with control codes.
bv_spinner_while() {
    local pid="${1:?pid required}"
    local label="${2:-Working}"

    # Skip animation when stderr is not a terminal.
    if [ ! -t 2 ]; then
        wait "$pid" 2>/dev/null
        return 0
    fi

    # Braille glyph cycle — each element is a single multi-byte char.
    local glyphs=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local n_glyphs=${#glyphs[@]}
    local start_ts
    start_ts="$(date +%s)"
    local i=0

    # Hide cursor; ensure it's restored even if the caller is killed.
    printf '\033[?25l' >&2
    # shellcheck disable=SC2064
    trap "printf '\\033[?25h\\r\\033[K' >&2" RETURN

    while kill -0 "$pid" 2>/dev/null; do
        local glyph="${glyphs[$((i % n_glyphs))]}"
        local elapsed=$(( $(date +%s) - start_ts ))
        printf '\r  %s %s… %ds   ' "$glyph" "$label" "$elapsed" >&2
        sleep 0.15
        i=$((i + 1))
    done

    printf '\033[?25h\r\033[K' >&2
    trap - RETURN
    return 0
}

# Verify the previous release dir's data symlinks resolve.
#
# Per §Symlink contract: accounts/, user/data/, logs/ MUST resolve
# (Phase 2 will gate this on data-version matching). The two
# security.yaml symlinks are allowed to dangle — Grav regenerates them
# on first request.
#
# Caller passes the release dir path. Returns 0 if all three resolve;
# non-zero with diagnostic on stderr if any dangle.
bv_check_previous_release_data_symlinks() {
    local release_dir="${1:?release dir required}"

    if [ ! -d "$release_dir" ]; then
        echo "FATAL: release dir '$release_dir' does not exist" >&2
        return 1
    fi

    local sym path bad=0
    # Note the security.yaml pair are explicitly NOT in this list —
    # they're allowed to dangle.
    for sym in "user/accounts" "user/data" "logs"; do
        path="$release_dir/$sym"
        if [ ! -L "$path" ]; then
            echo "FATAL: expected symlink at $sym in previous release dir, but none found" >&2
            bad=$((bad+1))
            continue
        fi
        # -e on a symlink follows it, so `! -e` means "dangling".
        if [ ! -e "$path" ]; then
            local target
            target="$(readlink "$path" 2>/dev/null || echo "<unreadable>")"
            echo "FATAL: data symlink dangles in previous release: $sym -> $target" >&2
            bad=$((bad+1))
        fi
    done

    if [ "$bad" -gt 0 ]; then
        return 1
    fi
    return 0
}

# Append a single rollback row to <releases-dir>/rollback-log.yaml.
#
# Format: each row is a YAML list element (- key: value …). The file
# is appended to, never overwritten — chronology preserved across runs.
# greppable-without-yaml-library: every field is a literal key on its
# own line within the row, so `grep '^  to_release: '` etc. works.
#
# Quoting discipline mirrors bv_write_release_meta_yaml_full.
bv_append_rollback_log_row() {
    local releases_dir="${1:?releases dir required}"
    local rolled_back_at="${2:?rolled_back_at required}"
    local rolled_back_by="${3:?rolled_back_by required}"
    local from_release="${4:?from_release required}"
    local to_release="${5:?to_release required}"
    local swap_duration_ms="${6:?swap_duration_ms required}"
    local probe_url="${7:-}"
    local probe_status="${8:-0}"
    local probe_substring="${9:-}"
    local probe_matched="${10:-false}"

    if ! bv_validate_release_id "$from_release"; then
        return 1
    fi
    if ! bv_validate_release_id "$to_release"; then
        return 1
    fi
    case "$swap_duration_ms" in
        ''|*[!0-9]*)
            echo "FATAL: swap_duration_ms must be a non-negative integer" >&2
            return 1
            ;;
    esac
    case "$probe_status" in
        ''|*[!0-9]*)
            echo "FATAL: probe_status must be a non-negative integer" >&2
            return 1
            ;;
    esac
    case "$probe_matched" in
        true|false) ;;
        *)
            echo "FATAL: probe_matched must be 'true' or 'false'" >&2
            return 1
            ;;
    esac

    if [ ! -d "$releases_dir" ]; then
        echo "FATAL: releases dir '$releases_dir' does not exist" >&2
        return 1
    fi

    local log="$releases_dir/rollback-log.yaml"

    # Header on first write, comment-only — no list start needed; YAML
    # accepts a stream of `- key:` rows directly.
    if [ ! -f "$log" ]; then
        {
            printf '# rollback-log.yaml — append-only audit log of rollback invocations\n'
            printf '# Each row records: rolled_back_at, rolled_back_by, from_release,\n'
            printf '#                   to_release, swap_duration_ms, smoke_probe.{url,status,expected_version_substring,matched}\n'
        } > "$log"
    fi

    {
        printf -- '- rolled_back_at: "%s"\n' "$(bv_yaml_quote_escape "$rolled_back_at")"
        printf '  rolled_back_by: "%s"\n' "$(bv_yaml_quote_escape "$rolled_back_by")"
        printf '  from_release: %s\n' "$from_release"
        printf '  to_release: %s\n' "$to_release"
        printf '  swap_duration_ms: %s\n' "$swap_duration_ms"
        printf '  smoke_probe:\n'
        printf '    url: "%s"\n' "$(bv_yaml_quote_escape "$probe_url")"
        printf '    status: %s\n' "$probe_status"
        printf '    expected_version_substring: "%s"\n' "$(bv_yaml_quote_escape "$probe_substring")"
        printf '    matched: %s\n' "$probe_matched"
    } >> "$log"
}

# Read previous_release out of a release-meta.yaml and emit it on
# stdout. Validates the value against the strict release-id regex
# BEFORE returning it — caller can use the output as a path component
# without re-validating.
#
# Refuses to emit anything if the file is missing, the field is
# missing, the field is empty, or the value fails the regex.
bv_read_previous_release_id() {
    local meta="${1:?release-meta.yaml path required}"

    if [ ! -f "$meta" ]; then
        echo "FATAL: release-meta.yaml not found at $meta" >&2
        return 1
    fi

    # Read the previous_release value. Strip leading/trailing whitespace
    # and a single layer of double quotes. We use awk -F': ' on the
    # FIRST occurrence of ^previous_release: only.
    local raw
    raw="$(awk '
        /^previous_release:/ {
            sub(/^previous_release:[[:space:]]*/, "")
            sub(/[[:space:]]+$/, "")
            # strip one layer of double quotes if present
            if (length($0) >= 2 && substr($0,1,1)=="\"" && substr($0,length($0),1)=="\"") {
                $0 = substr($0, 2, length($0)-2)
            }
            print
            exit
        }
    ' "$meta")"

    if [ -z "$raw" ]; then
        echo "FATAL: previous_release is empty in $meta — first deploy or corrupt meta" >&2
        return 1
    fi

    # Strict regex validation BEFORE the value is used as a path
    # component anywhere downstream. Defence in depth: explicit checks
    # for forbidden patterns first.
    case "$raw" in
        *..*|*/*|-*)
            echo "FATAL: previous_release value '$raw' contains forbidden characters (path traversal)" >&2
            return 1
            ;;
    esac
    if ! bv_validate_release_id "$raw" 2>/dev/null; then
        echo "FATAL: previous_release value '$raw' does not match expected release-id regex" >&2
        return 1
    fi

    printf '%s\n' "$raw"
}

# ─────────────────────────────────────────────────────────────────────
# Shared utilities (post-PR-#17 review follow-up).
# ─────────────────────────────────────────────────────────────────────

# Escape backslashes and double-quotes so a value is safe to embed in an
# inline-double-quoted YAML scalar. Single source of truth — used by
# release-meta and rollback-log writers (and by migrate.sh's bootstrap
# meta emission).
bv_yaml_quote_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Probe for GNU coreutils' `date +%s%N` (ms resolution). Apple BSD
# `date` only gives seconds — without coreutils a single-digit-second
# swap would round to 0-999 ms with no useful precision, defeating the
# purpose of swap_duration_ms in release-meta.yaml.
#
# Caller invokes this once at script top; if it exits non-zero we
# abort BEFORE any state mutation. macOS needs `brew install coreutils`
# (which installs gdate plus a `date` shim under /opt/homebrew/bin).
bv_require_ms_timing() {
    local probe
    probe="$(date +%s%N 2>/dev/null || true)"
    # POSIX case glob — works on bash 3.2 (macOS Intel default) without
    # the bash-4-only ${probe: -1} negative-substring syntax we shipped
    # in the first follow-up. The regression mode under bash 3.2 was a
    # parse error inside [ ], silent exit 0 — strictly worse than the
    # diagnostic this branch produces.
    case "$probe" in
        ''|*N)
            echo "❌  ms-resolution timing requires GNU coreutils." >&2
            echo "    On macOS:    brew install coreutils  (then re-run)" >&2
            echo "    On Linux:    your packaged \`date\` already supports %N — check PATH." >&2
            return 1
            ;;
    esac
    return 0
}

# Echo current monotonic-ish time in milliseconds (epoch-based; not
# strictly monotonic but good enough for swap_duration_ms accounting
# over a single ln-sfn invocation). Trusts the caller has already run
# bv_require_ms_timing and the probe succeeded.
bv_now_ms() {
    printf '%s\n' "$(( $(date +%s%N) / 1000000 ))"
}

# Scan a built staging dir for git-lfs pointer files. A pointer is the
# tiny (~130-byte) text file that lives in a worktree which hasn't run
# `git lfs checkout` — its first line is literally
#     version https://git-lfs.github.com/spec/v1
# Without this guard, rsync ships the pointers verbatim to the remote;
# browsers fetch 131-byte "JPEG" responses that won't render, and the
# smoke probe still passes because HTTP returns 200. Result: every LFS-
# tracked asset on the deployed site looks broken.
#
# Returns 0 if the staging tree is clean, 1 if any pointer is found
# (with an operator-readable list + recovery command on stderr). The
# scan is bounded to files ≤ 200 bytes for speed — real LFS pointers
# are always tiny; binary assets are always larger. Failure mode is
# fail-loud-before-rsync, not silent-rsync-of-broken-bundle.
bv_check_no_lfs_pointers() {
    local staging_dir="${1:-}"
    if [ -z "$staging_dir" ] || [ ! -d "$staging_dir" ]; then
        echo "FATAL: bv_check_no_lfs_pointers requires an existing staging-dir argument" >&2
        return 2
    fi

    local hits
    # find -size -200c restricts to candidates small enough to plausibly
    # be a pointer. grep -l prints filenames of matches. The magic line
    # is the version: URL — checking that substring is enough; pointer
    # format guarantees it on line 1.
    hits="$(find "$staging_dir" -type f -size -200c \
            -exec grep -l "git-lfs.github.com/spec/v1" {} + 2>/dev/null \
            || true)"
    if [ -n "$hits" ]; then
        echo "" >&2
        echo "❌  Git LFS pointer files found in the deploy bundle." >&2
        echo "    These are tiny text files (~131 bytes) — the real binary" >&2
        echo "    is stored in LFS. Deploying these breaks every LFS-tracked" >&2
        echo "    asset on the site (browsers receive 131 bytes of YAML and" >&2
        echo "    fail to render). The smoke probe will still pass because" >&2
        echo "    HTTP returns 200 — so this is a silent regression class." >&2
        echo "" >&2
        echo "    Recover by materialising the LFS objects in this checkout:" >&2
        echo "" >&2
        echo "        git lfs checkout" >&2
        echo "" >&2
        echo "    Then re-run the deploy. Pointer files found:" >&2
        printf '%s\n' "$hits" | sed "s|^$staging_dir/|      • |" >&2
        echo "" >&2
        return 1
    fi
    return 0
}

# Dispatch a bash body to the remote configured by the caller's
# DEPLOY_HOST/USER/PASS/PORT environment. Values are passed as named
# environment variables on the remote side, NOT interpolated into the
# script string — every KEY=VALUE pair is `printf %q`-quoted before
# being emitted as a remote-side `export`, then the body runs with the
# vars in scope and uses them via "$KEY".
#
# Why this exists: the naive `ssh "$host" "test -w $PATH"` pattern
# concatenates $PATH unquoted into the remote command line. ssh joins
# its args with spaces and the remote shell re-parses, so a value
# containing whitespace, a glob, or a shell metacharacter executes
# uncontrolled code on the remote. This helper closes that surface for
# every dynamic value — the only thing flowing into the remote shell is
# the body string itself (caller-controlled, never operator-controlled)
# and `printf %q`-quoted exports.
#
# Usage:
#   bv_remote_run '
#       test -w "$PARENT" || mkdir -p "$RELEASES" "$DATA"
#   ' \
#       PARENT="$DEPLOY_DOCROOT_PARENT" \
#       RELEASES="$RELEASES_DIR" \
#       DATA="$DATA_DIR"
#
# Or, to capture remote stdout:
#   STATE="$(bv_remote_run 'if [ -L "$T" ]; then echo symlink; else echo other; fi' T="$DEPLOY_TARGET")"
#
# Allowed keys: caller-defined upper-case identifiers matching
# `[A-Z_][A-Z0-9_]*`. Lower-case identifiers, mixed-case identifiers,
# numeric prefixes, and known-dangerous environment names are all
# rejected. The allowlist shape is the principled choice — it makes
# adding a new call site noisier on purpose, since the convention is
# "if it goes through bv_remote_run, the key is UPPER_CASE".
#
# Why an allowlist and not a denylist: shell environments inherit
# behaviour from a long tail of variables (IFS, BASH_ENV, PROMPT_COMMAND,
# PS4, SHELL, SHELLOPTS, BASHOPTS, CDPATH, ENV, BASH_FUNC_*, plus the
# original SSHPASS/PATH/HOME/USER/LD_*/DYLD_* set). Enumerating them
# all is a maintenance trap; requiring upper-case identifiers is a
# single rule that excludes every reserved name (which by convention
# is also upper-case but typically named distinctively, e.g. PATH not
# PARENT — and our explicit denylist below catches the remaining
# overlap) while keeping caller-side intent obvious.
#
# The explicit denylist below covers the upper-case identifiers a
# caller might plausibly pick that ARE reserved. Adding to it is
# cheap; the caller-side cost of a false positive is "rename your
# variable to something that isn't a documented shell-internal name".
#
# Remote-side shell discipline (load-bearing for body authors):
# The body always runs under `set -euo pipefail` — the helper prepends
# it before the body. Three implications:
#   * An unset variable is a fatal error on the remote even if local
#     callers are lax about defaults. Use "${X:-fallback}" inside the
#     body if a value might legitimately be empty.
#   * Pipelines fail if ANY stage exits non-zero. Patterns like
#     `grep -c something` (returns 1 on no-match) or `cmd | head`
#     (SIGPIPE on upstream) need explicit `|| true` if the non-zero
#     exit is tolerated. The retention pruner's
#     `grep -c . || true` is the canonical example.
#   * `set -e` aborts on the first non-zero exit. Wrap test commands
#     in `if`, guard `while read` against empty streams, etc.
# This is a deliberate hardening choice — the alternative (permissive
# remote shell) means a remote-side failure can go undetected until
# the deploy completes badly.
bv_remote_run() {
    # Explicit input validation via `return 1` (NOT `${var:?msg}`) so
    # callers can gracefully `if bv_remote_run ...; then ... fi` against
    # rejection paths. The `:?` form exits the entire shell, which makes
    # the rejection paths impossible to test in a fixture.
    if [ -z "${1:-}" ]; then
        echo "FATAL: bv_remote_run requires a body argument" >&2
        return 1
    fi
    local body="$1"
    shift

    if [ -z "${DEPLOY_HOST:-}" ]; then
        echo "FATAL: bv_remote_run requires DEPLOY_HOST" >&2
        return 1
    fi
    if [ -z "${DEPLOY_USER:-}" ]; then
        echo "FATAL: bv_remote_run requires DEPLOY_USER" >&2
        return 1
    fi
    # DEPLOY_PASS is OPTIONAL since the key-auth bring-up:
    #   * Empty  → key-auth path (bv_ssh_cmd's BatchMode=yes branch).
    #              Used by prod against chosting.dk where SSH-keys are
    #              the only supported auth mode per the cPanel default.
    #   * Set    → password-auth path (sshpass). Used by dev/test/staging
    #              against one.com hackersbychoice.dk.
    # Both paths converge on bv_ssh_cmd below; the helper picks the right
    # one based on whether a password is resolved for the active TIER.
    if [ -z "${DEPLOY_PORT:-}" ]; then
        echo "FATAL: bv_remote_run requires DEPLOY_PORT" >&2
        return 1
    fi

    local script_input
    script_input="$(
        local kv k v
        for kv in "$@"; do
            # Reject malformed KEY=VALUE shapes early.
            case "$kv" in
                *=*) ;;
                *)
                    echo "FATAL: bv_remote_run argument '$kv' must be KEY=VALUE" >&2
                    return 1
                    ;;
            esac
            k="${kv%%=*}"
            v="${kv#*=}"
            # ALLOWLIST: upper-case shell identifiers only.
            # `[A-Z_]` for the first char, `[A-Z0-9_]*` for the rest —
            # POSIX-portable case-glob shape that excludes lower-case,
            # numeric-prefix, and any character outside the alphabet.
            # `_` alone is also rejected — it's the conventional
            # "throwaway / unused" name and would be a smell as a
            # remote env var.
            case "$k" in
                ''|_|[!A-Z_]*|*[!A-Z0-9_]*)
                    echo "FATAL: bv_remote_run refuses key '$k' — must match [A-Z_][A-Z0-9_]* (upper-case shell identifier; bare '_' rejected)" >&2
                    return 1
                    ;;
            esac
            # DENYLIST (defence in depth): even within the upper-case
            # shape, certain identifiers change shell behaviour or leak
            # secrets and must never be set by callers.
            case "$k" in
                SSHPASS|PATH|HOME|USER|SHELL|SHELLOPTS|BASHOPTS|IFS|\
                BASH_ENV|PROMPT_COMMAND|PS1|PS2|PS3|PS4|CDPATH|ENV|\
                LD_*|DYLD_*|BASH_FUNC_*)
                    echo "FATAL: bv_remote_run refuses to set remote env var '$k' (reserved / dangerous)" >&2
                    return 1
                    ;;
            esac
            # printf %q produces a value safe to be eaten by `export KEY=...`
            # on the remote. The remote shell sees the export as
            # `export KEY=value` where `value` is whatever quoting form
            # printf %q chose.
            printf 'export %s=%q\n' "$k" "$v"
        done
        printf 'set -euo pipefail\n'
        printf '%s\n' "$body"
    )" || return $?

    # Dispatch via bv_ssh_cmd from ssh-auth.sh — picks sshpass vs bare
    # ssh+BatchMode=yes based on whether bv_resolve_ssh_password yields
    # a password for the active TIER. Lazy-source the helper here so
    # callers (like the unit-remote-run.sh fixture) that don't preload
    # ssh-auth.sh still get the dispatch behaviour.
    if ! declare -F bv_ssh_cmd >/dev/null 2>&1; then
        local _lib_dir
        _lib_dir="$(dirname "${BASH_SOURCE[0]}")"
        # shellcheck source=ssh-auth.sh
        . "$_lib_dir/ssh-auth.sh"
    fi

    bv_ssh_cmd -p "$DEPLOY_PORT" "${DEPLOY_USER}@${DEPLOY_HOST}" \
        bash -s <<<"$script_input"
}
