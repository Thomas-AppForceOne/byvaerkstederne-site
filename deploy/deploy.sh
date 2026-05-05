#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

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
# All four hackersbychoice.dk surfaces (landing + three Grav installs) live
# on a single one.com account. one.com maps each subdomain to its matching
# subfolder, and the apex docroot serves the landing selector page.
# Production lives elsewhere; do NOT extend this script's hackersbychoice.dk
# credentials to it.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STAGING_DIR="$PROJECT_DIR/deploy/staging"
GRAV_VERSION="1.7.49.5"
GRAV_ZIP="$PROJECT_DIR/deploy/grav-admin-v${GRAV_VERSION}.zip"
GRAV_URL="https://getgrav.org/download/core/grav-admin/${GRAV_VERSION}"

# Argument parsing — accept --dry-run as a flag in any position; the
# remaining positional arg is the env. DEPLOY_DRY_RUN=1 in the
# environment is also honoured. Dry-run produces all staging-dir
# artifacts (BUILD, VERSION, version.json, package contents) but skips
# the rsync/sshpass upload to one.com, so an operator (or test) can
# verify what *would* be deployed without needing credentials.
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

# Environment selection
ENV="${1:-landing}"
case "$ENV" in
    prod|production)
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
    *)
        echo "❌  Unknown environment: $ENV"
        echo "    Usage: $0 [landing|dev|test|staging|prod]"
        exit 1
        ;;
esac

# Load credentials. Skipped under --dry-run so artifact production
# can be verified on hosts that don't hold the deploy secrets (e.g.
# the GAN evaluator running in a worktree).
ENV_FILE="$PROJECT_DIR/.env.deploy"
if [ "$DRY_RUN" != "1" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌  Missing .env.deploy — copy .env.deploy.example and fill in credentials"
        exit 1
    fi
    source "$ENV_FILE"
fi

# Production lives on a separate hosting account from
# hackersbychoice.dk (which serves landing + staging/test/dev). Gate prod
# deploys behind its own credential set so a stray `./deploy.sh prod`
# can't overwrite anything on hackersbychoice.dk.
if [ "$DRY_RUN" != "1" ] && { [ "$ENV" = "prod" ] || [ "$ENV" = "production" ]; }; then
    : "${DEPLOY_PROD_HOST:?prod deploy requires DEPLOY_PROD_HOST in .env.deploy — production is on a separate hosting account from staging/test/dev. Populate DEPLOY_PROD_HOST/USER/PASS/PORT/PATH there.}"
    : "${DEPLOY_PROD_USER:?prod deploy requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PASS:?prod deploy requires DEPLOY_PROD_PASS in .env.deploy}"
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
#
# Two component-scoped VERSION files now live in the repo:
#
#   apex/VERSION         — version of the apex selector page
#   config/www/VERSION   — version of the Grav site
#
# Plus a single auto-generated build number derived from the commit
# being deployed. The build number is the same for every tier deployed
# from the same commit (it is a function of the commit, not of the
# deploy step). It must be computed exactly once per run, before any
# per-tier branching, so apex and grav-tier deploys of the same commit
# produce byte-identical BUILD files.
#
# `branch` and `sha_short` stay in the manifest for ops debugging —
# nothing public reads them.

# 1. Verify the working tree is a real git repository.
if ! git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    echo "❌  Cannot compute build number: \$PROJECT_DIR is not a git repository." >&2
    echo "    deploy.sh must be run from inside the project's git checkout." >&2
    exit 1
fi

# 2. Shallow-clone guard. `git rev-list --count HEAD` reports only the
#    depth the clone has, so a `git fetch --depth 1` checkout would
#    silently underreport the build number and break the cross-tier
#    stability contract. Abort with a clear error before computing.
IS_SHALLOW="$(git -C "$PROJECT_DIR" rev-parse --is-shallow-repository 2>/dev/null || echo unknown)"
if [ "$IS_SHALLOW" != "false" ]; then
    echo "❌  Refusing to deploy from a shallow clone." >&2
    echo "    git rev-parse --is-shallow-repository returned: '$IS_SHALLOW'" >&2
    echo "    The build number is computed via 'git rev-list --count HEAD'," >&2
    echo "    which underreports on shallow clones and would silently produce" >&2
    echo "    different build numbers across tiers running the same commit." >&2
    echo "    Re-clone with full history (no --depth) and try again." >&2
    exit 1
fi

# 3. Compute the build number EXACTLY ONCE. This integer is the bare
#    output of `git rev-list --count HEAD` — no env vars or
#    operator-supplied strings are interpolated into it.
if ! BUILD="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null)"; then
    echo "❌  git rev-list --count HEAD failed in the project tree." >&2
    echo "    Cannot compute build number; aborting." >&2
    exit 1
fi
# Belt-and-braces validation: BUILD must be a non-empty digit string.
if ! printf '%s' "$BUILD" | grep -Eq '^[0-9]+$'; then
    echo "❌  git rev-list --count HEAD returned an unexpected value." >&2
    echo "    Refusing to write a non-integer build number." >&2
    exit 1
fi

# 4. Pick the component-scoped VERSION file based on env kind. Apex
#    deploys label themselves with apex/VERSION; Grav-tier deploys
#    label themselves with config/www/VERSION. The repo-root VERSION
#    file has been removed.
if [ "$ENV_KIND" = "landing" ]; then
    VERSION_SRC="$PROJECT_DIR/apex/VERSION"
else
    VERSION_SRC="$PROJECT_DIR/config/www/VERSION"
fi

VERSION="$(cat "$VERSION_SRC" 2>/dev/null | tr -d '[:space:]')"
VERSION="${VERSION:-unknown}"

GIT_SHA="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
GIT_BRANCH="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DEPLOYED_AT="$(date -u +%Y-%m-%dT%H:%MZ)"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  Byværkstederne — Deploy             ║"
echo "  ║  Environment: ${ENV_LABEL}$(printf '%*s' $((20 - ${#ENV_LABEL})) '')║"
echo "  ║  Target: ${DEPLOY_TARGET}            "
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── Step 1: Build deploy package ────────────────────────────
if [ "$ENV_KIND" = "grav" ]; then
    if [ "$DRY_RUN" = "1" ]; then
        echo "→ Step 1/4: (dry-run — skipping Grav core download/extract)"
        echo "→ Step 2/4: Building deploy package (dry-run, no Grav core)..."
        rm -rf "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"
    else
        echo "→ Step 1/4: Grav core..."
        if [ -f "$GRAV_ZIP" ]; then
            echo "  ✓ Cached (v${GRAV_VERSION})"
        else
            echo "  Downloading Grav v${GRAV_VERSION}..."
            curl -L -o "$GRAV_ZIP" "$GRAV_URL"
            echo "  ✓ Downloaded"
        fi

        echo "→ Step 2/4: Building deploy package..."
        rm -rf "$STAGING_DIR"
        mkdir -p "$STAGING_DIR"

        # Extract Grav core
        unzip -q "$GRAV_ZIP" -d "$STAGING_DIR"
        cp -a "$STAGING_DIR"/grav-admin/. "$STAGING_DIR"/
        rm -rf "$STAGING_DIR/grav-admin"
    fi

    # Overlay our custom user directory (executes in both real and
    # dry-run mode so version-related staging artifacts still see the
    # right tree; non-version package contents are validated by the
    # full deploy in production).
    rm -rf "$STAGING_DIR/user/pages" "$STAGING_DIR/user/themes/quark" 2>/dev/null

    rsync -a --exclude='.DS_Store' \
        "$PROJECT_DIR/config/www/user/" \
        "$STAGING_DIR/user/"

    # NOTE: no custom_base_url injection here. The dev/ and test/ tiers
    # ship a custom_base_url override via their env profile's system.yaml
    # because one.com's subdomain-via-folder mapping confuses Grav's URI
    # auto-detection. See config/www/user/env/dev.hackersbychoice.dk/config/system.yaml.

    # Create .htaccess (Grav routing + Varnish-aware HTTPS handling)
    cat > "$STAGING_DIR/.htaccess" << 'HTACCESS'
# Grav CMS .htaccess for one.com shared hosting (Varnish → Apache).
#
# one.com terminates TLS at Varnish and forwards to Apache as plain HTTP,
# so %{HTTPS} is always 'off'. A naive `RewriteCond %{HTTPS} !=on` redirect
# loops forever (debugged on test.hackersbychoice.dk 2026-04-25). Two fixes:
#   1. Gate the force-HTTPS rule on X-Forwarded-Proto so it doesn't fire
#      when the original request was already HTTPS.
#   2. Synthesise HTTPS=on for any PHP code (Grav core, plugins) that
#      reads $_SERVER['HTTPS'] to decide URL schemes.

# Make Apache + PHP see the real scheme behind Varnish.
SetEnvIf X-Forwarded-Proto https HTTPS=on

<IfModule mod_rewrite.c>
    RewriteEngine On

    # Force HTTPS — only when the original request was actually HTTP.
    # Both conditions must pass: Varnish header AND local HTTPS var.
    RewriteCond %{HTTP:X-Forwarded-Proto} !=https
    RewriteCond %{HTTPS} !=on
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]

    # Grav routing
    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteCond %{REQUEST_FILENAME} !-d
    RewriteRule ^(.*)$ index.php [QSA,L]
</IfModule>

# Security headers
<IfModule mod_headers.c>
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
HTACCESS

    # Conditional: every non-prod tier opts out of search indexing.
    # Production does NOT (byvaerkstederne.dk wants to be findable).
    if [ "$ENV" != "prod" ] && [ "$ENV" != "production" ]; then
        cat >> "$STAGING_DIR/.htaccess" << 'NOINDEX'
    Header always set X-Robots-Tag "noindex, nofollow, noarchive"
NOINDEX
    fi

    cat >> "$STAGING_DIR/.htaccess" << 'HTACCESS_REST'
</IfModule>

# Block access to sensitive files
<FilesMatch "(^\.git|\.yaml$|\.md$|\.twig$)">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
</FilesMatch>

# Cache static assets
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

# Gzip compression
<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/html text/css application/javascript application/json image/svg+xml
</IfModule>

# Hide the version manifest from public reads — landing page reads it
# from the local filesystem, not over HTTP.
<Files "version.json">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
</Files>

# Non-prod tiers also ship a robots.txt with `Disallow: /` (defence in
# depth alongside X-Robots-Tag). Production omits both.
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

# Non-prod tiers ship a robots.txt with `Disallow: /` for crawlers that
# don't honour X-Robots-Tag.
if [ "$ENV" != "prod" ] && [ "$ENV" != "production" ] && [ "$ENV_KIND" = "grav" ]; then
    cat > "$STAGING_DIR/robots.txt" << 'ROBOTS'
# Non-production tier — opted out of search indexing.
# The real public site is www.byvaerkstederne.dk and has its own robots.txt.
User-agent: *
Disallow: /
ROBOTS
fi

# =============================================================================
# Stage component-scoped VERSION + BUILD files.
# =============================================================================
#
# - Landing: $STAGING_DIR is the apex docroot, so VERSION + BUILD land
#   directly at its root. (Rsync copied apex/VERSION already; we
#   re-write it from the trimmed value to be explicit and to defend
#   against stray whitespace.)
# - Grav tiers: $STAGING_DIR is the Grav root, mirroring config/www/
#   on the remote. Place VERSION + BUILD at its root so the deployed
#   instance can read config/www/VERSION and config/www/BUILD at
#   request time (Sprint 2 wires that up).
#
# BUILD is the bare integer from `git rev-list --count HEAD`, computed
# once above. No env vars or operator strings are interpolated.
printf '%s\n' "$VERSION" > "$STAGING_DIR/VERSION"
printf '%s\n' "$BUILD"   > "$STAGING_DIR/BUILD"

# Write version manifest. The new schema gains a `build` field
# alongside `version`. Both mirror the deployed VERSION/BUILD files.
# `branch` and `sha_short` continue to be written for ops debugging
# only; nothing public reads them.
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

# ── Step 3: Upload via rsync ────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
    echo "→ Step 3/4: (dry-run — skipping upload to ${DEPLOY_HOST:-<unset>}:${DEPLOY_TARGET})"
    echo "  ✓ Staging dir ready at $STAGING_DIR"
    echo ""
    echo "  ✅  Dry-run complete — staging dir produced, no remote upload performed."
    echo "  📦  Inspect: $STAGING_DIR"
    echo ""
    exit 0
fi

echo "→ Step 3/4: Uploading to ${DEPLOY_HOST}:${DEPLOY_TARGET}..."

# Ensure target directory exists
sshpass -p "$DEPLOY_PASS" ssh -o StrictHostKeyChecking=no -p "$DEPLOY_PORT" \
    "${DEPLOY_USER}@${DEPLOY_HOST}" \
    "mkdir -p ${DEPLOY_TARGET}"

sshpass -p "$DEPLOY_PASS" rsync -avz --delete \
    --exclude='cache/compiled/*' \
    --exclude='cache/twig/*' \
    --exclude='cache/doctrine/*' \
    --exclude='logs/*' \
    --exclude='backup/*' \
    --exclude='tmp/*' \
    --exclude='.DS_Store' \
    --exclude='/dev/' \
    --exclude='/test/' \
    --exclude='/staging/' \
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "$STAGING_DIR/" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_TARGET}/"
# /dev /test /staging excludes protect sibling-folder subdomain deploys
# from being deleted by an apex-target rsync --delete. The leading / pins
# them to the rsync root (so we don't accidentally exclude e.g. user/test
# or any nested cache/dev path). On a dev/test/staging deploy the target
# is already inside the matching folder, so the excludes don't apply
# (rsync evaluates them relative to the source root).

echo "  ✓ Upload complete"

# ── Step 4: Post-deploy ─────────────────────────────────────
echo "→ Step 4/4: Post-deploy tasks..."

if [ "$ENV_KIND" = "grav" ]; then
    sshpass -p "$DEPLOY_PASS" ssh -o StrictHostKeyChecking=no -p "$DEPLOY_PORT" \
        "${DEPLOY_USER}@${DEPLOY_HOST}" \
        "cd ${DEPLOY_TARGET} && php bin/grav cache --all 2>/dev/null || true"
    echo "  ✓ Cache cleared"
else
    echo "  ✓ (landing — no Grav cache to clear)"
fi

echo ""
echo "  ✅  Deploy complete!"
echo "  🌐  ${ENV_URL}"
echo ""
