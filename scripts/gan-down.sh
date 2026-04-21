#!/usr/bin/env bash
set -euo pipefail

# Tear down the Grav container associated with a worktree and mark the
# worktree as stopped in .gan/port-registry.json. Paired with gan-up.sh.
#
# Usage:
#   scripts/gan-down.sh <worktree-path>

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <worktree-path>" >&2
  exit 2
fi

WORKTREE_PATH="$1"
WORKTREE_ABS="$(cd "$WORKTREE_PATH" && pwd 2>/dev/null || echo "$WORKTREE_PATH")"

WORKTREE_ID="$(printf '%s' "$WORKTREE_ABS" | shasum -a 256 | cut -c1-8)"
CONTAINER_NAME="grav-$WORKTREE_ID"
PROJECT_NAME="$CONTAINER_NAME"
REGISTRY_FILE="$WORKTREE_ABS/.gan/port-registry.json"

cd "$WORKTREE_ABS"

echo "Stopping container: $CONTAINER_NAME"
# docker compose needs the same env vars that up used, so the container
# name and port resolve identically. Port doesn't matter for down, just
# needs to be set to avoid an unset-variable error from the yaml.
GRAV_CONTAINER="$CONTAINER_NAME" \
GRAV_PORT="0" \
GRAV_ROOT="$WORKTREE_ABS/config" \
  docker compose -p "$PROJECT_NAME" down --remove-orphans 2>/dev/null \
  || echo "  (container already stopped or never started)"

if [[ -f "$REGISTRY_FILE" ]] && command -v jq >/dev/null 2>&1; then
  TMPFILE="$(mktemp)"
  if jq --arg path "$WORKTREE_ABS" \
        'if .worktrees[$path] then
           .worktrees[$path].status = "stopped"
           | .last_updated = (now | todate)
         else . end' \
        "$REGISTRY_FILE" > "$TMPFILE" 2>/dev/null; then
    mv "$TMPFILE" "$REGISTRY_FILE"
  else
    rm -f "$TMPFILE"
    echo "⚠️  Could not update registry (malformed JSON?)" >&2
  fi
fi

echo "✓ Container stopped"
