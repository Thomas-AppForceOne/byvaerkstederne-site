#!/usr/bin/env bash
set -euo pipefail

# Brings up a Grav container bound to a git worktree on a chosen port.
#
# Each worktree gets a deterministic container name (grav-<sha256_8>) and
# is registered in .gan/port-registry.json so the port can be recovered
# across Claude Desktop restarts. Multiple worktrees can run concurrently
# because every worktree maps to a unique container + port.
#
# Usage:
#   scripts/gan-up.sh <worktree-path> [port]
#
# Behaviour:
#   1. If the worktree is already registered and the container is running,
#      this is a no-op: we export GRAV_PORT/GRAV_CONTAINER/GRAV_ROOT and exit.
#   2. If registered but the container is gone, we restart on the registered
#      port (Claude restart recovery path).
#   3. Otherwise we validate the requested port is free, start the
#      container, wait until Grav responds, and write the registry entry.

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <worktree-path> [port]" >&2
  exit 2
fi

WORKTREE_PATH="$1"
REQUESTED_PORT="${2:-8081}"

if [[ ! -d "$WORKTREE_PATH/config/www" ]]; then
  echo "error: '$WORKTREE_PATH' does not contain config/www/ — not a valid worktree" >&2
  exit 1
fi

WORKTREE_ABS="$(cd "$WORKTREE_PATH" && pwd)"

# Deterministic, collision-resistant id from the absolute path.
# Uses shasum -a 256 for cross-platform support (macOS lacks sha256sum).
WORKTREE_ID="$(printf '%s' "$WORKTREE_ABS" | shasum -a 256 | cut -c1-8)"
CONTAINER_NAME="grav-$WORKTREE_ID"
PROJECT_NAME="$CONTAINER_NAME"
REGISTRY_FILE="$WORKTREE_ABS/.gan/port-registry.json"

port_in_use() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    if lsof -iTCP:"$port" -sTCP:LISTEN -Pn >/dev/null 2>&1; then
      return 0
    fi
  fi
  if command -v netstat >/dev/null 2>&1; then
    if netstat -an 2>/dev/null | grep -E "[:.]$port[[:space:]]+.*LISTEN" >/dev/null; then
      return 0
    fi
  fi
  if command -v ss >/dev/null 2>&1; then
    if ss -tuln 2>/dev/null | grep -qE "[:.]$port\\b"; then
      return 0
    fi
  fi
  if docker ps --format '{{.Ports}}' 2>/dev/null | grep -q ":$port->"; then
    return 0
  fi
  return 1
}

container_running() {
  docker ps --filter "name=^${CONTAINER_NAME}\$" --format '{{.Names}}' 2>/dev/null \
    | grep -qx "$CONTAINER_NAME"
}

# Recovery: if this worktree is already registered, reuse its port.
if [[ -f "$REGISTRY_FILE" ]] && command -v jq >/dev/null 2>&1; then
  EXISTING_PORT="$(jq -r --arg path "$WORKTREE_ABS" '.worktrees[$path].port // empty' "$REGISTRY_FILE" 2>/dev/null || echo "")"
  if [[ -n "$EXISTING_PORT" ]]; then
    echo "ℹ️  Worktree already registered on port $EXISTING_PORT"
    if container_running; then
      echo "✓ Container $CONTAINER_NAME is running"
      export GRAV_PORT="$EXISTING_PORT"
      export GRAV_CONTAINER="$CONTAINER_NAME"
      export GRAV_ROOT="$WORKTREE_ABS/config"
      echo "Exporting: GRAV_PORT=$GRAV_PORT, GRAV_CONTAINER=$GRAV_CONTAINER, GRAV_ROOT=$GRAV_ROOT"
      exit 0
    else
      echo "⚠️  Container not running — restarting on port $EXISTING_PORT..."
      REQUESTED_PORT="$EXISTING_PORT"
    fi
  fi
fi

echo "Checking if port $REQUESTED_PORT is available..."
if port_in_use "$REQUESTED_PORT"; then
  echo "❌ ERROR: Port $REQUESTED_PORT is already in use" >&2
  echo "   Try a different port: $0 $WORKTREE_PATH 9001" >&2
  echo "   Or list conflicting containers: docker ps" >&2
  exit 1
fi

export GRAV_PORT="$REQUESTED_PORT"
export GRAV_CONTAINER="$CONTAINER_NAME"
export GRAV_ROOT="$WORKTREE_ABS/config"

cd "$WORKTREE_ABS"
echo "Starting Grav on port $REQUESTED_PORT (container: $CONTAINER_NAME)..."
docker compose -p "$PROJECT_NAME" up -d --remove-orphans

echo "Waiting for Grav to be ready..."
MAX_ATTEMPTS=30
for i in $(seq 1 "$MAX_ATTEMPTS"); do
  code="$(curl -so /dev/null -w '%{http_code}' "http://127.0.0.1:$REQUESTED_PORT/" 2>/dev/null || true)"
  code="${code:-000}"
  if [[ "$code" =~ ^[23] ]]; then
    echo "✓ Grav is ready on http://127.0.0.1:$REQUESTED_PORT (HTTP $code)"
    break
  fi
  if [[ $i -eq $MAX_ATTEMPTS ]]; then
    echo "❌ ERROR: Grav failed to start on port $REQUESTED_PORT" >&2
    docker compose -p "$PROJECT_NAME" logs --tail=30 >&2 || true
    docker compose -p "$PROJECT_NAME" down --remove-orphans 2>/dev/null || true
    exit 1
  fi
  echo "  Attempt $i/$MAX_ATTEMPTS (HTTP $code)..."
  sleep 2
done

mkdir -p "$(dirname "$REGISTRY_FILE")"
if [[ ! -f "$REGISTRY_FILE" ]]; then
  printf '%s\n' '{"worktrees": {}, "last_updated": null}' > "$REGISTRY_FILE"
fi

if command -v jq >/dev/null 2>&1; then
  TMPFILE="$(mktemp)"
  jq --arg path "$WORKTREE_ABS" \
     --argjson port "$REQUESTED_PORT" \
     --arg container "$CONTAINER_NAME" \
     '.worktrees[$path] = {
        "port": $port,
        "container": $container,
        "started_at": (now | todate),
        "status": "running"
      } | .last_updated = (now | todate)' \
     "$REGISTRY_FILE" > "$TMPFILE" && mv "$TMPFILE" "$REGISTRY_FILE"
else
  echo "⚠️  jq not installed — skipping registry update. Install with: brew install jq" >&2
fi

echo ""
echo "=========================================="
echo "✓ Setup complete"
echo "=========================================="
echo "Port:      $GRAV_PORT"
echo "Container: $GRAV_CONTAINER"
echo "Site:      http://127.0.0.1:$GRAV_PORT"
echo "Exported:  GRAV_PORT, GRAV_CONTAINER, GRAV_ROOT"
echo "=========================================="
