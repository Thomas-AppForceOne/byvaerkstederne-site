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

# Load credentials
ENV_FILE="$PROJECT_DIR/.env.deploy"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌  Missing .env.deploy — copy .env.deploy.example and fill in credentials"
    exit 1
fi
source "$ENV_FILE"

# Production lives on a separate hosting account from
# hackersbychoice.dk (which serves landing + staging/test/dev). Gate prod
# deploys behind its own credential set so a stray `./deploy.sh prod`
# can't overwrite anything on hackersbychoice.dk.
if [ "$ENV" = "prod" ] || [ "$ENV" = "production" ]; then
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

DEPLOY_TARGET="${DEPLOY_PATH}${ENV_SUBFOLDER}"

# Capture deploy metadata (used for version.json on every tier)
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

    # Overlay our custom user directory
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
    rsync -a --exclude='.DS_Store' \
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

# Write version manifest. Reads back via apex/index.php for the selector;
# otherwise just a marker file useful for ops debugging.
cat > "$STAGING_DIR/version.json" << JSON
{
    "tier": "${ENV}",
    "branch": "${GIT_BRANCH}",
    "sha_short": "${GIT_SHA}",
    "deployed_at": "${DEPLOYED_AT}"
}
JSON

echo "  ✓ Package built ($(du -sh "$STAGING_DIR" | cut -f1))"

# ── Step 3: Upload via rsync ────────────────────────────────
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
