#!/usr/bin/env bash
# push-email.sh — push each tier's per-tier SMTP transport (email.yaml)
#                 to that tier's live data tree.
#
# WHY
# ---
# `email.yaml` is operator-provisioned secret state: SMTP host/port/user/
# password. It is gitignored and lives per tier at
#   config/www/user/env/<host>/config/plugins/email.yaml
# A normal `make deploy` only seeds it into <tier>data on the FIRST deploy
# (the bootstrap mv is guarded so it never tramples live state). To UPDATE
# the credentials on a tier that already has an email.yaml — or to provision
# one without a full code deploy — you need a direct push. This is the
# email sibling of push-data.sh.
#
# TIER-PINNED — NEVER BROADCAST ONE FILE TO MANY TIERS
# ----------------------------------------------------
# Every tier has its OWN identity, credentials, and delivery posture
# (spec WI-1 Prerequisites table):
#   dev / test  → noreply@hackersbychoice.dk  (one.com)
#   staging     → Mailtrap *sandbox* ONLY — real prod member data lives here
#                 (ADR-002); it must NEVER deliver to a real inbox.
#   prod        → noreply@byvaerkstederne.dk  (chosting, separate account)
# This script therefore pushes each tier's OWN local file to that same
# tier. The source path is derived from the tier's host, so one tier's
# credentials can never land on another. The promotion no-sync invariant
# (email.yaml must never cross tiers) is preserved.
#
# Grav reads per-tier config from user/env/<HOST>/ (it resolves the
# environment from the request hostname), so the file is pushed under the
# canonical host dir, matching deploy.sh's ENV_HOST. The target tier must
# already have been deployed with that host-named layout (the env-dir fix):
# the script refuses if the live release has no host-named email.yaml
# symlink, telling you to `make deploy tier=<tier>` first.
#
# SECRETS — the file content (incl. the SMTP password) is NEVER printed.
# Local/remote are compared by sha256 only; the summary shows server / port
# / user, never the password.
#
# USAGE
# -----
#   ./deploy/push-email.sh <tier|all> [options]
#
# Tiers: dev | test | staging | prod | all
#   all  → dev, test, staging (and prod ONLY with --i-mean-it). Tiers with
#          no local email.yaml are skipped with a notice.
#
# Options:
#   --yes, -y        Skip the confirmation prompt.
#   --dry-run, -n    Show what would change (no secret content) and exit.
#   --i-mean-it      Required to push prod, and to push staging with a
#                    non-sandbox (real-delivery) SMTP server.
#   --help, -h       Show this help.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

# Canonical host per tier — MUST match deploy.sh's ENV_HOST (= ENV_URL host).
tier_host() {
    case "$1" in
        dev)     echo "dev.hackersbychoice.dk" ;;
        test)    echo "test.hackersbychoice.dk" ;;
        staging) echo "staging.hackersbychoice.dk" ;;
        prod)    echo "www.byvaerkstederne.dk" ;;
        *) return 1 ;;
    esac
}

tier_url() {
    case "$1" in
        prod) echo "https://www.byvaerkstederne.dk" ;;
        *)    echo "https://$1.hackersbychoice.dk" ;;
    esac
}

# ── 1. Parse args ────────────────────────────────────────────────────
SELECTOR=""
YES=0
DRY_RUN=0
I_MEAN_IT=0

for arg in "$@"; do
    case "$arg" in
        dev|test|staging|prod|all) SELECTOR="$arg" ;;
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

if [ -z "$SELECTOR" ]; then
    usage >&2
    exit 1
fi

# Expand the selector into the candidate tier list. `all` excludes prod
# unless --i-mean-it (prod is a separate account and a real-delivery tier).
if [ "$SELECTOR" = "all" ]; then
    CANDIDATES=(dev test staging)
    if [ "$I_MEAN_IT" = "1" ]; then
        CANDIDATES+=(prod)
    else
        echo "ℹ  'all' covers dev/test/staging; prod is excluded (re-run with --i-mean-it to include it)."
    fi
else
    CANDIDATES=("$SELECTOR")
fi

# prod ALWAYS requires --i-mean-it (whether selected explicitly or via all) —
# separate chosting account, and the only tier that delivers to real members.
for _t in "${CANDIDATES[@]}"; do
    if [ "$_t" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
        echo "❌  Refusing to push prod without --i-mean-it." >&2
        echo "    Prod is a separate (chosting) account and the only tier that delivers" >&2
        echo "    to real members. Re-run with --i-mean-it if you mean it." >&2
        exit 1
    fi
done

# ── 2. Local validation + per-tier safety (NO SSH yet) ───────────────
# Build PUSH_TIERS[] from the candidates whose local email.yaml exists and
# passes the tier's safety rules. Everything that can fail offline fails
# here, before any credentials are loaded or any server is contacted.
PUSH_TIERS=()
SKIPPED_LOCAL=()

is_placeholder() {
    # The provisioning template / our generated stub carry these markers.
    grep -qE 'PUT_THE_REAL_|REPLACE_WITH_' "$1"
}

for tier in "${CANDIDATES[@]}"; do
    host="$(tier_host "$tier")"
    local_file="$PROJECT_DIR/config/www/user/env/$host/config/plugins/email.yaml"

    if [ ! -f "$local_file" ]; then
        echo "→ $tier: no local email.yaml ($host) — skipping."
        SKIPPED_LOCAL+=("$tier(no-file)")
        continue
    fi
    if is_placeholder "$local_file"; then
        echo "→ $tier: email.yaml still has a placeholder credential — skipping." >&2
        SKIPPED_LOCAL+=("$tier(placeholder)")
        continue
    fi

    server="$(sed -n 's/^[[:space:]]*server:[[:space:]]*//p' "$local_file" | tr -d "'\"" | head -1)"

    # staging MUST NOT deliver to real inboxes (ADR-002 — real prod member
    # data lives there). Only a captured sandbox (Mailtrap) is allowed unless
    # the operator explicitly overrides. Skip (don't abort the whole run) so
    # `all` still pushes the valid tiers.
    if [ "$tier" = "staging" ] && ! printf '%s' "$server" | grep -qi 'mailtrap'; then
        if [ "$I_MEAN_IT" != "1" ]; then
            echo "→ staging: server '$server' is not a Mailtrap sandbox — skipping." >&2
            echo "    Staging carries real prod member data (ADR-002) and must never deliver" >&2
            echo "    to real inboxes. Use a Mailtrap sandbox, or pass --i-mean-it to override." >&2
            SKIPPED_LOCAL+=("staging(non-sandbox)")
            continue
        fi
        echo "⚠  staging: pushing a non-sandbox server '$server' under --i-mean-it."
    fi

    # prod sanity: its identity must be the byvaerkstederne sending domain,
    # not a hackersbychoice (dev/test/staging) credential pasted by mistake.
    if [ "$tier" = "prod" ] && grep -qi 'hackersbychoice' "$local_file"; then
        echo "→ prod: email.yaml references 'hackersbychoice' (non-prod credential) — skipping." >&2
        echo "    Prod sends as noreply@byvaerkstederne.dk via chosting." >&2
        SKIPPED_LOCAL+=("prod(wrong-identity)")
        continue
    fi

    PUSH_TIERS+=("$tier")
done

if [ ${#PUSH_TIERS[@]} -eq 0 ]; then
    echo ""
    echo "✓ Nothing to push — no tier has a pushable email.yaml."
    [ ${#SKIPPED_LOCAL[@]} -gt 0 ] && echo "  skipped: ${SKIPPED_LOCAL[*]}"
    exit 0
fi

echo ""
echo "Tiers to push: ${PUSH_TIERS[*]}"

# ── 3. Confirm (once, before any push) ───────────────────────────────
if [ "$DRY_RUN" != "1" ] && [ "$YES" != "1" ]; then
    printf "Push per-tier email.yaml to: %s ? [y/N] " "${PUSH_TIERS[*]}"
    read -r ans
    case "$ans" in
        y|Y|yes|YES) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

# ── 4. Load credentials ──────────────────────────────────────────────
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
# Provides bv_php_remote_bin — prod's shell PHP is the system default
# (8.4), not the version its domain is served with (8.5).
. "$SCRIPT_DIR/lib/php-parity.sh"
PHP_BIN="$(bv_php_remote_bin "${TIER:-${ENV:-}}" "$PROJECT_DIR")"

# ── 5. Per-tier push ─────────────────────────────────────────────────
FAILED=()
PUSHED=()
SKIPPED=()

for tier in "${PUSH_TIERS[@]}"; do
    host="$(tier_host "$tier")"
    local_file="$PROJECT_DIR/config/www/user/env/$host/config/plugins/email.yaml"

    echo ""
    echo "════════════════════════════════════════"
    echo "→ push-email: $tier ($host)"

    # Resolve SSH credentials for this tier (prod is a separate account).
    export TIER="$tier"
    if [ "$tier" = "prod" ]; then
        : "${DEPLOY_PROD_HOST:?prod push-email requires DEPLOY_PROD_HOST in .env.deploy}"
        : "${DEPLOY_PROD_USER:?prod push-email requires DEPLOY_PROD_USER in .env.deploy}"
        : "${DEPLOY_PROD_PATH:?prod push-email requires DEPLOY_PROD_PATH in .env.deploy}"
        host_ssh="$DEPLOY_PROD_HOST"
        user_ssh="$DEPLOY_PROD_USER"
        port_ssh="${DEPLOY_PROD_PORT:-${DEPLOY_PORT:-22}}"
        path_ssh="$DEPLOY_PROD_PATH"
    else
        : "${DEPLOY_HOST:?missing DEPLOY_HOST in .env.deploy}"
        : "${DEPLOY_USER:?missing DEPLOY_USER in .env.deploy}"
        : "${DEPLOY_PATH:?missing DEPLOY_PATH in .env.deploy}"
        : "${DEPLOY_PORT:?missing DEPLOY_PORT in .env.deploy}"
        host_ssh="$DEPLOY_HOST"
        user_ssh="$DEPLOY_USER"
        port_ssh="$DEPLOY_PORT"
        path_ssh="$DEPLOY_PATH"
    fi
    export DEPLOY_PASS
    DEPLOY_PASS="$(bv_resolve_ssh_password)"

    tier_dir="$path_ssh/$tier"
    data_root="$path_ssh/${tier}data"
    link="$tier_dir/user/env/$host/config/plugins/email.yaml"

    # Preflight: the live release must carry the host-named email.yaml
    # symlink (i.e. the tier was deployed with the env-dir layout). Resolve
    # the live data-version dir so we write to exactly what the release reads.
    echo "→ preflight: $user_ssh@$host_ssh"
    pf="$(bv_ssh_cmd -p "$port_ssh" "$user_ssh@$host_ssh" "
        if [ ! -e \"$tier_dir\" ]; then echo NOTIER; exit 0; fi
        CUR=\"\$(readlink \"$data_root/current\" 2>/dev/null || echo v0)\"; CUR=\"\$(basename \"\$CUR\")\"
        case \"\$CUR\" in ''|*/*|*..*) echo BADVDIR; exit 0;; esac
        if [ ! -L \"$link\" ]; then echo NOLINK; exit 0; fi
        echo \"OK:\$CUR\"
    " 2>/dev/null || echo "SSHFAIL")"

    case "$pf" in
        OK:*) vdir="${pf#OK:}" ;;
        NOTIER)
            echo "✗ $tier: $tier_dir does not exist — deploy the tier first (make deploy tier=$tier)." >&2
            FAILED+=("$tier"); continue ;;
        NOLINK)
            echo "✗ $tier: no host-named email.yaml symlink in the live release." >&2
            echo "    Deploy the env-dir layout first: make deploy tier=$tier" >&2
            FAILED+=("$tier"); continue ;;
        BADVDIR)
            echo "✗ $tier: unsafe data-version dir resolved on remote." >&2
            FAILED+=("$tier"); continue ;;
        *)
            echo "✗ $tier: SSH preflight failed (auth / host / network)." >&2
            FAILED+=("$tier"); continue ;;
    esac

    target="$data_root/$vdir/user/env/$host/config/plugins/email.yaml"

    # Compare by hash — never transmit or print the content for diffing.
    local_sha="$(shasum -a 256 "$local_file" | cut -d' ' -f1)"
    remote_sha="$(bv_ssh_cmd -p "$port_ssh" "$user_ssh@$host_ssh" \
        "sha256sum \"$target\" 2>/dev/null | cut -d' ' -f1" 2>/dev/null || true)"

    # Non-secret summary only (server / port / user — never password).
    echo "  target: $user_ssh@$host_ssh:$target"
    sed -n -e 's/^[[:space:]]*\(server\|port\|user\|encryption\):.*/  local  \0/p' "$local_file"

    if [ -n "$remote_sha" ] && [ "$remote_sha" = "$local_sha" ]; then
        echo "  (identical on $tier — no-op)"
        SKIPPED+=("$tier"); continue
    elif [ -z "$remote_sha" ]; then
        echo "  (remote email.yaml missing — push will create it)"
    else
        echo "  (remote email.yaml differs — push will overwrite it)"
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo "  dry-run: not pushed"
        continue
    fi

    # Push: ensure the target dir exists, then rsync the single file.
    bv_ssh_cmd -p "$port_ssh" "$user_ssh@$host_ssh" \
        "mkdir -p \"$(dirname "$target")\""
    _rsync_e="$(bv_rsync_ssh_e "$port_ssh")" \
        || { echo "✗ $tier: could not build rsync ssh-cmd (sshpass missing?)" >&2; FAILED+=("$tier"); continue; }
    if ! bv_rsync_via_ssh -a --exclude='.DS_Store' -e "$_rsync_e" \
            "$local_file" \
            "$user_ssh@$host_ssh:$target"; then
        echo "✗ $tier: rsync failed" >&2
        FAILED+=("$tier"); continue
    fi

    echo "→ clearing Grav cache on $tier"
    if ! bv_ssh_cmd -p "$port_ssh" "$user_ssh@$host_ssh" \
            "cd \"$tier_dir\" && $PHP_BIN bin/grav clearcache" >/dev/null 2>&1; then
        echo "⚠  $tier: cache clear failed — file is pushed; Grav auto-cache rolls over shortly." >&2
    fi
    echo "✓ $tier: email.yaml pushed"
    PUSHED+=("$tier")
done

# ── 6. Summary ───────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
if [ "$DRY_RUN" = "1" ]; then
    echo "  dry-run complete; no changes made"
else
    echo "  pushed:  ${PUSHED[*]:-<none>}"
    echo "  no-op:   ${SKIPPED[*]:-<none>}"
    echo "  failed:  ${FAILED[*]:-<none>}"
fi
[ ${#SKIPPED_LOCAL[@]} -gt 0 ] && echo "  skipped (local guard): ${SKIPPED_LOCAL[*]}"
echo "─────────────────────────────────────"

[ ${#FAILED[@]} -eq 0 ]
