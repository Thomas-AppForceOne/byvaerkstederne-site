#!/usr/bin/env bash
# Resolve a PATH-driven bash so /opt/homebrew/bin (Homebrew bash 5+)
# is picked up. /bin/bash on macOS is bash 3.2, which fails to parse
# nested-quoting inside $(...) constructs that the lib uses.
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

# Hard requirement: bash 4+. The atomic-release lib uses constructs
# (nested $(...) with single-quotes inside double-quotes) that bash 3.2
# fails to parse. Surface this as a readable diagnostic rather than a
# cryptic "syntax error near unexpected token `('".
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "❌  bash 4+ required (this is bash ${BASH_VERSION:-?}). On macOS:" >&2
    echo "      brew install bash" >&2
    echo "    Then ensure /opt/homebrew/bin is on PATH ahead of /usr/bin." >&2
    exit 1
fi

# =============================================================================
# Byværkstederne — Deploy to one.com shared hosting
# Usage: ./deploy/deploy.sh [environment]
#   Environments: landing, dev, test, staging, prod
# =============================================================================
#
# Topology (canonical hostnames):
#   landing → hackersbychoice.dk          (apex docroot — non-prod selector page)
#   dev     → dev.hackersbychoice.dk      (folder /dev under apex)
#   test    → test.hackersbychoice.dk     (folder /test under apex)
#   staging → staging.hackersbychoice.dk  (folder /staging under apex)
#   prod    → www.byvaerkstederne.dk      (separate hosting account, gated)
#
# Deploy model:
#   * Grav tiers (dev, test, staging, prod) — atomic-release model.
#     Code lives in <tier>-releases/<release-id>/, mutable state lives
#     in <tier>data/v0/, the docroot is a single <tier> symlink that
#     swaps atomically via `ln -sfn`. The April 2026 / May 2026 wipe
#     class is structurally impossible: the rsync target is, by
#     construction, a fresh empty release dir, and the live state is
#     never in the rsync's path tree.
#   * Apex landing — legacy in-place rsync flow. Landing has no
#     mutable state and no rollback story to preserve, so the atomic-
#     release machinery is overkill there.
#
# All four hackersbychoice.dk surfaces (landing + three Grav installs)
# live on a single one.com account; production lives elsewhere.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STAGING_DIR="$PROJECT_DIR/deploy/staging"
GRAV_VERSION="1.7.52"
GRAV_ZIP="$PROJECT_DIR/deploy/grav-admin-v${GRAV_VERSION}.zip"
GRAV_URL="https://github.com/getgrav/grav/releases/download/${GRAV_VERSION}/grav-admin-v${GRAV_VERSION}.zip"

# shellcheck source=deploy/lib/atomic-release.sh
. "$SCRIPT_DIR/lib/atomic-release.sh"

# Require GNU coreutils for ms-resolution swap_duration_ms timing.
# Fail loud BEFORE we touch any path or read .env.deploy. macOS needs
# `brew install coreutils` (the script's PATH prepend brings in
# /opt/homebrew/bin where it lives).
bv_require_ms_timing

# Argument parsing — accept --dry-run as a flag in any position; the
# remaining positional arg is the env. DEPLOY_DRY_RUN=1 in the
# environment is also honoured.
DRY_RUN="${DEPLOY_DRY_RUN:-0}"
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --dry-run|--staging-only)
            DRY_RUN=1
            ;;
        *)
            POSITIONAL+=("$arg")
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

# =============================================================================
# Step 0 — Tier-name validation (closed set, before any path concat)
# =============================================================================
#
# The env arg is the only operator-controlled string that becomes a
# path component (in DEPLOY_TARGET, in <tier>-releases/, in symlink
# targets). Validate it against the closed set BEFORE using it
# anywhere — defence in depth against argument injection / path
# traversal even if every later quote is correct.

ENV_RAW="${1:-landing}"
if ! ENV="$(bv_validate_tier_name "$ENV_RAW")"; then
    echo "    Usage: $0 [landing|dev|test|staging|prod]" >&2
    exit 1
fi

case "$ENV" in
    prod)
        ENV_LABEL="Production"
        ENV_SUBFOLDER=""
        ENV_URL="https://www.byvaerkstederne.dk"
        ENV_KIND="grav"
        ;;
    staging)
        ENV_LABEL="Staging"
        ENV_SUBFOLDER="/staging"
        ENV_URL="https://staging.hackersbychoice.dk"
        ENV_KIND="grav"
        ;;
    test)
        ENV_LABEL="Test"
        ENV_SUBFOLDER="/test"
        ENV_URL="https://test.hackersbychoice.dk"
        ENV_KIND="grav"
        ;;
    dev)
        ENV_LABEL="Development"
        ENV_SUBFOLDER="/dev"
        ENV_URL="https://dev.hackersbychoice.dk"
        ENV_KIND="grav"
        ;;
    landing)
        ENV_LABEL="Landing"
        ENV_SUBFOLDER=""
        ENV_URL="https://hackersbychoice.dk"
        ENV_KIND="landing"
        ;;
esac

# Load credentials. Skipped under --dry-run.
ENV_FILE="$PROJECT_DIR/.env.deploy"
if [ "$DRY_RUN" != "1" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌  Missing .env.deploy — copy .env.deploy.example and fill in credentials"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    # Resolve the SSH password — env var DEPLOY_PASS (or DEPLOY_PROD_PASS
    # for prod), or DEPLOY_PASS_KEYCHAIN / DEPLOY_PROD_PASS_KEYCHAIN
    # holding the macOS Keychain item name. backup.sh and restore.sh
    # already go through bv_ssh_cmd (lib/ssh-auth.sh) which supports
    # Keychain; bv_remote_run (lib/atomic-release.sh) reads DEPLOY_PASS
    # directly. Resolve once here into the legacy env var so both code
    # paths see a populated value.
    # shellcheck source=deploy/lib/ssh-auth.sh
    . "$SCRIPT_DIR/lib/ssh-auth.sh"
    TIER="$ENV"
    if [ "$ENV" = "prod" ]; then
        DEPLOY_PROD_PASS="$(bv_resolve_ssh_password)"
    else
        DEPLOY_PASS="$(bv_resolve_ssh_password)"
    fi
fi

# Production lives on a separate hosting account; gate prod behind its
# own credential set.
if [ "$DRY_RUN" != "1" ] && [ "$ENV" = "prod" ]; then
    : "${DEPLOY_PROD_HOST:?prod deploy requires DEPLOY_PROD_HOST in .env.deploy — production is on a separate hosting account from staging/test/dev. Populate DEPLOY_PROD_HOST/USER/PASS/PORT/PATH there.}"
    : "${DEPLOY_PROD_USER:?prod deploy requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PASS:?prod deploy requires DEPLOY_PROD_PASS in .env.deploy or DEPLOY_PROD_PASS_KEYCHAIN naming the Keychain item}"
    : "${DEPLOY_PROD_PATH:?prod deploy requires DEPLOY_PROD_PATH in .env.deploy}"
    DEPLOY_HOST="$DEPLOY_PROD_HOST"
    DEPLOY_USER="$DEPLOY_PROD_USER"
    DEPLOY_PASS="$DEPLOY_PROD_PASS"
    DEPLOY_PORT="${DEPLOY_PROD_PORT:-${DEPLOY_PORT}}"
    DEPLOY_PATH="$DEPLOY_PROD_PATH"
fi

DEPLOY_TARGET="${DEPLOY_PATH:-}${ENV_SUBFOLDER}"

# =============================================================================
# Capture deploy metadata (used for version.json on every tier).
# =============================================================================

# 1. Verify the working tree is a real git repository.
if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "❌  Cannot compute build number: \$PROJECT_DIR is not a git repository." >&2
    echo "    deploy.sh must be run from inside the project's git checkout." >&2
    exit 1
fi

# 2. Shallow-clone guard.
IS_SHALLOW="$(git -C "$PROJECT_DIR" rev-parse --is-shallow-repository 2>/dev/null || echo unknown)"
if [ "$IS_SHALLOW" != "false" ]; then
    echo "❌  Refusing to deploy from a shallow clone." >&2
    echo "    git rev-parse --is-shallow-repository returned: '$IS_SHALLOW'" >&2
    echo "    Re-clone with full history (no --depth) and try again." >&2
    exit 1
fi

# 3. Compute build number EXACTLY ONCE.
if ! BUILD="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null)"; then
    echo "❌  git rev-list --count HEAD failed in the project tree." >&2
    exit 1
fi
if ! printf '%s' "$BUILD" | grep -Eq '^[0-9]+$'; then
    echo "❌  git rev-list --count HEAD returned an unexpected value." >&2
    exit 1
fi

# 4. Pick the component-scoped VERSION file based on env kind.
if [ "$ENV_KIND" = "landing" ]; then
    VERSION_SRC="$PROJECT_DIR/apex/VERSION"
else
    VERSION_SRC="$PROJECT_DIR/config/www/VERSION"
fi

VERSION="$(cat "$VERSION_SRC" 2>/dev/null | tr -d '[:space:]')"
VERSION="${VERSION:-unknown}"

GIT_SHA="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_SHA_FULL="$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%MZ)"
DEPLOYED_AT_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DEPLOYED_BY="$(git -C "$PROJECT_DIR" config user.email 2>/dev/null || echo unknown)"

# Audit context for the full release-meta schema.
DEPLOYED_FROM_HOST="$(hostname 2>/dev/null || echo unknown)"
DEPLOYED_FROM_CWD="$PROJECT_DIR"
# is_dirty is a YAML boolean — check working tree for unstaged changes
# AND staged-but-uncommitted, i.e. anything `git status --porcelain`
# emits.
if [ -z "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)" ]; then
    DEPLOYED_IS_DIRTY="false"
else
    DEPLOYED_IS_DIRTY="true"
fi

# Compute the release id once. It's used as a path component on the
# remote, so we validate it through the strict regex BEFORE using it.
RELEASE_ID="$(bv_compute_release_id "$GIT_SHA")"
# Operator-supplied override (used by the shell-level test fixture to
# force a collision with a pre-existing release dir).
if [ -n "${BV_FORCE_RELEASE_ID:-}" ]; then
    RELEASE_ID="$BV_FORCE_RELEASE_ID"
fi
if ! bv_validate_release_id "$RELEASE_ID"; then
    echo "❌  Refusing to use computed release id '$RELEASE_ID' as a path component." >&2
    exit 1
fi

draw_banner() {
    local lines=("$@") line max=0 w pad inner border
    _w() { printf '%s' "$1" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' '; }
    for line in "${lines[@]}"; do
        w=$(_w "$line")
        [ "$w" -gt "$max" ] && max="$w"
    done
    inner=$((max + 4))
    border=$(printf '═%.0s' $(seq 1 "$inner"))
    echo ""
    echo "  ╔${border}╗"
    for line in "${lines[@]}"; do
        w=$(_w "$line")
        pad=$((max - w))
        printf "  ║  %s%*s  ║\n" "$line" "$pad" ""
    done
    echo "  ╚${border}╝"
    echo ""
}

draw_banner \
    "Byværkstederne — Deploy" \
    "Environment: ${ENV_LABEL}" \
    "Target: ${DEPLOY_TARGET}" \
    "Release: ${RELEASE_ID}"

# ── Step 1: Build deploy package ────────────────────────────
if [ "$ENV_KIND" = "grav" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "→ Step 1/8: (dry-run — skipping Grav core download/extract)"
        echo "→ Step 2/8: Building deploy package (dry-run, no Grav core)..."
        rm -rf "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"
    else
        echo "→ Step 1/8: Grav core..."
        if [ -f "$GRAV_ZIP" ]; then
            echo "  ✓ Cached (v${GRAV_VERSION})"
        else
            echo "  Downloading Grav v${GRAV_VERSION}..."
            GRAV_TMP="${GRAV_ZIP}.tmp.$$"
            if ! curl -fL --retry 2 -o "$GRAV_TMP" "$GRAV_URL"; then
                rm -f "$GRAV_TMP"
                echo "  ✗ Failed to download $GRAV_URL — check GRAV_VERSION (currently '$GRAV_VERSION') against https://github.com/getgrav/grav/releases" >&2
                exit 1
            fi
            if ! unzip -tq "$GRAV_TMP" >/dev/null 2>&1; then
                rm -f "$GRAV_TMP"
                echo "  ✗ Downloaded file is not a valid zip — refusing to cache" >&2
                exit 1
            fi
            mv "$GRAV_TMP" "$GRAV_ZIP"
            echo "  ✓ Downloaded"
        fi

        echo "→ Step 2/8: Building deploy package..."
        rm -rf "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"

        unzip -q "$GRAV_ZIP" -d "$STAGING_DIR"
        cp -a "$STAGING_DIR"/grav-admin/. "$STAGING_DIR"/
        rm -rf "$STAGING_DIR/grav-admin"
    fi

    rm -rf "$STAGING_DIR/user/pages" "$STAGING_DIR/user/themes/quark" 2>/dev/null

    rsync -a --exclude='.DS_Store' \
        "$PROJECT_DIR/config/www/user/" \
        "$STAGING_DIR/user/"

    cat > "$STAGING_DIR/.htaccess" << 'HTACCESS'
# Grav CMS .htaccess for one.com shared hosting (Varnish → Apache).

SetEnvIf X-Forwarded-Proto https HTTPS=on

<IfModule mod_rewrite.c>
    RewriteEngine On

    RewriteCond %{HTTP:X-Forwarded-Proto} !=https
    RewriteCond %{HTTPS} !=on
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]

    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteCond %{REQUEST_FILENAME} !-d
    RewriteRule ^(.*)$ index.php [QSA,L]
</IfModule>

<IfModule mod_headers.c>
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
HTACCESS

    if [ "$ENV" != "prod" ]; then
        cat >> "$STAGING_DIR/.htaccess" << 'NOINDEX'
    Header always set X-Robots-Tag "noindex, nofollow, noarchive"
NOINDEX
    fi

    cat >> "$STAGING_DIR/.htaccess" << 'HTACCESS_REST'
</IfModule>

<FilesMatch "(^\.git|\.yaml$|\.md$|\.twig$)">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
</FilesMatch>

<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType image/svg+xml "access plus 1 month"
    ExpiresByType image/webp "access plus 1 month"
    ExpiresByType text/css "access plus 1 week"
    ExpiresByType application/javascript "access plus 1 week"
    ExpiresByType font/woff2 "access plus 1 month"
</IfModule>

<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/html text/css application/javascript application/json image/svg+xml
</IfModule>

<Files "version.json">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
</Files>

HTACCESS_REST

else
    # ── Landing (apex selector) — no Grav, just the apex/ folder ────
    echo "→ Step 1/4: (landing — no Grav core needed)"
    echo "→ Step 2/4: Building apex landing package..."
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    rsync -a --exclude='.DS_Store' --exclude='BUILD' \
        "$PROJECT_DIR/apex/" \
        "$STAGING_DIR/"
fi

if [ "$ENV" != "prod" ] && [ "$ENV_KIND" = "grav" ]; then
    cat > "$STAGING_DIR/robots.txt" << 'ROBOTS'
User-agent: *
Disallow: /
ROBOTS
fi

# Stage component-scoped VERSION + BUILD files.
printf '%s\n' "$VERSION" > "$STAGING_DIR/VERSION"
printf '%s\n' "$BUILD"   > "$STAGING_DIR/BUILD"

cat > "$STAGING_DIR/version.json" << JSON
{
    "tier": "${ENV}",
    "version": "${VERSION}",
    "build": "${BUILD}",
    "deployed_at": "${DEPLOYED_AT}",
    "branch": "${GIT_BRANCH}",
    "sha_short": "${GIT_SHA}"
}
JSON

echo "  ✓ Package built ($(du -sh "$STAGING_DIR" | cut -f1))"
echo "  ✓ Version: ${VERSION} · build ${BUILD}"

# =============================================================================
# Landing branch — legacy in-place rsync flow. Atomic-release machinery
# is overkill for the apex selector page.
# =============================================================================
if [ "$ENV_KIND" = "landing" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "→ Step 3/4: (dry-run — skipping upload to ${DEPLOY_HOST:-<unset>}:${DEPLOY_TARGET})"
        echo "  ✓ Staging dir ready at $STAGING_DIR"
        echo ""
        echo "  ✅  Dry-run complete — staging dir produced, no remote upload performed."
        echo "  📦  Inspect: $STAGING_DIR"
        echo ""
        exit 0
    fi

    echo "→ Step 3/4: Uploading apex (landing) to ${DEPLOY_HOST}:${DEPLOY_TARGET}..."

    sshpass -p "$DEPLOY_PASS" ssh -o StrictHostKeyChecking=no -p "$DEPLOY_PORT" \
        "${DEPLOY_USER}@${DEPLOY_HOST}" \
        "mkdir -p ${DEPLOY_TARGET}"

    # Apex docroot has no Grav state to preserve, but we still
    # exclude sibling-tier subfolders so a landing rsync can never
    # accidentally clobber the Grav tiers' release dirs / data dirs.
    # The leading slash pins these to the rsync root.
    RSYNC_FLAGS=(
        -az --delete --max-delete=25
        --info=progress2,stats0
        --exclude='.DS_Store'
        --exclude='/dev/'
        --exclude='/test/'
        --exclude='/staging/'
        --exclude='/dev-releases/'
        --exclude='/test-releases/'
        --exclude='/staging-releases/'
        --exclude='/proddata/'
        --exclude='/devdata/'
        --exclude='/testdata/'
        --exclude='/stagingdata/'
    )

    sshpass -p "$DEPLOY_PASS" rsync "${RSYNC_FLAGS[@]}" \
        -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
        "$STAGING_DIR/" \
        "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_TARGET}/"

    echo "  ✓ Upload complete"
    echo ""
    echo "  ✅  Landing deploy complete!"
    echo "  🌐  ${ENV_URL}"
    echo ""
    exit 0
fi

# =============================================================================
# Grav-tier branch — atomic-release model.
# =============================================================================
#
# Sequence (mirrors §Deploy command in
# specifications/atomic_deploy_releases_specification.md):
#
#   3. Pre-flight checks (ssh, parent writable, existing <tier>
#      symlink resolves or absent, <tier>data/v0/ exists or first run)
#   4. rsync to fresh <tier>-releases/<release-id>/  (--max-delete=0)
#   5. Wire symlinks per §Symlink contract (relative targets only)
#   6. Write release-meta.yaml (basic shape; full audit polish
#      lands Sprint 2)
#   7. Cache clear in the new release (fail-loud; aborts before swap)
#   8. Atomic ln -sfn swap of <tier>
#   (Sprint 2 will add: post-swap smoke probe + rollback hint)
#   (Sprint 1 ships: retention pruner runs after the swap)
#
# Live-state (<tier>data/, accounts/, user/data/, logs/) is NEVER in
# the rsync source tree, NEVER in the rsync destination tree, NEVER
# rm-targeted, and NEVER symlink-rewritten. The only writes into
# <tier>data/ are the bootstrap step's mkdir -p of empty directories
# the first time we deploy to a fresh tier.

if [ "$DRY_RUN" = "1" ]; then
    echo "→ Step 3/8: (dry-run — skipping remote pre-flight)"
    echo "  ✓ Staging dir ready at $STAGING_DIR"
    echo "  ✓ Release id: $RELEASE_ID"
    echo ""
    echo "  ✅  Dry-run complete — staging dir produced, no remote upload performed."
    echo "  📦  Inspect: $STAGING_DIR"
    echo ""
    exit 0
fi

# Compose tier-scoped paths on the remote. DEPLOY_TARGET is the
# legacy in-place docroot; for the atomic layout we keep the same
# docroot path (it becomes a symlink) and place sibling
# <tier>-releases/ and <tier>data/ next to it.
#
# Layout on remote (assuming DEPLOY_TARGET=/dev under DEPLOY_PATH):
#   <DEPLOY_PATH>/dev                       → symlink → dev-releases/<id>
#   <DEPLOY_PATH>/dev-releases/<id>/        → real dir (this deploy's release)
#   <DEPLOY_PATH>/devdata/v0/...            → mutable state, sibling of -releases/
#
# For prod, DEPLOY_TARGET is the docroot itself (DEPLOY_PATH/, no
# subfolder). We synthesise a tier-scoped layout under a sibling
# `prod-releases/` and `proddata/` of the docroot.
DEPLOY_DOCROOT_PARENT="$(dirname "$DEPLOY_TARGET")"
DEPLOY_DOCROOT_NAME="$(basename "$DEPLOY_TARGET")"
# For prod where ENV_SUBFOLDER is empty, DEPLOY_TARGET == DEPLOY_PATH
# and the docroot's basename is whatever DEPLOY_PATH ends in. Use
# "prod" as the layout-name in that case so siblings are consistently
# named `prod-releases/` and `proddata/`.
if [ -z "$ENV_SUBFOLDER" ]; then
    LAYOUT_NAME="$ENV"
else
    LAYOUT_NAME="$DEPLOY_DOCROOT_NAME"
fi
RELEASES_DIR="${DEPLOY_DOCROOT_PARENT}/${LAYOUT_NAME}-releases"
DATA_DIR="${DEPLOY_DOCROOT_PARENT}/${LAYOUT_NAME}data"
RELEASE_DIR="${RELEASES_DIR}/${RELEASE_ID}"

# Remote dispatch goes through bv_remote_run (defined in
# deploy/lib/atomic-release.sh) — values flow as printf %q-quoted
# remote-side env exports, never via direct shell-string interpolation.
# See the helper's docblock for the security rationale.

# ── Step 3: Pre-flight checks (remote) ────────────────────────────────
echo "→ Step 3/8: Pre-flight checks on ${DEPLOY_HOST}..."

# 3a. ssh works.
if ! bv_remote_run 'true'; then
    echo "❌  ssh to ${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PORT} failed." >&2
    exit 1
fi

# 3b. parent of <tier>-releases/ is writable.
if ! bv_remote_run '
    test -w "$PARENT" || mkdir -p "$RELEASES" "$DATA"
' \
    PARENT="$DEPLOY_DOCROOT_PARENT" \
    RELEASES="$RELEASES_DIR" \
    DATA="$DATA_DIR"; then
    echo "❌  Parent dir ${DEPLOY_DOCROOT_PARENT} not writable on remote." >&2
    exit 1
fi

# 3c. release-id collision check. Refuse to overwrite an existing
# release dir on the remote.
if bv_remote_run '
    test -e "$RELEASE_DIR"
' RELEASE_DIR="$RELEASE_DIR"; then
    echo "❌  Release dir already exists on remote: ${RELEASE_DIR}" >&2
    echo "    Refusing to overwrite. Pick a new release id or remove the existing dir." >&2
    exit 1
fi

# 3d. existing <tier> symlink resolves, or doesn't exist (first
# deploy). A bare directory at the docroot location means a tier in
# the legacy in-place layout — refuse and direct the operator to the
# migration script (Sprint 3).
DOCROOT_STATE="$(bv_remote_run '
    if [ -L "$DEPLOY_TARGET" ]; then
        echo symlink
    elif [ -d "$DEPLOY_TARGET" ]; then
        echo dir
    elif [ -e "$DEPLOY_TARGET" ]; then
        echo other
    else
        echo absent
    fi
' DEPLOY_TARGET="$DEPLOY_TARGET")"
case "$DOCROOT_STATE" in
    symlink|absent)
        : # OK
        ;;
    dir)
        echo "❌  Docroot ${DEPLOY_TARGET} is a real directory, not a symlink." >&2
        echo "    This tier is still in the legacy in-place layout." >&2
        echo "    Run deploy/migrate-to-atomic-layout.sh ${ENV} (Sprint 3) first." >&2
        exit 1
        ;;
    *)
        echo "❌  Docroot ${DEPLOY_TARGET} is in an unexpected state: ${DOCROOT_STATE}" >&2
        exit 1
        ;;
esac

# 3e. bootstrap <tier>data/v0/ on first run.
# Remote env var is named DEPLOY_ENV, not ENV — bv_remote_run's denylist
# forbids ENV (POSIX bash reads its rc from $ENV; setting it on the
# remote side is a footgun).
bv_remote_run '
    mkdir -p "$DATA/v0/user/accounts" \
             "$DATA/v0/user/data" \
             "$DATA/v0/user/config" \
             "$DATA/v0/user/env/$DEPLOY_ENV/config" \
             "$DATA/logs"
    if [ ! -e "$DATA/current" ] || [ -L "$DATA/current" ]; then
        ln -sfn v0 "$DATA/current"
    fi
' DATA="$DATA_DIR" DEPLOY_ENV="$ENV"

# 3f. read previous release id (target of existing <tier> symlink), if any.
PREV_RELEASE_ID=""
if [ "$DOCROOT_STATE" = "symlink" ]; then
    PREV_TARGET="$(bv_remote_run 'readlink "$DEPLOY_TARGET"' DEPLOY_TARGET="$DEPLOY_TARGET" 2>/dev/null || echo "")"
    PREV_RELEASE_ID="$(basename "$PREV_TARGET")"
    if [ -n "$PREV_RELEASE_ID" ] && ! bv_validate_release_id "$PREV_RELEASE_ID" 2>/dev/null; then
        echo "  ⚠️  existing <tier> symlink target '${PREV_RELEASE_ID}' is not a valid release id; treating as no-previous." >&2
        PREV_RELEASE_ID=""
    fi
fi
echo "  ✓ Previous release: ${PREV_RELEASE_ID:-<none>}"
echo "  ✓ New release: ${RELEASE_ID}"

# ── Step 4: rsync to fresh release dir ────────────────────────────────
echo "→ Step 4/8: Uploading to ${DEPLOY_HOST}:${RELEASE_DIR}..."

# Make sure the release dir exists and is empty.
bv_remote_run 'mkdir -p "$RELEASE_DIR"' RELEASE_DIR="$RELEASE_DIR"

# Atomic-release rsync flag set. Note the differences from the legacy
# in-place flag set:
#
#   * --max-delete=0   — belt-and-braces; the destination is a fresh
#                        empty dir, so nothing should ever be deleted.
#                        If rsync finds anything to delete, the
#                        destination wasn't actually fresh and we
#                        bail.
#   * NO live-state excludes — the live state isn't in the staging
#                              tree at all. Excluding it here would
#                              be cargo-cult.
#   * --exclude='cache/' / 'tmp/' / 'logs/' / 'backup/' / '.DS_Store'
#     — staging may carry local-dev versions of these. Strip them.
#
# RSYNC_FLAGS_ATOMIC is named differently from the landing-branch
# RSYNC_FLAGS so the two flag sets are visibly distinct in code review.
# The exclude list comes from bv_atomic_release_excludes (the lib's
# single source of truth) so deploy.sh and the test fixture cannot
# drift on what gets stripped.
RSYNC_FLAGS_ATOMIC=(
    -az --max-delete=0
    --info=progress2,stats0
)
# Extend with the lib's exclude list (single source of truth — see
# bv_atomic_release_excludes in deploy/lib/atomic-release.sh).
while IFS= read -r _excl_line; do
    [ -n "$_excl_line" ] && RSYNC_FLAGS_ATOMIC+=("$_excl_line")
done < <(bv_atomic_release_excludes)
unset _excl_line

sshpass -p "$DEPLOY_PASS" rsync "${RSYNC_FLAGS_ATOMIC[@]}" \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "$STAGING_DIR/" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${RELEASE_DIR}/"

echo "  ✓ Upload complete"

# Create empty runtime dirs that bv_atomic_release_excludes() strips
# from the rsync source. Grav's startup-checker (Problems plugin)
# requires `cache/`, `tmp/`, and `backup/` to exist + be writable in
# the docroot, otherwise it returns HTTP 500 for every page. These
# are per-release dirs (Grav writes into them at runtime); creating
# them empty here is sufficient. The migrate-bootstrap release had
# them by accident (carried from the legacy in-place tier); fresh
# atomic releases don't, so we materialise them explicitly.
bv_remote_run '
    mkdir -p "$RELEASE_DIR/cache" \
             "$RELEASE_DIR/tmp" \
             "$RELEASE_DIR/backup"
' RELEASE_DIR="$RELEASE_DIR"

# First-deploy bootstrap of §Symlink-contract files. The rsynced
# release carries default copies of `user/config/security.yaml` and
# `user/env/<env>/config/security.yaml` (Grav defaults). The symlink-
# wiring step about to run will REPLACE those files with symlinks
# pointing at `<datadir>/v0/...`. On a fresh tier (after `rm -rf
# devdata/` disaster recovery) those data-dir copies don't exist yet,
# so the symlinks dangle and `bin/grav clearcache` fails:
#     Failed to save file .../user/config/security.yaml
# Move the rsynced defaults into the data dir so the symlinks have
# valid targets. `mv` (not `cp`) so the source goes away cleanly —
# bv_wire_release_symlinks then sees the path absent and creates the
# symlink without needing to rm anything. Idempotent on second
# deploy: the `! -f $DD/...` guard skips if data-dir already holds
# the live operator-modified copy.
bv_remote_run '
    if [ -f "$RD/user/config/security.yaml" ] && [ ! -f "$DD/v0/user/config/security.yaml" ]; then
        mv "$RD/user/config/security.yaml" "$DD/v0/user/config/security.yaml"
    fi
    if [ -f "$RD/user/env/$DEPLOY_ENV/config/security.yaml" ] && [ ! -f "$DD/v0/user/env/$DEPLOY_ENV/config/security.yaml" ]; then
        mkdir -p "$DD/v0/user/env/$DEPLOY_ENV/config"
        mv "$RD/user/env/$DEPLOY_ENV/config/security.yaml" "$DD/v0/user/env/$DEPLOY_ENV/config/security.yaml"
    fi
' RD="$RELEASE_DIR" DD="$DATA_DIR" DEPLOY_ENV="$ENV"

# ── Step 5: Wire release symlinks ─────────────────────────────────────
echo "→ Step 5/8: Wiring release symlinks (per §Symlink contract)..."

# Symlink-wiring on the remote side. Values flow as printf %q-quoted
# remote-side env exports (rd, ddn, e); the body uses them via "$rd"
# etc. so no operator-controlled metacharacter can land in the command
# line.
bv_remote_run '
    mkdir -p "$RD/user/config" "$RD/user/env/$E/config"
    for p in "$RD/user/accounts" "$RD/user/data" "$RD/user/config/security.yaml" "$RD/user/env/$E/config/security.yaml" "$RD/logs"; do
        if [ -e "$p" ] && [ ! -L "$p" ]; then rm -rf "$p"; fi
    done
    ln -sfn "../../../$DDN/v0/user/accounts"                              "$RD/user/accounts"
    ln -sfn "../../../$DDN/v0/user/data"                                  "$RD/user/data"
    ln -sfn "../../../../$DDN/v0/user/config/security.yaml"               "$RD/user/config/security.yaml"
    ln -sfn "../../../../../../$DDN/v0/user/env/$E/config/security.yaml"  "$RD/user/env/$E/config/security.yaml"
    ln -sfn "../../$DDN/logs"                                             "$RD/logs"
' \
    RD="$RELEASE_DIR" \
    DDN="${LAYOUT_NAME}data" \
    E="$ENV"

echo "  ✓ Symlinks wired"

# ── Step 6: Write release-meta.yaml (pre-swap fields) ────────────────
#
# Pre-swap field set (per §Audit + sprint-2 contract):
#   release_id, deployed_at, deployed_by, deployed_from.{host,cwd,
#   branch,sha,sha_short,is_dirty}, code_version, build, data_version,
#   previous_release, previous_data_version
#
# Post-swap fields (swapped_at, swap_duration_ms, smoke_probe.*) are
# APPENDED after step 8 + 10 below, via bv_append_post_swap_meta.
echo "→ Step 6/8: Writing release-meta.yaml (pre-swap fields)..."

# Write the YAML locally to the staging dir, then rsync that single
# file up. This keeps the YAML-emitter on the local side so it can be
# unit-tested without ssh.
META_LOCAL="$STAGING_DIR/release-meta.yaml"
bv_write_release_meta_yaml_full \
    "$STAGING_DIR" \
    "$RELEASE_ID" \
    "$PREV_RELEASE_ID" \
    "$VERSION" \
    "$BUILD" \
    "v0" \
    "$DEPLOYED_AT_ISO" \
    "$DEPLOYED_BY" \
    "$DEPLOYED_FROM_HOST" \
    "$DEPLOYED_FROM_CWD" \
    "$GIT_BRANCH" \
    "$GIT_SHA_FULL" \
    "$GIT_SHA" \
    "$DEPLOYED_IS_DIRTY" \
    "v0"

sshpass -p "$DEPLOY_PASS" rsync -a \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "$META_LOCAL" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${RELEASE_DIR}/release-meta.yaml"

echo "  ✓ release-meta.yaml (pre-swap) written"

# ── Step 7: Cache clear (fail-loud; aborts BEFORE the swap) ───────────
echo "→ Step 7/8: Clearing Grav cache in new release..."
if ! bv_remote_run '
    cd "$RELEASE_DIR" && php bin/grav clearcache
' RELEASE_DIR="$RELEASE_DIR"; then
    echo ""
    echo "❌  Cache clear failed in ${RELEASE_DIR}." >&2
    echo "    Aborting BEFORE the docroot swap — the previous release stays live." >&2
    echo "    Inspect: ssh ${DEPLOY_USER}@${DEPLOY_HOST} 'cd ${RELEASE_DIR} && php bin/grav clearcache'" >&2
    exit 1
fi
echo "  ✓ Cache cleared in new release"

# ── Step 8: Atomic ln -sfn swap of <tier> ─────────────────────────────
echo "→ Step 8/8: Atomic swap of ${DEPLOY_TARGET}..."

# Capture monotonic ms before/after the swap so we can record
# swap_duration_ms in release-meta.yaml. Falls back to 0 on systems
# whose `date` doesn't support nanoseconds (some BSDs); we never let a
# missing value spoil the deploy.
SWAP_START_MS="$(bv_now_ms)"

# Single ln -sfn invocation; no rm of the old symlink first (that
# would open a race window). ln -sfn replaces atomically.
bv_remote_run 'ln -sfn "$TARGET_REL" "$DEPLOY_TARGET"' \
    TARGET_REL="${LAYOUT_NAME}-releases/${RELEASE_ID}" \
    DEPLOY_TARGET="$DEPLOY_TARGET"

SWAP_END_MS="$(bv_now_ms)"
SWAP_DURATION_MS=$(( SWAP_END_MS - SWAP_START_MS ))
[ "$SWAP_DURATION_MS" -lt 0 ] && SWAP_DURATION_MS=0
SWAPPED_AT_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "  ✓ ${DEPLOY_TARGET} → ${LAYOUT_NAME}-releases/${RELEASE_ID}  (${SWAP_DURATION_MS} ms)"

# ── Step 9 (Sprint 2): Smoke probe — fail-loud, NO auto-rollback ──────
#
# Per the source spec's §Deploy command, step 10:
#   "If the probe fails, do not auto-rollback (operator decision);
#    print a clear 'rollback command:' hint and exit non-zero."
#
# The release stays LIVE on probe failure. Rollback is a deliberate
# operator decision invoked via `make rollback tier=<env>`. This is the
# spec-mandated behavioural contract; do not weaken it.
PROBE_URL="${BV_SMOKE_PROBE_URL_OVERRIDE:-${ENV_URL}/}"
PROBE_EXPECTED="$(bv_compute_expected_version_substring "$STAGING_DIR")"
echo "→ Smoke probe: GET ${PROBE_URL}  (expecting: ${PROBE_EXPECTED})"

PROBE_RESULT="$(bv_smoke_probe "$PROBE_URL" "$PROBE_EXPECTED" || true)"
PROBE_STATUS="${PROBE_RESULT%%|*}"
PROBE_MATCHED="${PROBE_RESULT##*|}"
case "$PROBE_STATUS" in
    ''|*[!0-9]*) PROBE_STATUS=0 ;;
esac
case "$PROBE_MATCHED" in
    true|false) ;;
    *) PROBE_MATCHED=false ;;
esac

# Append the post-swap fields to the local copy of release-meta.yaml,
# then rsync the updated file up. We deliberately re-rsync the meta
# file rather than do a live edit on the remote — the local file is
# the canonical artefact and matching the remote keeps the audit
# surface single-sourced.
bv_append_post_swap_meta \
    "$STAGING_DIR" \
    "$SWAPPED_AT_ISO" \
    "$SWAP_DURATION_MS" \
    "$PROBE_URL" \
    "$PROBE_STATUS" \
    "$PROBE_EXPECTED" \
    "$PROBE_MATCHED"

sshpass -p "$DEPLOY_PASS" rsync -a \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "$META_LOCAL" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${RELEASE_DIR}/release-meta.yaml"

if [ "$PROBE_MATCHED" != "true" ] || [ "$PROBE_STATUS" != "200" ]; then
    # Re-fetch to capture the redirected URL + body so the diagnostic
    # helper can fingerprint the failure mode. bv_smoke_probe doesn't
    # expose these signals — cheap to do a second curl, the site is
    # reachable enough to talk to.
    PROBE_DIAG_BODY="$(mktemp)"
    PROBE_FINAL_URL="$(curl -sSL --max-time 15 \
        -o "$PROBE_DIAG_BODY" \
        -w '%{url_effective}' \
        "$PROBE_URL" 2>/dev/null || echo '')"

    echo "" >&2
    echo "❌  Smoke probe FAILED for ${PROBE_URL}" >&2
    echo "    expected:  ${PROBE_EXPECTED}" >&2
    echo "    status:    ${PROBE_STATUS}" >&2
    echo "    matched:   ${PROBE_MATCHED}" >&2
    if [ -n "$PROBE_FINAL_URL" ] && [ "$PROBE_FINAL_URL" != "$PROBE_URL" ]; then
        echo "    final URL: ${PROBE_FINAL_URL}" >&2
    fi
    echo "" >&2
    bv_diagnose_probe_failure \
        "$PROBE_STATUS" \
        "$PROBE_FINAL_URL" \
        "$PROBE_DIAG_BODY" \
        "$PROBE_EXPECTED" \
        | sed 's/^/    /' >&2
    rm -f "$PROBE_DIAG_BODY"
    echo "" >&2
    echo "    The new release IS LIVE — there is NO auto-rollback." >&2
    echo "    Inspect: ${PROBE_URL}" >&2
    echo "" >&2
    echo "    rollback command:  make rollback tier=${ENV}" >&2
    echo "    (or:               ./deploy/rollback.sh ${ENV})" >&2
    echo "" >&2
    exit 1
fi

echo "  ✓ Smoke probe matched (status=${PROBE_STATUS})"

# ── Retention pruner ──────────────────────────────────────────────────
# Keep last N=5 release dirs. Two newest (current + immediate prev)
# never eligible. Inline-on-remote so no list of release ids needs to
# be shuffled across the wire.
KEEP_N="${BV_RELEASES_KEEP:-5}"
bv_remote_run '
    [ -d "$RDIR" ] || exit 0
    cd "$RDIR"
    all=$(ls -1 | sort)
    total=$(printf "%s\n" "$all" | grep -c . || true)
    if [ "$total" -le "$KEEP" ]; then exit 0; fi
    drop=$((total - KEEP))
    n=0
    for rid in $all; do
        [ "$n" -ge "$drop" ] && break
        n=$((n+1))
        case "$rid" in
            "$CUR"|"$PREV") continue ;;
        esac
        case "$rid" in
            migrate-bootstrap-*)
                # Bootstrap dirs from migrate-to-atomic-layout.sh
                # are intentionally outside the standard release-id
                # regex; skip silently rather than warn on every prune.
                continue
                ;;
        esac
        case "$rid" in
            *..*|*/*|-*) echo "  skip (suspicious id): $rid"; continue ;;
        esac
        if printf "%s" "$rid" | grep -Eq "^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$"; then
            rm -rf -- "$rid"
            echo "  pruned old release: $rid"
        else
            echo "  skip (not a release id): $rid"
        fi
    done
    echo "  data-version retention deferred to data-versioning spec"
' \
    RDIR="$RELEASES_DIR" \
    CUR="$RELEASE_ID" \
    PREV="${PREV_RELEASE_ID:-__none__}" \
    KEEP="$KEEP_N"

echo ""
echo "  ✅  Atomic deploy complete!"
echo "  🌐  ${ENV_URL}"
echo "  📦  Release: ${RELEASE_ID}"
echo "  ↩  Rollback target: ${PREV_RELEASE_ID:-<none — first deploy>}"
echo ""
