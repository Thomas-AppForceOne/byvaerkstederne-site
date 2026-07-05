#!/usr/bin/env bash
set -euo pipefail

# Seed: playwright — provisions pw-test-user, pw-test-admin and
# pw-test-organizer against a running Grav container. Idempotent.
#
# Usage: apply.sh [container-name]   # defaults to 'grav'
#
# Requires ~/.gan-secrets/workshop-site.env with TEST_PASSWORD,
# TEST_ADMIN_PASSWORD and TEST_ORGANIZER_PASSWORD set. See ./README.md.
#
# The organizer seed is a multi-step contract (frontend event CRUD spec §12):
# the `bin/plugin login newuser` CLI has no --groups flag, so the account is
# created as an ordinary member and its YAML is then patched with
# `groups: [organizers]`; the group's access tree comes from the repo's
# user/config/groups.yaml, whose presence in the container is asserted below
# (fail loud — without it the entire authz suite would run permission-less).

CONTAINER="${1:-grav}"
SECRETS="$HOME/.gan-secrets/workshop-site.env"

if [[ ! -f "$SECRETS" ]]; then
  echo "FATAL: $SECRETS does not exist — cannot seed test accounts." >&2
  echo "Create it with TEST_PASSWORD=... and TEST_ADMIN_PASSWORD=... lines, mode 600." >&2
  exit 1
fi

# shellcheck disable=SC1090
set -a; . "$SECRETS"; set +a

if [[ -z "${TEST_PASSWORD:-}" || -z "${TEST_ADMIN_PASSWORD:-}" || -z "${TEST_ORGANIZER_PASSWORD:-}" ]]; then
  echo "FATAL: $SECRETS exists but TEST_PASSWORD / TEST_ADMIN_PASSWORD / TEST_ORGANIZER_PASSWORD are empty." >&2
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
  docker exec -u abc -w "$GRAV_ROOT" "$CONTAINER" bin/plugin login newuser \
    -u "$user" \
    -p "$pw" \
    -e "$email" \
    -N "$fullname" \
    -t "$title" \
    -P "$perm" \
    -s enabled \
    -n >/dev/null
}

provision pw-test-user      "$TEST_PASSWORD"           pw-test-user@example.invalid      "Playwright Test User"      Member s
provision pw-test-admin     "$TEST_ADMIN_PASSWORD"     pw-test-admin@example.invalid     "Playwright Test Admin"     Admin  b
provision pw-test-organizer "$TEST_ORGANIZER_PASSWORD" pw-test-organizer@example.invalid "Playwright Test Organizer" Member s

# (a) groups.yaml must resolve in the test tier or the organizers access tree
# never applies on login — fail loud rather than let the authz suite run
# permission-less.
if ! docker exec "$CONTAINER" test -f /config/www/user/config/groups.yaml; then
  echo "FATAL: user/config/groups.yaml is missing in container '$CONTAINER' — the organizers group cannot resolve." >&2
  exit 1
fi
if ! docker exec "$CONTAINER" grep -q '^organizers:' /config/www/user/config/groups.yaml; then
  echo "FATAL: user/config/groups.yaml in container '$CONTAINER' has no 'organizers' group." >&2
  exit 1
fi

# (c) Patch the organizer account into the group (idempotent; the newuser CLI
# has no --groups flag).
docker exec -u abc "$CONTAINER" sh -c \
  'grep -q "^groups:" /config/www/user/accounts/pw-test-organizer.yaml || printf "groups:\n  - organizers\n" >> /config/www/user/accounts/pw-test-organizer.yaml'

echo "done."
