#!/usr/bin/env bash
#
# Byværkstederne — production backup tool.
#
# Usage:
#   ./deploy/backup.sh <tier> [--keep-local] [--tag <label>]
#
#   <tier>          One of: prod, staging, test, dev (validated below).
#   --keep-local    Also retain a copy under ./backups/ on the operator's
#                   laptop. Without this, only the managed-storage copy
#                   is kept.
#   --tag <label>   Tag this backup; tagged backups are exempt from the
#                   retention sweep. Label must match [A-Za-z0-9._-]{1,64}.
#
# Behaviour:
#   1. SSH to the tier (using DEPLOY_<TIER>_* env vars from .env.deploy)
#      OR — for testing/CI — read from $BACKUP_FIXTURE_DIR if it is set.
#   2. Tar the paths listed in deploy/backup-paths.txt, applying the
#      hard-coded deny-list (cache/, logs/, system/, vendor/, tmp/,
#      *.tmp).
#   3. Generate backup-meta.yaml from VERSION/BUILD/data-version markers.
#   4. Encrypt the archive via `age -R deploy/age-recipients.txt`.
#   5. Upload to managed storage atomically (upload to .partial, then
#      rename), or — for testing — to $BACKUP_LOCAL_STORE_DIR if it is
#      set. Falls back to keeping the local archive on upload failure.
#   6. Sweep retention: keep all daily backups for the past 14 days,
#      one weekly (Sunday) for past 12 weeks, one monthly (1st of
#      month) for past 12 months. Tagged backups are never deleted.
#
# Filename format (deterministic, parsed by promote/restore tooling):
#   <tier>-<YYYY-MM-DD>T<HH-MM>Z-v<semver>-b<build>.tar.gz.age
#
# Exit codes:
#   0  success
#   1  CLI / configuration error
#   2  source unreachable (SSH / fixture missing)
#   3  archive build / encryption failure
#   4  managed-storage upload failure (local archive preserved)
#   5  retention sweep failure
#
# This script is non-interactive. It NEVER prompts. Set environment
# variables in .env.deploy (gitignored) before invocation.

set -euo pipefail

# Producer version. Bump in the same commit as a behaviour change.
readonly BACKUP_SCRIPT_VERSION="0.1.0"
export BACKUP_SCRIPT_VERSION

# Resolve repo paths.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly PATHS_FILE="${BACKUP_PATHS_FILE:-$SCRIPT_DIR/backup-paths.txt}"
readonly RECIPIENTS_FILE="${BACKUP_RECIPIENTS_FILE:-$SCRIPT_DIR/age-recipients.txt}"
# Local-keep dir for archived backups + upload-fallback copies.
# Machine-wide by default so all worktrees + GAN run worktrees share
# one location — that way `tmutil addexclusion` is a once-per-machine
# operation, not once-per-worktree (the prior <repo>/backups/ default
# accumulated a separate dir in every worktree, each needing its own
# exclusion). Override via BV_KEEP_LOCAL_DIR env var (in .env.deploy
# or per-invocation).
readonly LOCAL_BACKUP_DIR="${BV_KEEP_LOCAL_DIR:-$HOME/.byvaerkstederne/backups}"
readonly DENY_PATTERNS=(
    "cache"
    "logs"
    "system"
    "vendor"
    "tmp"
    "*.tmp"
)

# ──────────────────────────────────────────────────────────────────────
# Logging helpers (stderr only — stdout is reserved for parseable
# output: the final URL/path).
# ──────────────────────────────────────────────────────────────────────

log()  { printf '[backup] %s\n' "$*" >&2; }
warn() { printf '[backup] WARN: %s\n' "$*" >&2; }
die()  { local code="${2:-1}"; printf '[backup] ERROR: %s\n' "$1" >&2; exit "$code"; }

# Operator-laptop privacy-hygiene banner (shared with restore.sh).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/banner.sh"

# ──────────────────────────────────────────────────────────────────────
# Argument parsing & validation. Every externally-sourced value is
# validated before reaching shell commands or storage. Shell-meta and
# traversal characters are rejected up front.
# ──────────────────────────────────────────────────────────────────────

validate_tier() {
    local t="$1"
    case "$t" in
        prod|staging|test|dev) return 0 ;;
        *) die "Unknown tier '$t' (allowed: prod, staging, test, dev)" 1 ;;
    esac
}

validate_tag() {
    local t="$1"
    if ! [[ "$t" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        die "Invalid --tag value (must match [A-Za-z0-9._-]{1,64}, was: $(printf %q "$t"))" 1
    fi
}

TIER=""
KEEP_LOCAL=0
TAG=""

# First positional arg must be the tier — we deliberately do NOT
# default it, to keep this script cron-friendly without surprise
# fallbacks.
if [ $# -lt 1 ]; then
    die "Usage: $(basename "$0") <tier> [--keep-local] [--tag <label>]" 1
fi
TIER="$1"; shift
validate_tier "$TIER"

while [ $# -gt 0 ]; do
    case "$1" in
        --keep-local) KEEP_LOCAL=1; shift ;;
        --tag)
            [ $# -ge 2 ] || die "--tag requires a value" 1
            validate_tag "$2"
            TAG="$2"; shift 2
            ;;
        --tag=*)
            tag_value="${1#--tag=}"
            validate_tag "$tag_value"
            TAG="$tag_value"; shift
            ;;
        *) die "Unknown option: $(printf %q "$1")" 1 ;;
    esac
done

readonly TIER KEEP_LOCAL TAG

# ──────────────────────────────────────────────────────────────────────
# Dependency checks. Fail loudly if a required binary is missing.
# ──────────────────────────────────────────────────────────────────────

require_bin() {
    command -v "$1" >/dev/null 2>&1 || die "Missing required binary: $1" 1
}
require_bin tar
require_bin age
# `ssh`, `rsync`, and `aws`/`s3cmd` are only required when not in
# fixture/local-store mode; check at use time.

# ──────────────────────────────────────────────────────────────────────
# Recipients file must exist with at least one age public key.
# ──────────────────────────────────────────────────────────────────────

if [ ! -f "$RECIPIENTS_FILE" ]; then
    die "Missing recipients file: $RECIPIENTS_FILE" 1
fi
if ! grep -E '^age1[0-9a-z]+$' "$RECIPIENTS_FILE" >/dev/null 2>&1; then
    die "No valid age recipient (line starting with age1...) in $RECIPIENTS_FILE" 1
fi

# Enforce the cap: 1..BV_AGE_RECIPIENTS_CAP active recipients.
# Source the helper just for BV_AGE_RECIPIENTS_CAP and the count fn;
# helper is also used by restore.sh for Keychain identities.
# shellcheck source=deploy/lib/age-keychain.sh
. "$SCRIPT_DIR/lib/age-keychain.sh"
BV_AGE_RECIPIENTS_FILE="$RECIPIENTS_FILE"   # tell the helper which file
RECIPIENT_COUNT="$(bv_age_recipients_count)"
if [ "$RECIPIENT_COUNT" -lt 1 ]; then
    die "No active recipients in $RECIPIENTS_FILE (need at least 1)" 1
fi
if [ "$RECIPIENT_COUNT" -gt "$BV_AGE_RECIPIENTS_CAP" ]; then
    die "Recipients file has $RECIPIENT_COUNT keys (cap: $BV_AGE_RECIPIENTS_CAP). Retire one with \`./deploy/manage-age-keys.sh retire <label>\`." 1
fi

# ──────────────────────────────────────────────────────────────────────
# Source environment file (gitignored). Only sourced if it exists —
# unit tests run without it and inject env vars directly. We avoid
# sourcing user-controlled files when they aren't trusted; .env.deploy
# is on the operator's machine only.
# ──────────────────────────────────────────────────────────────────────

ENV_FILE="${BACKUP_ENV_FILE:-$REPO_ROOT/.env.deploy}"
if [ -f "$ENV_FILE" ] && [ -z "${BACKUP_FIXTURE_DIR:-}" ]; then
    # Only auto-source when not running against a fixture (tests inject
    # env directly). `set -a` so values export to subshells.
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

# SSH-auth helpers (bv_ssh_cmd, bv_rsync_ssh_e, bv_rsync_via_ssh,
# bv_resolve_ssh_password). These pick between sshpass+password and
# bare ssh+key-auth based on whether DEPLOY_PASS / DEPLOY_PROD_PASS is
# set for the active tier. Source unconditionally — fixture mode never
# calls them, real-host mode does.
# shellcheck source=deploy/lib/ssh-auth.sh
. "$REPO_ROOT/deploy/lib/ssh-auth.sh"

# ──────────────────────────────────────────────────────────────────────
# Resolve source: either a remote SSH host (production path) or a
# local fixture directory (test path). The fixture path is the
# GAN-evaluator-friendly stand-in.
# ──────────────────────────────────────────────────────────────────────

USE_FIXTURE=0
if [ -n "${BACKUP_FIXTURE_DIR:-}" ]; then
    if [ ! -d "$BACKUP_FIXTURE_DIR" ]; then
        die "BACKUP_FIXTURE_DIR not a directory: $(printf %q "$BACKUP_FIXTURE_DIR")" 2
    fi
    # Reject traversal in the fixture path to keep test runners honest.
    case "$BACKUP_FIXTURE_DIR" in
        *..*) die "BACKUP_FIXTURE_DIR contains '..' — refusing" 1 ;;
    esac
    USE_FIXTURE=1
    SOURCE_HOST="${BACKUP_SOURCE_HOST:-fixture.local}"
fi

if [ "$USE_FIXTURE" = "0" ]; then
    # Pull credentials per tier. Each tier has its own block of vars.
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
                staging) SSH_PATH="$base_path/staging" ;;
                test)    SSH_PATH="$base_path/test" ;;
                dev)     SSH_PATH="$base_path/dev" ;;
            esac
            ;;
    esac
    [ -n "$SSH_HOST" ] || die "Missing required env var for $TIER: SSH host" 1
    [ -n "$SSH_USER" ] || die "Missing required env var for $TIER: SSH user" 1
    [ -n "$SSH_PATH" ] || die "Missing required env var for $TIER: remote path" 1
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        die "Invalid SSH port: $(printf %q "$SSH_PORT")" 1
    fi
    SOURCE_HOST="$SSH_HOST"
    require_bin ssh
    require_bin rsync

    # Probe SSH up front so the spec-mandated "ssh to host:port failed"
    # error fires BEFORE we try to read VERSION/BUILD/data-version.yaml
    # over a dead connection. Without this probe, an unreachable host
    # would surface as "source tier missing config/www/VERSION" — a
    # misleading message that hides the real failure mode (network).
    #
    # bv_ssh_cmd dispatches to sshpass+password OR bare ssh+BatchMode
    # depending on whether DEPLOY_PASS / DEPLOY_PROD_PASS is set for
    # this tier (see deploy/lib/ssh-auth.sh).
    if ! bv_ssh_cmd -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" true 2>/dev/null; then
        die "ssh to ${SSH_HOST}:${SSH_PORT} failed" 2
    fi
fi

# ──────────────────────────────────────────────────────────────────────
# Read paths allow-list. Lines starting with `#` and blank lines are
# ignored. Paths must not contain `..` or absolute prefixes.
# ──────────────────────────────────────────────────────────────────────

[ -f "$PATHS_FILE" ] || die "Missing allow-list file: $PATHS_FILE" 1

declare -a INCLUDE_PATHS=()
while IFS= read -r line || [ -n "$line" ]; do
    # Strip comments and whitespace.
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    case "$line" in
        /*|*..*|*"\$"*|*'`'*) die "Invalid path in $PATHS_FILE: $line" 1 ;;
    esac
    INCLUDE_PATHS+=("$line")
done < "$PATHS_FILE"
[ "${#INCLUDE_PATHS[@]}" -gt 0 ] || die "No paths in $PATHS_FILE (allow-list empty)" 1

# ──────────────────────────────────────────────────────────────────────
# Build the backup. Operate in a private tempdir; trap cleans up.
# ──────────────────────────────────────────────────────────────────────

cleanup_workdir() {
    if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/bv-backup.XXXXXXXX")"
chmod 700 "$WORKDIR"
trap cleanup_workdir EXIT INT TERM

# Compute the deterministic timestamp + filename early so meta and the
# archive name agree.
NOW_EPOCH="${BACKUP_FAKE_NOW_EPOCH:-$(date -u +%s)}"
NOW_ISO="$(date -u -r "$NOW_EPOCH" +'%Y-%m-%dT%H:%MZ' 2>/dev/null \
        || date -u -d "@$NOW_EPOCH" +'%Y-%m-%dT%H:%MZ')"
# Filename uses HH-MM (colon-to-hyphen) but date keeps `-`.
NOW_FNAME_TIME="${NOW_ISO//:/-}"   # 2026-04-29T12-34Z

# ──────────────────────────────────────────────────────────────────────
# Source-tier metadata fetch.
#
# The version/build/data-version markers MUST come from the live tier
# being backed up — that's the whole point of "what was the source
# tier running when this backup was taken". Reading them from the
# operator's local repo (which used to happen) is the bug we're
# fixing here: it silently makes downstream consumers (migration
# runner, promote-to-staging, promote-to-prod) trust laptop-local
# state that has no relation to the tier.
#
# Provenance:
#   code_version → <source>/config/www/VERSION       (first line, trimmed)
#   code_build   → <source>/config/www/BUILD         (first line, trimmed)
#   data_version → <source>/config/www/user/data-version.yaml `version:` field
#
# Failure modes:
#   - VERSION or BUILD missing on the source: hard fail (exit 3,
#     "archive build" code). Backup metadata would be useless without
#     them.
#   - data-version.yaml missing on the source: stderr warning + write
#     "0.0.0" to meta. The data-versioning spec hasn't shipped yet,
#     so the file legitimately won't exist on first runs. Defaulting
#     to 0.0.0 (NOT to code_version, NOT to the operator's local
#     repo) is the only sensible behaviour.
#
# Tests inject metadata by populating
# `$BACKUP_FIXTURE_DIR/config/www/{VERSION,BUILD,user/data-version.yaml}`
# and letting the script's normal source-read path consume it. No
# env-var bypass exists — the chunked override path used to be a
# `BACKUP_FAKE_CODE_VERSION` / `BACKUP_FAKE_CODE_BUILD` /
# `BACKUP_FAKE_DATA_VERSION` triple, but it was a footgun: tests
# that set those variables skipped the source-fetch code path
# entirely and would have masked a regression in either fixture
# mode or SSH mode. Removing the overrides forces every test that
# touches metadata to exercise the same fetch logic an operator
# run uses, just routed through the fixture.
# ──────────────────────────────────────────────────────────────────────

# Trim CR/LF and surrounding whitespace from a single-line value.
trim_line() {
    printf '%s' "$1" | tr -d '\r\n' | awk '{$1=$1; print}'
}

# Fetch a single small file from the source tier (≤1KiB) and emit its
# first line trimmed on stdout. Empty stdout = file missing.
# In fixture mode the source is a local directory; in SSH mode we
# round-trip a `cat` over ssh.
source_read_first_line() {
    local rel="$1"   # path relative to the Grav root, e.g. "VERSION"
    # NOTE: deploy.sh ships the contents of <repo>/config/www/* as the
    # tier root on the remote — i.e. <SSH_PATH>/index.php exists, NOT
    # <SSH_PATH>/config/www/index.php. Both fixture and SSH paths
    # therefore look at the Grav root directly, never with a config/www/
    # prefix. (Earlier versions had a `config/www/` segment here that
    # made backup.sh fail against real one.com tiers; the bats fixture
    # masked it because it built `<fixture>/config/www/` to match.)
    if [ "$USE_FIXTURE" = "1" ]; then
        local f="$BACKUP_FIXTURE_DIR/$rel"
        if [ -f "$f" ]; then
            head -n 1 "$f"
        fi
        return 0
    fi
    # SSH path. -n binds stdin to /dev/null so the loop's stdin (if any)
    # isn't consumed. We swallow stderr to keep "no such file" from
    # leaking into our parsed value; the calling site interprets the
    # empty stdout as "missing".
    bv_ssh_cmd -n -p "$SSH_PORT" \
        "${SSH_USER}@${SSH_HOST}" \
        "test -f $(printf %q "$SSH_PATH/$rel") && head -n 1 $(printf %q "$SSH_PATH/$rel")" \
        2>/dev/null || true
}

# Parse a yaml `version:` field (top-level) from the supplied content.
# Accepts quoted or unquoted values. Echoes the value or empty.
extract_yaml_version_field() {
    local content="$1"
    printf '%s\n' "$content" \
        | awk '
            /^[[:space:]]*#/ { next }
            /^version:[[:space:]]*/ {
                v = $0
                sub(/^version:[[:space:]]*/, "", v)
                # strip surrounding quotes
                gsub(/^["'\'']|["'\'']$/, "", v)
                # strip trailing comment
                sub(/[[:space:]]+#.*$/, "", v)
                # trim
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                print v
                exit
            }
        '
}

# Read raw data-version.yaml content from source (empty if missing).
# Same path-shape note as source_read_first_line: source root IS the
# Grav root, so the file lives at `<root>/user/data-version.yaml` —
# never `<root>/config/www/user/data-version.yaml`.
source_read_data_version_yaml() {
    if [ "$USE_FIXTURE" = "1" ]; then
        local f="$BACKUP_FIXTURE_DIR/user/data-version.yaml"
        if [ -f "$f" ]; then
            cat "$f"
        fi
        return 0
    fi
    bv_ssh_cmd -n -p "$SSH_PORT" \
        "${SSH_USER}@${SSH_HOST}" \
        "test -f $(printf %q "$SSH_PATH/user/data-version.yaml") && cat $(printf %q "$SSH_PATH/user/data-version.yaml")" \
        2>/dev/null || true
}

# CODE_VERSION ----------------------------------------------------------
raw="$(source_read_first_line VERSION)"
CODE_VERSION="$(trim_line "$raw")"
if [ -z "$CODE_VERSION" ]; then
    die "source tier missing VERSION (cannot stamp backup metadata)" 3
fi

# CODE_BUILD ------------------------------------------------------------
raw="$(source_read_first_line BUILD)"
CODE_BUILD="$(trim_line "$raw")"
if [ -z "$CODE_BUILD" ]; then
    die "source tier missing BUILD (cannot stamp backup metadata)" 3
fi

# DATA_VERSION ----------------------------------------------------------
# Fall-back rule: if the source has no data-version.yaml, write
# "0.0.0" (the literal string) and emit a stderr warning naming the
# missing file. Do NOT inherit code_version, do NOT consult the
# operator's local repo. The malformed-but-present case (file exists
# but has no parseable `version:` field) is treated as a hard error
# below — silently defaulting would let downstream migration tooling
# trust a metadata field that came from corrupted state.
dv_raw="$(source_read_data_version_yaml)"
if [ -z "$dv_raw" ]; then
    # File-not-present: fallback to "0.0.0". data-version.yaml is reserved
    # for a future data-versioning feature that has not yet shipped.
    DATA_VERSION="0.0.0"
else
    DATA_VERSION="$(extract_yaml_version_field "$dv_raw")"
    if [ -z "$DATA_VERSION" ]; then
        # File-present-but-malformed: hard fail. Defaulting would
        # produce metadata claiming a version of 0.0.0 for a tier
        # whose data-version.yaml exists but is corrupt or
        # hand-edited. Downstream migration tooling consuming that
        # metadata could then apply migrations targeting 0.0.0 →
        # 0.x.y to data that's actually at 0.x.y already, with
        # destructive results. Refusing to back up is the safe
        # response — the operator can fix or remove the file and
        # retry.
        die "source tier user/data-version.yaml exists but has no parseable 'version:' field; refusing to stamp metadata" 3
    fi
fi

# Sanity-check version + build shapes (defence-in-depth — the schema
# enforces them on consumers, but we may as well refuse to write bad
# meta in the first place).
if ! [[ "$CODE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    die "Malformed code version: $(printf %q "$CODE_VERSION")" 3
fi
if ! [[ "$CODE_BUILD" =~ ^[0-9]+$ ]]; then
    die "Malformed code build: $(printf %q "$CODE_BUILD")" 3
fi
if ! [[ "$DATA_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    die "Malformed data version: $(printf %q "$DATA_VERSION")" 3
fi

ARCHIVE_BASENAME="${TIER}-${NOW_FNAME_TIME}-v${CODE_VERSION}-b${CODE_BUILD}.tar.gz.age"

# ──────────────────────────────────────────────────────────────────────
# Stage files.
# ──────────────────────────────────────────────────────────────────────

STAGE_DIR="$WORKDIR/stage"
mkdir -p "$STAGE_DIR"

if [ "$USE_FIXTURE" = "1" ]; then
    log "Reading source from fixture: $BACKUP_FIXTURE_DIR"
    for rel in "${INCLUDE_PATHS[@]}"; do
        src="$BACKUP_FIXTURE_DIR/$rel"
        if [ -e "$src" ]; then
            mkdir -p "$STAGE_DIR/$(dirname "$rel")"
            # Use cp -R rather than rsync to avoid the rsync-delete
            # confinement gate; we're staging into a fresh tempdir so
            # there's nothing to delete.
            cp -R "$src" "$STAGE_DIR/$rel"
        else
            log "  (allow-list path not in fixture, skipping: $rel)"
        fi
    done
else
    log "Pulling source from ${SSH_USER}@${SSH_HOST}:${SSH_PORT} (${SSH_PATH})"
    # SSH reachability was already probed up front in the credentials
    # block; if we got here, the connection is alive.
    #
    # Pre-rsync existence probe per allow-list entry. rsync of a
    # missing source aborts the whole backup; missing user-content
    # paths (e.g. user/uploads on a fresh dev tier) are legitimately
    # absent, so we skip them with a WARN — same shape as fixture
    # mode. Tier:reldir collisions in the deny-list still apply
    # (the rsync --exclude handling below).
    rsync_e="$(bv_rsync_ssh_e "$SSH_PORT")" \
        || die "could not build rsync ssh-cmd (sshpass missing?)" 2
    rsync_excludes=()
    for pat in "${DENY_PATTERNS[@]}"; do
        rsync_excludes+=(--exclude="$pat")
    done
    SKIPPED_PATHS=()
    for rel in "${INCLUDE_PATHS[@]}"; do
        # Probe the allow-list entry's existence on the remote.
        # Skip-on-missing matches fixture mode's `[ -e $src ]` gate
        # below, so backup behaviour is consistent across both modes.
        # Missing paths are silently skipped — allow-list entries like
        # user/uploads are legitimately absent on tiers that have never
        # had file uploads.
        if ! bv_ssh_cmd -n -p "$SSH_PORT" "${SSH_USER}@${SSH_HOST}" \
            "test -e $(printf %q "$SSH_PATH/$rel")" >/dev/null 2>&1; then
            SKIPPED_PATHS+=("$rel")
            continue
        fi

        mkdir -p "$STAGE_DIR/$(dirname "$rel")"
        # Use rsync without --delete; we're rsyncing INTO an empty
        # tempdir, so deletion is meaningless and the confinement hook
        # blocks --delete anyway.
        # bv_rsync_via_ssh exports SSHPASS for rsync's child process
        # when password-auth is configured.
        bv_rsync_via_ssh -az -e "$rsync_e" \
              "${rsync_excludes[@]}" \
              "${SSH_USER}@${SSH_HOST}:${SSH_PATH}/${rel}/" \
              "$STAGE_DIR/${rel}/" \
              || die "rsync failed for ${rel} from ${SSH_HOST}" 2
    done
    true
fi

# Apply deny-list locally as a belt-and-braces measure (in case the
# fixture path included unwanted content).
prune_deny() {
    local root="$1"
    local pat
    for pat in "${DENY_PATTERNS[@]}"; do
        # Find and remove matches at any depth. -prune to avoid
        # descending into them.
        find "$root" -depth -name "$pat" -print0 2>/dev/null \
            | xargs -0 rm -rf 2>/dev/null || true
    done
}
prune_deny "$STAGE_DIR"

# ──────────────────────────────────────────────────────────────────────
# Write backup-meta.yaml.
# ──────────────────────────────────────────────────────────────────────

META_FILE="$STAGE_DIR/backup-meta.yaml"
{
    printf 'backup_taken_at: "%s"\n' "$NOW_ISO"
    printf 'source_host: "%s"\n' "$SOURCE_HOST"
    printf 'code_version: "%s"\n' "$CODE_VERSION"
    printf 'code_build: "%s"\n' "$CODE_BUILD"
    printf 'data_version: "%s"\n' "$DATA_VERSION"
    printf 'producer: "deploy/backup.sh"\n'
    printf 'producer_version: "%s"\n' "$BACKUP_SCRIPT_VERSION"
    if [ -n "$TAG" ]; then
        printf 'tag: "%s"\n' "$TAG"
    fi
    # encrypted_to: list every age public-key recipient at backup
    # time. Restore.sh reads this BEFORE decrypt so the operator can
    # cross-reference against `manage-age-keys.sh list` to find
    # which Keychain item would unlock the archive.
    printf 'encrypted_to:\n'
    grep -E '^age1[a-z0-9]+$' "$RECIPIENTS_FILE" | while IFS= read -r _pk; do
        printf '  - "%s"\n' "$_pk"
    done
} > "$META_FILE"

# ──────────────────────────────────────────────────────────────────────
# Tar and encrypt. Unencrypted tar lives in WORKDIR briefly; never
# uploaded.
# ──────────────────────────────────────────────────────────────────────

TAR_FILE="$WORKDIR/${TIER}.tar.gz"
ENC_FILE="$WORKDIR/$ARCHIVE_BASENAME"

log "Building archive: $ARCHIVE_BASENAME"
# Build the tar from STAGE_DIR contents — paths in the archive are
# relative (no leading STAGE_DIR/), so restore-to-scratch produces a
# tree shaped exactly like the original tier's user/ dir plus
# backup-meta.yaml at the root.
tar -czf "$TAR_FILE" -C "$STAGE_DIR" . \
    || die "tar failed" 3

# Encrypt with age. -R points at recipients file, -o gives the output.
age -R "$RECIPIENTS_FILE" -o "$ENC_FILE" "$TAR_FILE" \
    || die "age encryption failed" 3

# Wipe the unencrypted tar before doing anything else.
rm -f "$TAR_FILE"

# ──────────────────────────────────────────────────────────────────────
# Managed-storage upload (atomic). The backup script uses one of:
#   1. BACKUP_LOCAL_STORE_DIR — a directory acting as managed storage
#      (used by tests and the GAN evaluator). Atomic-rename via mv.
#   2. AWS S3 / S3-compatible — only when BACKUP_S3_BUCKET is set and
#      the `aws` binary is available. Atomic by uploading to a
#      .partial key, then `aws s3 mv`.
#   3. None — no managed storage configured. The script reports the
#      local archive path and exits non-zero (failure mode (b)).
# ──────────────────────────────────────────────────────────────────────

LOCAL_KEEP_PATH=""
if [ "$KEEP_LOCAL" = "1" ]; then
    # First write into ./backups/ — show the privacy-hygiene banner.
    bv_show_first_write_banner_if_needed
    mkdir -p "$LOCAL_BACKUP_DIR"
    LOCAL_KEEP_PATH="$LOCAL_BACKUP_DIR/$ARCHIVE_BASENAME"
    cp "$ENC_FILE" "$LOCAL_KEEP_PATH"
fi

UPLOAD_REMOTE_URL=""
upload_to_managed_storage() {
    local local_archive="$1"
    local final_name="$2"

    if [ -n "${BACKUP_LOCAL_STORE_DIR:-}" ]; then
        case "$BACKUP_LOCAL_STORE_DIR" in
            *..*) die "BACKUP_LOCAL_STORE_DIR contains '..' — refusing" 1 ;;
        esac
        mkdir -p "$BACKUP_LOCAL_STORE_DIR"
        local partial="$BACKUP_LOCAL_STORE_DIR/${final_name}.partial"
        local final="$BACKUP_LOCAL_STORE_DIR/${final_name}"
        cp "$local_archive" "$partial" || return 1
        mv "$partial" "$final" || return 1
        UPLOAD_REMOTE_URL="file://$final"
        return 0
    fi

    if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
        require_bin aws
        local endpoint_args=()
        if [ -n "${BACKUP_S3_ENDPOINT:-}" ]; then
            endpoint_args=(--endpoint-url "$BACKUP_S3_ENDPOINT")
        fi
        # Credentials passed via env so they don't appear on the
        # command line / in `ps`.
        local s3_partial="s3://${BACKUP_S3_BUCKET}/${final_name}.partial"
        local s3_final="s3://${BACKUP_S3_BUCKET}/${final_name}"
        AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}" \
        AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
        aws "${endpoint_args[@]}" s3 cp "$local_archive" "$s3_partial" >&2 \
            || return 1
        AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}" \
        AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
        aws "${endpoint_args[@]}" s3 mv "$s3_partial" "$s3_final" >&2 \
            || return 1
        UPLOAD_REMOTE_URL="$s3_final"
        return 0
    fi

    return 2  # No managed storage configured.
}

upload_tag_marker() {
    local final_name="$1"
    local label="$2"
    [ -n "$label" ] || return 0
    local tag_payload
    tag_payload="$(mktemp "${TMPDIR:-/tmp}/bv-tag.XXXXXXXX")"
    printf '%s\n' "$label" > "$tag_payload"

    if [ -n "${BACKUP_LOCAL_STORE_DIR:-}" ]; then
        cp "$tag_payload" "$BACKUP_LOCAL_STORE_DIR/${final_name}.tag" || { rm -f "$tag_payload"; return 1; }
        rm -f "$tag_payload"
        return 0
    fi
    if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
        local endpoint_args=()
        if [ -n "${BACKUP_S3_ENDPOINT:-}" ]; then
            endpoint_args=(--endpoint-url "$BACKUP_S3_ENDPOINT")
        fi
        AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}" \
        AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
        aws "${endpoint_args[@]}" s3 cp "$tag_payload" "s3://${BACKUP_S3_BUCKET}/${final_name}.tag" >&2 \
            || { rm -f "$tag_payload"; return 1; }
        rm -f "$tag_payload"
        return 0
    fi
    rm -f "$tag_payload"
    return 0
}

if upload_to_managed_storage "$ENC_FILE" "$ARCHIVE_BASENAME"; then
    log "Uploaded to managed storage: $UPLOAD_REMOTE_URL"
    if [ -n "$TAG" ]; then
        upload_tag_marker "$ARCHIVE_BASENAME" "$TAG" \
            || warn "tag marker upload failed (archive uploaded successfully)"
    fi
else
    rc=$?
    # Preserve the encrypted local archive on upload failure or when
    # no managed storage is configured. This is the spec's failure
    # mode (b): the operator must be able to recover the archive.
    # First write into ./backups/ here too — show the privacy banner
    # before the fallback materialises.
    bv_show_first_write_banner_if_needed
    mkdir -p "$LOCAL_BACKUP_DIR"
    if [ -z "$LOCAL_KEEP_PATH" ]; then
        LOCAL_KEEP_PATH="$LOCAL_BACKUP_DIR/$ARCHIVE_BASENAME"
        mv "$ENC_FILE" "$LOCAL_KEEP_PATH"
    fi
    if [ "$rc" = "2" ]; then
        die "Managed storage not configured (set BACKUP_LOCAL_STORE_DIR or BACKUP_S3_BUCKET). Local archive preserved at: $LOCAL_KEEP_PATH" 4
    else
        die "Upload to managed storage failed. Local archive preserved at: $LOCAL_KEEP_PATH" 4
    fi
fi

# ──────────────────────────────────────────────────────────────────────
# Retention sweep. Delegates to bash functions that operate against
# whichever storage backend is in use.
# ──────────────────────────────────────────────────────────────────────

# Print all backup filenames in managed storage (one per line). Used
# by the retention sweep. Filenames only — no paths/URLs.
list_managed_backups() {
    if [ -n "${BACKUP_LOCAL_STORE_DIR:-}" ] && [ -d "$BACKUP_LOCAL_STORE_DIR" ]; then
        find "$BACKUP_LOCAL_STORE_DIR" -maxdepth 1 -type f \
             -name '*.tar.gz.age' -exec basename {} \; \
             | sort
        return 0
    fi
    if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
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
    return 0
}

delete_managed_backup() {
    local fname="$1"
    if [ -n "${BACKUP_LOCAL_STORE_DIR:-}" ]; then
        rm -f -- "$BACKUP_LOCAL_STORE_DIR/$fname"
        return 0
    fi
    if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
        local endpoint_args=()
        if [ -n "${BACKUP_S3_ENDPOINT:-}" ]; then
            endpoint_args=(--endpoint-url "$BACKUP_S3_ENDPOINT")
        fi
        AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}" \
        AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
        aws "${endpoint_args[@]}" s3 rm "s3://${BACKUP_S3_BUCKET}/$fname" >&2 \
            || true
        return 0
    fi
    return 0
}

# Decide whether a given backup filename should be kept under the
# spec's retention rules:
#   - Tagged backups: never deleted (filename matches *-tag-<label>*).
#   - Daily for past 14 days.
#   - Weekly (Sundays) for past 12 weeks (84 days).
#   - Monthly (1st of month) for past 12 months (~366 days).
# Tagging is encoded by adding `.tag-<label>` before `.tar.gz.age`.
has_tag_marker() {
    local fname="$1"
    if [ -n "${BACKUP_LOCAL_STORE_DIR:-}" ]; then
        [ -f "$BACKUP_LOCAL_STORE_DIR/${fname}.tag" ]
        return $?
    fi
    if [ -n "${BACKUP_S3_BUCKET:-}" ]; then
        local endpoint_args=()
        if [ -n "${BACKUP_S3_ENDPOINT:-}" ]; then
            endpoint_args=(--endpoint-url "$BACKUP_S3_ENDPOINT")
        fi
        AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}" \
        AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
        aws "${endpoint_args[@]}" s3 ls "s3://${BACKUP_S3_BUCKET}/${fname}.tag" \
            >/dev/null 2>&1
        return $?
    fi
    return 1
}

keep_filename() {
    local fname="$1"
    local now_epoch="$2"

    # Tagged backups are exempt from retention sweeps.
    if has_tag_marker "$fname"; then
        return 0
    fi

    # Extract YYYY-MM-DD and HH-MM from filename:
    #   <tier>-YYYY-MM-DDTHH-MMZ-...
    if ! [[ "$fname" =~ ^[a-z]+-([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2})-([0-9]{2})Z- ]]; then
        # Unrecognised filename — keep, don't delete.
        return 0
    fi
    local Y="${BASH_REMATCH[1]}" M="${BASH_REMATCH[2]}" D="${BASH_REMATCH[3]}"
    local h="${BASH_REMATCH[4]}" m="${BASH_REMATCH[5]}"

    # Convert to epoch (UTC).
    local file_epoch
    file_epoch=$(TZ=UTC date -j -f '%Y-%m-%d %H:%M:%S' "${Y}-${M}-${D} ${h}:${m}:00" +%s 2>/dev/null \
              || TZ=UTC date -d "${Y}-${M}-${D} ${h}:${m}:00 UTC" +%s)

    local age_seconds=$((now_epoch - file_epoch))
    local age_days=$((age_seconds / 86400))

    # Day-of-week: 0=Sunday on macOS `date -j`, also 0=Sunday on GNU.
    local dow
    dow=$(TZ=UTC date -j -f '%Y-%m-%d' "${Y}-${M}-${D}" +%w 2>/dev/null \
       || TZ=UTC date -d "${Y}-${M}-${D}" +%w)
    local dom="$D"

    # Daily: <14 days old → keep.
    if [ "$age_days" -lt 14 ]; then return 0; fi
    # Weekly: Sunday and <84 days → keep.
    if [ "$dow" = "0" ] && [ "$age_days" -lt 84 ]; then return 0; fi
    # Monthly: first of month and <366 days → keep.
    if [ "$dom" = "01" ] && [ "$age_days" -lt 366 ]; then return 0; fi

    return 1
}

retention_sweep() {
    local now_epoch="$1"
    local listing
    listing="$(list_managed_backups || true)"
    [ -z "$listing" ] && return 0
    local f
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if ! keep_filename "$f" "$now_epoch"; then
            log "  retention: deleting $f"
            delete_managed_backup "$f" || warn "    (delete reported failure for $f)"
        fi
    done <<< "$listing"
}

retention_sweep "$NOW_EPOCH" || die "Retention sweep failed" 5

# Local-copy retention: keep the most recent 14 archives in
# ./backups/, drop older ones.
local_retention_sweep() {
    [ -d "$LOCAL_BACKUP_DIR" ] || return 0
    # List by mtime, newest first; drop tail past index 14.
    local count=0
    # macOS find supports -t; portably, sort by name (filenames are
    # ISO-timestamped so lexical = chronological).
    find "$LOCAL_BACKUP_DIR" -maxdepth 1 -type f -name '*.tar.gz.age' \
         | sort -r \
         | while IFS= read -r f; do
            count=$((count + 1))
            if [ "$count" -gt 14 ]; then
                rm -f -- "$f" || true
            fi
        done
}
local_retention_sweep || warn "Local-retention sweep encountered an error (non-fatal)"

# ──────────────────────────────────────────────────────────────────────
# Final summary on stdout (parseable). The first line is the URL/path
# of the uploaded archive. Subsequent lines are key=value diagnostics.
# ──────────────────────────────────────────────────────────────────────

printf '%s\n' "$UPLOAD_REMOTE_URL"
printf 'archive=%s\n' "$ARCHIVE_BASENAME"
printf 'tier=%s\n' "$TIER"
printf 'taken_at=%s\n' "$NOW_ISO"
printf 'code_version=%s\n' "$CODE_VERSION"
printf 'code_build=%s\n' "$CODE_BUILD"
printf 'data_version=%s\n' "$DATA_VERSION"
if [ -n "$TAG" ]; then
    printf 'tag=%s\n' "$TAG"
fi
if [ -n "$LOCAL_KEEP_PATH" ]; then
    printf 'local_archive=%s\n' "$LOCAL_KEEP_PATH"
fi

log "Backup complete."
exit 0
