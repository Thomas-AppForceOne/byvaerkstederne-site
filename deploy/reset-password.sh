#!/usr/bin/env bash
# reset-password.sh — set a new password for a member account on a tier
#
# WHY
# ---
# Members who lose access on a tier without working mail cannot use the
# self-service reset flow (it emails a link). The fix is a new
# `hashed_password` in the account YAML. The login plugin's own
# change-password CLI exists, but its -p option puts the password in the
# remote process list (its help text warns about exactly that — and the
# tiers are shared hosting). This script instead injects the password into
# a small PHP program LOCALLY (base64, deploy/lib/account-password.php)
# and pipes it over SSH stdin to the tier's PHP — the password never
# appears as a process argument or in shell history on either side. The
# hash is password_hash(PASSWORD_DEFAULT), the same call Grav uses, and
# any pending reset token is cleared so old reset links die.
#
# PASSWORD INPUT (never via command line):
#   * default        — prompted interactively, hidden, typed twice
#   * --generate     — a strong policy-compliant password is generated and
#                      printed ONCE on success (hand it to the member; they
#                      can change it themselves afterwards)
#   * BV_NEW_PASSWORD env var — non-interactive override for automation;
#                      subject to the same policy validation
#
# The site's password policy is enforced locally before anything is sent:
# at least 8 characters with an upper-case letter, a lower-case letter and
# a digit (mirrors system.pwd_regex and the registration form).
#
# USAGE
# -----
#   ./deploy/reset-password.sh <tier> <username|email> [options]
#
# Tiers: dev | test | staging | prod
#
# Options:
#   --generate, -g  Generate and print the new password instead of prompting.
#   --yes, -y       Skip the confirmation prompt.
#   --dry-run, -n   Resolve and validate everything; change nothing.
#   --i-mean-it     Required for tier=prod and for the protected Playwright
#                   seed accounts (pw-test-*), whose passwords must match
#                   ~/.gan-secrets/workshop-site.env.
#   --help, -h      Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PASSWORD_PHP="$SCRIPT_DIR/lib/account-password.php"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

PROTECTED_USER_PREFIX="pw-test-"

# ── 1. Parse args ────────────────────────────────────────────────────
POSITIONAL=()
YES=0
DRY_RUN=0
I_MEAN_IT=0
GENERATE=0

for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --i-mean-it) I_MEAN_IT=1 ;;
        --generate|-g) GENERATE=1 ;;
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
    *) echo "❌  reset-password: invalid or missing tier (got: '$TIER') — allowed: dev|test|staging|prod" >&2; err=1 ;;
esac
if [ -z "$USERID" ]; then
    echo "❌  reset-password: missing user (a username, or an email to resolve)" >&2; err=1
fi
if [ "$err" = "1" ]; then
    echo "    Usage:   $0 <dev|test|staging|prod> <username|email> [--generate] [--yes] [--dry-run] [--i-mean-it]" >&2
    echo "    Example: $0 dev anders@example.dk --generate" >&2
    exit 1
fi

case "$USERID" in
    *[!A-Za-z0-9._@+-]*|*..*|.*)
        echo "❌  Refusing unsafe user id '$USERID' (allowed: A-Z a-z 0-9 . _ @ + -, no '..', no leading '.')." >&2
        exit 1
        ;;
esac

if [ "$TIER" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
    echo "❌  Refusing to reset a password on prod without --i-mean-it (this changes a REAL member's credentials)." >&2
    exit 1
fi

if [ ! -f "$PASSWORD_PHP" ]; then
    echo "❌  Missing $PASSWORD_PHP (repo checkout incomplete?)." >&2
    exit 1
fi

# ── 2. Obtain the new password (policy-validated, never from argv) ───
# Policy mirror of system.pwd_regex / the registration form: ≥8 chars,
# ≥1 upper, ≥1 lower, ≥1 digit.
password_policy_ok() {
    local pw="$1"
    [ "${#pw}" -ge 8 ] || return 1
    case "$pw" in *[A-Z]*) ;; *) return 1 ;; esac
    case "$pw" in *[a-z]*) ;; *) return 1 ;; esac
    case "$pw" in *[0-9]*) ;; *) return 1 ;; esac
    return 0
}

NEW_PASSWORD=""
if [ "$GENERATE" = "1" ]; then
    # 'Bv9-' guarantees the upper/lower/digit classes; 16 hex chars of
    # entropy follow. 20 chars total.
    NEW_PASSWORD="Bv9-$(openssl rand -hex 8)"
elif [ -n "${BV_NEW_PASSWORD:-}" ]; then
    NEW_PASSWORD="$BV_NEW_PASSWORD"
    if ! password_policy_ok "$NEW_PASSWORD"; then
        echo "❌  BV_NEW_PASSWORD does not meet the password policy (≥8 chars, ≥1 upper, ≥1 lower, ≥1 digit)." >&2
        exit 1
    fi
elif [ "$DRY_RUN" = "1" ]; then
    : # dry-run changes nothing — don't bother the operator for a password
else
    if [ ! -t 0 ]; then
        echo "❌  No TTY to prompt for a password. Use --generate, or set BV_NEW_PASSWORD in the environment." >&2
        exit 1
    fi
    printf "New password for the account (hidden, ≥8 chars with upper/lower/digit): "
    read -rs pw1; echo
    printf "Repeat the password: "
    read -rs pw2; echo
    if [ "$pw1" != "$pw2" ]; then
        echo "❌  Passwords do not match." >&2
        exit 1
    fi
    if ! password_policy_ok "$pw1"; then
        echo "❌  Password does not meet the policy (≥8 chars, ≥1 upper, ≥1 lower, ≥1 digit)." >&2
        exit 1
    fi
    NEW_PASSWORD="$pw1"
    unset pw1 pw2
fi

# ── 3. Load credentials + resolve SSH for the tier ───────────────────
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
    : "${DEPLOY_PROD_HOST:?prod reset-password requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod reset-password requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod reset-password requires DEPLOY_PROD_PATH in .env.deploy}"
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
ACCOUNTS_DIR="$TIER_DIR/user/accounts"
FLEX_INDEX="$TIER_DIR/user/data/flex/indexes/accounts.yaml"

# ── 4. Resolve the user; protected-account gate ──────────────────────
if ! USERNAME="$(bv_resolve_username "$USERID")"; then
    exit 1
fi

case "$USERNAME" in
    "$PROTECTED_USER_PREFIX"*)
        if [ "$I_MEAN_IT" != "1" ]; then
            echo "❌  '$USERNAME' is a protected Playwright seed account." >&2
            echo "    Its password must match ~/.gan-secrets/workshop-site.env or the auth suites break." >&2
            echo "    Re-run with --i-mean-it if you mean it." >&2
            exit 1
        fi
        ;;
esac

ACCT="$ACCOUNTS_DIR/$USERNAME.yaml"

echo "→ reset password for '$USERNAME' @ $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$ACCT"

# ── 5. Preflight: account exists; surface a disabled state ───────────
current="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
    if [ ! -f \"$ACCT\" ]; then echo __NOACCT__; exit 0; fi
    st=\$(sed -n 's/^state:[[:space:]]*//p' \"$ACCT\" | head -1)
    echo \"state:\${st:-unset}\"
" < /dev/null 2>/dev/null || echo __SSHFAIL__)"
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
if [ "$CURRENT_STATE" != "enabled" ]; then
    echo "⚠️  Account state is '$CURRENT_STATE' — a new password alone won't let them log in." >&2
    echo "    Activate first: make activate-user tier=$TIER user=$USERNAME" >&2
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "  dry-run: would set a new hashed_password (and clear any pending reset token) on $ACCT, then clear the tier cache; nothing changed."
    exit 0
fi

# ── 6. Confirm ───────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
    printf "Reset the password for '%s' on %s? Their current password stops working immediately. [y/N] " "$USERNAME" "$TIER"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── 7. Inject the password into the PHP source and run it remotely ───
# bash parameter substitution (not sed) — base64 may contain / and + —
# and the composed source only ever exists in this process and the SSH
# stdin stream.
PW_B64="$(printf '%s' "$NEW_PASSWORD" | base64 | tr -d '\n')"
php_source="$(cat "$PASSWORD_PHP")"
php_source="${php_source//__PW_B64__/$PW_B64}"

result="$(printf '%s' "$php_source" | bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
    "cd \"$TIER_DIR\" && php -- \"$ACCT\"" 2>&1 || echo __PHPFAIL__)"

case "$result" in
    *__PHPFAIL__*|*error:*)
        echo "✗ Remote password reset failed:" >&2
        printf '%s\n' "$result" | sed 's/^/    /' >&2
        exit 1
        ;;
    *changed*) ;;
    *)
        echo "✗ Unexpected response from the remote password reset:" >&2
        printf '%s\n' "$result" | sed 's/^/    /' >&2
        exit 1
        ;;
esac

if ! bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "rm -f \"$FLEX_INDEX\" && cd \"$TIER_DIR\" && php bin/grav clearcache" >/dev/null < /dev/null; then
    echo "⚠️  Password changed, but the cache clear failed — run it manually on the tier:" >&2
    echo "      cd $TIER_DIR && php bin/grav clearcache" >&2
    exit 1
fi

echo "✓ Password reset for '$USERNAME' on $TIER. Any pending reset-email token was invalidated."
if [ "$GENERATE" = "1" ]; then
    echo ""
    echo "  Generated password (shown once — pass it to the member over a safe channel):"
    echo ""
    echo "      $NEW_PASSWORD"
    echo ""
    echo "  Recommend they change it themselves via the site's password-reset flow once mail works."
fi
