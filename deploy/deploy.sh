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

# Environment selection
ENV="${1:-prod}"
case "$ENV" in
    prod|production)
        ENV_LABEL="Production"
        ENV_SUBFOLDER=""
        ENV_URL="https://hackersbychoice.dk"
        ;;
    test)
        ENV_LABEL="Test"
        ENV_SUBFOLDER="/test"
        ENV_URL="https://hackersbychoice.dk/test"
        ;;
    dev)
        ENV_LABEL="Development"
        ENV_SUBFOLDER="/dev"
        ENV_URL="https://hackersbychoice.dk/dev"
        ;;
    staging)
        ENV_LABEL="Staging"
        ENV_SUBFOLDER="/staging"
        ENV_URL="https://hackersbychoice.dk/staging"
        ;;
    *)
        echo "❌  Unknown environment: $ENV"
        echo "    Usage: $0 [prod|test|dev|staging]"
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

# Set base URL for subfolder deployments
if [ -n "$ENV_SUBFOLDER" ]; then
    # Update system.yaml to set custom_base_url for subfolder
    if grep -q "custom_base_url" "$STAGING_DIR/user/config/system.yaml" 2>/dev/null; then
        sed -i '' "s|custom_base_url:.*|custom_base_url: '${ENV_URL}'|" "$STAGING_DIR/user/config/system.yaml"
    else
        echo "" >> "$STAGING_DIR/user/config/system.yaml"
        echo "custom_base_url: '${ENV_URL}'" >> "$STAGING_DIR/user/config/system.yaml"
    fi
fi

# Create .htaccess
cat > "$STAGING_DIR/.htaccess" << 'HTACCESS'
# Grav CMS .htaccess

<IfModule mod_rewrite.c>
    RewriteEngine On

    # Force HTTPS
    RewriteCond %{HTTPS} !=on
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]

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
