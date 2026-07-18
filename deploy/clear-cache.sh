#!/usr/bin/env bash
# clear-cache.sh — clear Grav's cache on a tier
#
# WHY
# ---
# The local `make cache-clear` / `make reset-cache` only touches the Docker
# container. After manual edits on a tier (or a data/user change made outside
# the deploy scripts) the tier's Grav cache can go stale; this runs
# `php bin/grav clearcache` from the tier's release root, through the same
# SSH machinery as the other deploy scripts. Non-destructive — Grav rebuilds
# the cache on the next request.
#
# USAGE
# -----
#   ./deploy/clear-cache.sh <tier>
#
# Tiers: dev | test | staging | prod
#   --help, -h   Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# ── 1. Parse args ────────────────────────────────────────────────────
TIER=""
for arg in "$@"; do
    case "$arg" in
        dev|test|staging|prod) TIER="$arg" ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌  Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

case "$TIER" in
    dev|test|staging|prod) ;;
    *) echo "❌  Usage: $0 <dev|test|staging|prod>" >&2; exit 1 ;;
esac

# ── 2. Load credentials + resolve SSH for the tier ───────────────────
ENV_FILE="$PROJECT_DIR/.env.deploy"
[ -f "$ENV_FILE" ] || { echo "❌  Missing $ENV_FILE — copy .env.deploy.example and fill in credentials" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
# shellcheck source=deploy/lib/ssh-auth.sh
. "$SCRIPT_DIR/lib/ssh-auth.sh"

export TIER
if [ "$TIER" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod clear-cache requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod clear-cache requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod clear-cache requires DEPLOY_PROD_PATH in .env.deploy}"
    HOST_SSH="$DEPLOY_PROD_HOST"; USER_SSH="$DEPLOY_PROD_USER"
    PORT_SSH="${DEPLOY_PROD_PORT:-${DEPLOY_PORT:-22}}"; PATH_SSH="$DEPLOY_PROD_PATH"
else
    : "${DEPLOY_HOST:?missing DEPLOY_HOST in .env.deploy}"
    : "${DEPLOY_USER:?missing DEPLOY_USER in .env.deploy}"
    : "${DEPLOY_PATH:?missing DEPLOY_PATH in .env.deploy}"
    : "${DEPLOY_PORT:?missing DEPLOY_PORT in .env.deploy}"
    HOST_SSH="$DEPLOY_HOST"; USER_SSH="$DEPLOY_USER"
    PORT_SSH="$DEPLOY_PORT"; PATH_SSH="$DEPLOY_PATH"
fi
export DEPLOY_PASS
if ! DEPLOY_PASS="$(bv_resolve_ssh_password)"; then
    # bv_resolve_ssh_password already printed an actionable Keychain error.
    exit 1
fi

TIER_DIR="$PATH_SSH/$TIER"

echo "→ clear-cache: $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$TIER_DIR"

if ! bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "cd '$TIER_DIR' && php bin/grav clearcache"; then
    echo "✗ cache clear failed." >&2
    bv_ssh_diagnose "$USER_SSH" "$HOST_SSH" "$PORT_SSH"
    exit 1
fi

echo "✓ Cleared Grav cache on $TIER."
