#!/usr/bin/env bash
set -euo pipefail

# Seed: playwright — provisions pw-test-user and pw-test-admin against a
# running Grav container. Idempotent.
#
# Usage: apply.sh [container-name]   # defaults to 'grav'
#
# Requires ~/.gan-secrets/workshop-site.env with TEST_PASSWORD and
# TEST_ADMIN_PASSWORD set. See ./README.md for details.

CONTAINER="${1:-grav}"
SECRETS="$HOME/.gan-secrets/workshop-site.env"

if [[ ! -f "$SECRETS" ]]; then
  echo "FATAL: $SECRETS does not exist — cannot seed test accounts." >&2
  echo "Create it with TEST_PASSWORD=... and TEST_ADMIN_PASSWORD=... lines, mode 600." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; . "$SECRETS"; set +a

if [[ -z "${TEST_PASSWORD:-}" || -z "${TEST_ADMIN_PASSWORD:-}" ]]; then
  echo "FATAL: $SECRETS exists but TEST_PASSWORD / TEST_ADMIN_PASSWORD are empty." >&2
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "FATAL: container '$CONTAINER' is not running." >&2
  echo "Start it with: scripts/grav-up.sh <worktree>" >&2
  exit 1
fi

# Grav's new-user CLI must be run from the Grav root (/app/www/public in
# the linuxserver/grav image).
GRAV_ROOT="/app/www/public"

user_exists() {
  # Check the filesystem directly (fast, no PHP bootstrap needed).
  docker exec "$CONTAINER" test -f "/config/www/user/accounts/$1.yaml"
}

provision() {
  local user="$1" pw="$2" email="$3" fullname="$4" title="$5" perm="$6"

  if user_exists "$user"; then
    echo "skip: $user already exists"
    return 0
  fi

  echo "creating: $user"
  docker exec -w "$GRAV_ROOT" "$CONTAINER" bin/plugin login newuser \
    -u "$user" \
    -p "$pw" \
    -e "$email" \
    -N "$fullname" \
    -t "$title" \
    -P "$perm" \
    -s enabled \
    -n >/dev/null
}

provision pw-test-user  "$TEST_PASSWORD"       pw-test-user@example.invalid  "Playwright Test User"  Member s
provision pw-test-admin "$TEST_ADMIN_PASSWORD" pw-test-admin@example.invalid "Playwright Test Admin" Admin  b

echo "done."
