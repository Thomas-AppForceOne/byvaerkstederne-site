#!/usr/bin/env bash
# manage-super.sh — grant/revoke super-admin on a tier; list current supers.
#
# WHY
# ---
# `access.admin.super: true` in an account YAML is what makes someone a
# super-admin. manage-groups.sh covers the `groups:` list, and create-admin /
# reset-admin are LOCAL-only (they run against the Docker container), so
# promoting an account on a deployed tier was a hand edit over SSH — the very
# thing the other tier scripts exist to eliminate.
#
# This matters beyond convenience: operator mail (access requests, ops alerts)
# is addressed to every enabled super on the tier
# (account-manager AccountEmail::adminRecipients). A tier with no super
# reachable by email cannot notify anyone about a member's access request —
# it degrades to telling the member to write to the association instead.
# Setting up a tier therefore means setting up its supers.
#
# Grav allows any number of supers; nothing here assumes a single one.
# `Admin::doAnyUsersExist()` gates the initial admin screen on ANY account
# existing, not on a super existing.
#
# The account YAML is rewritten remotely with the tier's own PHP + Symfony
# Yaml (deploy/lib/account-super.php, piped over SSH) — a real YAML parse,
# not sed — so quoting and every unrelated field survive. Grav's cache is
# cleared afterwards so the change takes effect on next login.
#
# USAGE
# -----
#   ./deploy/manage-super.sh list   <tier>
#   ./deploy/manage-super.sh grant  <tier> <username|email> [options]
#   ./deploy/manage-super.sh revoke <tier> <username|email> [options]
#       The user may be given by username or by email; an email is resolved
#       against the tier's accounts and must match exactly one.
#
# Tiers: dev | test | staging | prod
#
# Options:
#   --yes, -y       Skip the confirmation prompt.
#   --dry-run, -n   Resolve and validate everything; change nothing.
#   --i-mean-it     Required for tier=prod and for the protected Playwright
#                   seed accounts (pw-test-*).
#   --help, -h      Show this help.
#
# REVOKE REFUSES THE LAST SUPER. A tier with zero supers cannot notify anyone
# about access requests and cannot be administered from the panel; pass
# --i-mean-it if that is genuinely what you want.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SUPER_PHP="$SCRIPT_DIR/lib/account-super.php"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Accounts the Playwright suites depend on — protected from casual changes,
# same posture as delete-user.sh and manage-groups.sh.
PROTECTED_USER_PREFIX="pw-test-"

YES=0
DRY_RUN=0
I_MEAN_IT=0
ACTION=""
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        --yes|-y) YES=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --i-mean-it) I_MEAN_IT=1 ;;
        --help|-h) usage; exit 0 ;;
        list|grant|revoke)
            if [ -z "$ACTION" ]; then ACTION="$arg"; else POSITIONAL+=("$arg"); fi
            ;;
        -*) echo "❌  Unknown option '$arg'" >&2; usage >&2; exit 1 ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done

if [ -z "$ACTION" ]; then
    echo "❌  Missing action (list | grant | revoke)" >&2
    usage >&2
    exit 1
fi

TIER="${POSITIONAL[0]:-}"
case "$TIER" in
    dev|test|staging|prod) ;;
    *) echo "❌  $ACTION: invalid or missing tier (got: '$TIER') — allowed: dev|test|staging|prod" >&2; exit 1 ;;
esac

if [ "$ACTION" != "list" ]; then
    USERID="${POSITIONAL[1]:-}"
    if [ -z "$USERID" ]; then
        echo "❌  $ACTION: missing user (a username, or an email to resolve)" >&2
        echo "    Usage:   $0 $ACTION <dev|test|staging|prod> <username|email> [--yes] [--dry-run] [--i-mean-it]" >&2
        echo "    Example: $0 grant dev test+admin@hackersbychoice.dk" >&2
        exit 1
    fi
    # The user id becomes a remote path component (username) or a grep
    # pattern (email) — restrict both to a safe charset.
    case "$USERID" in
        *[!A-Za-z0-9._@+-]*|*..*|.*)
            echo "❌  Refusing unsafe user id '$USERID' (allowed: A-Z a-z 0-9 . _ @ + -, no '..', no leading '.')." >&2
            exit 1
            ;;
    esac
    if [ "$TIER" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
        echo "❌  Refusing to change super-admin rights on prod without --i-mean-it." >&2
        exit 1
    fi
    if [ ! -f "$SUPER_PHP" ]; then
        echo "❌  Missing $SUPER_PHP (repo checkout incomplete?)." >&2
        exit 1
    fi
fi

# ── Load credentials + resolve SSH for the tier ──────────────────────
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
    : "${DEPLOY_PROD_HOST:?prod manage-super requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod manage-super requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod manage-super requires DEPLOY_PROD_PATH in .env.deploy}"
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

# Usernames of every account with `super: true`, one per line. Used by `list`
# and by the last-super guard on revoke.
remote_supers() {
    bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
        for f in $ACCOUNTS_DIR/*.yaml; do
            [ -f \"\$f\" ] || continue
            if grep -qE '^[[:space:]]*super:[[:space:]]*true' \"\$f\"; then
                b=\$(basename \"\$f\"); echo \"\${b%.yaml}\"
            fi
        done
    " 2>/dev/null || echo __SSHFAIL__
}

# ── Action: list ─────────────────────────────────────────────────────
if [ "$ACTION" = "list" ]; then
    supers="$(remote_supers)"
    if printf '%s' "$supers" | grep -q '__SSHFAIL__'; then
        echo "✗ SSH to $USER_SSH@$HOST_SSH:$PORT_SSH failed." >&2
        bv_ssh_diagnose "$USER_SSH" "$HOST_SSH" "$PORT_SSH"
        exit 1
    fi
    if [ -z "$(printf '%s' "$supers" | tr -d '[:space:]')" ]; then
        echo "No super-admins on $TIER."
        echo "  Operator mail (access requests, ops alerts) has nowhere to go on this tier."
        exit 0
    fi
    echo "Super-admins on $TIER:"
    printf '%s\n' "$supers" | sed '/^$/d;s/^/  - /'
    exit 0
fi

# ── Resolve the user (email → username, shared lib) ──────────────────
if ! USERNAME="$(bv_resolve_username "$USERID")"; then
    exit 1
fi

case "$USERNAME" in
    "$PROTECTED_USER_PREFIX"*)
        if [ "$I_MEAN_IT" != "1" ]; then
            echo "❌  '$USERNAME' is a protected Playwright seed account." >&2
            echo "    Changing its rights breaks the auth suites. Re-run with --i-mean-it if you mean it." >&2
            exit 1
        fi
        ;;
esac

ACCT="$ACCOUNTS_DIR/$USERNAME.yaml"

echo "→ $ACTION super-admin for '$USERNAME' @ $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$ACCT"

# ── Preflight: the account must exist ────────────────────────────────
preflight="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
    "if [ -f \"$ACCT\" ]; then echo __OK__; else echo __NOACCT__; fi" \
    2>/dev/null || echo __SSHFAIL__)"
case "$preflight" in
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

# ── Guard: never strand a tier without a super by accident ───────────
if [ "$ACTION" = "revoke" ]; then
    supers="$(remote_supers)"
    if printf '%s' "$supers" | grep -q '__SSHFAIL__'; then
        echo "✗ Could not read the tier's supers — refusing to revoke blind." >&2
        exit 1
    fi
    # `grep -v` exits 1 when it filters everything away — which is exactly the
    # case this guard exists for. Without the `|| true` the whole script would
    # die under `set -e` right here and the refusal would never print.
    remaining="$(printf '%s\n' "$supers" | sed '/^$/d' | { grep -vxF "$USERNAME" || true; } | wc -l | tr -d ' ')"
    if [ "$remaining" = "0" ] && [ "$I_MEAN_IT" != "1" ]; then
        echo "❌  '$USERNAME' is the LAST super-admin on $TIER." >&2
        echo "    Revoking leaves the tier with nobody to notify about access requests" >&2
        echo "    and nobody who can administer it. Re-run with --i-mean-it if you mean it." >&2
        exit 1
    fi
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "  dry-run: would $ACTION super-admin on $ACCT and clear the tier cache; nothing changed."
    exit 0
fi

# ── Confirm ──────────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
    printf "%s super-admin %s '%s' on %s? [y/N] " \
        "$([ "$ACTION" = "grant" ] && echo "Grant" || echo "Revoke")" \
        "$([ "$ACTION" = "grant" ] && echo "to" || echo "from")" \
        "$USERNAME" "$TIER"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── Mutate the account YAML with the tier's PHP, then clear cache ────
# The actor is recorded in the tier's audit log alongside in-app rights
# changes. Restricted charset: it is interpolated into the remote command.
ACTOR="$(printf '%s@%s' "${USER:-unknown}" "$(hostname -s 2>/dev/null || echo host)" | tr -cd 'A-Za-z0-9._@-' | cut -c1-64)"

result="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
    "cd \"$TIER_DIR\" && php -- \"$ACCT\" \"$ACTION\" \"$ACTOR\"" \
    < "$SUPER_PHP" 2>&1 || echo __PHPFAIL__)"

case "$result" in
    *__PHPFAIL__*|*error:*)
        echo "✗ Remote super-admin edit failed:" >&2
        printf '%s\n' "$result" | sed 's/^/    /' >&2
        exit 1
        ;;
    *already-super*)
        echo "✓ '$USERNAME' is already a super-admin on $TIER — nothing to do."
        exit 0
        ;;
    *not-super*)
        echo "✓ '$USERNAME' is not a super-admin on $TIER — nothing to do."
        exit 0
        ;;
    *changed*) ;;
    *)
        echo "✗ Unexpected response from the remote super-admin edit:" >&2
        printf '%s\n' "$result" | sed 's/^/    /' >&2
        exit 1
        ;;
esac

# The Flex accounts index caches the account list; a stale index serves the
# pre-change access tree until it rebuilds.
if ! bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "rm -f \"$FLEX_INDEX\" && cd \"$TIER_DIR\" && php bin/grav clearcache" >/dev/null < /dev/null; then
    echo "⚠  Rights changed, but clearing the tier cache failed. Clear it manually:" >&2
    echo "      cd $TIER_DIR && php bin/grav clearcache" >&2
fi

# ── Alert the tier's supers that someone was promoted ────────────────
# After the cache clear, so the recipient resolver sees current state. A
# failed alert is reported but never undoes the change — and it is loud,
# because "nobody was told" is the part an operator needs to know.
if [ "$ACTION" = "grant" ]; then
    if alert="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
            "cd \"$TIER_DIR\" && php bin/plugin account-manager notify-super-granted --user \"$USERNAME\" --actor \"$ACTOR\" --source deploy/manage-super.sh" \
            2>&1 < /dev/null)"; then
        echo "  alerted: every super-admin on $TIER has been mailed about this change"
    else
        echo "⚠  The rights change succeeded, but the super-admins could NOT be alerted:" >&2
        printf '%s\n' "$alert" | sed 's/^/      /' >&2
        echo "      Tell them by hand — a silent privilege escalation is the thing this mail exists to prevent." >&2
    fi
fi

echo "✓ super-admin ${ACTION}ed for '$USERNAME' on $TIER (effective at next login)"
case "$result" in
    *changed+login*)
        echo "  note: the account had no access.site.login — it was granted too, so the"
        echo "        super can reach the member surfaces the approval links live on."
        ;;
esac
case "$result" in
    *"audit entry could not be written"*)
        echo "⚠  The change is NOT in the tier's audit log — record it by hand." >&2
        ;;
    *)
        echo "  logged: user/data/account-manager/account-audit.jsonl (actor $ACTOR)"
        ;;
esac
