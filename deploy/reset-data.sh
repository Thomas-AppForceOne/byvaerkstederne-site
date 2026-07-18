#!/usr/bin/env bash
# reset-data.sh — delete all flex-objects data YAML on a tier
#
# WHY
# ---
# The local `make reset-data` wipes config/www/user/data/flex-objects/ for a
# clean slate. Tiers need the same reset while testing events / RSVPs /
# roadmap flows: this deletes every *.yaml in the tier's flex-objects data
# dir (the versioned data tree push-data.sh writes into) and clears Grav's
# cache. Directories and non-YAML files are left alone.
#
# DESTRUCTIVE — this includes user-generated content (bug-reports.yaml,
# feature-suggestions.yaml, event RSVPs, votes). Always prints the file list
# before touching anything. On prod this destroys REAL member activity —
# gated behind --i-mean-it (and `make reset-data tier=prod` is refused at
# the Make layer entirely).
#
# USAGE
# -----
#   ./deploy/reset-data.sh <tier> [options]
#
# Tiers: dev | test | staging | prod
#
# Options:
#   --yes, -y       Skip the confirmation prompt.
#   --dry-run, -n   List what would be deleted; delete nothing.
#   --i-mean-it     Required for tier=prod.
#   --help, -h      Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# ── 1. Parse args ────────────────────────────────────────────────────
TIER=""
YES=0
DRY_RUN=0
I_MEAN_IT=0

for arg in "$@"; do
    case "$arg" in
        dev|test|staging|prod) TIER="$arg" ;;
        --yes|-y) YES=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --i-mean-it) I_MEAN_IT=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌  Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

case "$TIER" in
    dev|test|staging|prod) ;;
    *) echo "❌  Usage: $0 <dev|test|staging|prod> [--yes] [--dry-run] [--i-mean-it]" >&2; exit 1 ;;
esac

if [ "$TIER" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
    echo "❌  Refusing to reset data on prod without --i-mean-it (destroys REAL member activity)." >&2
    exit 1
fi

# ── 2. Load credentials + resolve SSH for the tier ───────────────────
ENV_FILE="$PROJECT_DIR/.env.deploy"
[ -f "$ENV_FILE" ] || { echo "❌  Missing $ENV_FILE — copy .env.deploy.example and fill in credentials" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
# shellcheck source=deploy/lib/ssh-auth.sh
. "$SCRIPT_DIR/lib/ssh-auth.sh"

export TIER
if [ "$TIER" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod reset-data requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod reset-data requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod reset-data requires DEPLOY_PROD_PATH in .env.deploy}"
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

# Same versioned data tree push-data.sh writes into; cache clear runs from
# the tier's release root, matching push-data.sh.
DATA_DIR="$PATH_SSH/${TIER}data/v0/user/data/flex-objects"
TIER_DIR="$(bv_tier_root "$PATH_SSH" "$TIER")"

echo "→ reset-data: $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$DATA_DIR/"

# ── 3. List the data files on the remote ─────────────────────────────
out="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
    d=\"$DATA_DIR\"
    [ -d \"\$d\" ] || { echo __NODIR__; exit 0; }
    n=0
    for f in \"\$d\"/*.yaml; do
        [ -e \"\$f\" ] || continue
        n=\$((n+1))
        sz=\$(wc -c < \"\$f\" | tr -d ' ')
        printf '%s\t%s\n' \"\$(basename \"\$f\")\" \"\$sz\"
    done
    if [ \"\$n\" = 0 ]; then echo __EMPTY__; fi
    exit 0
" 2>/dev/null || echo __SSHFAIL__)"

if printf '%s' "$out" | grep -q '__SSHFAIL__'; then
    echo "✗ SSH to $USER_SSH@$HOST_SSH:$PORT_SSH failed." >&2
    bv_ssh_diagnose "$USER_SSH" "$HOST_SSH" "$PORT_SSH"
    exit 1
fi
if printf '%s' "$out" | grep -q '__NODIR__'; then
    echo "No flex-objects data dir on $TIER ($DATA_DIR) — tier not deployed yet, or fresh."
    exit 0
fi
if printf '%s' "$out" | grep -q '__EMPTY__'; then
    echo "No flex-objects data on $TIER — nothing to reset."
    exit 0
fi

# Filenames become remote path components in the delete step — refuse the
# whole run if the listing contains anything outside the safe charset.
FILES=()
while IFS="$(printf '\t')" read -r f sz; do
    [ -n "$f" ] || continue
    case "$f" in
        *[!A-Za-z0-9._-]*|*..*|.*)
            echo "❌  Refusing: unsafe filename in remote data dir: '$f'. Inspect the tier by hand." >&2
            exit 1
            ;;
    esac
    FILES+=("$f")
done <<EOF
$out
EOF

count=${#FILES[@]}
verb="Will delete"; [ "$DRY_RUN" = "1" ] && verb="Would delete"
echo ""
echo "$verb $count data file(s) on $TIER (includes user-generated content):"
{ printf 'FILE\tBYTES\n'; printf '%s\n' "$out"; } | column -t -s "$(printf '\t')" | sed 's/^/  /'

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "  dry-run: nothing deleted. Re-run without --dry-run to delete."
    exit 0
fi

# ── 4. Confirm ───────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
    printf "Delete these %s data file(s) from %s? This cannot be undone (run 'make backup tier=%s' first). [y/N] " "$count" "$TIER" "$TIER"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── 5. Delete + clear cache ──────────────────────────────────────────
# Filenames were charset-validated above, so quoting each path is safe.
RM_PATHS=""
for f in "${FILES[@]}"; do
    RM_PATHS="$RM_PATHS '$DATA_DIR/$f'"
done
if ! bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "rm -f $RM_PATHS && cd '$TIER_DIR' && php bin/grav clearcache"; then
    echo "✗ reset failed (data may be partly removed — re-run, or check the tier)." >&2
    exit 1
fi

echo ""
echo "✓ Deleted $count flex-objects data file(s) from $TIER and cleared cache."
