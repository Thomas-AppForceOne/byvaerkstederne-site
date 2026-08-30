#!/usr/bin/env bash
#
# resend-activation.sh — re-send a registration activation email on a tier.
#
#   ./deploy/resend-activation.sh <dev|test|staging|prod> <username|email> [--dry-run] [--yes]
#
# Thin SSH wrapper around the plugin command that does the work:
#   bin/plugin account-manager resend-activation <user> --env <host>
#
# WHY THIS EXISTS
# ---------------
# Grav's login plugin sends the activation mail once, during registration, and
# never again. Before this, a member whose mail was filtered or lost left an
# operator with two bad options: activate the account by hand — skipping the
# address verification the mail exists to provide — or delete it so they could
# register a second time. Found on production 2026-08-29.
#
# --env IS NOT OPTIONAL
# ---------------------
# Grav resolves per-tier config by hostname and a CLI run resolves to the
# `cli` environment, so without --env the tier's own SMTP block and
# `plugins.login.site_host` are never loaded. The same trap manage-super.sh
# documents for its alert mail. This script always passes it, derived from the
# tier — an operator cannot forget it.
#
# THE OLD LINK DIES
# -----------------
# The plugin command mints a fresh token and SAVES the account before handing
# off to the mailer, so any previous activation link stops working the moment
# a real run starts — including when the send then fails. --dry-run mutates
# nothing, which is why it is the right first move.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Canonical host per tier — the value Grav's --env expects, and the directory
# name under user/env/. Same mapping as manage-super.sh.
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
POSITIONAL=()
DRY_RUN=0
YES=0

for arg in "$@"; do
    case "$arg" in
        --dry-run|-n) DRY_RUN=1 ;;
        --yes|-y) YES=1 ;;
        --help|-h) usage; exit 0 ;;
        --*) echo "❌  Unknown option: $arg" >&2; usage >&2; exit 1 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

TIER="${POSITIONAL[0]:-}"
USERID="${POSITIONAL[1]:-}"

err=0
case "$TIER" in
    dev|test|staging|prod) ;;
    *) echo "❌  resend-activation: invalid or missing tier (got: '$TIER') — allowed: dev|test|staging|prod" >&2; err=1 ;;
esac
if [ -z "$USERID" ]; then
    echo "❌  resend-activation: missing user (a username, or an email to resolve)" >&2; err=1
fi
if [ "$err" = "1" ]; then
    echo "    Usage:   $0 <dev|test|staging|prod> <username|email> [--dry-run] [--yes]" >&2
    echo "    Example: $0 prod anders@example.dk --dry-run" >&2
    exit 1
fi

# The user id becomes a remote argument — restrict it to a safe charset, the
# same rule delete-user.sh and activate-user.sh apply.
case "$USERID" in
    *[!A-Za-z0-9._@+-]*|*..*|.*)
        echo "❌  Refusing unsafe user id '$USERID' (allowed: A-Z a-z 0-9 . _ @ + -, no '..', no leading '.')." >&2
        exit 1
        ;;
esac

# ── 2. Credentials + SSH for the tier ────────────────────────────────
ENV_FILE="$PROJECT_DIR/.env.deploy"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌  Missing $ENV_FILE — copy .env.deploy.example and fill in credentials" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
# shellcheck source=deploy/lib/ssh-auth.sh
. "$SCRIPT_DIR/lib/ssh-auth.sh"
# shellcheck source=deploy/lib/php-parity.sh
# Provides bv_php_remote_bin — prod's shell PHP is the system default (8.4),
# not the version its domain is served with (8.5).
. "$SCRIPT_DIR/lib/php-parity.sh"
# shellcheck source=deploy/lib/user-resolve.sh
. "$SCRIPT_DIR/lib/user-resolve.sh"

export TIER
if [ "$TIER" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod resend-activation requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod resend-activation requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod resend-activation requires DEPLOY_PROD_PATH in .env.deploy}"
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

PHP_BIN="$(bv_php_remote_bin "$TIER" "$PROJECT_DIR")"
TIER_DIR="$(bv_tier_root "$PATH_SSH" "$TIER")"
# bv_resolve_username greps this over SSH to turn an email into a username.
# Its contract (lib/user-resolve.sh) requires TIER, ACCOUNTS_DIR, PORT_SSH,
# USER_SSH and HOST_SSH — omitting ACCOUNTS_DIR made every email lookup die
# on `unbound variable` and then report "no account has that email", which
# reads like the member does not exist.
ACCOUNTS_DIR="$TIER_DIR/user/accounts"
ENV_HOST="$(tier_host "$TIER")"

# ── 3. Resolve the user (email → username, shared lib) ───────────────
if ! USERNAME="$(bv_resolve_username "$USERID")"; then
    exit 1
fi

echo "→ resend-activation: $TIER"
echo "  target: ${USER_SSH}@${HOST_SSH}:${TIER_DIR}"
echo "  user:   $USERNAME"
echo "  env:    $ENV_HOST"

# ── 4. Confirm — a real run spends the member's current link ─────────
if [ "$DRY_RUN" != "1" ] && [ "$YES" != "1" ]; then
    echo ""
    echo "  This mints a NEW activation token: any link the member already has"
    echo "  stops working, even if the send then fails."
    # No usable TTY (CI, a pipeline, make with redirected stdin) — refuse
    # rather than read an empty line and call it a decision. yes=1 is the
    # deliberate non-interactive path.
    #
    # Tested by ATTEMPTING the redirect, not with `[ -r /dev/tty ]`: on macOS
    # the device node is readable by that test yet still fails to open with
    # "Device not configured", which leaks a shell error into the output.
    if ! (exec < /dev/tty) 2>/dev/null; then
        echo "❌  No terminal to confirm on — re-run with yes=1 to proceed non-interactively." >&2
        exit 1
    fi
    printf "  Re-send the activation email to '%s' on %s? [y/N] " "$USERNAME" "$TIER"
    read -r reply < /dev/tty || reply=""
    case "$reply" in
        y|Y|yes|YES) ;;
        *) echo "  aborted — nothing changed."; exit 1 ;;
    esac
fi

# ── 5. Run it on the tier ────────────────────────────────────────────
REMOTE_ARGS="account-manager resend-activation $(printf %q "$USERNAME") --env $(printf %q "$ENV_HOST")"
if [ "$DRY_RUN" = "1" ]; then
    REMOTE_ARGS="$REMOTE_ARGS --dry-run"
fi

if out="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "cd \"$TIER_DIR\" && $PHP_BIN bin/plugin $REMOTE_ARGS" 2>&1 < /dev/null)"; then
    printf '%s\n' "$out" | sed 's/^/  /'
    exit 0
fi

printf '%s\n' "$out" | sed 's/^/  /' >&2
echo "" >&2
echo "❌  resend-activation failed on $TIER." >&2
exit 1
