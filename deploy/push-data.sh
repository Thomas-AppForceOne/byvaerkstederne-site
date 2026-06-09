#!/usr/bin/env bash
# push-data.sh — push local flex-objects YAML to a tier's data tree
#
# WHY
# ---
# `make deploy tier=<tier>` deploys code only. The deploy rsync deliberately
# excludes the live-state tree (`<tier>data/`, `accounts/`, `user/data/`,
# `logs/`) — see deploy.sh §"Live-state … is NEVER in the rsync source
# tree". That protects admin-edited content from being trampled by a code
# deploy, but it also means data changes you make locally (flex-objects
# YAML — events, opgaver, ønskeliste, roadmap items, …) don't reach the
# remote tier through the regular deploy.
#
# This script closes that gap for developer-facing tiers (dev / test /
# staging): it rsyncs the named YAML file(s) from
# config/www/user/data/flex-objects/ to the remote
# <DEPLOY_PATH>/<tier>data/v0/user/data/flex-objects/ and clears Grav's
# cache so the new data is picked up.
#
# Prod is refused without --i-mean-it. Prod's flex-objects are the
# canonical source of truth (admin-UI managed); pushing local YAML to
# prod overwrites every admin edit since the last push. If you need to
# do it, you mean it explicitly.
#
# Three files are unconditionally refused regardless of tier:
# bug-reports.yaml, feature-suggestions.yaml, and submission-tokens.yaml
# — they carry user-generated content and CSRF/submission tokens.
# Local-as-truth there is always wrong.
#
# USAGE
# -----
#   ./deploy/push-data.sh <tier> [options]
#
# Tiers: dev | test | staging | prod
#
# Options:
#   --files=<list>   Comma-separated YAML filenames to push from
#                    config/www/user/data/flex-objects/.
#                    Default: begivenheder.yaml.
#   --yes            Skip the confirmation prompt.
#   --dry-run        Show the diff and exit; do not push.
#   --i-mean-it      Required for tier=prod.
#   --help           Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# ── 1. Parse args ────────────────────────────────────────────────────
TIER=""
FILES_RAW="begivenheder.yaml"
YES=0
DRY_RUN=0
I_MEAN_IT=0

for arg in "$@"; do
    case "$arg" in
        dev|test|staging|prod) TIER="$arg" ;;
        --files=*) FILES_RAW="${arg#--files=}" ;;
        --yes|-y) YES=1 ;;
        --dry-run|-n) DRY_RUN=1 ;;
        --i-mean-it) I_MEAN_IT=1 ;;
        --help|-h) usage; exit 0 ;;
        *)
            echo "❌  Unknown arg: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$TIER" ]; then
    usage >&2
    exit 1
fi

if [ "$TIER" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
    cat >&2 <<'EOF'
❌  Refusing to push to prod without --i-mean-it.

    Prod's flex-objects are managed via the admin UI on byvaerkstederne.dk.
    Pushing local YAML overwrites every admin edit since the last push.

    Re-run with --i-mean-it if you genuinely want to do this.
EOF
    exit 1
fi

# ── 2. Validate the file list ────────────────────────────────────────
# Files that carry user-generated content or auth/submission tokens —
# local-as-truth would erase real activity on the remote tier.
FORBIDDEN_FILES=(
    "bug-reports.yaml"
    "feature-suggestions.yaml"
    "submission-tokens.yaml"
)

LOCAL_DATA_DIR="$PROJECT_DIR/config/www/user/data/flex-objects"

# Trim, split on comma into FILES[].
FILES=()
IFS=',' read -ra _split <<<"$FILES_RAW"
for f in "${_split[@]}"; do
    f="$(echo "$f" | tr -d '[:space:]')"
    [ -z "$f" ] && continue

    # Reject path traversal / subdirs — only bare filenames allowed.
    case "$f" in
        */*|*..*|.*)
            echo "❌  Refusing path containing '/', '..', or leading '.': $f" >&2
            exit 1
            ;;
    esac

    # Reject forbidden files.
    for forb in "${FORBIDDEN_FILES[@]}"; do
        if [ "$f" = "$forb" ]; then
            echo "❌  Refusing to push $f — it carries user-generated content / auth tokens." >&2
            echo "    Pushing local-as-truth would erase real activity on the remote." >&2
            exit 1
        fi
    done

    # Confirm file exists locally.
    if [ ! -f "$LOCAL_DATA_DIR/$f" ]; then
        echo "❌  Local file does not exist: $LOCAL_DATA_DIR/$f" >&2
        exit 1
    fi

    FILES+=("$f")
done

if [ ${#FILES[@]} -eq 0 ]; then
    echo "❌  No files to push (after parsing --files=)" >&2
    exit 1
fi

# ── 3. Load credentials ──────────────────────────────────────────────
ENV_FILE="$PROJECT_DIR/.env.deploy"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌  Missing $ENV_FILE — copy .env.deploy.example and fill in credentials" >&2
    exit 1
fi
# shellcheck disable=SC1090
. "$ENV_FILE"
# shellcheck source=deploy/lib/ssh-auth.sh
. "$SCRIPT_DIR/lib/ssh-auth.sh"

# ── 4. Resolve SSH credentials for the tier ──────────────────────────
# bv_resolve_ssh_password reads $TIER to decide which env-var / Keychain
# item to consult — same convention deploy.sh uses.
export TIER

if [ "$TIER" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod push-data requires DEPLOY_PROD_HOST in .env.deploy — prod lives on a separate hosting account from staging/test/dev}"
    : "${DEPLOY_PROD_USER:?prod push-data requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod push-data requires DEPLOY_PROD_PATH in .env.deploy}"
    DEPLOY_HOST="$DEPLOY_PROD_HOST"
    DEPLOY_USER="$DEPLOY_PROD_USER"
    DEPLOY_PORT="${DEPLOY_PROD_PORT:-${DEPLOY_PORT}}"
    DEPLOY_PATH="$DEPLOY_PROD_PATH"
    # bv_resolve_ssh_password picks DEPLOY_PROD_PASS / DEPLOY_PROD_PASS_KEYCHAIN
    # when TIER=prod; for chosting.dk (SSH key-auth) it returns empty and
    # bv_ssh_cmd falls through to BatchMode=yes.
    DEPLOY_PASS="$(bv_resolve_ssh_password)"
else
    : "${DEPLOY_HOST:?missing DEPLOY_HOST in .env.deploy}"
    : "${DEPLOY_USER:?missing DEPLOY_USER in .env.deploy}"
    : "${DEPLOY_PATH:?missing DEPLOY_PATH in .env.deploy}"
    : "${DEPLOY_PORT:?missing DEPLOY_PORT in .env.deploy}"
    DEPLOY_PASS="$(bv_resolve_ssh_password)"
fi
export DEPLOY_PASS

REMOTE_DATA_DIR="$DEPLOY_PATH/${TIER}data/v0/user/data/flex-objects"
REMOTE_TIER_DIR="$DEPLOY_PATH/$TIER"

echo "→ push-data: $TIER"
echo "  target: $DEPLOY_USER@$DEPLOY_HOST:$REMOTE_DATA_DIR/"
echo "  files:  ${FILES[*]}"
echo ""

# ── 5. Pre-flight: confirm the remote data tree exists ──────────────
# We don't auto-create <tier>data/v0 — that's `make deploy`'s bootstrap
# step and creating it here would mask a real "tier never deployed" bug.
echo "→ pre-flight: checking $REMOTE_DATA_DIR exists on $DEPLOY_HOST..."
if ! bv_ssh_cmd -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" \
        "test -d \"$REMOTE_DATA_DIR\""; then
    cat >&2 <<EOF
❌  Remote $REMOTE_DATA_DIR does not exist on $DEPLOY_HOST.

    Either $TIER has never been code-deployed (so the data tree was never
    bootstrapped), or your DEPLOY_PATH points at the wrong account.

    Run 'make deploy tier=$TIER' first to bootstrap the layout, then
    re-run this push.
EOF
    exit 1
fi

# ── 6. Diff each file ────────────────────────────────────────────────
ANY_DIFF=0
for f in "${FILES[@]}"; do
    echo ""
    echo "── $f ─────────────────────────"
    _remote_content="$(bv_ssh_cmd -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" \
        "cat \"$REMOTE_DATA_DIR/$f\" 2>/dev/null || true")"

    if [ -z "$_remote_content" ]; then
        echo "  (remote file missing — push will create it)"
        ANY_DIFF=1
        continue
    fi

    _local_content="$(cat "$LOCAL_DATA_DIR/$f")"
    if [ "$_remote_content" = "$_local_content" ]; then
        echo "  (no differences — push would be a no-op)"
        continue
    fi

    # Show up to 80 lines of unified diff per file.
    if diff -u <(printf '%s' "$_remote_content") "$LOCAL_DATA_DIR/$f" \
            | sed "1,2s|^\\(---\\|+++\\).*|& ($TIER:$f)|" \
            | head -80; then
        : # unreachable: diff returns non-zero when files differ
    fi
    ANY_DIFF=1
done

if [ "$ANY_DIFF" = "0" ]; then
    echo ""
    echo "✓ Nothing to push — all files identical on $TIER."
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    echo ""
    echo "✓ dry-run complete; no changes made"
    exit 0
fi

# ── 7. Confirm ───────────────────────────────────────────────────────
if [ "$YES" != "1" ]; then
    echo ""
    printf "Push these changes to %s? [y/N] " "$TIER"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── 8. Rsync each file ───────────────────────────────────────────────
echo ""
_rsync_e="$(bv_rsync_ssh_e "$DEPLOY_PORT")" \
    || { echo "❌  could not build rsync ssh-cmd (sshpass missing?)" >&2; exit 1; }

for f in "${FILES[@]}"; do
    echo "→ rsync $f"
    bv_rsync_via_ssh -a \
        --exclude='.DS_Store' \
        -e "$_rsync_e" \
        "$LOCAL_DATA_DIR/$f" \
        "$DEPLOY_USER@$DEPLOY_HOST:$REMOTE_DATA_DIR/$f"
done

# ── 9. Clear Grav cache ──────────────────────────────────────────────
echo ""
echo "→ clearing Grav cache on $TIER"
if ! bv_ssh_cmd -p "$DEPLOY_PORT" "$DEPLOY_USER@$DEPLOY_HOST" \
        "cd \"$REMOTE_TIER_DIR\" && php bin/grav clearcache"; then
    echo "⚠  Cache clear failed — data is pushed but you may see stale renders" >&2
    echo "    until Grav's auto-cache rolls over (a few minutes)." >&2
fi

# ── 10. Done ─────────────────────────────────────────────────────────
echo ""
case "$TIER" in
    prod) _url="https://byvaerkstederne.dk/vaerkstedskalenderen" ;;
    *)    _url="https://${TIER}.hackersbychoice.dk/vaerkstedskalenderen" ;;
esac
echo "✓ push-data: ${#FILES[@]} file(s) synced to $TIER"
echo "  inspect: $_url"
