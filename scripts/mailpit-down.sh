#!/usr/bin/env bash
set -euo pipefail

# Tears down the Mailpit sink for THIS worktree (WI-6). Stops the sink container
# and DEFENSIVELY restores email.yaml — the Playwright run restores it itself in
# global-teardown, so under normal use the restore here is a no-op; it exists as
# the operator's recovery path after a killed run left the override behind.
# Leaves the Grav container itself running.
#
# Usage:
#   scripts/mailpit-down.sh <worktree-path>

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <worktree-path>" >&2
  exit 2
fi

WORKTREE_PATH="$1"
WORKTREE_ABS="$(cd "$WORKTREE_PATH" && pwd -P)"
WORKTREE_ID="$(printf '%s' "$WORKTREE_ABS" | shasum -a 256 | cut -c1-8)"
GRAV_CONTAINER_NAME="grav-$WORKTREE_ID"
PROJECT_NAME="$GRAV_CONTAINER_NAME"
MAILPIT_CONTAINER_NAME="mailpit-$WORKTREE_ID"

cd "$WORKTREE_ABS"

echo "Stopping Mailpit ($MAILPIT_CONTAINER_NAME)..."
GRAV_CONTAINER="$GRAV_CONTAINER_NAME" \
GRAV_ROOT="$WORKTREE_ABS/config" \
MAILPIT_CONTAINER="$MAILPIT_CONTAINER_NAME" \
  docker compose -p "$PROJECT_NAME" --profile test rm -sf mailpit 2>/dev/null || true

# Defensively restore the committed credential-free email.yaml so the working
# tree is clean again. `git checkout` is the source of truth (a no-op when the
# file is already clean). Also drop any stale backup a legacy, pre-suite-owned
# mailpit-up.sh may have written under .gan/.
if command -v git >/dev/null 2>&1; then
  git -C "$WORKTREE_ABS" checkout -- config/www/user/config/plugins/email.yaml 2>/dev/null || true
fi
rm -f "$WORKTREE_ABS/.gan/email.yaml.committed.bak"

# Legacy cleanup: older mailpit-up.sh relaxed session.secure and backed
# system.yaml up to .gan/. That relaxation is gone (system.yaml no longer
# hard-forces secure), but restore any stale backup left by an old run so the
# working tree can't be left modified.
SYSTEM_CFG="$WORKTREE_ABS/config/www/user/config/system.yaml"
SYSTEM_BAK="$WORKTREE_ABS/.gan/system.yaml.committed.bak"
if [ -f "$SYSTEM_BAK" ]; then
  cp "$SYSTEM_BAK" "$SYSTEM_CFG"
  rm -f "$SYSTEM_BAK"
fi
if docker ps --filter "name=^${GRAV_CONTAINER_NAME}\$" --format '{{.Names}}' | grep -qx "$GRAV_CONTAINER_NAME"; then
  docker exec -u abc -w /app/www/public "$GRAV_CONTAINER_NAME" bin/grav clearcache >/dev/null 2>&1 || true
fi

echo "✓ Mailpit stopped"
