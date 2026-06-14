#!/usr/bin/env bash
# promote-to-staging.sh — refresh staging with current code AND a
# migration-applied snapshot of prod data.
#
# WHY
# ---
# "Deploy to staging" historically meant deploy code only; staging's
# data was whatever it last happened to have. That makes staging a
# useless rehearsal venue for anything content-shaped. This command
# orchestrates the now-shipped pieces — backup.sh, restore.sh,
# migrate.sh, deploy.sh — into a single one-shot promote so staging
# genuinely mirrors what prod is about to become. It is the third step
# of the data-lifecycle series (backup → restore → promote).
#
# See specifications/promote_to_staging_specification.md for the
# authoritative contract. The blessing marker this script writes
# (config/www/staging-blessed.yaml at the staging Grav root, OUTSIDE
# user/) is the only signal the promote-to-prod spec consumes to gate a
# prod deploy — producing it correctly is this script's primary
# downstream obligation.
#
# USAGE
# -----
#   ./deploy/promote-to-staging.sh [--from-backup <id>] [--yes] [--help]
#
# Options:
#   --from-backup <id>  Skip the fresh prod backup; use this existing
#                       archive id instead (e.g. "restore staging to
#                       last night's prod state").
#   --yes               Non-interactive; assume yes to any prompt.
#                       (This script is already non-interactive; the
#                       flag is reserved for symmetry with push-data.sh
#                       and to make scripted invocation explicit.)
#   --help              Show this help.
#
# DATA MODEL — versioned-data-dir SERVING (ADR-005)
# -------------------------------------------------
# A release binds to the data-version dir that <tier>data/current points
# at AT DEPLOY TIME (deploy.sh wires its symlinks to <tier>data/<vdir>/).
# So to serve a migrated snapshot, promote BUILDS a complete
# v_<target> dir and repoints `current` at it BEFORE the code deploy:
#
#   1. CURRENT_VDIR = basename(readlink stagingdata/current)   (v0 fallback)
#   2. VDIR         = bv_version_to_dirname(TARGET_VERSION)     (e.g. v_0_2_0)
#   3. cp -a stagingdata/<CURRENT_VDIR> stagingdata/<VDIR>      (inherit per-tier
#      secrets/config/env), then overlay the migrated accounts/data/pages/uploads
#   4. ln -sfn <VDIR> stagingdata/current
#   5. deploy.sh staging --skip-data-migration   → wires the new release to <VDIR>
#
# This supersedes the interim "refresh v0 in place" behaviour. Rollback
# stays safe because each release keeps its own symlinks pinned to the
# dir it deployed with (the v_<target> dir is preserved, never deleted by
# a later promote unless it is being rebuilt for that same target).
#
# LOCAL MODE (testing)
# --------------------
# When PROMOTE_LOCAL_TIER_DIR=<absolute-path> is set, the script
# operates against that local directory instead of SSH: it skips the
# reachability probes, skips the real code deploy, skips the curl
# smoke-test, and performs the BUILD+ACTIVATE step as local
# cp -a + rsync into $PROMOTE_LOCAL_TIER_DIR/stagingdata/<VDIR>/... and a
# local `current` repoint. This is the testable analogue of the
# operator's SSH path; the live SSH path is reviewed, not run in CI (no
# SSH; ADR-002 also gates a real run).
#
# Override points (env vars, all optional):
#   PROMOTE_SCRATCH_DIR   absolute path for the restore scratch dir
#                         (default: a mktemp dir under $TMPDIR).
#
# The live path's destructive operations (rm -rf of an existing
# stagingdata/<VDIR> before the cp -a rebuild — string-rooted under
# DATA_ROOT with VDIR validated non-empty — and the per-subdirectory
# rsync --delete over accounts/data/pages/uploads into <VDIR>,
# preserving user/config secrets) plus the blessing write are gated on
# $PROMOTE_LOCAL_TIER_DIR being unset; they are implemented by analogy
# to restore.sh / push-data.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR PROJECT_DIR

# bv_version_to_dirname (0.2.0 → v_0_2_0) is the single source of truth
# for the versioned-data-dir naming convention. Sourced from the
# migration-integration lib (which is pure shell — no ssh side effects
# at source time), so it is available in BOTH local and live mode.
# shellcheck source=deploy/lib/migrate-integration.sh
. "$SCRIPT_DIR/lib/migrate-integration.sh"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

log()  { printf '→ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '⚠  %s\n' "$*" >&2; }
die()  { printf '❌  %s\n' "$1" >&2; exit "${2:-1}"; }

# ── 1. Parse args ────────────────────────────────────────────────────
FROM_BACKUP=""
YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --from-backup)
            [ $# -ge 2 ] || die "--from-backup requires an id argument"
            FROM_BACKUP="$2"; shift 2
            ;;
        --from-backup=*)
            FROM_BACKUP="${1#--from-backup=}"; shift
            ;;
        --yes|-y) YES=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown arg: $(printf %q "$1")" ;;
    esac
done
readonly FROM_BACKUP YES

# ── 2. Determine mode (local vs live) ────────────────────────────────
LOCAL_MODE=0
LOCAL_TIER_DIR=""
if [ -n "${PROMOTE_LOCAL_TIER_DIR:-}" ]; then
    LOCAL_TIER_DIR="$PROMOTE_LOCAL_TIER_DIR"
    case "$LOCAL_TIER_DIR" in
        /*) ;;  # absolute — required
        *) die "PROMOTE_LOCAL_TIER_DIR must be an absolute path (got: $(printf %q "$LOCAL_TIER_DIR"))" ;;
    esac
    case "$LOCAL_TIER_DIR" in
        *..*) die "PROMOTE_LOCAL_TIER_DIR contains '..' — refusing for safety" ;;
    esac
    if [ ! -d "$LOCAL_TIER_DIR" ]; then
        die "PROMOTE_LOCAL_TIER_DIR does not exist or is not a directory: $(printf %q "$LOCAL_TIER_DIR")"
    fi
    LOCAL_MODE=1
fi
readonly LOCAL_MODE LOCAL_TIER_DIR

# ── 3. Load credentials + helpers ────────────────────────────────────
# Live mode needs the SSH helpers + .env.deploy. Local mode never makes
# an SSH call, so we don't require the env file there (matches restore.sh's
# RESTORE_LOCAL_TIER_DIR idiom, which still sources it harmlessly if present).
ENV_FILE="${PROMOTE_ENV_FILE:-$PROJECT_DIR/.env.deploy}"
if [ "$LOCAL_MODE" != "1" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        die "Missing $ENV_FILE — copy .env.deploy.example and fill in staging credentials (or set PROMOTE_LOCAL_TIER_DIR for local-mode testing)"
    fi
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    # SSH-auth helpers — resolve staging credentials. TIER drives
    # bv_resolve_ssh_password's dispatch.
    TIER="staging"
    export TIER
    # shellcheck source=deploy/lib/ssh-auth.sh
    . "$SCRIPT_DIR/lib/ssh-auth.sh"

    : "${DEPLOY_HOST:?missing DEPLOY_HOST in .env.deploy}"
    : "${DEPLOY_USER:?missing DEPLOY_USER in .env.deploy}"
    : "${DEPLOY_PATH:?missing DEPLOY_PATH in .env.deploy}"
    : "${DEPLOY_PORT:?missing DEPLOY_PORT in .env.deploy}"
    DEPLOY_PASS="$(bv_resolve_ssh_password)"
    export DEPLOY_PASS
    # Staging Grav docroot + data root on the remote. deploy.sh ships
    # code to $DEPLOY_PATH/staging and keeps live state in the sibling
    # $DEPLOY_PATH/stagingdata/ tree (same convention push-data.sh uses).
    STAGING_DOCROOT="$DEPLOY_PATH/staging"
    DATA_ROOT="$DEPLOY_PATH/stagingdata"
    # The blessing marker lives at the staging Grav root — which, since
    # deploy.sh ships config/www/* directly into the tier root, IS the
    # docroot. NOT inside user/ and NOT inside the stagingdata/ tree, so
    # no data push can wipe it.
    BLESSING_REMOTE="$STAGING_DOCROOT/staging-blessed.yaml"
else
    DATA_ROOT="$LOCAL_TIER_DIR/stagingdata"
    BLESSING_LOCAL="$LOCAL_TIER_DIR/staging-blessed.yaml"
fi

# Reusable wrappers so the step logic reads the same in both modes.
# In local mode they are no-ops / local equivalents.
ssh_run() {
    # Run a command on the staging host (live mode only).
    bv_ssh_cmd -p "$DEPLOY_PORT" "${DEPLOY_USER}@${DEPLOY_HOST}" "$@"
}

# Mirror backup.sh's parseable-stdout convention: the marker file we
# remove at step 1, then re-write at step 9.
remove_blessing() {
    if [ "$LOCAL_MODE" = "1" ]; then
        rm -f "$BLESSING_LOCAL"
    else
        # `rm -f` is idempotent; absence of a prior marker is fine.
        ssh_run "rm -f $(printf %q "$BLESSING_REMOTE")" || true
    fi
}

# ──────────────────────────────────────────────────────────────────────
# YAML field extractor (data_version:) — shared by step 4. Mirrors the
# parser in migrate.sh / migrate-integration.sh.
# ──────────────────────────────────────────────────────────────────────
extract_data_version_field() {
    local path="$1"
    [ -f "$path" ] || { printf ''; return 0; }
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

echo "=== promote-to-staging ==="
if [ "$LOCAL_MODE" = "1" ]; then
    note "mode:   LOCAL (PROMOTE_LOCAL_TIER_DIR=$LOCAL_TIER_DIR)"
else
    note "mode:   LIVE (staging via ${DEPLOY_USER}@${DEPLOY_HOST})"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 1 — remove any stale blessing; reachability checks (live only).
# A stale blessing from a previous (possibly failed) promote must not
# survive a fresh attempt — promote-to-prod gates on it.
# ──────────────────────────────────────────────────────────────────────
log "Step 1/11: removing any stale blessing marker"
remove_blessing
note "stale blessing (if any) removed"

if [ "$LOCAL_MODE" != "1" ]; then
    log "Step 1/11: verifying staging is reachable"
    if ! ssh_run true 2>/dev/null; then
        die "ssh to staging (${DEPLOY_HOST}:${DEPLOY_PORT}) failed — aborting; nothing changed" 2
    fi
    note "staging reachable"
    log "Step 1/11: verifying prod is reachable"
    : "${DEPLOY_PROD_HOST:?prod reachability check requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod reachability check requires DEPLOY_PROD_USER in .env.deploy}"
    PROD_PORT="${DEPLOY_PROD_PORT:-${DEPLOY_PORT}}"
    # Resolve prod's password under its own tier so bv_ssh_cmd dispatches
    # correctly for the prod host (which may be key-auth on chosting.dk).
    if ! ( TIER="prod" bv_ssh_cmd -p "$PROD_PORT" "${DEPLOY_PROD_USER}@${DEPLOY_PROD_HOST}" true 2>/dev/null ); then
        die "ssh to prod (${DEPLOY_PROD_HOST}:${PROD_PORT}) failed — aborting; nothing changed" 2
    fi
    note "prod reachable"
else
    note "local mode: skipping reachability checks"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 2 — obtain the backup id (fresh backup, or --from-backup).
# ──────────────────────────────────────────────────────────────────────
BACKUP_ID=""
BACKUP_DATA_VERSION=""   # from backup.sh stdout, used as a fallback in step 4
if [ -n "$FROM_BACKUP" ]; then
    log "Step 2/11: using existing backup id (--from-backup)"
    BACKUP_ID="$FROM_BACKUP"
    note "backup id: $BACKUP_ID"
else
    log "Step 2/11: taking a fresh prod backup (deploy/backup.sh prod)"
    BACKUP_OUT="$("$SCRIPT_DIR/backup.sh" prod)" \
        || die "prod backup failed — aborting; nothing changed on staging or prod" 2
    BACKUP_ID="$(printf '%s\n' "$BACKUP_OUT" | awk -F= '/^archive=/ { print $2; exit }')"
    BACKUP_DATA_VERSION="$(printf '%s\n' "$BACKUP_OUT" | awk -F= '/^data_version=/ { print $2; exit }')"
    [ -n "$BACKUP_ID" ] || die "could not parse archive id from backup.sh output" 2
    note "backup id:           $BACKUP_ID"
    note "backup data_version: ${BACKUP_DATA_VERSION:-<unknown>}"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 3 — restore the backup into a scratch dir (restore-to-scratch).
# The scratch dir holds real prod data temporarily. Removed on success,
# left in place (with its path printed) on any failure.
# ──────────────────────────────────────────────────────────────────────
if [ -n "${PROMOTE_SCRATCH_DIR:-}" ]; then
    case "$PROMOTE_SCRATCH_DIR" in
        /*) ;;
        *) die "PROMOTE_SCRATCH_DIR must be an absolute path (got: $(printf %q "$PROMOTE_SCRATCH_DIR"))" ;;
    esac
    case "$PROMOTE_SCRATCH_DIR" in
        *..*) die "PROMOTE_SCRATCH_DIR contains '..' — refusing for safety" ;;
    esac
    SCRATCH="$PROMOTE_SCRATCH_DIR"
    # restore.sh refuses a non-empty target; keep the slot fresh.
    if [ -e "$SCRATCH" ] && [ -n "$(ls -A "$SCRATCH" 2>/dev/null)" ]; then
        die "PROMOTE_SCRATCH_DIR is not empty: $SCRATCH (move it aside or pick another)"
    fi
else
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bv-promote.XXXXXXXX")"
    # restore.sh refuses a pre-existing non-empty dir, so hand it a
    # non-existent path inside the tempdir.
    rmdir "$SCRATCH" 2>/dev/null || true
    SCRATCH="$SCRATCH/scratch"
fi

log "Step 3/11: restoring backup into scratch dir"
note "scratch: $SCRATCH"
if ! "$SCRIPT_DIR/restore.sh" --to "$SCRATCH" --from "$BACKUP_ID" >/dev/null; then
    die "restore-to-scratch failed for backup id '$BACKUP_ID' — aborting; staging untouched (scratch: $SCRATCH)" 2
fi
note "restore complete"
echo ""

# On any failure from here on, leave the scratch dir for inspection and
# print its path. On success we remove it explicitly at the end.
fail_with_scratch() {
    warn "scratch dir left for inspection: $SCRATCH"
    die "$1" "${2:-1}"
}

# ──────────────────────────────────────────────────────────────────────
# STEP 4 — determine SOURCE (scratch) and TARGET (code) data versions.
# SOURCE comes from the restored snapshot's backup-meta.yaml; the
# archive deliberately omits user/data-version.yaml, so the meta file is
# the authority. Fall back to backup.sh's reported data_version if meta
# lacks the field.
# ──────────────────────────────────────────────────────────────────────
log "Step 4/11: reading source + target data versions"
META="$SCRATCH/backup-meta.yaml"
SOURCE_VERSION=""
if [ -f "$META" ]; then
    SOURCE_VERSION="$(extract_data_version_field "$META")"
fi
if [ -z "$SOURCE_VERSION" ] && [ -n "$BACKUP_DATA_VERSION" ]; then
    SOURCE_VERSION="$BACKUP_DATA_VERSION"
fi
[ -n "$SOURCE_VERSION" ] || fail_with_scratch "could not determine source data version (no data_version in $META and none reported by backup.sh)"

CODE_MARKER="$PROJECT_DIR/config/www/user/data-version.yaml"
TARGET_VERSION="$(extract_data_version_field "$CODE_MARKER")"
[ -n "$TARGET_VERSION" ] || fail_with_scratch "could not determine target data version from $CODE_MARKER"

note "source (prod snapshot): $SOURCE_VERSION"
note "target (current code):  $TARGET_VERSION"
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 5 — make the scratch a valid migrate data-dir and migrate it.
# The archive omits user/data-version.yaml, but migrate.sh needs it
# present. Seed it with SOURCE_VERSION, then migrate to TARGET if they
# differ. On migration failure, abort with the scratch left intact.
# ──────────────────────────────────────────────────────────────────────
log "Step 5/11: preparing + migrating the scratch snapshot"
mkdir -p "$SCRATCH/user"
SCRATCH_MARKER="$SCRATCH/user/data-version.yaml"

if [ "$SOURCE_VERSION" = "$TARGET_VERSION" ]; then
    note "source == target ($TARGET_VERSION): no migration needed"
    # Ensure the marker reflects the agreed version (the archive omitted it).
    printf 'data_version: "%s"\n' "$TARGET_VERSION" > "$SCRATCH_MARKER"
else
    note "migration required: $SOURCE_VERSION → $TARGET_VERSION"
    # Seed the from-version so migrate.sh reads the correct starting point.
    printf 'data_version: "%s"\n' "$SOURCE_VERSION" > "$SCRATCH_MARKER"
    if ! "$SCRIPT_DIR/migrate.sh" "$SCRATCH" --to "$TARGET_VERSION"; then
        fail_with_scratch "migration $SOURCE_VERSION → $TARGET_VERSION failed — staging untouched"
    fi
    # migrate.sh updates the marker in place; assert it landed at TARGET.
    post="$(extract_data_version_field "$SCRATCH_MARKER")"
    if [ "$post" != "$TARGET_VERSION" ]; then
        fail_with_scratch "post-migration data version is '$post', expected '$TARGET_VERSION'"
    fi
    note "migration complete: scratch now at $TARGET_VERSION"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 6 — BUILD + ACTIVATE the versioned data dir (versioned-data-dir
# SERVING model — ADR-005). This runs BEFORE the code deploy so that
# deploy.sh (step 7) wires the new release's symlinks to the dir we just
# activated.
#
#   a. CURRENT_VDIR = basename(readlink stagingdata/current)  (v0 fallback)
#   b. VDIR         = bv_version_to_dirname(TARGET_VERSION)    (e.g. v_0_2_0)
#   c. if stagingdata/<VDIR> exists → rm -rf it (string-rooted under
#      DATA_ROOT, VDIR validated non-empty), then
#      cp -a stagingdata/<CURRENT_VDIR> stagingdata/<VDIR> to INHERIT the
#      per-tier secrets/config/env. (If <CURRENT_VDIR> is absent — fresh
#      tier — mkdir the <VDIR>/user skeleton instead.)
#   d. overlay the migrated snapshot: per-subdir rsync --delete over
#      accounts/data/pages/uploads into <VDIR>/user/<sub>/, then copy the
#      data-version.yaml marker.
#   e. repoint stagingdata/current → <VDIR> (relative ln -sfn).
#
# Secrets in <CURRENT_VDIR>/user/config are preserved by the cp -a in (c)
# and never overwritten — the overlay in (d) touches ONLY the four
# STATE_SUBDIRS. Rollback safety: each existing release keeps its own
# symlinks pinned to the dir it deployed with; building a NEW dir +
# repointing current does not disturb them.
# ──────────────────────────────────────────────────────────────────────
STATE_SUBDIRS=(accounts data pages uploads)   # FIXED list — secrets/config untouched

# VDIR = the data-version dir name this promote builds + activates.
# bv_version_to_dirname is the single source of truth (0.2.0 → v_0_2_0).
VDIR="$(bv_version_to_dirname "$TARGET_VERSION")"
# Defence in depth: VDIR becomes an rm -rf / cp -a / ln target below.
# It must be a single, non-empty, traversal-free path component.
case "$VDIR" in
    ''|*/*|*..*) fail_with_scratch "computed data-version dir name '$VDIR' is unsafe (empty / contains '/' or '..')" 6 ;;
esac
readonly VDIR STATE_SUBDIRS

log "Step 6/11: building + activating versioned data dir ($DATA_ROOT/$VDIR)"

if [ "$LOCAL_MODE" = "1" ]; then
    # (a) resolve the live data-version dir (the dir current points at).
    CURRENT_VDIR="$(basename "$(readlink "$DATA_ROOT/current" 2>/dev/null || echo v0)")"
    note "current data-version dir: $CURRENT_VDIR → building $VDIR"

    # (c) build a COMPLETE v_<target> inheriting per-tier secrets/config/env.
    if [ -d "$DATA_ROOT/$VDIR" ]; then
        # String-rooted under DATA_ROOT; VDIR validated non-empty + single
        # component above. Quoted. Rebuilding the target's own dir is the
        # only case we rm — a stale partial build from a prior failed promote.
        note "  $VDIR already exists — removing before rebuild"
        rm -rf "$DATA_ROOT/$VDIR"
    fi
    if [ -d "$DATA_ROOT/$CURRENT_VDIR" ]; then
        note "  cp -a $CURRENT_VDIR → $VDIR (inherit per-tier secrets/config/env)"
        cp -a "$DATA_ROOT/$CURRENT_VDIR" "$DATA_ROOT/$VDIR" \
            || fail_with_scratch "cp -a $CURRENT_VDIR → $VDIR failed" 6
    else
        note "  fresh tier ($CURRENT_VDIR absent) — creating $VDIR/user skeleton"
        mkdir -p "$DATA_ROOT/$VDIR/user" \
            || fail_with_scratch "could not create $DATA_ROOT/$VDIR/user" 6
    fi

    # (d) overlay the migrated snapshot — accounts/data/pages/uploads only.
    mkdir -p "$DATA_ROOT/$VDIR/user"
    for sub in "${STATE_SUBDIRS[@]}"; do
        src="$SCRATCH/user/$sub"
        if [ ! -d "$src" ]; then
            note "  skip user/$sub (absent in scratch)"
            continue
        fi
        dst="$DATA_ROOT/$VDIR/user/$sub"
        mkdir -p "$dst"
        note "  rsync --delete user/$sub/ → $VDIR"
        rsync -a --delete -- "$src/" "$dst/" \
            || fail_with_scratch "local rsync of user/$sub into $dst failed" 6
    done
    # Stamp the versioned dir's data-version marker.
    if [ -f "$SCRATCH_MARKER" ]; then
        cp "$SCRATCH_MARKER" "$DATA_ROOT/$VDIR/user/data-version.yaml" \
            || fail_with_scratch "copying data-version.yaml into $VDIR failed" 6
    fi

    # (e) repoint current → VDIR (relative target).
    ln -sfn "$VDIR" "$DATA_ROOT/current" \
        || fail_with_scratch "repointing $DATA_ROOT/current → $VDIR failed" 6
    note "  current → $VDIR (release deployed next binds to this dir)"
else
    rsync_e="$(bv_rsync_ssh_e "$DEPLOY_PORT")" \
        || fail_with_scratch "could not build rsync ssh-cmd (sshpass missing?)" 6

    # (a) resolve the live data-version dir over SSH.
    CURRENT_VDIR="$(ssh_run "basename \"\$(readlink $(printf %q "$DATA_ROOT/current") 2>/dev/null || echo v0)\"")" \
        || fail_with_scratch "could not read $DATA_ROOT/current on staging" 6
    CURRENT_VDIR="$(basename "$CURRENT_VDIR")"
    case "$CURRENT_VDIR" in
        ''|*/*|*..*) fail_with_scratch "live current data-version dir '$CURRENT_VDIR' is unsafe" 6 ;;
    esac
    note "current data-version dir: $CURRENT_VDIR → building $VDIR"

    # (c) build a COMPLETE v_<target> over SSH. Both VDIR and CURRENT_VDIR
    # are validated single components; DATA_ROOT is operator-config. Each
    # path is printf %q-quoted into the remote command. The rm -rf is
    # string-rooted under DATA_ROOT/<VDIR> and only fires on a pre-existing
    # rebuild of the SAME target dir.
    if ! ssh_run "
        set -e
        if [ -d $(printf %q "$DATA_ROOT/$VDIR") ]; then rm -rf $(printf %q "$DATA_ROOT/$VDIR"); fi
        if [ -d $(printf %q "$DATA_ROOT/$CURRENT_VDIR") ]; then
            cp -a $(printf %q "$DATA_ROOT/$CURRENT_VDIR") $(printf %q "$DATA_ROOT/$VDIR")
        else
            mkdir -p $(printf %q "$DATA_ROOT/$VDIR/user")
        fi
    "; then
        fail_with_scratch "building $VDIR on staging (rm/cp -a) failed" 6
    fi
    ssh_run "mkdir -p $(printf %q "$DATA_ROOT/$VDIR/user")" \
        || fail_with_scratch "could not create $DATA_ROOT/$VDIR/user on staging" 6

    # (d) overlay the migrated snapshot — accounts/data/pages/uploads only.
    for sub in "${STATE_SUBDIRS[@]}"; do
        src="$SCRATCH/user/$sub"
        if [ ! -d "$src" ]; then
            note "  skip user/$sub (absent in scratch)"
            continue
        fi
        remote_dst="$DATA_ROOT/$VDIR/user/$sub"
        ssh_run "mkdir -p $(printf %q "$remote_dst")" \
            || fail_with_scratch "could not create $remote_dst on staging" 6
        note "  rsync --delete user/$sub/ → staging:$VDIR"
        # Per-subdirectory rsync --delete into the versioned data dir. The
        # ONLY destructive overlay write — it touches exactly the four data
        # subdirs, never user/config (secrets inherited by cp -a above),
        # never the blessing marker (Grav root, different tree).
        bv_rsync_via_ssh -az --delete -e "$rsync_e" \
            "$src/" "${DEPLOY_USER}@${DEPLOY_HOST}:${remote_dst}/" \
            || fail_with_scratch "rsync of user/$sub to staging failed" 6
    done
    # Stamp the versioned dir's data-version marker.
    if [ -f "$SCRATCH_MARKER" ]; then
        bv_rsync_via_ssh -az -e "$rsync_e" \
            "$SCRATCH_MARKER" "${DEPLOY_USER}@${DEPLOY_HOST}:${DATA_ROOT}/${VDIR}/user/data-version.yaml" \
            || fail_with_scratch "rsync of data-version.yaml to staging failed" 6
    fi

    # (e) repoint current → VDIR (relative target) over SSH.
    ssh_run "ln -sfn $(printf %q "$VDIR") $(printf %q "$DATA_ROOT/current")" \
        || fail_with_scratch "repointing staging current → $VDIR failed" 6
    note "  current → $VDIR (release deployed next binds to this dir)"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 7 — deploy code to staging (code-only; --skip-data-migration).
# `current` already points at the v_<target> dir we built in step 6, so
# deploy.sh wires the new release's symlinks to it. Promote owns the
# migration (step 5) and the data-dir build (step 6), so deploy.sh must
# NOT also try its in-deploy schema bump.
# ──────────────────────────────────────────────────────────────────────
log "Step 7/11: deploying code to staging"
if [ "$LOCAL_MODE" = "1" ]; then
    note "local mode: skipping real code deploy (deploy.sh staging --skip-data-migration)"
else
    if ! "$SCRIPT_DIR/deploy.sh" staging --skip-data-migration; then
        fail_with_scratch "code deploy to staging failed — staging may have new code with old data; redeploy or revert" 7
    fi
    note "code deployed to staging (--skip-data-migration); release wired to $VDIR"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 8 — clear caches (warn-and-continue on failure per spec §8).
# ──────────────────────────────────────────────────────────────────────
log "Step 8/11: clearing staging cache"
if [ "$LOCAL_MODE" = "1" ]; then
    grav_bin="$LOCAL_TIER_DIR/bin/grav"
    if [ -f "$grav_bin" ]; then
        if ( cd "$LOCAL_TIER_DIR" && bin/grav clearcache ) >/dev/null 2>&1; then
            note "cache cleared"
        else
            warn "bin/grav clearcache returned non-zero (continuing; cache refills naturally)"
        fi
    else
        note "no Grav binary at $grav_bin — skipping cache clear"
    fi
else
    if ! ssh_run "cd $(printf %q "$STAGING_DOCROOT") && php bin/grav clearcache"; then
        warn "cache clear failed on staging (continuing; cache refills naturally)"
    else
        note "cache cleared"
    fi
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 9 — write the blessing marker (only now that every prior step
# succeeded). All seven fields; lives at the staging Grav root, OUTSIDE
# user/ and outside the stagingdata/ tree.
# ──────────────────────────────────────────────────────────────────────
log "Step 9/11: writing the blessing marker"
BLESSED_AT="$(date -u +%FT%TZ)"
CODE_COMMIT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
CODE_VERSION="$(head -n1 "$PROJECT_DIR/config/www/VERSION" 2>/dev/null | tr -d '\r\n')"
CODE_BUILD="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
FEATURES_YAML="$PROJECT_DIR/config/www/user/env/staging.hackersbychoice.dk/config/features.yaml"
if [ -f "$FEATURES_YAML" ]; then
    FEATURES_SHA="$(shasum -a 256 "$FEATURES_YAML" | awk '{print $1}')"
else
    fail_with_scratch "staging features.yaml not found at $FEATURES_YAML — cannot stamp blessing" 9
fi

[ -n "$CODE_COMMIT" ]  || fail_with_scratch "could not resolve code_commit (git rev-parse)" 9
[ -n "$CODE_VERSION" ] || fail_with_scratch "could not read code_version from config/www/VERSION" 9
[ -n "$CODE_BUILD" ]   || fail_with_scratch "could not resolve code_build (git rev-list)" 9
[ -n "$FEATURES_SHA" ] || fail_with_scratch "could not compute features_yaml_sha256" 9

# Build the marker content once; write it locally or over SSH.
BLESSING_CONTENT="$(cat <<EOF
blessed_at: "$BLESSED_AT"
code_commit: "$CODE_COMMIT"
code_version: "$CODE_VERSION"
code_build: "$CODE_BUILD"
data_version: "$TARGET_VERSION"
features_yaml_sha256: "$FEATURES_SHA"
source_backup_id: "$BACKUP_ID"
EOF
)"

if [ "$LOCAL_MODE" = "1" ]; then
    printf '%s\n' "$BLESSING_CONTENT" > "$BLESSING_LOCAL" \
        || fail_with_scratch "writing blessing marker to $BLESSING_LOCAL failed" 9
    note "blessing written: $BLESSING_LOCAL"
else
    # Write via SSH. Heredoc to a remote `cat >` keeps the content off
    # the command line and intact. printf %q the destination path.
    if ! printf '%s\n' "$BLESSING_CONTENT" \
        | ssh_run "cat > $(printf %q "$BLESSING_REMOTE")"; then
        fail_with_scratch "writing blessing marker to staging failed" 9
    fi
    note "blessing written: $BLESSING_REMOTE"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 10 — smoke test (live only; warn-and-continue per spec §10).
# The blessing is already written; the operator decides whether to
# consume it on a smoke-test failure.
# ──────────────────────────────────────────────────────────────────────
log "Step 10/11: smoke test"
if [ "$LOCAL_MODE" = "1" ]; then
    note "local mode: skipping curl smoke test"
else
    SMOKE_BASE="https://staging.hackersbychoice.dk"
    smoke_fail=0
    # URL → expected-status pairs. /medlemmer redirects to /login (302).
    smoke_check() {
        local rel="$1" want="$2" extra="${3:-}"
        local code
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$SMOKE_BASE$rel" || echo "000")"
        if [ "$code" != "$want" ]; then
            warn "smoke: $rel returned $code, expected $want"
            smoke_fail=1
            return 0
        fi
        note "smoke: $rel → $code (ok)"
    }
    smoke_check "/"               200
    smoke_check "/login"          200
    smoke_check "/medlemmer"      302
    smoke_check "/begivenheder"   200
    smoke_check "/vaerksteder"    200
    # The blessing endpoint must serve 200 AND echo the deployed commit.
    blessing_body="$(curl -sS --max-time 20 "$SMOKE_BASE/staging-blessed.yaml" || echo "")"
    if printf '%s' "$blessing_body" | grep -q "code_commit: \"$CODE_COMMIT\""; then
        note "smoke: /staging-blessed.yaml → 200 and code_commit matches ($CODE_COMMIT)"
    else
        warn "smoke: /staging-blessed.yaml missing or code_commit mismatch"
        smoke_fail=1
    fi
    if [ "$smoke_fail" = "1" ]; then
        warn "smoke test reported failures — blessing IS written; inspect staging and decide next step"
    else
        note "all smoke checks passed"
    fi
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 11 — summary + cleanup. Remove the scratch on success.
# ──────────────────────────────────────────────────────────────────────
log "Step 11/11: summary"
echo ""
echo "  ✓ promote-to-staging complete"
echo "    backup consumed:  $BACKUP_ID"
if [ "$SOURCE_VERSION" = "$TARGET_VERSION" ]; then
    echo "    migrations:       none ($TARGET_VERSION already)"
else
    echo "    migrations:       $SOURCE_VERSION → $TARGET_VERSION"
fi
echo "    code version:     $CODE_VERSION (commit $CODE_COMMIT, build $CODE_BUILD)"
echo "    data version:     $TARGET_VERSION (served from $DATA_ROOT/$VDIR; current → $VDIR)"
echo "    features sha256:  $FEATURES_SHA"
echo "    blessed_at:       $BLESSED_AT"
echo ""

# Cleanup scratch on success.
if [ -d "$SCRATCH" ]; then
    rm -rf "$SCRATCH"
    note "scratch removed"
fi

exit 0
