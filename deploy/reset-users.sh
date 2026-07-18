#!/usr/bin/env bash
# reset-users.sh — bulk-delete MEMBER accounts on a tier (keeps admins + seeds)
#
# WHY
# ---
# The local `make reset-users` wipes config/www/user/accounts/ to give
# registration testing a clean slate. Tiers need the same reset: after a test
# campaign the tier is littered with throwaway member accounts whose usernames
# and emails are squatted (the duplicate guards block re-registration). This is
# the tier-side counterpart: it deletes every MEMBER account on the tier in one
# pass, through the same SSH machinery as delete-user.sh.
#
# WHAT IT KEEPS — never deleted, regardless of flags:
#   * super-admin and admin accounts (access.admin present)
#   * pw-test-* Playwright seed accounts (the auth suite depends on them)
#   * accounts whose access block cannot be classified (shown as kept, so a
#     malformed YAML is surfaced instead of silently deleted)
# Only accounts classified `member` (access.site, no admin block) are removed.
# Per-account deletes (including seeds/admins) go via delete-user.sh instead.
#
# DESTRUCTIVE. Always prints the candidate list before touching anything.
# On prod this bulk-deletes REAL members — gated behind --i-mean-it (and
# `make reset-users tier=prod` is refused at the Make layer entirely).
#
# USAGE
# -----
#   ./deploy/reset-users.sh <tier> [options]
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
    echo "❌  Refusing to reset users on prod without --i-mean-it (bulk-deletes REAL members)." >&2
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
    : "${DEPLOY_PROD_HOST:?prod reset-users requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod reset-users requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod reset-users requires DEPLOY_PROD_PATH in .env.deploy}"
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

TIER_DIR="$PATH_SSH/$TIER"
ACCOUNTS_DIR="$TIER_DIR/user/accounts"
FLEX_INDEX="$TIER_DIR/user/data/flex/indexes/accounts.yaml"

echo "→ reset-users: $TIER"
echo "  target: $USER_SSH@$HOST_SSH:$ACCOUNTS_DIR/"

# ── 3. Classify accounts on the remote (same scheme as list-users.sh) ─
out="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
    d=\"$ACCOUNTS_DIR\"
    [ -d \"\$d\" ] || { echo __NODIR__; exit 0; }
    n=0
    for f in \"\$d\"/*.yaml; do
        [ -e \"\$f\" ] || continue
        n=\$((n+1))
        b=\$(basename \"\$f\"); u=\${b%.yaml}
        st=\$(sed -n 's/^state:[[:space:]]*//p' \"\$f\" | head -1)
        em=\$(sed -n 's/^email:[[:space:]]*//p' \"\$f\" | head -1)
        if grep -qE '^[[:space:]]*super:[[:space:]]+true' \"\$f\"; then ty=super-admin
        elif grep -qE '^[[:space:]]*admin:[[:space:]]*\$' \"\$f\"; then ty=admin
        elif grep -qE '^[[:space:]]*site:[[:space:]]*\$' \"\$f\"; then ty=member
        else ty='?'; fi
        printf '%s\t%s\t%s\t%s\n' \"\$u\" \"\$ty\" \"\${st:-?}\" \"\$em\"
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
    echo "No accounts dir on $TIER ($ACCOUNTS_DIR) — tier not deployed yet, or fresh."
    exit 0
fi
if printf '%s' "$out" | grep -q '__EMPTY__'; then
    echo "No member accounts on $TIER — nothing to reset."
    exit 0
fi

# ── 4. Split into delete / keep sets ─────────────────────────────────
DELETE_USERS=()
DELETE_ROWS=""
KEEP_ROWS=""
while IFS="$(printf '\t')" read -r u ty st em; do
    [ -n "$u" ] || continue
    keep_reason=""
    case "$u" in
        pw-test-*) keep_reason="playwright-seed" ;;
    esac
    if [ -z "$keep_reason" ]; then
        case "$ty" in
            super-admin|admin) keep_reason="admin" ;;
            member) ;;
            *) keep_reason="unclassified" ;;
        esac
    fi
    # The username becomes a remote path component in the delete step —
    # keep (and flag) anything outside the safe charset rather than pass
    # it into a remote rm.
    if [ -z "$keep_reason" ]; then
        case "$u" in
            *[!A-Za-z0-9._-]*|*..*|.*) keep_reason="unsafe-name" ;;
        esac
    fi
    if [ -n "$keep_reason" ]; then
        KEEP_ROWS="${KEEP_ROWS}${u}	${ty}	${st}	${em}	${keep_reason}
"
    else
        DELETE_USERS+=("$u")
        DELETE_ROWS="${DELETE_ROWS}${u}	${ty}	${st}	${em}
"
    fi
done <<EOF
$out
EOF

if [ -n "$KEEP_ROWS" ]; then
    echo ""
    echo "Kept (never touched by reset-users):"
    { printf 'USERNAME\tTYPE\tSTATE\tEMAIL\tWHY-KEPT\n'; printf '%s' "$KEEP_ROWS"; } | column -t -s "$(printf '\t')" | sed 's/^/  /'
fi

if [ ${#DELETE_USERS[@]} -eq 0 ]; then
    echo ""
    echo "✓ No member accounts to delete on $TIER."
    exit 0
fi

verb="Will delete"; [ "$DRY_RUN" = "1" ] && verb="Would delete"
echo ""
echo "$verb ${#DELETE_USERS[@]} member account(s) on $TIER:"
{ printf 'USERNAME\tTYPE\tSTATE\tEMAIL\n'; printf '%s' "$DELETE_ROWS"; } | column -t -s "$(printf '\t')" | sed 's/^/  /'

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "  dry-run: nothing deleted. Re-run without --dry-run to delete."
    exit 0
fi

# ── 5. Confirm ───────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
    printf "Delete these %s account(s) from %s? This cannot be undone. [y/N] " "${#DELETE_USERS[@]}" "$TIER"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── 6. Delete the account YAMLs + flex index, then clear cache ───────
# Usernames were charset-validated above, so quoting each path is safe.
# Removing the flex index is safe — Grav rebuilds it on the next cache
# clear; this drops deleted users from listings and frees the usernames
# and emails for re-registration.
RM_PATHS=""
for u in "${DELETE_USERS[@]}"; do
    RM_PATHS="$RM_PATHS '$ACCOUNTS_DIR/$u.yaml'"
done
if ! bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" \
        "rm -f $RM_PATHS '$FLEX_INDEX' && cd '$TIER_DIR' && php bin/grav clearcache"; then
    echo "✗ reset failed (accounts may be partly removed — re-run, or check the tier with list-users)." >&2
    exit 1
fi

echo ""
echo "✓ Deleted ${#DELETE_USERS[@]} member account(s) from $TIER and cleared cache."
echo "  The usernames and emails are now free to register again."
