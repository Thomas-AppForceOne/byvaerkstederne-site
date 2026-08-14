#!/usr/bin/env bash
# scheduler-token.sh — provision or rotate a tier's scheduler-trigger token.
#
# WHY
# ---
# The hosting plan has no cron and no crontab in its SSH shell, so the site's
# scheduled work (account purge, privilege-escalation watch, Grav's own cache
# jobs) only runs when something calls the token-gated trigger URL. An
# external cron service does the calling; this provisions the secret it needs.
#
# THE TOKEN NEVER TRAVELS. It is generated ON THE TIER with the tier's own
# openssl and written straight into that tier's live-state dir. Nothing is
# printed but a fingerprint — so provisioning it does not put the secret into
# a terminal scrollback, a shell history, a CI log or an assistant's
# transcript.
#
# To read the full URL (once, when you set up the cron service), the operator
# runs it themselves with --show. That is deliberately a separate, explicit
# action.
#
# USAGE
# -----
#   ./deploy/scheduler-token.sh <tier>            # generate/rotate, print fingerprint
#   ./deploy/scheduler-token.sh <tier> --show     # print the full trigger URL
#   ./deploy/scheduler-token.sh <tier> --status   # is one provisioned? (no secret)
#
# Tiers: dev | test | staging | prod
#
# Options:
#   --yes, -y     Skip the confirmation prompt on rotate.
#   --show        Print the full URL including the token. Never redirect this
#                 into a file that is not gitignored.
#   --status      Report whether a token exists, its length and age. No secret.
#   --help, -h    Show this help.
#
# ROTATION invalidates the old URL immediately: update the cron service in the
# same sitting, or the tier stops running its jobs — silently, which is the
# failure mode this whole endpoint exists to fix.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Canonical public URL per tier — must match deploy.sh's ENV_URL.
tier_url() {
    case "$1" in
        dev)     echo "https://dev.hackersbychoice.dk" ;;
        test)    echo "https://test.hackersbychoice.dk" ;;
        staging) echo "https://staging.hackersbychoice.dk" ;;
        prod)    echo "https://www.byvaerkstederne.dk" ;;
        *) return 1 ;;
    esac
}

YES=0
SHOW=0
STATUS=0
TIER=""

for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=1 ;;
        --show) SHOW=1 ;;
        --status) STATUS=1 ;;
        --help|-h) usage; exit 0 ;;
        -*) echo "❌  Unknown option '$arg'" >&2; usage >&2; exit 1 ;;
        *) if [ -z "$TIER" ]; then TIER="$arg"; else echo "❌  Unexpected argument '$arg'" >&2; exit 1; fi ;;
    esac
done

case "$TIER" in
    dev|test|staging|prod) ;;
    *) echo "❌  Missing or invalid tier (got: '$TIER') — allowed: dev|test|staging|prod" >&2; exit 1 ;;
esac

ENV_FILE="$PROJECT_DIR/.env.deploy"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌  Missing $ENV_FILE — copy .env.deploy.example and fill in credentials" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
# shellcheck source=deploy/lib/ssh-auth.sh
. "$SCRIPT_DIR/lib/ssh-auth.sh"

export TIER
if [ "$TIER" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod scheduler-token requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod scheduler-token requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod scheduler-token requires DEPLOY_PROD_PATH in .env.deploy}"
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
    exit 1
fi

TIER_DIR="$(bv_tier_root "$PATH_SSH" "$TIER")"
# Live state, not a release: the token survives every deploy and is never in
# the repo, exactly like the tier's email.yaml.
STATE_DIR="$TIER_DIR/user/data/scheduler-trigger"
TOKEN_FILE="$STATE_DIR/token"

if [ "$STATUS" = "1" ]; then
    out="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
        if [ -f \"$TOKEN_FILE\" ]; then
            printf 'provisioned length=%s modified=%s\n' \
                \"\$(tr -d '\n' < \"$TOKEN_FILE\" | wc -c | tr -d ' ')\" \
                \"\$(date -r \"$TOKEN_FILE\" '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)\"
        else
            echo 'absent'
        fi
    " 2>/dev/null || echo __SSHFAIL__)"
    case "$out" in
        *__SSHFAIL__*) echo "✗ SSH failed." >&2; bv_ssh_diagnose "$USER_SSH" "$HOST_SSH" "$PORT_SSH"; exit 1 ;;
        *absent*) echo "$TIER: NO scheduler token — the tier's scheduled jobs are not running." ;;
        *) echo "$TIER: $out" ;;
    esac
    exit 0
fi

if [ "$SHOW" = "1" ]; then
    token="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "cat \"$TOKEN_FILE\" 2>/dev/null || true" 2>/dev/null | tr -d '\r\n')"
    if [ -z "$token" ]; then
        echo "✗ No token provisioned on $TIER. Run: $0 $TIER" >&2
        exit 1
    fi
    echo "Paste this as the cron job's URL (keep it out of shared documents):"
    echo "  $(tier_url "$TIER")/scheduler-trigger?token=$token"
    exit 0
fi

echo "→ provision scheduler token for $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$TOKEN_FILE"

existing="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
    "[ -f \"$TOKEN_FILE\" ] && echo yes || echo no" 2>/dev/null || echo __SSHFAIL__)"
case "$existing" in
    *__SSHFAIL__*)
        echo "✗ SSH preflight failed." >&2
        bv_ssh_diagnose "$USER_SSH" "$HOST_SSH" "$PORT_SSH"
        exit 1
        ;;
    *yes*)
        echo "  a token already exists — continuing REPLACES it and breaks the current cron URL"
        if [ "$YES" != "1" ]; then
            printf "Rotate the scheduler token on %s? [y/N] " "$TIER"
            read -r ans
            case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
        fi
        ;;
esac

# Generated remotely; the value never crosses the wire. The fingerprint is a
# prefix of its sha256 — enough to tell two tokens apart, useless as a secret.
fingerprint="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
    set -e
    mkdir -p \"$STATE_DIR\"
    umask 077
    openssl rand -hex 32 > \"$TOKEN_FILE\"
    chmod 600 \"$TOKEN_FILE\"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum \"$TOKEN_FILE\" | cut -c1-12
    else
        openssl dgst -sha256 \"$TOKEN_FILE\" | awk '{print substr(\$NF,1,12)}'
    fi
" 2>&1 || echo __SSHFAIL__)"

case "$fingerprint" in
    *__SSHFAIL__*|*"not found"*|*rror*)
        echo "✗ Could not write the token:" >&2
        printf '%s\n' "$fingerprint" | sed 's/^/    /' >&2
        exit 1
        ;;
esac

echo "✓ token written (sha256 starts with ${fingerprint})"
echo
echo "  Next: get the full URL — run this yourself, it prints the secret:"
echo "      ./deploy/scheduler-token.sh $TIER --show"
echo "  then create a job at https://cron-job.org calling that URL every 15 minutes."
