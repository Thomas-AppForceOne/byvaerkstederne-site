#!/usr/bin/env bash
set -euo pipefail

# Tear down a GAN-run Grav container. Must be pointed at the same
# worktree the paired scripts/gan-up.sh was given so the project name
# resolves identically.
#
# Usage: scripts/gan-down.sh <worktree-path>

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <worktree-path>" >&2
  exit 2
fi

WORKTREE="$1"
WORKTREE_ABS="$(cd "$WORKTREE" && pwd 2>/dev/null || echo "$WORKTREE")"

PROJECT="gan-$(basename "$WORKTREE_ABS" | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
if [[ -z "$PROJECT" || "$PROJECT" == "gan-" ]]; then
  PROJECT="gan-$(printf '%s' "$WORKTREE_ABS" | shasum | cut -c1-8)"
fi

cd "$(dirname "$0")/.."

GRAV_CONTAINER="$PROJECT" \
GRAV_PORT="0" \
GRAV_ROOT="$WORKTREE_ABS/config" \
  docker compose -p "$PROJECT" down --remove-orphans
