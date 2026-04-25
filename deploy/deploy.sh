#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

# =============================================================================
# Byværkstederne — Deploy to one.com shared hosting
# Usage: ./deploy/deploy.sh [environment]
#   Environments: prod (default), test, dev, staging
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STAGING_DIR="$PROJECT_DIR/deploy/staging"
GRAV_VERSION="1.7.49.5"
GRAV_ZIP="$PROJECT_DIR/deploy/grav-admin-v${GRAV_VERSION}.zip"
GRAV_URL="https://getgrav.org/download/core/grav-admin/${GRAV_VERSION}"

# Environment selection — see decisions/ and the four-tier topology in the
# project memory for canonical hostnames per tier:
#   prod    → www.byvaerkstederne.dk  (separate hosting; not yet provisioned)
#   staging → www.hackersbychoice.dk  (apex of hackersbychoice.dk on one.com)
#   test    → test.hackersbychoice.dk (folder /test under apex; one.com maps subdomain → folder)
#   dev     → dev.hackersbychoice.dk  (folder /dev under apex; same mechanism)
ENV="${1:-staging}"
case "$ENV" in
    prod|production)
        ENV_LABEL="Production"
        ENV_SUBFOLDER=""
        ENV_URL="https://www.byvaerkstederne.dk"
        ;;
    staging)
        ENV_LABEL="Staging"
        ENV_SUBFOLDER=""
        ENV_URL="https://www.hackersbychoice.dk"
        ;;
    test)
        ENV_LABEL="Test"
        ENV_SUBFOLDER="/test"
        ENV_URL="https://test.hackersbychoice.dk"
        ;;
    dev)
        ENV_LABEL="Development"
        ENV_SUBFOLDER="/dev"
        ENV_URL="https://dev.hackersbychoice.dk"
        ;;
    *)
        echo "❌  Unknown environment: $ENV"
        echo "    Usage: $0 [prod|staging|test|dev]"
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
# hackersbychoice.dk (which serves staging/test/dev). Gate prod deploys
# behind its own credential set so a stray `./deploy.sh prod` can't
# overwrite staging when prod's hosting hasn't been wired up yet.
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

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  Byværkstederne — Deploy             ║"
echo "  ║  Environment: ${ENV_LABEL}$(printf '%*s' $((20 - ${#ENV_LABEL})) '')║"
echo "  ║  Target: ${DEPLOY_TARGET}            "
echo "  ╚══════════════════════════════════════╝"
echo ""

# ── Step 1: Download Grav core (cached) ─────────────────────
echo "→ Step 1/4: Grav core..."
if [ -f "$GRAV_ZIP" ]; then
    echo "  ✓ Cached (v${GRAV_VERSION})"
else
    echo "  Downloading Grav v${GRAV_VERSION}..."
    curl -L -o "$GRAV_ZIP" "$GRAV_URL"
    echo "  ✓ Downloaded"
fi

# ── Step 2: Build staging directory ──────────────────────────
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

# NOTE: no custom_base_url injection. Earlier versions of this script set
# custom_base_url for subfolder deploys (e.g. /test → hackersbychoice.dk/test)
# because tiers were path-based on the apex. Under the four-tier topology
# the test/ and dev/ filesystem subfolders are docroot-mapped by one.com
# to test.hackersbychoice.dk / dev.hackersbychoice.dk. Grav running inside
# those folders sees `/` as its base — injecting a custom_base_url here
# would break asset paths and routing when accessed via the canonical
# subdomain URL.

# Create .htaccess
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

    # Redirect www → apex.
    RewriteCond %{HTTP_HOST} ^www\.(.+)$ [NC]
    RewriteRule ^(.*)$ https://%1/$1 [R=301,L]

    # Force HTTPS — but only when the original request was actually HTTP.
    # Both conditions must pass: Varnish header AND local HTTPS var.
    # This prevents the redirect loop on one.com where %{HTTPS} is always off.
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
HTACCESS

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
    -e "ssh -o StrictHostKeyChecking=no -p ${DEPLOY_PORT}" \
    "$STAGING_DIR/" \
    "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_TARGET}/"

echo "  ✓ Upload complete"

# ── Step 4: Post-deploy ─────────────────────────────────────
echo "→ Step 4/4: Post-deploy tasks..."

sshpass -p "$DEPLOY_PASS" ssh -o StrictHostKeyChecking=no -p "$DEPLOY_PORT" \
    "${DEPLOY_USER}@${DEPLOY_HOST}" \
    "cd ${DEPLOY_TARGET} && php bin/grav cache --all 2>/dev/null || true"

echo "  ✓ Cache cleared"

echo ""
echo "  ✅  Deploy complete!"
echo "  🌐  ${ENV_URL}"
echo ""
