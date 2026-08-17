#!/usr/bin/env bash
# list-users.sh — list the member accounts on a tier (read-only)
#
# WHY
# ---
# The login plugin's CLI only looks up ONE user at a time (lookup-user), and
# accounts are flat YAML at user/accounts/<username>.yaml. While testing
# registration you want to see what accounts exist (and their state — to spot
# disabled/un-activated ones) so you know what to delete. This lists them, with
# username / type / state / email / groups, through the same SSH machinery as
# the other deploy scripts. Read-only: it never writes or deletes.
#
# GROUPS answers "who is an organizer here?" without opening each account YAML
# or reaching for manage-groups.sh one user at a time. The column reads the
# same top-level `groups:` key manage-groups.sh writes, in both the block form
# Symfony's dumper produces and the flow form (`groups: [a, b]`) a hand edit
# may leave. An account with no groups shows `-`.
#
# Passwords are stored hashed in the account YAML and are never read or shown —
# only username, type, state, email, and groups.
#
# USAGE
#   ./deploy/list-users.sh <tier>
# Tiers: dev | test | staging | prod
#   --help, -h   Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# ── 1. Parse args ────────────────────────────────────────────────────
TIER=""
for arg in "$@"; do
    case "$arg" in
        dev|test|staging|prod) TIER="$arg" ;;
        --help|-h) usage; exit 0 ;;
        *) echo "❌  Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
    esac
done

case "$TIER" in
    dev|test|staging|prod) ;;
    *) echo "❌  Usage: $0 <dev|test|staging|prod>" >&2; exit 1 ;;
esac

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
    : "${DEPLOY_PROD_HOST:?prod list-users requires DEPLOY_PROD_HOST in .env.deploy}"
    : "${DEPLOY_PROD_USER:?prod list-users requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod list-users requires DEPLOY_PROD_PATH in .env.deploy}"
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

ACCOUNTS_DIR="$(bv_tier_root "$PATH_SSH" "$TIER")/user/accounts"

# ── 3. List on the remote (tab-separated: username, type, state, email,
#       groups) ────────────────────────────────────────────────────────
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
        # Groups, flow form first (\`groups: [a, b]\`), then the block form
        # Symfony's dumper writes. The tr -cd keeps only the characters a
        # group name may contain (manage-groups.sh pins them to
        # ^[a-z0-9_-]+\$), so brackets, quotes and stray spaces fall away
        # without any quoting gymnastics across the SSH boundary.
        gr=\$(sed -n 's/^groups:[[:space:]]*\[\(.*\)\][[:space:]]*\$/\\1/p' \"\$f\" | head -1)
        if [ -z \"\$gr\" ]; then
            gr=\$(sed -n '/^groups:[[:space:]]*\$/,/^[^[:space:]#-]/{ s/^[[:space:]]*-[[:space:]]*//p; }' \"\$f\" | tr '\n' ',')
        fi
        gr=\$(printf '%s' \"\$gr\" | tr -cd 'a-z0-9_,-' | sed 's/,,*/,/g; s/^,//; s/,\$//')
        if [ -z \"\$gr\" ]; then gr='-'; fi
        printf '%s\t%s\t%s\t%s\t%s\n' \"\$u\" \"\$ty\" \"\${st:-?}\" \"\${em:--}\" \"\$gr\"
    done
    if [ \"\$n\" = 0 ]; then echo __EMPTY__; fi
    exit 0
" 2>/dev/null || echo __SSHFAIL__)"

# ── 4. Report ────────────────────────────────────────────────────────
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
    echo "No member accounts on $TIER."
    exit 0
fi

count="$(printf '%s\n' "$out" | grep -c .)"
echo "Member accounts on $TIER:"
[ "$TIER" = "prod" ] && echo "(real member data)"
{ printf 'USERNAME\tTYPE\tSTATE\tEMAIL\tGROUPS\n'; printf '%s\n' "$out"; } | column -t -s "$(printf '\t')"
echo "($count account(s))"
