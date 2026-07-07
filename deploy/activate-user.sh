#!/usr/bin/env bash
# activate-user.sh — enable (or disable) a member account on a tier
#
# WHY
# ---
# Registration creates accounts DISABLED (state: disabled + an activation
# token) and relies on the activation email to flip them. On a tier whose
# mailer is down or unconfigured the member registers and can never log in
# — the fix is what the activation link would have done: set
# `state: enabled` in the account YAML. The login plugin ships a CLI for
# exactly that (`bin/plugin login toggle-user`); this wraps it in the same
# SSH machinery and guardrails as manage-groups.sh / delete-user.sh so it
# stops being a hand edit over SSH.
#
# USAGE
# -----
#   ./deploy/activate-user.sh <tier> <username|email> [options]
#
# Tiers: dev | test | staging | prod
#
# The user may be given by username or by email; an email is resolved
# against the tier's accounts and must match exactly one.
#
# Options:
#   --state <enabled|disabled>  Target state (default: enabled). Disabling
#                               is the reverse operation — locking an
#                               account out without deleting it.
#   --yes, -y                   Skip the confirmation prompt.
#   --dry-run, -n               Resolve and validate everything; change nothing.
#   --i-mean-it                 Required for tier=prod and for the protected
#                               Playwright seed accounts (pw-test-*).
#   --help, -h                  Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Accounts the Playwright suites depend on — a stray disable would break
# the auth suites; same posture as delete-user.sh / manage-groups.sh.
PROTECTED_USER_PREFIX="pw-test-"

# ── 1. Parse args ────────────────────────────────────────────────────
POSITIONAL=()
YES=0
DRY_RUN=0
I_MEAN_IT=0
STATE="enabled"
EXPECT_STATE_VALUE=0

for arg in "$@"; do
    if [ "$EXPECT_STATE_VALUE" = "1" ]; then
        STATE="$arg"
        EXPECT_STATE_VALUE=0
        continue
    fi
    case "$arg" in
        --yes|-y) YES=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --i-mean-it) I_MEAN_IT=1 ;;
        --state) EXPECT_STATE_VALUE=1 ;;
        --state=*) STATE="${arg#--state=}" ;;
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
    *) echo "❌  activate-user: invalid or missing tier (got: '$TIER') — allowed: dev|test|staging|prod" >&2; err=1 ;;
esac
if [ -z "$USERID" ]; then
    echo "❌  activate-user: missing user (a username, or an email to resolve)" >&2; err=1
fi
if [ "$err" = "1" ]; then
    echo "    Usage:   $0 <dev|test|staging|prod> <username|email> [--state enabled|disabled] [--yes] [--dry-run] [--i-mean-it]" >&2
    echo "    Example: $0 dev anders@example.dk" >&2
    exit 1
fi

case "$STATE" in
    enabled|disabled) ;;
    *) echo "❌  Invalid state '$STATE' (allowed: enabled | disabled)." >&2; exit 1 ;;
esac

# The user id becomes a remote path component (username) or a grep
# pattern (email) — restrict both to a safe charset.
case "$USERID" in
    *[!A-Za-z0-9._@+-]*|*..*|.*)
        echo "❌  Refusing unsafe user id '$USERID' (allowed: A-Z a-z 0-9 . _ @ + -, no '..', no leading '.')." >&2
        exit 1
        ;;
esac

if [ "$TIER" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
    echo "❌  Refusing to change account state on prod without --i-mean-it (this changes a REAL member's access)." >&2
    exit 1
fi

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
# shellcheck source=deploy/lib/user-resolve.sh
. "$SCRIPT_DIR/lib/user-resolve.sh"

export TIER
if [ "$TIER" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod activate-user requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod activate-user requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod activate-user requires DEPLOY_PROD_PATH in .env.deploy}"
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

TIER_DIR="$PATH_SSH/$TIER"
ACCOUNTS_DIR="$TIER_DIR/user/accounts"
FLEX_INDEX="$TIER_DIR/user/data/flex/indexes/accounts.yaml"

# ── 3. Resolve the user (email → username, shared lib) ───────────────
if ! USERNAME="$(bv_resolve_username "$USERID")"; then
    exit 1
fi

case "$USERNAME" in
    "$PROTECTED_USER_PREFIX"*)
        if [ "$I_MEAN_IT" != "1" ]; then
            echo "❌  '$USERNAME' is a protected Playwright seed account." >&2
            echo "    Changing its state breaks the auth suites. Re-run with --i-mean-it if you mean it." >&2
            exit 1
        fi
        ;;
esac

ACCT="$ACCOUNTS_DIR/$USERNAME.yaml"

echo "→ set state=$STATE for '$USERNAME' @ $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$ACCT"

# ── 4. Preflight: account exists; read its current state ─────────────
current="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
    if [ ! -f \"$ACCT\" ]; then echo __NOACCT__; exit 0; fi
    st=\$(sed -n 's/^state:[[:space:]]*//p' \"$ACCT\" | head -1)
    echo \"state:\${st:-unset}\"
" 2>/dev/null || echo __SSHFAIL__)"
case "$current" in
    *__SSHFAIL__*)
        echo "✗ SSH preflight failed (auth / host / network)." >&2
        bv_ssh_diagnose "$USER_SSH" "$HOST_SSH" "$PORT_SSH"
        exit 1
        ;;
    *__NOACCT__*)
        echo "✗ No account '$USERNAME' on $TIER ($ACCT not found)." >&2
        echo "  Check the username (try: make list-users tier=$TIER)." >&2
        exit 1
        ;;
esac
CURRENT_STATE="$(printf '%s' "$current" | sed -n 's/^state://p' | head -1)"
echo "  current state: $CURRENT_STATE"

if [ "$CURRENT_STATE" = "$STATE" ]; then
    echo "✓ '$USERNAME' is already $STATE on $TIER — nothing to do."
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "  dry-run: would set state=$STATE via 'bin/plugin login toggle-user' and clear the tier cache; nothing changed."
    exit 0
fi

# ── 5. Confirm ───────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
    printf "Set account '%s' on %s to state '%s'? [y/N] " "$USERNAME" "$TIER" "$STATE"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── 6. Flip the state via the login plugin's own CLI, then clear cache ─
# toggle-user is the supported write path (same code the activation link
# ultimately drives); with both -u and -s given it runs non-interactively.
result="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
    "cd \"$TIER_DIR\" && php bin/plugin login toggle-user -u \"$USERNAME\" -s \"$STATE\"" \
    < /dev/null 2>&1 || echo __CLIFAIL__)"
case "$result" in
    *__CLIFAIL__*|*rror*)
        echo "✗ Remote toggle-user failed:" >&2
        printf '%s\n' "$result" | sed 's/^/    /' >&2
        exit 1
        ;;
esac

if ! bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "rm -f \"$FLEX_INDEX\" && cd \"$TIER_DIR\" && php bin/grav clearcache" >/dev/null < /dev/null; then
    echo "⚠️  State changed, but the cache clear failed — run it manually on the tier:" >&2
    echo "      cd $TIER_DIR && php bin/grav clearcache" >&2
    exit 1
fi

if [ "$STATE" = "enabled" ]; then
    echo "✓ Activated '$USERNAME' on $TIER — they can log in now."
else
    echo "✓ Disabled '$USERNAME' on $TIER — they can no longer log in."
fi
