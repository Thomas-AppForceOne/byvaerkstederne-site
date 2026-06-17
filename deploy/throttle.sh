#!/usr/bin/env bash
# throttle.sh — toggle the registration throttle on/off on a tier, live.
#
# Flips the `enabled:` flag in the tier's DEPLOYED env override
# (user/env/<host>/config/plugins/registration-throttle.yaml) and clears Grav's
# cache, over SSH. The change takes effect immediately — no redeploy — and
# REVERTS to the committed value on the next deploy. Handy for verifying the
# throttle on dev/test (which ship disabled) without a full deploy cycle.
#
# USAGE
#   ./deploy/throttle.sh <tier> <on|off> [--i-mean-it]
#
# Tiers: dev | test | staging | prod
#   prod requires --i-mean-it (toggling prod changes live abuse protection).
#   --help, -h   Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# Canonical host per tier — MUST match deploy.sh's ENV_HOST.
tier_host() {
    case "$1" in
        dev)     echo "dev.hackersbychoice.dk" ;;
        test)    echo "test.hackersbychoice.dk" ;;
        staging) echo "staging.hackersbychoice.dk" ;;
        prod)    echo "www.byvaerkstederne.dk" ;;
        *) return 1 ;;
    esac
}

# ── 1. Parse args ────────────────────────────────────────────────────
TIER=""; STATE=""; I_MEAN_IT=0
for arg in "$@"; do
    case "$arg" in
        dev|test|staging|prod) TIER="$arg" ;;
        on|off) STATE="$arg" ;;
        --i-mean-it) I_MEAN_IT=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌  Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "$TIER" ] || [ -z "$STATE" ]; then
    echo "❌  Usage: $0 <dev|test|staging|prod> <on|off> [--i-mean-it]" >&2
    exit 1
fi
if [ "$TIER" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
    echo "❌  Toggling prod's registration throttle changes live abuse protection." >&2
    echo "    Re-run with --i-mean-it if you mean it." >&2
    exit 1
fi
VAL="$([ "$STATE" = "on" ] && echo true || echo false)"

# ── 2. Load credentials + resolve SSH for the tier ───────────────────
ENV_FILE="$PROJECT_DIR/.env.deploy"
[ -f "$ENV_FILE" ] || { echo "❌  Missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
# shellcheck source=deploy/lib/ssh-auth.sh
. "$SCRIPT_DIR/lib/ssh-auth.sh"

export TIER
if [ "$TIER" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod throttle requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod throttle requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod throttle requires DEPLOY_PROD_PATH in .env.deploy}"
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
DEPLOY_PASS="$(bv_resolve_ssh_password)"

host="$(tier_host "$TIER")"
TIER_DIR="$PATH_SSH/$TIER"
FILE="$TIER_DIR/user/env/$host/config/plugins/registration-throttle.yaml"

echo "→ throttle $STATE on $TIER ($host)"

# ── 3. Flip the flag + clear cache (live) ────────────────────────────
out="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
    [ -f \"$FILE\" ] || { echo __NOFILE__; exit 0; }
    sed -i 's/^enabled:.*/enabled: $VAL/' \"$FILE\"
    cd \"$TIER_DIR\" && php bin/grav clearcache >/dev/null 2>&1 || true
    grep -E '^enabled:' \"$FILE\"
" 2>/dev/null || echo __SSHFAIL__)"

case "$out" in
    __NOFILE__)
        echo "✗ $TIER has no throttle config yet ($FILE)." >&2
        echo "    Deploy the branch to $TIER first (make deploy tier=$TIER)." >&2
        exit 1 ;;
    __SSHFAIL__)
        echo "✗ SSH failed (auth / host / network)." >&2
        exit 1 ;;
    *)
        echo "✓ $TIER throttle is now '$out' (live; reverts to the committed value on next deploy)." ;;
esac
