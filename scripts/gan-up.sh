#!/usr/bin/env bash
set -euo pipefail

# Brings up a Grav container bound to a GAN worktree on a non-default port.
# Each GAN run gets its own container + project name so it can never
# collide with the primary dev container or another GAN run.
#
# Usage: scripts/gan-up.sh <worktree-path> [port]
#
# The worktree path must exist and contain config/www/ (i.e. be a git
# worktree of this repo). The port defaults to 8081.
#
# The paired scripts/gan-down.sh tears it down.

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <worktree-path> [port]" >&2
  exit 2
fi

WORKTREE="$1"
PORT="${2:-8081}"

if [[ ! -d "$WORKTREE/config/www" ]]; then
  echo "error: '$WORKTREE' does not contain config/www/ — not a valid worktree" >&2
  exit 1
fi

WORKTREE_ABS="$(cd "$WORKTREE" && pwd)"
# Derive a unique project/container name from the worktree branch name so
# multiple GAN runs can coexist. Fall back to a hash of the path.
PROJECT="gan-$(basename "$WORKTREE_ABS" | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
if [[ -z "$PROJECT" || "$PROJECT" == "gan-" ]]; then
  PROJECT="gan-$(printf '%s' "$WORKTREE_ABS" | shasum | cut -c1-8)"
fi

cd "$(dirname "$0")/.."

GRAV_CONTAINER="$PROJECT" \
GRAV_PORT="$PORT" \
GRAV_ROOT="$WORKTREE_ABS/config" \
  docker compose -p "$PROJECT" up -d

echo
echo "GAN container up:"
echo "  project:   $PROJECT"
echo "  port:      http://localhost:$PORT"
echo "  worktree:  $WORKTREE_ABS"
echo
echo "Tear down with:  scripts/gan-down.sh $WORKTREE_ABS"
