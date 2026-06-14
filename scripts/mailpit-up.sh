#!/usr/bin/env bash
set -euo pipefail

# Brings up the Mailpit mail sink (WI-6) in THIS worktree's compose project so
# it shares the Docker network with the worktree's Grav container and is
# reachable from Grav as `mailpit:1025`. Also injects the test SMTP override
# into the running Grav container's email.yaml so the real login + email plugin
# path sends captured mail to Mailpit (nothing mocked at the Grav layer).
#
# Mailpit is scoped to the `test` compose profile, so the plain dev workflow
# (`make start` / :8080) never starts it.
#
# Usage:
#   scripts/mailpit-up.sh <worktree-path> [smtp-host-port] [api-host-port]
#
# Exports (for the calling shell):
#   MAILPIT_URL  — host-side REST API base, e.g. http://127.0.0.1:8025
#
# Tear down with scripts/mailpit-down.sh <worktree-path>.

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <worktree-path> [smtp-host-port] [api-host-port]" >&2
  exit 2
fi

WORKTREE_PATH="$1"
SMTP_PORT="${2:-1025}"
API_PORT="${3:-8025}"

if [[ ! -d "$WORKTREE_PATH/config/www" ]]; then
  echo "❌ ERROR: $WORKTREE_PATH does not look like a worktree (no config/www)" >&2
  exit 2
fi

WORKTREE_ABS="$(cd "$WORKTREE_PATH" && pwd -P)"
WORKTREE_ID="$(printf '%s' "$WORKTREE_ABS" | shasum -a 256 | cut -c1-8)"
GRAV_CONTAINER_NAME="grav-$WORKTREE_ID"
PROJECT_NAME="$GRAV_CONTAINER_NAME"
MAILPIT_CONTAINER_NAME="mailpit-$WORKTREE_ID"

cd "$WORKTREE_ABS"

echo "Starting Mailpit (container: $MAILPIT_CONTAINER_NAME) in project $PROJECT_NAME..."
GRAV_CONTAINER="$GRAV_CONTAINER_NAME" \
GRAV_ROOT="$WORKTREE_ABS/config" \
MAILPIT_CONTAINER="$MAILPIT_CONTAINER_NAME" \
MAILPIT_SMTP_PORT="$SMTP_PORT" \
MAILPIT_API_PORT="$API_PORT" \
  docker compose -p "$PROJECT_NAME" --profile test up -d mailpit

echo "Waiting for Mailpit API to respond..."
for i in $(seq 1 30); do
  code="$(curl -so /dev/null -w '%{http_code}' "http://127.0.0.1:$API_PORT/api/v1/info" 2>/dev/null || true)"
  if [[ "$code" == "200" ]]; then
    echo "✓ Mailpit API ready on http://127.0.0.1:$API_PORT"
    break
  fi
  if [[ $i -eq 30 ]]; then
    echo "❌ ERROR: Mailpit API did not come up on port $API_PORT" >&2
    exit 1
  fi
  sleep 1
done

# Inject the test SMTP override so the real login + email plugin path sends
# captured mail to Mailpit. We override the USER config_plugins email.yaml in
# place — Grav 1.7's env-config merge does not apply per-host overrides to
# plugin configs, so the env path (user/env/<host>/config/email.yaml) that
# WI-1 uses for production tier secrets is not honoured for the SMTP block at
# runtime; the user config_plugins file is. This is the "test environment's
# email.yaml overrides the SMTP block" from WI-6, applied at the layer Grav
# actually reads.
#
# Because /config is volume-mounted, this write touches the host tree. We back
# up the committed credential-free file first; scripts/mailpit-down.sh restores
# it. The repo file is unchanged after a clean up/down cycle.
EMAIL_CFG="$WORKTREE_ABS/config/www/user/config/plugins/email.yaml"
EMAIL_BAK="$WORKTREE_ABS/.gan/email.yaml.committed.bak"
mkdir -p "$WORKTREE_ABS/.gan"
if [ -f "$EMAIL_CFG" ] && [ ! -f "$EMAIL_BAK" ]; then
  cp "$EMAIL_CFG" "$EMAIL_BAK"
fi
cat > "$EMAIL_CFG" <<'YAML'
# TEST-ONLY Mailpit override written by scripts/mailpit-up.sh. The committed
# credential-free file is backed up at .gan/email.yaml.committed.bak and
# restored by scripts/mailpit-down.sh. DO NOT COMMIT this form.
enabled: true
from: 'noreply@hackersbychoice.dk'
from_name: 'Byværkstederne'
charset: utf-8
content_type: text/html
debug: false
mailer:
  engine: smtp
  smtp:
    server: mailpit
    port: 1025
    encryption: none
    user: ''
    password: ''
YAML

# Relax the hardened session cookie for LOCAL HTTP testing (WI-4). The
# committed system.yaml sets session.secure: true for the TLS tiers; over the
# worktree container's plain HTTP a Secure cookie is set but never sent back by
# the browser, so authenticated flows can't hold a session. Flip secure -> false
# in the container's system.yaml for the test run only. Backed up to .gan/ and
# restored by scripts/mailpit-down.sh. The production hardening in the repo file
# is unchanged. (The X-Forwarded-Proto: https cookie-flag assertions still run
# against the committed value via a probe request, before this relaxation
# matters — see tests/anonymous/session-cookie.js, which reads the live header.)
SYSTEM_CFG="$WORKTREE_ABS/config/www/user/config/system.yaml"
SYSTEM_BAK="$WORKTREE_ABS/.gan/system.yaml.committed.bak"
if [ -f "$SYSTEM_CFG" ] && [ ! -f "$SYSTEM_BAK" ]; then
  cp "$SYSTEM_CFG" "$SYSTEM_BAK"
fi
# Only rewrite the secure: true line inside the session: block.
if grep -qE '^\s*secure:\s*true' "$SYSTEM_CFG"; then
  # macOS/BSD sed in-place
  sed -i.tmp -E 's/^([[:space:]]*)secure:[[:space:]]*true/\1secure: false/' "$SYSTEM_CFG"
  rm -f "$SYSTEM_CFG.tmp"
fi

if docker ps --filter "name=^${GRAV_CONTAINER_NAME}\$" --format '{{.Names}}' | grep -qx "$GRAV_CONTAINER_NAME"; then
  echo "Pointed email.yaml at mailpit:1025 and relaxed session.secure for HTTP tests (backups in .gan/); clearing Grav cache..."
  docker exec -u abc -w /app/www/public "$GRAV_CONTAINER_NAME" bin/grav clearcache >/dev/null 2>&1 || true
else
  echo "⚠️  Grav container $GRAV_CONTAINER_NAME not running — start it first with scripts/grav-up.sh" >&2
fi

export MAILPIT_URL="http://127.0.0.1:$API_PORT"
echo ""
echo "=========================================="
echo "✓ Mailpit ready"
echo "  API/UI:   http://127.0.0.1:$API_PORT"
echo "  SMTP:     mailpit:1025 (from inside the compose network)"
echo "  Exported: MAILPIT_URL=$MAILPIT_URL"
echo "=========================================="
