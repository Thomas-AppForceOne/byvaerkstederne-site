#!/bin/bash
set -euo pipefail

# =============================================================================
# Byværkstederne — Deploy to one.com shared hosting
# Usage: make deploy
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STAGING_DIR="$PROJECT_DIR/deploy/staging"
GRAV_VERSION="1.7.49.5"
GRAV_ZIP="$PROJECT_DIR/deploy/grav-admin-v${GRAV_VERSION}.zip"
GRAV_URL="https://getgrav.org/download/core/grav-admin/${GRAV_VERSION}"

# Load credentials
ENV_FILE="$PROJECT_DIR/.env.deploy"
if [ ! -f "$ENV_FILE" ]; then
    echo "❌  Missing .env.deploy — copy .env.deploy.example and fill in credentials"
    exit 1
fi
source "$ENV_FILE"

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║  Byværkstederne — Deploy             ║"
echo "  ║  Target: ${DEPLOY_HOST}              ║"
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
# Grav extracts to grav-admin/ subfolder — move contents up
cp -a "$STAGING_DIR"/grav-admin/. "$STAGING_DIR"/
rm -rf "$STAGING_DIR/grav-admin"

# Overlay our custom user directory (theme, pages, plugins config, data)
# Remove default user content first
rm -rf "$STAGING_DIR/user/pages" "$STAGING_DIR/user/themes/quark" 2>/dev/null

# Copy our user directory
rsync -a --exclude='.DS_Store' \
    "$PROJECT_DIR/config/www/user/" \
    "$STAGING_DIR/user/"

# Create .htaccess for one.com (Apache)
cat > "$STAGING_DIR/.htaccess" << 'HTACCESS'
# Grav CMS .htaccess for one.com shared hosting

<IfModule mod_rewrite.c>
    RewriteEngine On

    # Redirect to non-www
    RewriteCond %{HTTP_HOST} ^www\.(.+)$ [NC]
    RewriteRule ^(.*)$ https://%1/$1 [R=301,L]

    # Force HTTPS
    RewriteCond %{HTTPS} !=on
    RewriteRule ^(.*)$ https://%{HTTP_HOST}/$1 [R=301,L]

    # Grav routing
    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteCond %{REQUEST_FILENAME} !-d
    RewriteRule ^(.*)$ index.php [QSA,L]
</IfModule>

# Security headers
<IfModule mod_headers.c>
    Header set X-Content-Type-Options "nosniff"
    Header set X-Frame-Options "SAMEORIGIN"
    Header set X-XSS-Protection "1; mode=block"
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

# Remove Docker-only plugin (flex-cache-bust works differently on shared hosting)
# The plugin is still useful — it just needs no Docker workarounds

# Remove the Docker port fix from the plugin (not needed on shared hosting)
# The cache-busting part still works fine

echo "  ✓ Package built ($(du -sh "$STAGING_DIR" | cut -f1))"

# ── Step 3: Upload via rsync ────────────────────────────────
echo "→ Step 3/4: Uploading to ${DEPLOY_HOST}..."
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
    "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/"

echo "  ✓ Upload complete"

# ── Step 4: Post-deploy ─────────────────────────────────────
echo "→ Step 4/4: Post-deploy tasks..."

# Clear Grav cache on server
sshpass -p "$DEPLOY_PASS" ssh -o StrictHostKeyChecking=no -p "$DEPLOY_PORT" \
    "${DEPLOY_USER}@${DEPLOY_HOST}" \
    "cd ${DEPLOY_PATH} && php bin/grav cache --all 2>/dev/null || true"

echo "  ✓ Cache cleared"

echo ""
echo "  ✅  Deploy complete!"
echo "  🌐  https://hackersbychoice.dk"
echo ""
