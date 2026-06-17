#!/usr/bin/env bash
# test-registration-throttle.sh — one-command LOCAL verification of the
# registration throttle.
#
# Enables the throttle locally with a low limit, fires a burst of registrations
# at the local Grav, asserts it throttles, then cleans everything back up (the
# temp override, the test account, the cache). Touches NO tier — purely local.
# Requires a running local container (`make start`).
#
# Exit 0 if the throttle engaged (PASS), 1 otherwise (FAIL).
#
# Usage: scripts/test-registration-throttle.sh [attempts]   (default 6)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO"

ATTEMPTS="${1:-6}"
case "$ATTEMPTS" in ''|*[!0-9]*) echo "❌  attempts must be a whole number (got '$ATTEMPTS')" >&2; exit 1 ;; esac
MAX_COUNT=3
USERNAME=throttletest
OVERRIDE="$REPO/config/www/user/config/plugins/registration-throttle.yaml"
ACCOUNT="$REPO/config/www/user/accounts/$USERNAME.yaml"

# Resolve the local container + port (fail loud → make start).
ENV_LINE="$(node -e 'try{const e=require("./scripts/discover-grav-port.js").discoverGravEnv(".");process.stdout.write(e.container+" "+e.port)}catch(err){process.exit(1)}' 2>/dev/null)" \
    || { echo "❌  No local Grav container — run: make start" >&2; exit 1; }
CONTAINER="${ENV_LINE%% *}"
PORT="${ENV_LINE##* }"
[ -n "$CONTAINER" ] && [ -n "$PORT" ] || { echo "❌  Could not resolve local container/port — run: make start" >&2; exit 1; }

clearcache() { docker exec -w /app/www/public "$CONTAINER" php bin/grav clearcache >/dev/null 2>&1 || true; }

BACKUP=""
created=0
cleanup() {
    [ "$created" = 1 ] && rm -f "$OVERRIDE"
    [ -n "$BACKUP" ] && mv -f "$BACKUP" "$OVERRIDE"
    rm -f "$ACCOUNT"
    docker exec -w /app/www/public "$CONTAINER" rm -f /config/www/user/data/flex/indexes/accounts.yaml >/dev/null 2>&1 || true
    clearcache
    echo "  (cleaned up: override removed, $USERNAME deleted, cache cleared)"
}
trap cleanup EXIT

# Enable locally — back up any pre-existing override so we never clobber it.
[ -e "$OVERRIDE" ] && { BACKUP="$OVERRIDE.bak.$$"; mv "$OVERRIDE" "$BACKUP"; }
mkdir -p "$(dirname "$OVERRIDE")"
printf 'enabled: true\nmax_count: %s\ninterval: 60\n' "$MAX_COUNT" > "$OVERRIDE"
created=1
clearcache

echo "→ local throttle test: enabled (max_count=$MAX_COUNT), $ATTEMPTS attempts on http://localhost:$PORT"
echo ""
OUT="$(mktemp)"
"$SCRIPT_DIR/registration-throttle-burst.sh" "http://localhost:$PORT" "$ATTEMPTS" | tee "$OUT" || true
echo ""
if grep -q 'throttle engaged at attempt' "$OUT"; then
    rm -f "$OUT"
    echo "✓ PASS — the throttle engaged."
    exit 0
else
    rm -f "$OUT"
    echo "✗ FAIL — no throttling observed (is the plugin loading? try: docker exec $CONTAINER php -l /config/www/user/plugins/registration-throttle/registration-throttle.php)" >&2
    exit 1
fi
