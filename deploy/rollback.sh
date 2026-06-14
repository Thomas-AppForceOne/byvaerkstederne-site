#!/usr/bin/env bash
# Resolve a PATH-driven bash so /opt/homebrew/bin (Homebrew bash 5+)
# is picked up. /bin/bash on macOS is bash 3.2, which fails to parse
# nested-quoting inside $(...) constructs that the lib uses.
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

# Hard requirement: bash 4+. See deploy.sh's matching check for context.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "❌  bash 4+ required (this is bash ${BASH_VERSION:-?}). On macOS:" >&2
    echo "      brew install bash" >&2
    echo "    Then ensure /opt/homebrew/bin is on PATH ahead of /usr/bin." >&2
    exit 1
fi

# =============================================================================
# Byværkstederne — Rollback to the previous atomic release
# Usage: ./deploy/rollback.sh <environment>
#   Environments: dev, test, staging, prod
# =============================================================================
#
# Reads the previous-release id from
#   <tier>-releases/<current>/release-meta.yaml
# and atomically swaps the docroot symlink back to it via `ln -sfn`.
# Then runs the same smoke probe deploy.sh runs, and appends an audit
# row to <tier>-releases/rollback-log.yaml.
#
# Refuses (non-zero exit, BEFORE the swap, docroot unchanged) if:
#   * env name is not in the closed set {dev,test,staging,prod}
#   * no <tier>-releases/<current>/release-meta.yaml exists
#   * previous_release is empty / missing / fails the strict release-id
#     regex (^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$)
#   * the previous release dir was pruned (no longer on disk)
#   * the previous release's data symlinks (accounts/, user/data/,
#     logs/) dangle — Phase-2 hook for cross-schema rollback
#
# Rollback is MANUAL by design. Smoke-probe failure on rollback is
# fail-loud (exit non-zero, audit row records matched=false) but the
# rolled-back release stays LIVE. The operator's next move is to roll
# forward again, fix the bug, redeploy.
#
# Concurrency: SINGLE-OPERATOR ONLY. The rollback-log.yaml append is
# unguarded — two simultaneous `rollback.sh <env>` invocations against
# the same tier could interleave their audit rows, and (worse) the
# `ln -sfn` swap is not serialised between operators. If the project
# ever grows automated/scheduled rollbacks, wire `flock(1)` around the
# log append AND a per-tier lockfile around the swap. Until then, the
# operator-supervised contract (one human running one make-target at a
# time) is the synchronisation primitive.
#
# Local-fixture mode (used by tests/deploy/rollback.sh):
#   * BV_ROLLBACK_LOCAL_PARENT=<dir>  — operate against a local parent
#                                       dir instead of an ssh remote.
#   * BV_SMOKE_PROBE_URL_OVERRIDE=<url> — point the probe at a stub
#                                         HTTP responder.
#   * BV_ROLLBACK_DEPLOYED_BY=<email>   — override the audit row's
#                                         rolled_back_by (so the test
#                                         can assert a known value).
#
# Security:
#   * Tier name validated against the closed set BEFORE any path
#     concat. Anything else exits non-zero with a usage diagnostic.
#   * previous_release value parsed out of YAML is validated against
#     the strict release-id regex BEFORE use as a path component, ln
#     target, or anywhere else. Forbids '..', '/', leading '-', and
#     any shell metacharacter.
#   * Every variable that flows into ln, rm, ssh, curl is double-
#     quoted and passed as a separate argument. No eval. No string-
#     concatenated commands.
#   * The ONLY filesystem mutation against the docroot is a single
#     `ln -sfn` call. No rsync, no rm against <tier> or <tier>data/.
#   * The rollback audit log is appended to <releases-dir>/rollback-
#     log.yaml — never to <tier>data/.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=deploy/lib/atomic-release.sh
. "$SCRIPT_DIR/lib/atomic-release.sh"
# shellcheck source=deploy/lib/banner.sh
. "$SCRIPT_DIR/lib/banner.sh"
# shellcheck source=deploy/lib/migrate-integration.sh
# Provides bv_version_to_dirname (0.2.0 → v_0_2_0) — used by the
# post-swap bookkeeping step to map a rolled-back release's recorded
# data_version onto its versioned-data-dir name. Pure shell; no ssh.
. "$SCRIPT_DIR/lib/migrate-integration.sh"

# Non-fatal warning to stderr (the bookkeeping step is best-effort:
# a failure to repoint current must never abort a rollback whose docroot
# swap already succeeded).
warn() { printf '⚠  %s\n' "$*" >&2; }

# Require GNU coreutils for ms-resolution swap_duration_ms timing in
# the rollback audit row. Fail loud BEFORE we touch any path. macOS
# needs `brew install coreutils`.
bv_require_ms_timing

# =============================================================================
# Step 0 — Closed-set env validation BEFORE any path concat
# =============================================================================

ENV_RAW="${1:-}"
if [ -z "$ENV_RAW" ]; then
    echo "❌  Usage: $0 <dev|test|staging|prod>" >&2
    echo "    Rollback is the inverse of deploy. The previous release" >&2
    echo "    is read from <tier>-releases/<current>/release-meta.yaml." >&2
    echo "    Audit trail: <tier>-releases/rollback-log.yaml" >&2
    exit 1
fi

if ! ENV="$(bv_validate_tier_name "$ENV_RAW")"; then
    echo "    Usage: $0 <dev|test|staging|prod>" >&2
    exit 1
fi

# Apex landing has no rollback story (no mutable state, no atomic
# layout). Refuse explicitly so the operator gets a clear diagnostic
# rather than ssh-ing into an in-place tier and finding nothing.
if [ "$ENV" = "landing" ]; then
    echo "❌  No rollback for the apex landing tier." >&2
    echo "    Landing has no mutable state and no atomic layout — there" >&2
    echo "    is nothing to swap back to. Re-deploy the previous commit" >&2
    echo "    via 'make deploy tier=landing' instead." >&2
    exit 1
fi

case "$ENV" in
    prod)
        ENV_LABEL="Production"
        ENV_SUBFOLDER=""
        ENV_URL="https://www.byvaerkstederne.dk"
        ;;
    staging)
        ENV_LABEL="Staging"
        ENV_SUBFOLDER="/staging"
        ENV_URL="https://staging.hackersbychoice.dk"
        ;;
    test)
        ENV_LABEL="Test"
        ENV_SUBFOLDER="/test"
        ENV_URL="https://test.hackersbychoice.dk"
        ;;
    dev)
        ENV_LABEL="Development"
        ENV_SUBFOLDER="/dev"
        ENV_URL="https://dev.hackersbychoice.dk"
        ;;
    *)
        echo "❌  Internal: env '$ENV' passed validation but has no path config." >&2
        exit 1
        ;;
esac

# =============================================================================
# Local-fixture mode — used by tests/deploy/rollback.sh.
# =============================================================================
#
# When BV_ROLLBACK_LOCAL_PARENT is set, we skip all ssh and operate
# directly against a local parent dir. The layout under that parent is
# the same as the remote layout the deploy script produces:
#
#   <parent>/<tier>                       — symlink (the docroot)
#   <parent>/<tier>-releases/<release-id>/
#   <parent>/<tier>data/...
#
# This lets the shell-level probe drive rollback.sh end-to-end without
# needing a real remote.

LOCAL_MODE=0
if [ -n "${BV_ROLLBACK_LOCAL_PARENT:-}" ]; then
    LOCAL_MODE=1
    if [ ! -d "$BV_ROLLBACK_LOCAL_PARENT" ]; then
        echo "❌  BV_ROLLBACK_LOCAL_PARENT='$BV_ROLLBACK_LOCAL_PARENT' is not a directory" >&2
        exit 1
    fi
    DEPLOY_DOCROOT_PARENT="$BV_ROLLBACK_LOCAL_PARENT"
    DEPLOY_TARGET="$BV_ROLLBACK_LOCAL_PARENT/$ENV"
    LAYOUT_NAME="$ENV"
fi

if [ "$LOCAL_MODE" = "0" ]; then
    # Real remote — load credentials from .env.deploy.
    ENV_FILE="$PROJECT_DIR/.env.deploy"
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌  Missing .env.deploy — copy .env.deploy.example and fill in credentials" >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    # Resolve the SSH password via env-var or macOS Keychain
    # (DEPLOY_PASS_KEYCHAIN / DEPLOY_PROD_PASS_KEYCHAIN). Same shape
    # as deploy.sh — keeps bv_remote_run's DEPLOY_PASS check happy
    # without forcing the operator to leave plaintext in .env.deploy.
    # shellcheck source=deploy/lib/ssh-auth.sh
    . "$SCRIPT_DIR/lib/ssh-auth.sh"
    TIER="$ENV"
    if [ "$ENV" = "prod" ]; then
        DEPLOY_PROD_PASS="$(bv_resolve_ssh_password)"
    else
        DEPLOY_PASS="$(bv_resolve_ssh_password)"
    fi

    if [ "$ENV" = "prod" ]; then
        : "${DEPLOY_PROD_HOST:?prod rollback requires DEPLOY_PROD_HOST in .env.deploy}"
        : "${DEPLOY_PROD_USER:?prod rollback requires DEPLOY_PROD_USER in .env.deploy}"
        : "${DEPLOY_PROD_PASS:?prod rollback requires DEPLOY_PROD_PASS in .env.deploy}"
        : "${DEPLOY_PROD_PATH:?prod rollback requires DEPLOY_PROD_PATH in .env.deploy}"
        DEPLOY_HOST="$DEPLOY_PROD_HOST"
        DEPLOY_USER="$DEPLOY_PROD_USER"
        DEPLOY_PASS="$DEPLOY_PROD_PASS"
        DEPLOY_PORT="${DEPLOY_PROD_PORT:-${DEPLOY_PORT}}"
        DEPLOY_PATH="$DEPLOY_PROD_PATH"
    fi

    DEPLOY_TARGET="${DEPLOY_PATH:-}${ENV_SUBFOLDER}"
    DEPLOY_DOCROOT_PARENT="$(dirname "$DEPLOY_TARGET")"
    DEPLOY_DOCROOT_NAME="$(basename "$DEPLOY_TARGET")"
    if [ -z "$ENV_SUBFOLDER" ]; then
        LAYOUT_NAME="$ENV"
    else
        LAYOUT_NAME="$DEPLOY_DOCROOT_NAME"
    fi
fi

RELEASES_DIR="${DEPLOY_DOCROOT_PARENT}/${LAYOUT_NAME}-releases"
DATA_DIR="${DEPLOY_DOCROOT_PARENT}/${LAYOUT_NAME}data"

# Wrappers around remote vs local execution. The remote case dispatches
# through bv_remote_run (in deploy/lib/atomic-release.sh) — values flow
# as printf %q-quoted remote-side env exports, never via direct shell-
# string interpolation. See the helper's docblock for the security
# rationale.

# read_remote_file <remote-path>  → echoes contents on stdout
read_remote_file() {
    local p="$1"
    if [ "$LOCAL_MODE" = "1" ]; then
        cat "$p"
    else
        bv_remote_run 'cat "$P"' P="$p"
    fi
}

# remote_test_d <remote-path>  → returns 0 if a directory exists
remote_test_d() {
    local p="$1"
    if [ "$LOCAL_MODE" = "1" ]; then
        [ -d "$p" ]
    else
        bv_remote_run 'test -d "$P"' P="$p"
    fi
}

# remote_readlink_basename <remote-symlink>  → echoes basename of target
remote_readlink_basename() {
    local p="$1"
    if [ "$LOCAL_MODE" = "1" ]; then
        basename "$(readlink "$p")"
    else
        bv_remote_run 'basename "$(readlink "$P")"' P="$p"
    fi
}

# Atomic swap. Single ln -sfn — no pre-rm of the old symlink.
# The release-id and layout-name are both validated upstream before
# this is called.
remote_atomic_swap() {
    local target_release_id="$1"
    if [ "$LOCAL_MODE" = "1" ]; then
        ln -sfn "${LAYOUT_NAME}-releases/${target_release_id}" "$DEPLOY_TARGET"
    else
        bv_remote_run 'ln -sfn "$TARGET_REL" "$DEPLOY_TARGET"' \
            TARGET_REL="${LAYOUT_NAME}-releases/${target_release_id}" \
            DEPLOY_TARGET="$DEPLOY_TARGET"
    fi
}

# =============================================================================
# Banner
# =============================================================================

draw_banner() {
    local lines=("$@") line max=0 w pad inner border
    _w() { printf '%s' "$1" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' '; }
    for line in "${lines[@]}"; do
        w=$(_w "$line")
        [ "$w" -gt "$max" ] && max="$w"
    done
    inner=$((max + 4))
    border=$(printf '═%.0s' $(seq 1 "$inner"))
    echo ""
    echo "  ╔${border}╗"
    for line in "${lines[@]}"; do
        w=$(_w "$line")
        pad=$((max - w))
        printf "  ║  %s%*s  ║\n" "$line" "$pad" ""
    done
    echo "  ╚${border}╝"
    echo ""
}

draw_banner \
    "Byværkstederne — Rollback" \
    "Environment: ${ENV_LABEL}" \
    "Target: ${DEPLOY_TARGET}"

# =============================================================================
# Step 1 — Resolve the current release id
# =============================================================================

echo "→ Step 1/5: Resolving current release..."

# The docroot must be a symlink resolving to a release-id-shaped name.
# If it's anything else (real dir, missing, junk target), refuse —
# rollback only makes sense against an atomic-layout tier.
if [ "$LOCAL_MODE" = "1" ]; then
    if [ ! -L "$DEPLOY_TARGET" ]; then
        echo "❌  Docroot ${DEPLOY_TARGET} is not a symlink — tier is not in atomic layout." >&2
        echo "    Run deploy/migrate-to-atomic-layout.sh ${ENV} (Sprint 3) first." >&2
        exit 1
    fi
else
    DOCROOT_KIND="$(bv_remote_run '
        if [ -L "$DEPLOY_TARGET" ]; then
            echo symlink
        elif [ -e "$DEPLOY_TARGET" ]; then
            echo other
        else
            echo absent
        fi
    ' DEPLOY_TARGET="$DEPLOY_TARGET")"
    if [ "$DOCROOT_KIND" != "symlink" ]; then
        echo "❌  Docroot ${DEPLOY_TARGET} is not a symlink (state: $DOCROOT_KIND)." >&2
        echo "    Tier is not in atomic layout. Migrate first (Sprint 3)." >&2
        exit 1
    fi
fi

CURRENT_RELEASE_ID="$(remote_readlink_basename "$DEPLOY_TARGET" 2>/dev/null || echo "")"
if [ -z "$CURRENT_RELEASE_ID" ]; then
    echo "❌  Could not read current release id from ${DEPLOY_TARGET}" >&2
    exit 1
fi

# Strict regex on the current release id BEFORE we use it as a path
# component. The deploy script wrote it through the regex; if we're
# reading something else back, refuse.
if ! bv_validate_release_id "$CURRENT_RELEASE_ID" 2>/dev/null; then
    echo "❌  Current release id '${CURRENT_RELEASE_ID}' fails regex validation." >&2
    echo "    Refusing to proceed — the docroot symlink target is not a valid release id." >&2
    exit 1
fi

CURRENT_RELEASE_DIR="${RELEASES_DIR}/${CURRENT_RELEASE_ID}"
CURRENT_META_PATH="${CURRENT_RELEASE_DIR}/release-meta.yaml"

echo "  ✓ Current release: ${CURRENT_RELEASE_ID}"

# =============================================================================
# Step 2 — Read previous_release and validate
# =============================================================================

echo "→ Step 2/5: Reading previous_release from ${CURRENT_META_PATH}..."

# In remote mode we read the meta into a local tempfile so the regex
# validator can run in this shell without sending the value back over
# ssh.
META_TMP="$(mktemp)"
trap 'rm -f "$META_TMP"' EXIT

if [ "$LOCAL_MODE" = "1" ]; then
    if [ ! -f "$CURRENT_META_PATH" ]; then
        echo "❌  release-meta.yaml not found at ${CURRENT_META_PATH}" >&2
        echo "    Cannot determine the rollback target." >&2
        exit 1
    fi
    cp "$CURRENT_META_PATH" "$META_TMP"
else
    if ! bv_remote_run 'test -f "$P"' P="$CURRENT_META_PATH"; then
        echo "❌  release-meta.yaml not found at ${CURRENT_META_PATH}" >&2
        exit 1
    fi
    if ! read_remote_file "$CURRENT_META_PATH" > "$META_TMP"; then
        echo "❌  Failed to read ${CURRENT_META_PATH}" >&2
        exit 1
    fi
fi

# bv_read_previous_release_id validates the value against the strict
# regex BEFORE returning it, so PREV_RELEASE_ID is safe to use as a
# path component on the next line.
if ! PREV_RELEASE_ID="$(bv_read_previous_release_id "$META_TMP")"; then
    echo "❌  Cannot read a valid previous_release from release-meta.yaml." >&2
    echo "    Either this is the first deploy (no previous release), the" >&2
    echo "    meta file is corrupt, or someone tampered with previous_release." >&2
    exit 1
fi

# Defence in depth: re-validate before use.
if ! bv_validate_release_id "$PREV_RELEASE_ID" 2>/dev/null; then
    echo "❌  previous_release='$PREV_RELEASE_ID' fails regex validation." >&2
    exit 1
fi
if [ "$PREV_RELEASE_ID" = "$CURRENT_RELEASE_ID" ]; then
    echo "❌  previous_release equals current release id ('$CURRENT_RELEASE_ID')." >&2
    echo "    Refusing to no-op rollback." >&2
    exit 1
fi

PREV_RELEASE_DIR="${RELEASES_DIR}/${PREV_RELEASE_ID}"
echo "  ✓ Previous release: ${PREV_RELEASE_ID}"

# =============================================================================
# Step 3 — Confirm the previous release dir exists and its data symlinks resolve
# =============================================================================

echo "→ Step 3/5: Confirming previous release is on disk..."

if ! remote_test_d "$PREV_RELEASE_DIR"; then
    echo "" >&2
    echo "❌  Previous release directory is missing: ${PREV_RELEASE_DIR}" >&2
    echo "    The release id '${PREV_RELEASE_ID}' was pruned past retention," >&2
    echo "    or never created. Cannot roll back to a release that no longer" >&2
    echo "    exists on disk." >&2
    echo "" >&2
    echo "    Inspect: ls ${RELEASES_DIR}/" >&2
    exit 1
fi

# Phase-2 hook: confirm the previous release's data symlinks resolve.
# In Phase 1 this only fires if someone hand-edited <tier>data/, but
# we wire the check so Phase 2 inherits the gate.
#
# In remote mode we check via ssh; in local mode we run the lib helper
# directly.
if [ "$LOCAL_MODE" = "1" ]; then
    if ! bv_check_previous_release_data_symlinks "$PREV_RELEASE_DIR"; then
        echo "" >&2
        echo "❌  Previous release '${PREV_RELEASE_ID}' has dangling data symlinks." >&2
        echo "    This is the Phase-2 cross-schema-rollback gate firing in Phase 1," >&2
        echo "    which means someone hand-edited <tier>data/ between deploys." >&2
        echo "    Refusing to swap the docroot at a release whose live data is" >&2
        echo "    not coherent. Inspect <tier>data/ and the release's user/" >&2
        echo "    symlinks; restore the missing target before retrying." >&2
        exit 1
    fi
else
    # Remote mode: probe the three symlinks via ssh. Each `test -e`
    # follows the symlink, so a dangling target returns non-zero.
    REMOTE_SYM_CHECK="$(bv_remote_run '
        bad=""
        for s in user/accounts user/data logs; do
            if [ ! -L "$RD/$s" ]; then bad="$bad missing-link:$s"; continue; fi
            if [ ! -e "$RD/$s" ]; then bad="$bad dangling:$s"; fi
        done
        printf "%s" "$bad"
    ' RD="$PREV_RELEASE_DIR")"
    if [ -n "$REMOTE_SYM_CHECK" ]; then
        echo "" >&2
        echo "❌  Previous release '${PREV_RELEASE_ID}' has dangling data symlinks:${REMOTE_SYM_CHECK}" >&2
        echo "    Refusing to swap. See ${PREV_RELEASE_DIR} on the remote." >&2
        exit 1
    fi
fi
echo "  ✓ Previous release dir present, data symlinks resolve"

# =============================================================================
# Step 4 — Atomic swap back
# =============================================================================

echo "→ Step 4/5: Atomic swap of ${DEPLOY_TARGET} → ${LAYOUT_NAME}-releases/${PREV_RELEASE_ID}..."

SWAP_START_MS="$(bv_now_ms)"

# Single ln -sfn — no pre-rm of the docroot symlink. PREV_RELEASE_ID
# has been regex-validated; LAYOUT_NAME is a fixed string per env.
remote_atomic_swap "$PREV_RELEASE_ID"

SWAP_END_MS="$(bv_now_ms)"
SWAP_DURATION_MS=$(( SWAP_END_MS - SWAP_START_MS ))
[ "$SWAP_DURATION_MS" -lt 0 ] && SWAP_DURATION_MS=0
ROLLED_BACK_AT_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "  ✓ Swapped back (${SWAP_DURATION_MS} ms)"

# =============================================================================
# Step 4b — Bookkeeping: repoint <tier>data/current at the rolled-back
# release's data-version dir.
# =============================================================================
#
# Under the versioned-data-dir SERVING model (ADR-005) each release is
# pinned to its own data-version dir via its OWN symlinks (preserved
# across deploys), so DATA rollback is automatic — the swap above is
# already serving the right data dir. This step is pure bookkeeping: it
# keeps <tier>data/current consistent with what is now live, so the next
# forward deploy binds to the same dir the rolled-back release uses.
#
# We resolve the target vdir from the rolled-back release WITHOUT
# guessing:
#   1. parse the <vdir> path component out of that release's
#      user/accounts symlink target (the authoritative source — it is
#      what the release actually serves), else
#   2. read its release-meta.yaml data_version (a bare dir name like
#      v0/v_… is used as-is; a SemVer is mapped via bv_version_to_dirname).
# If neither yields a safe single-component dir name, we WARN and SKIP —
# never repoint current at a guessed/unsafe dir. The docroot swap already
# succeeded; leaving current stale is strictly safer than mispointing it.

# read_symlink_target <path> → echoes `readlink` of a symlink (local or remote)
read_symlink_target() {
    local p="$1"
    if [ "$LOCAL_MODE" = "1" ]; then
        readlink "$p" 2>/dev/null || true
    else
        bv_remote_run 'readlink "$P" 2>/dev/null || true' P="$p" 2>/dev/null || true
    fi
}

# Extract the <vdir> component from an accounts symlink target of the
# shape "…/<tier>data/<vdir>/user/accounts". Echoes the vdir or nothing.
extract_vdir_from_accounts_target() {
    local target="$1"
    case "$target" in
        */user/accounts)
            local head="${target%/user/accounts}"   # strip trailing /user/accounts
            printf '%s' "${head##*/}"                # basename = the <vdir>
            ;;
        *) : ;;  # unexpected shape → echo nothing
    esac
}

RESOLVED_VDIR=""
ACCOUNTS_TARGET="$(read_symlink_target "$PREV_RELEASE_DIR/user/accounts")"
if [ -n "$ACCOUNTS_TARGET" ]; then
    RESOLVED_VDIR="$(extract_vdir_from_accounts_target "$ACCOUNTS_TARGET")"
fi

# Fallback: the release-meta data_version field (already fetched into
# META_TMP for the CURRENT release; for the PREVIOUS release we read it
# fresh). Only consulted if the symlink parse failed.
if [ -z "$RESOLVED_VDIR" ]; then
    PREV_META_DV=""
    if [ "$LOCAL_MODE" = "1" ]; then
        if [ -f "$PREV_RELEASE_DIR/release-meta.yaml" ]; then
            PREV_META_DV="$(grep -E '^data_version:' "$PREV_RELEASE_DIR/release-meta.yaml" \
                | head -n1 | sed -E 's/^data_version:[[:space:]]*//; s/^"//; s/"$//')"
        fi
    else
        PREV_META_DV="$(bv_remote_run '
            m="$RD/release-meta.yaml"
            if [ -f "$m" ]; then
                grep -E "^data_version:" "$m" | head -n1 \
                    | sed -E "s/^data_version:[[:space:]]*//; s/^\"//; s/\"$//"
            fi
        ' RD="$PREV_RELEASE_DIR" 2>/dev/null || echo "")"
    fi
    if [ -n "$PREV_META_DV" ]; then
        case "$PREV_META_DV" in
            v0|v_*) RESOLVED_VDIR="$PREV_META_DV" ;;          # already a dir name
            *)      RESOLVED_VDIR="$(bv_version_to_dirname "$PREV_META_DV")" ;;  # SemVer → dir
        esac
    fi
fi

# Final safety gate: a single, non-empty, traversal-free path component.
case "$RESOLVED_VDIR" in
    ''|*/*|*..*)
        warn "could not safely resolve the rolled-back release's data-version dir (got: '${RESOLVED_VDIR:-<none>}') — leaving ${DATA_DIR}/current unchanged"
        RESOLVED_VDIR=""
        ;;
esac

if [ -n "$RESOLVED_VDIR" ]; then
    # Only repoint when current actually differs — a redundant ln -sfn
    # would still rewrite the symlink and bump <tier>data/'s mtime for no
    # behavioural change, which is both wasteful and would trip the
    # "<tier>data/ mtime unchanged across the rollback" invariant.
    CURRENT_NOW="$(read_symlink_target "$DATA_DIR/current")"
    CURRENT_NOW="$(basename "${CURRENT_NOW:-}")"
    if [ "$CURRENT_NOW" = "$RESOLVED_VDIR" ]; then
        echo "  ✓ ${DATA_DIR}/current already → ${RESOLVED_VDIR} (bookkeeping no-op)"
    elif [ "$LOCAL_MODE" = "1" ]; then
        # ln -sfn is the only mutation; relative target; RESOLVED_VDIR
        # validated single-component above; DATA_DIR is config-derived.
        if ln -sfn "$RESOLVED_VDIR" "$DATA_DIR/current" 2>/dev/null; then
            echo "  ✓ ${DATA_DIR}/current → ${RESOLVED_VDIR} (bookkeeping)"
        else
            warn "could not repoint ${DATA_DIR}/current → ${RESOLVED_VDIR} (continuing; docroot already swapped)"
        fi
    else
        if bv_remote_run 'ln -sfn "$VDIR" "$DD/current"' VDIR="$RESOLVED_VDIR" DD="$DATA_DIR" 2>/dev/null; then
            echo "  ✓ ${DATA_DIR}/current → ${RESOLVED_VDIR} (bookkeeping)"
        else
            warn "could not repoint ${DATA_DIR}/current → ${RESOLVED_VDIR} on remote (continuing; docroot already swapped)"
        fi
    fi
fi

# =============================================================================
# Step 5 — Smoke probe (same contract as deploy.sh) + audit row
# =============================================================================

echo "→ Step 5/5: Smoke probe..."

# Compute the expected substring from the PREVIOUS release dir's
# VERSION + BUILD — that's the release we just swapped TO. Single
# source of truth (bv_compute_expected_version_substring); deploy.sh
# uses the same helper.
#
# In remote mode we'd need to fetch VERSION/BUILD from the remote;
# but the preferred operator workflow is to run rollback from a
# checkout that has the prior commit checked out. For now, in remote
# mode, fall back to `Version <X> · build <N>` based on whatever the
# local checkout has — and surface a warning if the local copy is
# unlikely to match. This will be tightened in a future iteration.
if [ "$LOCAL_MODE" = "1" ]; then
    PROBE_EXPECTED="$(bv_compute_expected_version_substring "$PREV_RELEASE_DIR")"
else
    # Pull VERSION + BUILD from the remote release dir into a local
    # tempdir, then run the helper.
    PROBE_TMP="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf \"$PROBE_TMP\"" EXIT
    if ! bv_remote_run 'cat "$RD/VERSION"' RD="$PREV_RELEASE_DIR" > "$PROBE_TMP/VERSION" 2>/dev/null \
       || ! bv_remote_run 'cat "$RD/BUILD"'   RD="$PREV_RELEASE_DIR" > "$PROBE_TMP/BUILD"   2>/dev/null; then
        echo "  ⚠️  Could not read VERSION/BUILD from previous release on remote — skipping probe." >&2
        PROBE_EXPECTED=""
    else
        PROBE_EXPECTED="$(bv_compute_expected_version_substring "$PROBE_TMP" 2>/dev/null || echo "")"
    fi
fi

PROBE_URL="${BV_SMOKE_PROBE_URL_OVERRIDE:-${ENV_URL}/}"
PROBE_STATUS=0
PROBE_MATCHED=false
PROBE_RC=0
if [ -n "$PROBE_EXPECTED" ]; then
    PROBE_RESULT="$(bv_smoke_probe "$PROBE_URL" "$PROBE_EXPECTED" || true)"
    PROBE_STATUS="${PROBE_RESULT%%|*}"
    PROBE_MATCHED="${PROBE_RESULT##*|}"
    case "$PROBE_STATUS" in
        ''|*[!0-9]*) PROBE_STATUS=0 ;;
    esac
    case "$PROBE_MATCHED" in
        true|false) ;;
        *) PROBE_MATCHED=false ;;
    esac
    if [ "$PROBE_MATCHED" != "true" ] || [ "$PROBE_STATUS" != "200" ]; then
        PROBE_RC=1
    fi
fi

# Append the audit row regardless of probe outcome — failure rows are
# part of the trail.
ROLLED_BACK_BY="${BV_ROLLBACK_DEPLOYED_BY:-$(git -C "$PROJECT_DIR" config user.email 2>/dev/null || echo "unknown")}"

if [ "$LOCAL_MODE" = "1" ]; then
    bv_append_rollback_log_row \
        "$RELEASES_DIR" \
        "$ROLLED_BACK_AT_ISO" \
        "$ROLLED_BACK_BY" \
        "$CURRENT_RELEASE_ID" \
        "$PREV_RELEASE_ID" \
        "$SWAP_DURATION_MS" \
        "$PROBE_URL" \
        "$PROBE_STATUS" \
        "$PROBE_EXPECTED" \
        "$PROBE_MATCHED"
else
    # Remote mode: bv_append_rollback_log_row writes via local FS ops
    # and would fail because RELEASES_DIR is a remote path. Build the
    # audit row locally and ssh-append it to the remote log file.
    # Stream the row via stdin so no shell-meta lands on the cmd line.
    AUDIT_ROW="$(
        printf -- '- rolled_back_at: "%s"\n' "$(bv_yaml_quote_escape "$ROLLED_BACK_AT_ISO")"
        printf '  rolled_back_by: "%s"\n' "$(bv_yaml_quote_escape "$ROLLED_BACK_BY")"
        printf '  from_release: %s\n' "$CURRENT_RELEASE_ID"
        printf '  to_release: %s\n' "$PREV_RELEASE_ID"
        printf '  swap_duration_ms: %s\n' "$SWAP_DURATION_MS"
        printf '  smoke_probe:\n'
        printf '    url: "%s"\n' "$(bv_yaml_quote_escape "$PROBE_URL")"
        printf '    status: %s\n' "$PROBE_STATUS"
        printf '    expected_version_substring: "%s"\n' "$(bv_yaml_quote_escape "$PROBE_EXPECTED")"
        printf '    matched: %s\n' "$PROBE_MATCHED"
    )"
    # Use bv_remote_run; row flows through ROW=... so no quoting concerns.
    # Initialise the log file with the standard header on first write.
    bv_remote_run '
        log_file="$RELEASES_DIR/rollback-log.yaml"
        if [ ! -f "$log_file" ]; then
            {
                printf "# rollback-log.yaml — append-only audit log of rollback invocations\n"
                printf "# Each row records: rolled_back_at, rolled_back_by, from_release,\n"
                printf "#                   to_release, swap_duration_ms, smoke_probe.{url,status,expected_version_substring,matched}\n"
            } > "$log_file"
        fi
        printf "%s\n" "$ROW" >> "$log_file"
    ' RELEASES_DIR="$RELEASES_DIR" ROW="$AUDIT_ROW"
fi

echo "  ✓ Audit row appended to ${RELEASES_DIR}/rollback-log.yaml"

if [ "$PROBE_RC" -ne 0 ]; then
    echo "" >&2
    echo "❌  Smoke probe FAILED after rollback." >&2
    echo "    expected: ${PROBE_EXPECTED}" >&2
    echo "    status:   ${PROBE_STATUS}" >&2
    echo "    matched:  ${PROBE_MATCHED}" >&2
    echo "" >&2
    echo "    The rolled-back release IS LIVE — no further auto-action." >&2
    echo "    Inspect: ${PROBE_URL}" >&2
    echo "" >&2
    exit 1
fi

echo ""
echo "  ✅  Rollback complete!"
echo "  🌐  ${ENV_URL}"
echo "  📦  Now live: ${PREV_RELEASE_ID}  (was: ${CURRENT_RELEASE_ID})"
echo "  📜  Audit log: ${RELEASES_DIR}/rollback-log.yaml"
echo ""
