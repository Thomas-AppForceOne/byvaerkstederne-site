#!/usr/bin/env bash
#
# List backup ids available for restore. Prints one id per line
# (filename without the .tar.gz.age suffix), in the format that
# restore.sh's --from accepts.
#
# Usage:
#   ./deploy/list-backups.sh                # all tiers
#   ./deploy/list-backups.sh dev            # filter by tier
#
# Storage resolution mirrors restore.sh:
#   1. BACKUP_LOCAL_STORE_DIR (if a directory)
#   2. BACKUP_S3_BUCKET (if set; requires `aws`)
#   3. ~/.byvaerkstederne/backups (or BV_KEEP_LOCAL_DIR)
#
# A header line prefixed with `# ` names the backend; ids follow on
# subsequent lines. Header goes to stderr so `make list-backups | head`
# stays useful.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source .env.deploy the same way backup.sh / restore.sh do, so the
# storage env vars resolve without the operator having to export them
# in their shell.
ENV_FILE="${BACKUP_ENV_FILE:-$REPO_ROOT/.env.deploy}"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
fi

LOCAL_BACKUP_DIR="${BV_KEEP_LOCAL_DIR:-$HOME/.byvaerkstederne/backups}"

TIER_FILTER="${1:-}"
case "$TIER_FILTER" in
    ""|prod|staging|test|dev) ;;
    *)
        echo "Usage: $(basename "$0") [prod|staging|test|dev]" >&2
        exit 1
        ;;
esac

apply_filter() {
    if [ -n "$TIER_FILTER" ]; then
        grep "^${TIER_FILTER}-" || true
    else
        cat
    fi
}

list_local_dir() {
    local d="$1"
    [ -d "$d" ] || return 0
    find "$d" -maxdepth 1 -type f -name '*.tar.gz.age' -exec basename {} \; \
        | sed 's/\.tar\.gz\.age$//' \
        | sort \
        | apply_filter
}

if [ -n "${BACKUP_LOCAL_STORE_DIR:-}" ] && [ -d "$BACKUP_LOCAL_STORE_DIR" ]; then
    echo "# managed storage: $BACKUP_LOCAL_STORE_DIR" >&2
    list_local_dir "$BACKUP_LOCAL_STORE_DIR"
elif [ -n "${BACKUP_S3_BUCKET:-}" ]; then
    command -v aws >/dev/null 2>&1 || { echo "❌  aws CLI not on PATH; needed to list s3://$BACKUP_S3_BUCKET" >&2; exit 1; }
    echo "# managed storage: s3://$BACKUP_S3_BUCKET" >&2
    endpoint_args=()
    if [ -n "${BACKUP_S3_ENDPOINT:-}" ]; then
        endpoint_args=(--endpoint-url "$BACKUP_S3_ENDPOINT")
    fi
    AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID:-}" \
    AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY:-}" \
    aws "${endpoint_args[@]}" s3 ls "s3://${BACKUP_S3_BUCKET}/" \
        | awk '{print $NF}' \
        | grep -E '\.tar\.gz\.age$' \
        | sed 's/\.tar\.gz\.age$//' \
        | sort \
        | apply_filter
elif [ -d "$LOCAL_BACKUP_DIR" ]; then
    echo "# local-keep dir: $LOCAL_BACKUP_DIR" >&2
    list_local_dir "$LOCAL_BACKUP_DIR"
else
    echo "(no backups found — set BACKUP_LOCAL_STORE_DIR or BACKUP_S3_BUCKET in .env.deploy, or run backup.sh with --keep-local to populate $LOCAL_BACKUP_DIR)" >&2
    exit 1
fi
