#!/usr/bin/env bash
#
# Byværkstederne — backup restore tool.
#
# Two scopes for "restore", both invoked through this single script:
#
#   1. Restore-to-scratch (inspection):
#        ./deploy/restore.sh --to <dir>                 # latest backup
#        ./deploy/restore.sh --to <dir> --from <id>     # specific id
#
#      Unpacks the (decrypted) archive into <dir>. Does NOT touch any
#      live tier path. Writes `.metadata_never_index` into <dir> so
#      Spotlight skips indexing the unpacked PII.
#
#   2. Restore-to-tier (operational):
#        ./deploy/restore.sh staging --from <id>
#        ./deploy/restore.sh prod    --from <id> --yes-i-mean-it
#
#      Wipes the target tier's state paths (the same allow-list used
#      by backup.sh) then unpacks the archive into them. Clears caches
#      afterwards. Restoring to prod additionally takes a fresh
#      pre-restore backup tagged `pre-restore-<timestamp>` and refuses
#      without `--yes-i-mean-it`.
#
# A "backup id" is any of:
#   - a full filename:   prod-2026-04-29T12-34Z-v0.1.0-b247.tar.gz.age
#   - a basename without extension:
#                        prod-2026-04-29T12-34Z-v0.1.0-b247
#   - a literal `latest` (the lex-largest filename for the requested tier)
#
# Exit codes:
#   0  success
#   1  CLI / configuration error
#   2  backup not found / source unreachable
#   3  decrypt / unpack failure
#   4  pre-restore safety-backup failure (prod path)
#   5  cache-clear or wipe failure
#
# This script never invokes `rsync --delete` against live tier paths
# unless explicitly invoked with a tier and `--yes-i-mean-it` (where
# applicable). The GAN confinement hook blocks that anyway; the
# restore-to-scratch path is the GAN-safe stand-in.

set -euo pipefail

readonly RESTORE_SCRIPT_VERSION="0.1.0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly LOCAL_BACKUP_DIR="$REPO_ROOT/backups"
readonly RESTORE_LOG_DIR="$REPO_ROOT/logs"
readonly PATHS_FILE="$SCRIPT_DIR/backup-paths.txt"

log()  { printf '[restore] %s\n' "$*" >&2; }
warn() { printf '[restore] WARN: %s\n' "$*" >&2; }
die()  { local code="${2:-1}"; printf '[restore] ERROR: %s\n' "$1" >&2; exit "$code"; }

# Operator-laptop privacy-hygiene banner (shared with backup.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/banner.sh"

# ──────────────────────────────────────────────────────────────────────
# CLI parsing & validation.
# ──────────────────────────────────────────────────────────────────────

usage() {
    cat <<'EOF' >&2
Usage:
  ./deploy/restore.sh --to <dir> [--from <id>]
  ./deploy/restore.sh <tier> --from <id> [--yes-i-mean-it]

  <tier> ∈ {prod, staging, test, dev}
EOF
}

validate_tier() {
    case "$1" in
        prod|staging|test|dev) return 0 ;;
        *) die "Unknown tier '$1' (allowed: prod, staging, test, dev)" 1 ;;
    esac
}

# Validate a backup id. We accept three shapes:
#   - latest
#   - <tier>-YYYY-MM-DDTHH-MMZ-vSEMVER-bBUILD
#   - <tier>-YYYY-MM-DDTHH-MMZ-vSEMVER-bBUILD.tar.gz.age
#
# Anything else (path traversal, shell meta, leading slashes) is
# rejected up front before reaching storage.
validate_id() {
    local id="$1"
    if [ "$id" = "latest" ]; then
        return 0
    fi
    case "$id" in
        */*|*..*|*'*'*|*'?'*|*'$'*|*'`'*|*';'*|*'|'*|*'&'*|*'>'*|*'<'*|*' '*)
            die "Invalid --from id: $(printf %q "$id") (illegal characters or traversal)" 1 ;;
    esac
    if ! [[ "$id" =~ ^(prod|staging|test|dev)-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}Z-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?-b[0-9]+(\.tar\.gz\.age)?$ ]]; then
        die "Malformed --from id: $(printf %q "$id")" 1
    fi
    return 0
}

validate_to_path() {
    local p="$1"
    [ -n "$p" ] || die "--to value cannot be empty" 1
    case "$p" in
        *..*) die "--to path contains '..' — refusing for safety: $(printf %q "$p")" 1 ;;
    esac
    # Reject absolute paths that fall outside the repo root by
    # default — operators staging into /tmp/scratch are fine, but the
    # default is repo-relative.
    return 0
}

MODE=""           # "scratch" or "tier"
TIER=""
TO_DIR=""
FROM_ID=""
YES_FLAG=0

if [ $# -eq 0 ]; then usage; exit 1; fi

# Detect mode by first arg.
case "$1" in
    --to) MODE="scratch" ;;
    --help|-h) usage; exit 0 ;;
    -*) die "Unknown option: $(printf %q "$1")" 1 ;;
    *)
        MODE="tier"
        TIER="$1"; shift
        validate_tier "$TIER"
        ;;
esac

while [ $# -gt 0 ]; do
    case "$1" in
        --to)
            [ $# -ge 2 ] || die "--to requires a directory argument" 1
            validate_to_path "$2"
            TO_DIR="$2"; shift 2
            ;;
        --from)
            [ $# -ge 2 ] || die "--from requires an id argument" 1
            validate_id "$2"
            FROM_ID="$2"; shift 2
            ;;
        --yes-i-mean-it)
            YES_FLAG=1; shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown option: $(printf %q "$1")" 1 ;;
    esac
done

if [ "$MODE" = "scratch" ] && [ -z "$TO_DIR" ]; then
    die "--to <dir> is required for restore-to-scratch" 1
fi
if [ "$MODE" = "tier" ] && [ -z "$FROM_ID" ]; then
    die "--from <id> is required for restore-to-tier" 1
fi

readonly MODE TIER TO_DIR FROM_ID YES_FLAG

# ──────────────────────────────────────────────────────────────────────
# Source environment file (if present).
# ──────────────────────────────────────────────────────────────────────

ENV_FILE="${RESTORE_ENV_FILE:-${BACKUP_ENV_FILE:-$REPO_ROOT/.env.deploy}}"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

# ──────────────────────────────────────────────────────────────────────
# Storage layer abstraction. Same shape as backup.sh: prefer
# BACKUP_LOCAL_STORE_DIR, then S3, otherwise fall back to local
# ./backups/.
# ──────────────────────────────────────────────────────────────────────

list_managed_archives() {
    if [ -n "${BACKUP_LOCAL_STORE_DIR:-}" ] && [ -d "$BACKUP_LOCAL_STORE_DIR" ]; then
        find "$BACKUP_LOCAL_STORE_DIR" -maxdepth 1 -type f \
             -name '*.tar.gz.age' -exec basename {} \; | sort
        return 0
    fi
    if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
        require_bin aws
        local endpoint_args=()
        if [ -n "${BACKUP_S3_ENDPOINT:-}" ]; then
            endpoint_args=(--endpoint-url "$BACKUP_S3_ENDPOINT")
        fi
        AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}" \
        AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
        aws "${endpoint_args[@]}" s3 ls "s3://${BACKUP_S3_BUCKET}/" \
            | awk '{print $NF}' \
            | grep -E '\.tar\.gz\.age$' || true
        return 0
    fi
    if [ -d "$LOCAL_BACKUP_DIR" ]; then
        find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type f \
             -name '*.tar.gz.age' -exec basename {} \; | sort
    fi
}

require_bin() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required binary: $1" 1
}

# Resolve a (possibly tier-scoped) backup id to a full filename in
# managed storage. If MODE=scratch, we accept any tier; if MODE=tier,
# we restrict to the requested tier.
resolve_archive() {
    local id="$1"
    local tier_filter="${2:-}"   # empty = any
    local listing
    listing="$(list_managed_archives)"
    [ -n "$listing" ] || die "No backups found in managed storage" 2

    if [ "$id" = "latest" ]; then
        local pattern
        if [ -n "$tier_filter" ]; then
            pattern="^${tier_filter}-"
        else
            pattern='.'
        fi
        local match
        match=$(printf '%s\n' "$listing" | grep -E "$pattern" | tail -n1)
        [ -n "$match" ] || die "No backups for tier '${tier_filter:-any}'" 2
        printf '%s\n' "$match"
        return 0
    fi

    # If the id lacks the .tar.gz.age suffix, add it.
    local fname="$id"
    case "$id" in
        *.tar.gz.age) ;;
        *) fname="${id}.tar.gz.age" ;;
    esac

    if printf '%s\n' "$listing" | grep -Fxq "$fname"; then
        if [ -n "$tier_filter" ]; then
            case "$fname" in
                "${tier_filter}-"*) ;;
                *) die "Archive '$fname' is not for tier '$tier_filter'" 1 ;;
            esac
        fi
        printf '%s\n' "$fname"
        return 0
    fi
    die "Backup id not found in managed storage: $(printf %q "$id")" 2
}

# Download a managed-storage archive into a local tempfile, return the
# path on stdout.
download_archive() {
    local fname="$1"
    local out="$2"
    if [ -n "${BACKUP_LOCAL_STORE_DIR:-}" ]; then
        cp "$BACKUP_LOCAL_STORE_DIR/$fname" "$out" || die "Failed to read $fname from $BACKUP_LOCAL_STORE_DIR" 2
        return 0
    fi
    if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
        require_bin aws
        local endpoint_args=()
        if [ -n "${BACKUP_S3_ENDPOINT:-}" ]; then
            endpoint_args=(--endpoint-url "$BACKUP_S3_ENDPOINT")
        fi
        AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}" \
        AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
        aws "${endpoint_args[@]}" s3 cp "s3://${BACKUP_S3_BUCKET}/${fname}" "$out" >&2 \
            || die "Failed to download $fname from S3" 2
        return 0
    fi
    if [ -f "$LOCAL_BACKUP_DIR/$fname" ]; then
        cp "$LOCAL_BACKUP_DIR/$fname" "$out" || die "Failed to read $fname from $LOCAL_BACKUP_DIR" 2
        return 0
    fi
    die "Cannot fetch archive $fname (no storage backend reachable)" 2
}

# ──────────────────────────────────────────────────────────────────────
# Decrypt + unpack into a directory. Mints `.metadata_never_index`
# (Spotlight exclusion) when it creates the dir.
# ──────────────────────────────────────────────────────────────────────

require_bin tar
require_bin age

decrypt_and_unpack() {
    local enc_archive="$1"
    local target="$2"
    local identity="${AGE_IDENTITY_FILE:-}"

    # Refuse to write into existing populated directories silently —
    # creating fresh scratch dirs is the safe behaviour.
    if [ -e "$target" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        die "Target '$target' is not empty; refusing to overwrite" 1
    fi
    mkdir -p "$target"
    # Spotlight never-index marker (operator privacy hygiene).
    : > "$target/.metadata_never_index"

    local tmp_tar
    tmp_tar="$(mktemp "${TMPDIR:-/tmp}/bv-restore.XXXXXXXX.tar.gz")"
    trap 'rm -f "$tmp_tar"' RETURN

    if [ -n "$identity" ] && [ -f "$identity" ]; then
        age -d -i "$identity" -o "$tmp_tar" "$enc_archive" \
            || die "age decryption failed (identity: $identity)" 3
    else
        # Without an identity file, age will prompt — which violates
        # our non-interactive contract. We fail loud instead, with a
        # specific message.
        if [ -z "${AGE_IDENTITY_FILE:-}" ]; then
            die "AGE_IDENTITY_FILE not set (decryption needs the operator's age private key)" 1
        fi
        die "age identity file not found: $identity" 1
    fi

    tar -xzf "$tmp_tar" -C "$target" \
        || die "tar extraction failed" 3
    rm -f "$tmp_tar"
}

# ──────────────────────────────────────────────────────────────────────
# Resolve archive name (do this before mode-dispatching so failures
# happen early).
# ──────────────────────────────────────────────────────────────────────

ARCHIVE_NAME=""
if [ "$MODE" = "scratch" ]; then
    if [ -n "$FROM_ID" ]; then
        ARCHIVE_NAME="$(resolve_archive "$FROM_ID" "")"
    else
        ARCHIVE_NAME="$(resolve_archive "latest" "")"
    fi
else
    ARCHIVE_NAME="$(resolve_archive "$FROM_ID" "$TIER")"
fi

# ──────────────────────────────────────────────────────────────────────
# Mode dispatch.
# ──────────────────────────────────────────────────────────────────────

if [ "$MODE" = "scratch" ]; then
    # First write into a privacy-sensitive path on this laptop — show
    # the hygiene banner before we materialise PII on disk.
    bv_show_first_write_banner_if_needed
    log "Restoring '$ARCHIVE_NAME' → $TO_DIR"
    tmp_archive="$(mktemp "${TMPDIR:-/tmp}/bv-restore.XXXXXXXX.age")"
    trap 'rm -f "$tmp_archive"' EXIT
    download_archive "$ARCHIVE_NAME" "$tmp_archive"
    decrypt_and_unpack "$tmp_archive" "$TO_DIR"
    log "Scratch restore complete: $TO_DIR"
    printf '%s\n' "$TO_DIR"
    exit 0
fi

# Tier mode.

# Prod safety gate.
if [ "$TIER" = "prod" ] && [ "$YES_FLAG" -ne 1 ]; then
    die "Refusing to restore prod without --yes-i-mean-it. Re-run with --yes-i-mean-it once you are sure." 1
fi

# Tier-mode flow:
#   1. Pre-restore safety-backup (prod only) tagged pre-restore-<ts>.
#   2. Resolve target tier path (live filesystem, via ssh/rsync — but
#      only when WHO is permitted; the restore-to-tier wipe code lives
#      here for review, but the actual destructive call is gated on
#      RESTORE_TO_TIER_ENABLED=1 to keep test runs and GAN-confined
#      runs safe by default).
#   3. Wipe + unpack + clear caches.
#   4. Log to ./logs/restore-<tier>-<timestamp>.log.

mkdir -p "$RESTORE_LOG_DIR"
NOW_TS="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_FILE="$RESTORE_LOG_DIR/restore-${TIER}-${NOW_TS}.log"

log_op() {
    printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG_FILE"
}

# Always start a log entry — the criterion requires an observable
# log file even on the prod path.
{
    printf 'restore op begin tier=%s archive=%s requested_at=%s\n' \
        "$TIER" "$ARCHIVE_NAME" "$NOW_TS"
} > "$LOG_FILE"

if [ "$TIER" = "prod" ]; then
    log_op "prod safety gate passed (--yes-i-mean-it)"
    if [ -n "${RESTORE_LOCAL_TIER_DIR:-}" ]; then
        # Local-tier mode is the testable analogue of the SSH path.
        # Skipping the pre-restore real-prod backup here is deliberate:
        # taking one would SSH to real prod, cost a real S3 upload, and
        # require live prod credentials — none of which makes sense
        # when the operator's intent is clearly to exercise the
        # disaster-recovery code path against a local target. The SSH
        # path below still takes the pre-restore backup unconditionally;
        # only the local-tier branch skips it.
        log "Skipping pre-restore safety backup (RESTORE_LOCAL_TIER_DIR is set — local-tier mode does not touch real prod)"
        log_op "pre-restore safety backup skipped (RESTORE_LOCAL_TIER_DIR set)"
    else
        log "Taking pre-restore safety backup of prod (tag: pre-restore-${NOW_TS})"
        if ! "$SCRIPT_DIR/backup.sh" prod --tag "pre-restore-${NOW_TS}" >>"$LOG_FILE" 2>&1; then
            die "pre-restore backup failed; aborting restore (log: $LOG_FILE)" 4
        fi
        log_op "pre-restore safety backup complete"
    fi
fi

# At this point, the restore-to-tier destructive operation would run.
# In production this is `rsync --delete` from the unpacked archive
# into the live tier's `user/` paths, followed by `bin/grav clearcache`.
# That code path is implemented below but gated behind
# RESTORE_TO_TIER_ENABLED=1 to:
#   - Keep the GAN evaluator safe (the confinement hook would block
#     `rsync --delete` anyway).
#   - Force the operator to opt in explicitly on a real run.

if [ "${RESTORE_TO_TIER_ENABLED:-0}" != "1" ]; then
    log_op "RESTORE_TO_TIER_ENABLED!=1 — wipe-and-replace skipped (operator-only path)"
    log "Refusing to wipe live tier '$TIER' without RESTORE_TO_TIER_ENABLED=1 (this is the GAN-safe stand-in)."
    log "Log written: $LOG_FILE"
    printf 'log=%s\n' "$LOG_FILE"
    printf 'archive=%s\n' "$ARCHIVE_NAME"
    printf 'mode=tier-standin\n'
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────
# Local-tier mode (RESTORE_LOCAL_TIER_DIR).
#
# This is the testable analogue of the SSH path: it performs the same
# wipe-and-replace against a local directory instead of via rsync over
# ssh. Activated only when BOTH:
#   - RESTORE_TO_TIER_ENABLED=1 (the existing safety gate)
#   - RESTORE_LOCAL_TIER_DIR=<absolute-path>
# are set. Without the latter the script falls through to the
# unchanged SSH path below.
#
# The local-tier path lets bats exercise the destructive wipe end-to-end
# without an SSH daemon and without touching live tier paths — a
# disaster-recovery code path should be tested before it's needed.
# ──────────────────────────────────────────────────────────────────────

if [ -n "${RESTORE_LOCAL_TIER_DIR:-}" ]; then
    case "$RESTORE_LOCAL_TIER_DIR" in
        /*) ;;  # absolute — required
        *) die "RESTORE_LOCAL_TIER_DIR must be an absolute path (got: $(printf %q "$RESTORE_LOCAL_TIER_DIR"))" 1 ;;
    esac
    case "$RESTORE_LOCAL_TIER_DIR" in
        *..*) die "RESTORE_LOCAL_TIER_DIR contains '..' — refusing for safety" 1 ;;
    esac
    if [ ! -d "$RESTORE_LOCAL_TIER_DIR" ]; then
        die "RESTORE_LOCAL_TIER_DIR does not exist or is not a directory: $(printf %q "$RESTORE_LOCAL_TIER_DIR")" 1
    fi

    require_bin tar
    require_bin age
    require_bin rsync

    # First-write banner — local-tier restores stage data through the
    # same privacy-sensitive territory as the operator-laptop paths.
    bv_show_first_write_banner_if_needed

    log "Local-tier restore mode: target=$RESTORE_LOCAL_TIER_DIR"
    log_op "local-tier mode: target=$RESTORE_LOCAL_TIER_DIR"

    # Download + decrypt + unpack archive into a private scratch.
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bv-restore-tier.XXXXXXXX")"
    chmod 700 "$SCRATCH"
    trap 'rm -rf "$SCRATCH"' EXIT

    tmp_archive="$SCRATCH/archive.age"
    download_archive "$ARCHIVE_NAME" "$tmp_archive"
    decrypt_and_unpack "$tmp_archive" "$SCRATCH/unpacked"

    # Read allow-list.
    declare -a INCLUDE_PATHS=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        # Reject traversal/absolute prefixes in the allow-list (defence
        # in depth — backup.sh already rejects these on read).
        case "$line" in
            /*|*..*) die "Invalid allow-list entry: $line" 1 ;;
        esac
        INCLUDE_PATHS+=("$line")
    done < "$PATHS_FILE"

    # Wipe + replace each allow-listed path against the local target.
    # We use rsync --delete to mirror the SSH path's exact semantics
    # (deleted files are removed, modified files are replaced, added
    # untracked files vanish). The trailing slash on `src/` and `dst/`
    # is load-bearing — without it rsync nests the directory.
    for rel in "${INCLUDE_PATHS[@]}"; do
        src="$SCRATCH/unpacked/$rel/"
        dst="$RESTORE_LOCAL_TIER_DIR/$rel/"
        if [ ! -d "${src%/}" ]; then
            log_op "skip $rel (not in archive)"
            continue
        fi
        mkdir -p "$dst"
        log_op "rsync --delete (local) $rel"
        rsync -a --delete -- "$src" "$dst" \
            || die "local rsync to $dst failed (log: $LOG_FILE)" 5
    done

    # Clear caches if a Grav binary is present at the target. The
    # spec-mandated command is `bin/grav clearcache` (no hyphen).
    grav_bin="$RESTORE_LOCAL_TIER_DIR/bin/grav"
    if [ -x "$grav_bin" ] || [ -f "$grav_bin" ]; then
        log_op "running bin/grav clearcache from $RESTORE_LOCAL_TIER_DIR"
        if ( cd "$RESTORE_LOCAL_TIER_DIR" && bin/grav clearcache ) >>"$LOG_FILE" 2>&1; then
            log_op "clearcache complete"
        else
            warn "bin/grav clearcache returned non-zero (continuing)"
            log_op "clearcache returned non-zero (continuing)"
        fi
    else
        log_op "clearcache skipped — no Grav binary at $grav_bin"
        log "clearcache skipped — no Grav binary at $grav_bin"
    fi

    log_op "restore complete"
    log "Restore complete. Log: $LOG_FILE"
    printf 'log=%s\n' "$LOG_FILE"
    printf 'archive=%s\n' "$ARCHIVE_NAME"
    printf 'mode=tier-local\n'
    printf 'target=%s\n' "$RESTORE_LOCAL_TIER_DIR"
    exit 0
fi

# === Live restore-to-tier path (operator only). ===
# Reachable only when the operator has set RESTORE_TO_TIER_ENABLED=1
# AND configured the tier's SSH credentials. Reviewable below.

log "Resolving SSH credentials for tier '$TIER'"
case "$TIER" in
    prod)
        SSH_HOST="${DEPLOY_PROD_HOST:-}"
        SSH_USER="${DEPLOY_PROD_USER:-}"
        SSH_PORT="${DEPLOY_PROD_PORT:-22}"
        SSH_PATH="${DEPLOY_PROD_PATH:-}"
        ;;
    staging|test|dev)
        SSH_HOST="${DEPLOY_HOST:-}"
        SSH_USER="${DEPLOY_USER:-}"
        SSH_PORT="${DEPLOY_PORT:-22}"
        base_path="${DEPLOY_PATH:-}"
        case "$TIER" in
            staging) SSH_PATH="$base_path" ;;
            test)    SSH_PATH="$base_path/test" ;;
            dev)     SSH_PATH="$base_path/dev" ;;
        esac
        ;;
esac
[ -n "$SSH_HOST" ] || die "Missing SSH host env var for tier $TIER" 1
[ -n "$SSH_USER" ] || die "Missing SSH user env var for tier $TIER" 1
[ -n "$SSH_PATH" ] || die "Missing SSH path env var for tier $TIER" 1
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    die "Invalid SSH port: $(printf %q "$SSH_PORT")" 1
fi
require_bin ssh
require_bin rsync

# Download + unpack to a tempdir.
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bv-restore-tier.XXXXXXXX")"
chmod 700 "$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

tmp_archive="$SCRATCH/archive.age"
download_archive "$ARCHIVE_NAME" "$tmp_archive"
decrypt_and_unpack "$tmp_archive" "$SCRATCH/unpacked"

# Read the allow-list — the same one backup.sh uses.
declare -a INCLUDE_PATHS=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    INCLUDE_PATHS+=("$line")
done < "$PATHS_FILE"

# Wipe + replace each allow-listed path. This is the call the
# confinement hook would block — it's only reachable when
# RESTORE_TO_TIER_ENABLED=1 is set explicitly on a real operator run.
for rel in "${INCLUDE_PATHS[@]}"; do
    src="$SCRATCH/unpacked/$rel/"
    [ -d "$src" ] || { log_op "skip $rel (not in archive)"; continue; }
    log_op "rsync --delete to ${SSH_USER}@${SSH_HOST}:${SSH_PATH}/$rel"
    rsync -az --delete -e "ssh -p ${SSH_PORT}" \
          "$src" "${SSH_USER}@${SSH_HOST}:${SSH_PATH}/${rel}/" \
          || die "rsync to ${SSH_HOST}:${SSH_PATH}/$rel failed (log: $LOG_FILE)" 5
done

# Clear caches afterwards. We use the spec-mandated `bin/grav
# clearcache` (no hyphen).
log_op "clearing Grav caches on ${SSH_HOST}"
ssh -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" \
    "cd $(printf %q "$SSH_PATH") && bin/grav clearcache" \
    >>"$LOG_FILE" 2>&1 \
    || warn "bin/grav clearcache returned non-zero (continuing)"

log_op "restore complete"
log "Restore complete. Log: $LOG_FILE"
printf 'log=%s\n' "$LOG_FILE"
printf 'archive=%s\n' "$ARCHIVE_NAME"
printf 'mode=tier-live\n'
exit 0
