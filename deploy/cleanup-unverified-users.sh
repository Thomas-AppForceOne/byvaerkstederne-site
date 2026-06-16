#!/usr/bin/env bash
# cleanup-unverified-users.sh — remove accounts that registered but never
#                               confirmed their email within a time window.
#
# WHY
# ---
# With email verification on (set_user_disabled + send_activation_email), a
# registration creates a DISABLED account with a pending activation_token. If
# the user never clicks the link, the stock plugin leaves that account on disk
# forever — it can't log in, and it squats on the username + email so nobody
# can re-register them. The activation token's 7-day lifetime is hardcoded in
# the plugin (Login.php) and cannot be shortened by config without patching the
# plugin (forbidden by spec). So instead we enforce a SHORTER window out of
# band: this deletes the account YAML once it has been unconfirmed for longer
# than --max-age. Deleting it IS the timeout — the link then errors, and the
# username/email are freed.
#
# WHAT IT TOUCHES — only accounts that are BOTH:
#   * state: disabled, AND
#   * still carry a pending activation_token
# i.e. unconfirmed registrations. Enabled members, admins, and accounts an
# admin disabled by hand (no token) are never matched. "Registered at" is
# derived from the token's embedded expiry (expire - 604800), so it reflects
# real registration time regardless of file mtime.
#
# DRY-RUN BY DEFAULT. Pass --apply to actually delete. prod additionally
# requires --i-mean-it. Intended to run on a schedule (cron / CI) per tier.
#
# USAGE
#   ./deploy/cleanup-unverified-users.sh <tier> [--max-age=MIN] [--apply] [--i-mean-it]
#
# Tiers: dev | test | staging | prod
# Options:
#   --max-age=MIN   Delete unconfirmed accounts older than MIN minutes (default 10).
#   --apply         Actually delete (default: dry-run — only report).
#   --i-mean-it     Required for tier=prod.
#   --help, -h
#
# NOTE: 10 minutes is aggressive for real email + a human clicking a link. Use a
#       generous window on prod (e.g. --max-age=1440 for 24h); short windows fit
#       dev/test and fast anti-squat sweeps.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

# The plugin's hardcoded token lifetime (Login.php: time() + 604800). We use it
# to recover registration time from the token's stored expiry.
TOKEN_LIFETIME=604800

# ── 1. Parse args ────────────────────────────────────────────────────
TIER=""
MAX_AGE_MIN=10
APPLY=0
I_MEAN_IT=0

for arg in "$@"; do
    case "$arg" in
        dev|test|staging|prod) TIER="$arg" ;;
        --max-age=*) MAX_AGE_MIN="${arg#--max-age=}" ;;
        --apply) APPLY=1 ;;
        --i-mean-it) I_MEAN_IT=1 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌  Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

case "$TIER" in
    dev|test|staging|prod) ;;
    *) echo "❌  Usage: $0 <dev|test|staging|prod> [--max-age=MIN] [--apply] [--i-mean-it]" >&2; exit 1 ;;
esac
case "$MAX_AGE_MIN" in
    ''|*[!0-9]*) echo "❌  --max-age must be a whole number of minutes (got '$MAX_AGE_MIN')." >&2; exit 1 ;;
esac
if [ "$TIER" = "prod" ] && [ "$APPLY" = "1" ] && [ "$I_MEAN_IT" != "1" ]; then
    echo "❌  Refusing to --apply on prod without --i-mean-it (this deletes real member registrations)." >&2
    exit 1
fi
MAX_AGE_SEC=$((MAX_AGE_MIN * 60))

# ── 2. Load credentials + resolve SSH ────────────────────────────────
ENV_FILE="$PROJECT_DIR/.env.deploy"
[ -f "$ENV_FILE" ] || { echo "❌  Missing $ENV_FILE" >&2; exit 1; }
# shellcheck disable=SC1090
. "$ENV_FILE"
# shellcheck source=deploy/lib/ssh-auth.sh
. "$SCRIPT_DIR/lib/ssh-auth.sh"

export TIER
if [ "$TIER" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod cleanup requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod cleanup requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod cleanup requires DEPLOY_PROD_PATH in .env.deploy}"
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

TIER_DIR="$PATH_SSH/$TIER"
ACCOUNTS_DIR="$TIER_DIR/user/accounts"
FLEX_INDEX="$TIER_DIR/user/data/flex/indexes/accounts.yaml"

mode="DRY-RUN (no deletes — pass --apply to remove)"
[ "$APPLY" = "1" ] && mode="APPLY (will delete)"
echo "→ cleanup-unverified-users: $TIER"
echo "  window: unconfirmed > ${MAX_AGE_MIN} min    mode: $mode"

# ── 3. Find (and optionally delete) stale unconfirmed accounts ───────
# Remote, POSIX sh: for each account that is state:disabled AND has a pending
# activation_token, derive registration time from the token's expiry and act if
# it is older than the window. Emits one line per matched account:
#   <username>\t<age_minutes>
out="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
    d=\"$ACCOUNTS_DIR\"; apply=$APPLY; maxsec=$MAX_AGE_SEC; life=$TOKEN_LIFETIME
    [ -d \"\$d\" ] || { echo __NODIR__; exit 0; }
    now=\$(date +%s); deleted=0
    for f in \"\$d\"/*.yaml; do
        [ -e \"\$f\" ] || continue
        st=\$(sed -n 's/^state:[[:space:]]*//p' \"\$f\" | head -1)
        [ \"\$st\" = disabled ] || continue
        tok=\$(sed -n 's/^activation_token:[[:space:]]*//p' \"\$f\" | head -1 | tr -d \"'\\\"\")
        [ -n \"\$tok\" ] || continue
        exp=\${tok##*::}
        case \"\$exp\" in ''|*[!0-9]*) continue ;; esac
        reg=\$((exp - life)); age=\$((now - reg))
        [ \"\$age\" -ge \"\$maxsec\" ] || continue
        b=\$(basename \"\$f\"); u=\${b%.yaml}
        printf '%s\t%s\n' \"\$u\" \"\$((age / 60))\"
        if [ \"\$apply\" = 1 ]; then rm -f \"\$f\"; deleted=1; fi
    done
    if [ \"\$apply\" = 1 ] && [ \"\$deleted\" = 1 ]; then
        rm -f \"$FLEX_INDEX\"; cd \"$TIER_DIR\" && php bin/grav clearcache >/dev/null 2>&1 || true
    fi
    exit 0
" 2>/dev/null || echo __SSHFAIL__)"

# ── 4. Report ────────────────────────────────────────────────────────
if printf '%s' "$out" | grep -q '__SSHFAIL__'; then
    echo "✗ SSH failed (auth / host / network)." >&2; exit 1
fi
if printf '%s' "$out" | grep -q '__NODIR__'; then
    echo "No accounts dir on $TIER — nothing to clean."; exit 0
fi

rows="$(printf '%s\n' "$out" | grep -cve '^[[:space:]]*$' || true)"
if [ "${rows:-0}" -eq 0 ]; then
    echo "✓ No unconfirmed accounts older than ${MAX_AGE_MIN} min on $TIER."
    exit 0
fi

verb="would remove"; [ "$APPLY" = "1" ] && verb="removed"
echo "$verb $rows unconfirmed account(s) (>${MAX_AGE_MIN} min):"
{ printf 'USERNAME\tAGE(min)\n'; printf '%s\n' "$out"; } | column -t -s "$(printf '\t')"
[ "$APPLY" != "1" ] && echo "(dry-run — re-run with --apply to delete)"
