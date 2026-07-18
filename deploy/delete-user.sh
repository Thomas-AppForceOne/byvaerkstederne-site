#!/usr/bin/env bash
# delete-user.sh — delete a member account from a tier (test-cleanup helper)
#
# WHY
# ---
# The login plugin ships no delete-user CLI (only new-user / toggle-user /
# change-password / lookup-user). Accounts are flat YAML at
# user/accounts/<username>.yaml with a flex index that rebuilds on
# cache-clear. While testing registration you create throwaway accounts and
# must remove them to re-test — the duplicate-username/email guards block
# re-registration otherwise. This removes the account YAML and the flex
# index, then clears Grav's cache, on the named tier (through the same SSH
# machinery as push-data.sh / push-email.sh).
#
# DESTRUCTIVE. On prod this deletes a REAL member — gated behind --i-mean-it.
# The Playwright seed accounts (pw-test-user / pw-test-admin) are likewise
# protected behind --i-mean-it so a stray cleanup can't break the auth suite.
#
# USAGE
# -----
#   ./deploy/delete-user.sh <tier> <username> [options]
#
# Tiers: dev | test | staging | prod
#
# Options:
#   --yes, -y       Skip the confirmation prompt.
#   --dry-run, -n   Show what would be deleted; delete nothing.
#   --i-mean-it     Required for tier=prod and for protected seed accounts.
#   --help, -h      Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Accounts the Playwright auth suite depends on — protected from casual delete.
PROTECTED_USERS="pw-test-user pw-test-admin pw-test-org"

# ── 1. Parse args ────────────────────────────────────────────────────
POSITIONAL=()
YES=0
DRY_RUN=0
I_MEAN_IT=0

for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --i-mean-it) I_MEAN_IT=1 ;;
        --help|-h) usage; exit 0 ;;
        --*) echo "❌  Unknown option: $arg" >&2; usage >&2; exit 1 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

TIER="${POSITIONAL[0]:-}"
USERNAME="${POSITIONAL[1]:-}"

case "$TIER" in
    dev|test|staging|prod) ;;
    *)
        echo "❌  Usage: $0 <dev|test|staging|prod> <username> [--yes] [--dry-run] [--i-mean-it]" >&2
        exit 1
        ;;
esac

# Strict username validation — the value becomes a remote path component, so
# reject anything that could traverse or inject. Accounts are created under the
# login username_regex ([a-z0-9_-]{3,16}); allow a slightly broader safe set.
if [ -z "$USERNAME" ]; then
    echo "❌  No username given. Usage: $0 $TIER <username>" >&2
    exit 1
fi
case "$USERNAME" in
    *[!A-Za-z0-9._-]*|*..*|.*)
        echo "❌  Refusing unsafe username '$USERNAME' (allowed: A-Z a-z 0-9 . _ -, no '..', no leading '.')." >&2
        exit 1
        ;;
esac

if [ "$TIER" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
    echo "❌  Refusing to delete a prod account without --i-mean-it (prod deletes a real member)." >&2
    exit 1
fi

for p in $PROTECTED_USERS; do
    if [ "$USERNAME" = "$p" ] && [ "$I_MEAN_IT" != "1" ]; then
        echo "❌  '$USERNAME' is a protected Playwright seed account." >&2
        echo "    Deleting it breaks the auth suite. Re-run with --i-mean-it if you mean it." >&2
        exit 1
    fi
done

# ── 2. Load credentials + resolve SSH for the tier ───────────────────
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
    : "${DEPLOY_PROD_HOST:?prod delete-user requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod delete-user requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod delete-user requires DEPLOY_PROD_PATH in .env.deploy}"
    HOST_SSH="$DEPLOY_PROD_HOST"
    USER_SSH="$DEPLOY_PROD_USER"
    PORT_SSH="${DEPLOY_PROD_PORT:-${DEPLOY_PORT:-22}}"
    PATH_SSH="$DEPLOY_PROD_PATH"
else
    : "${DEPLOY_HOST:?missing DEPLOY_HOST in .env.deploy}"
    : "${DEPLOY_USER:?missing DEPLOY_USER in .env.deploy}"
    : "${DEPLOY_PATH:?missing DEPLOY_PATH in .env.deploy}"
    : "${DEPLOY_PORT:?missing DEPLOY_PORT in .env.deploy}"
    HOST_SSH="$DEPLOY_HOST"
    USER_SSH="$DEPLOY_USER"
    PORT_SSH="$DEPLOY_PORT"
    PATH_SSH="$DEPLOY_PATH"
fi
export DEPLOY_PASS
DEPLOY_PASS="$(bv_resolve_ssh_password)"

TIER_DIR="$PATH_SSH/$TIER"
ACCT="$TIER_DIR/user/accounts/$USERNAME.yaml"
FLEX_INDEX="$TIER_DIR/user/data/flex/indexes/accounts.yaml"

echo "→ delete-user: $USERNAME @ $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$ACCT"

# ── 3. Preflight: the account must exist ─────────────────────────────
exists="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
    "test -f \"$ACCT\" && echo yes || echo no" 2>/dev/null || echo "sshfail")"
case "$exists" in
    yes) ;;
    no)
        echo "✗ No account '$USERNAME' on $TIER ($ACCT not found)." >&2
        echo "  Check the username (try: php bin/plugin login lookup-user on the tier)." >&2
        exit 1
        ;;
    *)
        echo "✗ SSH preflight failed (auth / host / network)." >&2
        exit 1
        ;;
esac

if [ "$DRY_RUN" = "1" ]; then
    echo "  dry-run: would remove the account YAML + flex index and clear cache; nothing deleted."
    exit 0
fi

# ── 4. Confirm ───────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
    printf "Delete account '%s' from %s? This cannot be undone. [y/N] " "$USERNAME" "$TIER"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── 5. Delete the account YAML + flex index, then clear cache ────────
# Removing the flex index is safe — Grav rebuilds it from user/accounts/ on
# the next cache clear; this drops the deleted user from listings and frees
# the username/email for re-registration.
if ! bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "rm -f \"$ACCT\" \"$FLEX_INDEX\" && cd \"$TIER_DIR\" && php bin/grav clearcache"; then
    echo "✗ delete failed (the account file may be partly removed — re-run, or check the tier)." >&2
    exit 1
fi

echo "✓ Deleted '$USERNAME' from $TIER and cleared cache."
echo "  The username and email are now free to register again."
