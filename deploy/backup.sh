#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# Byværkstederne — Backup production data from one.com
# Usage: ./deploy/backup.sh [environment]
#   Environments: prod (default), test, dev, staging
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$PROJECT_DIR/backups"

ENV="${1:-prod}"
case "$ENV" in
    prod|production) ENV_LABEL="Production"; ENV_SUBFOLDER="" ;;
    test)            ENV_LABEL="Test";       ENV_SUBFOLDER="/test" ;;
    dev)             ENV_LABEL="Dev";        ENV_SUBFOLDER="/dev" ;;
    staging)         ENV_LABEL="Staging";    ENV_SUBFOLDER="/staging" ;;
    *) echo "❌  Unknown environment: $ENV"; exit 1 ;;
esac

# Load credentials
ENV_FILE="$PROJECT_DIR/.env.deploy"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌  Missing .env.deploy"
    exit 1
fi
source "$ENV_FILE"

REMOTE_PATH="${DEPLOY_PATH}${ENV_SUBFOLDER}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
TARGET_DIR="$BACKUP_DIR/$ENV/$TIMESTAMP"
LATEST_LINK="$BACKUP_DIR/$ENV/latest"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  Byværkstederne — Backup             ║"
echo "  ║  Environment: ${ENV_LABEL}$(printf '%*s' $((20 - ${#ENV_LABEL})) '')║"
echo "  ╚══════════════════════════════════════╝"
echo ""

mkdir -p "$TARGET_DIR"

# Pull data files from server
echo "→ Pulling data from ${DEPLOY_HOST}..."

# Backup user accounts
sshpass -p "$DEPLOY_PASS" rsync -avz \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_PATH}/user/accounts/" \
    "$TARGET_DIR/accounts/" 2>/dev/null || true

# Backup Flex Objects data
sshpass -p "$DEPLOY_PASS" rsync -avz \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_PATH}/user/data/" \
    "$TARGET_DIR/data/" 2>/dev/null || true

# Backup page content (in case pages were edited via admin)
sshpass -p "$DEPLOY_PASS" rsync -avz \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_PATH}/user/pages/" \
    "$TARGET_DIR/pages/" 2>/dev/null || true

# Backup user config
sshpass -p "$DEPLOY_PASS" rsync -avz \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_PATH}/user/config/" \
    "$TARGET_DIR/config/" 2>/dev/null || true

# Backup uploaded media
sshpass -p "$DEPLOY_PASS" rsync -avz \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${REMOTE_PATH}/user/themes/byvaerkstederne/images/" \
    "$TARGET_DIR/images/" 2>/dev/null || true

# Update latest symlink
rm -f "$LATEST_LINK"
ln -s "$TIMESTAMP" "$LATEST_LINK"

# Count backups and show size
BACKUP_SIZE=$(du -sh "$TARGET_DIR" | cut -f1)
BACKUP_COUNT=$(ls -d "$BACKUP_DIR/$ENV"/20* 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "  ✅  Backup complete!"
echo "  📁  $TARGET_DIR"
echo "  📊  Size: $BACKUP_SIZE"
echo "  🗂   Total ${ENV_LABEL} backups: $BACKUP_COUNT"
echo "  🔗  Latest: $LATEST_LINK"
echo ""

# Prune old backups (keep last 30)
PRUNE_COUNT=30
BACKUPS_TO_PRUNE=$(ls -dt "$BACKUP_DIR/$ENV"/20* 2>/dev/null | tail -n +$((PRUNE_COUNT + 1)))
if [ -n "$BACKUPS_TO_PRUNE" ]; then
    echo "$BACKUPS_TO_PRUNE" | while read dir; do
        rm -rf "$dir"
        echo "  🗑  Pruned old backup: $(basename $dir)"
    done
fi
