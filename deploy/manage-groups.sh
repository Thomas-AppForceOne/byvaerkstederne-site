#!/usr/bin/env bash
# manage-groups.sh — list groups, grant/revoke group membership on a tier
#
# WHY
# ---
# Roles are granted by adding a group name to the `groups:` list in an
# account YAML (user/accounts/<username>.yaml); the group's access tree
# lives in the repo's user/config/groups.yaml and deploys with the code.
# The login plugin ships no CLI for group assignment, and on deployed
# tiers the accounts live in the non-versioned live-state dir — so the
# grant used to be a hand edit over SSH. This wraps it in the same SSH
# machinery and guardrails as delete-user.sh, ahead of more groups
# (organizers today, more roles soon).
#
# The account YAML is rewritten remotely with the tier's own PHP +
# Symfony Yaml (deploy/lib/account-groups.php, piped over SSH) — a real
# YAML parse, not sed — so flow-style lists and quoting survive. Grav's
# cache is cleared afterwards so the change takes effect on next login.
#
# USAGE
# -----
#   ./deploy/manage-groups.sh list [tier]
#       No tier: list groups from the repo's user/config/groups.yaml
#       (the source of truth). With a tier: list what that tier's
#       DEPLOYED groups.yaml defines (differs until the tier redeploys).
#
#   ./deploy/manage-groups.sh grant  <tier> <username|email> <group> [options]
#   ./deploy/manage-groups.sh revoke <tier> <username|email> <group> [options]
#       The user may be given by username or by email; an email is
#       resolved against the tier's accounts and must match exactly one.
#       grant refuses a group the tier's deployed groups.yaml does not
#       define (the grant would confer nothing until the next deploy);
#       revoke allows it (removing stale membership is legitimate).
#
# Tiers: dev | test | staging | prod
#
# Options:
#   --yes, -y       Skip the confirmation prompt.
#   --dry-run, -n   Resolve and validate everything; change nothing.
#   --i-mean-it     Required for tier=prod and for the protected
#                   Playwright seed accounts (pw-test-*).
#   --help, -h      Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_GROUPS_FILE="$PROJECT_DIR/config/www/user/config/groups.yaml"
GROUPS_PHP="$SCRIPT_DIR/lib/account-groups.php"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Accounts the Playwright suites depend on (pw-test-org's organizers
# membership backs the entire event-authz suite) — protected from casual
# membership changes, same posture as delete-user.sh.
PROTECTED_USER_PREFIX="pw-test-"

# Print "name<TAB>readableName<TAB>description" per group from a groups.yaml
# on stdin. Top-level keys are group names; nested keys are indented.
parse_groups_yaml() {
    awk '
        /^[A-Za-z0-9_-]+:[[:space:]]*$/ {
            if (name != "") printf "%s\t%s\t%s\n", name, rn, de
            name = $1; sub(/:$/, "", name); rn = ""; de = ""
        }
        /^[[:space:]]+readableName:/ {
            rn = $0; sub(/^[[:space:]]+readableName:[[:space:]]*/, "", rn); gsub(/^'\''|'\''$/, "", rn)
        }
        /^[[:space:]]+description:/ {
            de = $0; sub(/^[[:space:]]+description:[[:space:]]*/, "", de); gsub(/^'\''|'\''$/, "", de)
        }
        END { if (name != "") printf "%s\t%s\t%s\n", name, rn, de }
    '
}

# ── 1. Parse args ────────────────────────────────────────────────────
ACTION="${1:-}"
shift || true

case "$ACTION" in
    list|grant|revoke) ;;
    --help|-h|"") usage; exit 0 ;;
    *) echo "❌  Unknown action '$ACTION' (allowed: list | grant | revoke)" >&2; usage >&2; exit 1 ;;
esac

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

# ── 2. Action: list (local needs no SSH) ─────────────────────────────
if [ "$ACTION" = "list" ]; then
    TIER="${POSITIONAL[0]:-}"
    if [ -z "$TIER" ]; then
        if [ ! -f "$REPO_GROUPS_FILE" ]; then
            echo "❌  No groups defined yet ($REPO_GROUPS_FILE is missing)." >&2
            exit 1
        fi
        echo "Groups defined in the repo (user/config/groups.yaml):"
        { printf 'GROUP\tREADABLE NAME\tDESCRIPTION\n'; parse_groups_yaml < "$REPO_GROUPS_FILE"; } \
            | column -t -s "$(printf '\t')"
        exit 0
    fi
    case "$TIER" in
        dev|test|staging|prod) ;;
        *) echo "❌  Invalid tier '$TIER' (allowed: dev|test|staging|prod, or omit for the repo copy)" >&2; exit 1 ;;
    esac
fi

# ── 3. Action: grant/revoke argument validation ──────────────────────
if [ "$ACTION" != "list" ]; then
    TIER="${POSITIONAL[0]:-}"
    USERID="${POSITIONAL[1]:-}"
    GROUP="${POSITIONAL[2]:-}"

    err=0
    case "$TIER" in
        dev|test|staging|prod) ;;
        *) echo "❌  $ACTION: invalid or missing tier (got: '$TIER') — allowed: dev|test|staging|prod" >&2; err=1 ;;
    esac
    if [ -z "$USERID" ]; then
        echo "❌  $ACTION: missing user (a username, or an email to resolve)" >&2; err=1
    fi
    if [ -z "$GROUP" ]; then
        echo "❌  $ACTION: missing group name" >&2; err=1
    fi
    if [ "$err" = "1" ]; then
        echo "    Usage:   $0 $ACTION <dev|test|staging|prod> <username|email> <group> [--yes] [--dry-run] [--i-mean-it]" >&2
        echo "    Example: $0 grant dev anders@example.dk organizers" >&2
        exit 1
    fi

    # Group names are lowercase identifiers (they become config keys and a
    # remote grep pattern).
    case "$GROUP" in
        *[!a-z0-9_-]*|"")
            echo "❌  Refusing unsafe group name '$GROUP' (allowed: a-z 0-9 _ -)." >&2
            exit 1
            ;;
    esac

    # Grant checks the REPO groups.yaml first — the cheapest fail-fast for a
    # typo'd group. Revoke skips this: removing membership of a since-retired
    # group is a legitimate cleanup.
    if [ "$ACTION" = "grant" ]; then
        if [ ! -f "$REPO_GROUPS_FILE" ] || ! grep -qE "^${GROUP}:[[:space:]]*$" "$REPO_GROUPS_FILE"; then
            echo "❌  Group '$GROUP' is not defined in $REPO_GROUPS_FILE." >&2
            echo "    Known groups:" >&2
            [ -f "$REPO_GROUPS_FILE" ] && parse_groups_yaml < "$REPO_GROUPS_FILE" | cut -f1 | sed 's/^/      - /' >&2
            exit 1
        fi
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
        echo "❌  Refusing to change group membership on prod without --i-mean-it (this changes a REAL member's rights)." >&2
        exit 1
    fi

    if [ ! -f "$GROUPS_PHP" ]; then
        echo "❌  Missing $GROUPS_PHP (repo checkout incomplete?)." >&2
        exit 1
    fi
fi

# ── 4. Load credentials + resolve SSH for the tier ───────────────────
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
    : "${DEPLOY_PROD_HOST:?prod manage-groups requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod manage-groups requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod manage-groups requires DEPLOY_PROD_PATH in .env.deploy}"
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
TIER_GROUPS_FILE="$TIER_DIR/user/config/groups.yaml"
FLEX_INDEX="$TIER_DIR/user/data/flex/indexes/accounts.yaml"

# ── 5. Action: list (remote) ─────────────────────────────────────────
if [ "$ACTION" = "list" ]; then
    out="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "if [ -f \"$TIER_GROUPS_FILE\" ]; then cat \"$TIER_GROUPS_FILE\"; else echo __NOFILE__; fi" \
        2>/dev/null || echo __SSHFAIL__)"
    if printf '%s' "$out" | grep -q '__SSHFAIL__'; then
        echo "✗ SSH to $USER_SSH@$HOST_SSH:$PORT_SSH failed." >&2
        bv_ssh_diagnose "$USER_SSH" "$HOST_SSH" "$PORT_SSH"
        exit 1
    fi
    if printf '%s' "$out" | grep -q '__NOFILE__'; then
        echo "No groups.yaml deployed on $TIER ($TIER_GROUPS_FILE) — the tier predates the groups feature; redeploy it first."
        exit 0
    fi
    echo "Groups deployed on $TIER (user/config/groups.yaml):"
    { printf 'GROUP\tREADABLE NAME\tDESCRIPTION\n'; printf '%s\n' "$out" | parse_groups_yaml; } \
        | column -t -s "$(printf '\t')"
    exit 0
fi

# ── 6. Resolve the user (email → username, shared lib) ───────────────
if ! USERNAME="$(bv_resolve_username "$USERID")"; then
    exit 1
fi

case "$USERNAME" in
    "$PROTECTED_USER_PREFIX"*)
        if [ "$I_MEAN_IT" != "1" ]; then
            echo "❌  '$USERNAME' is a protected Playwright seed account." >&2
            echo "    Changing its groups breaks the auth/event suites. Re-run with --i-mean-it if you mean it." >&2
            exit 1
        fi
        ;;
esac

ACCT="$ACCOUNTS_DIR/$USERNAME.yaml"

echo "→ $ACTION '$GROUP' for '$USERNAME' @ $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$ACCT"

# ── 7. Preflight: account exists; on grant, the group must be live ───
preflight="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
    if [ ! -f \"$ACCT\" ]; then echo __NOACCT__; exit 0; fi
    if [ -f \"$TIER_GROUPS_FILE\" ] && grep -qE '^${GROUP}:[[:space:]]*\$' \"$TIER_GROUPS_FILE\"; then
        echo __GROUP_LIVE__
    else
        echo __GROUP_MISSING__
    fi
" 2>/dev/null || echo __SSHFAIL__)"
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
if [ "$ACTION" = "grant" ] && ! printf '%s' "$preflight" | grep -q '__GROUP_LIVE__'; then
    echo "✗ Group '$GROUP' is defined in the repo but NOT in $TIER's deployed groups.yaml." >&2
    echo "  Granting it now would confer nothing until the tier redeploys — deploy first:" >&2
    echo "      make deploy tier=$TIER" >&2
    exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
    echo "  dry-run: would $ACTION '$GROUP' on $ACCT and clear the tier cache; nothing changed."
    exit 0
fi

# ── 8. Confirm ───────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
    printf "%s group '%s' %s account '%s' on %s? [y/N] " \
        "$([ "$ACTION" = "grant" ] && echo "Grant" || echo "Revoke")" \
        "$GROUP" \
        "$([ "$ACTION" = "grant" ] && echo "to" || echo "from")" \
        "$USERNAME" "$TIER"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── 9. Mutate the account YAML with the tier's PHP, then clear cache ──
# account-groups.php is piped over stdin and parses/dumps the YAML with
# the tier's own Symfony Yaml — never sed. It prints one status token:
# changed | already-member | not-a-member.
result="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
    "cd \"$TIER_DIR\" && php -- \"$ACCT\" \"$GROUP\" \"$ACTION\"" \
    < "$GROUPS_PHP" 2>&1 || echo __PHPFAIL__)"

case "$result" in
    *__PHPFAIL__*|*error:*)
        echo "✗ Remote group edit failed:" >&2
        printf '%s\n' "$result" | sed 's/^/    /' >&2
        exit 1
        ;;
    *already-member*)
        echo "✓ '$USERNAME' already has group '$GROUP' on $TIER — nothing to do."
        exit 0
        ;;
    *not-a-member*)
        echo "✓ '$USERNAME' does not have group '$GROUP' on $TIER — nothing to do."
        exit 0
        ;;
    *changed*) ;;
    *)
        echo "✗ Unexpected response from the remote group edit:" >&2
        printf '%s\n' "$result" | sed 's/^/    /' >&2
        exit 1
        ;;
esac

# Clear the cache (and drop the flex accounts index — Grav rebuilds it) so
# the new access tree resolves on the member's next login.
if ! bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "rm -f \"$FLEX_INDEX\" && cd \"$TIER_DIR\" && php bin/grav clearcache" >/dev/null < /dev/null; then
    echo "⚠️  Group changed, but the cache clear failed — run it manually on the tier:" >&2
    echo "      cd $TIER_DIR && php bin/grav clearcache" >&2
    exit 1
fi

if [ "$ACTION" = "grant" ]; then
    echo "✓ Granted '$GROUP' to '$USERNAME' on $TIER (takes effect on their next login)."
else
    echo "✓ Revoked '$GROUP' from '$USERNAME' on $TIER (takes effect on their next login)."
fi
