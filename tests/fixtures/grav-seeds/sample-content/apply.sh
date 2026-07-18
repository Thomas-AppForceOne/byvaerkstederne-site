#!/usr/bin/env bash
set -euo pipefail

# Seed: sample-content — populates a running Grav container's flex-objects
# store with the repo's sample dataset (events incl. rich details, roadmap
# items, team/opgaver/ønskeliste). Idempotent: files that already exist in
# the container are skipped, so runtime mutations (RSVP signups, votes,
# organizer edits) are never overwritten. Pass --force to overwrite anyway.
#
# Usage: apply.sh [container-name] [--force]   # container defaults to 'grav'
#
# No secrets involved — the payload is plain sample content under ./data/.
# See ./README.md for what each file provides.

CONTAINER="grav"
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -*) echo "FATAL: unknown option '$arg' (only --force is supported)" >&2; exit 1 ;;
        *) CONTAINER="$arg" ;;
    esac
done

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/config/www/user/data/flex-objects"
GRAV_ROOT="/app/www/public"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "FATAL: container '$CONTAINER' is not running." >&2
    echo "Start it with: scripts/grav-up.sh <worktree>" >&2
    exit 1
fi

# Writes run as the container's app user (abc) — root-owned files under
# /config break Grav (see the cache-clear house rule).
docker exec -u abc "$CONTAINER" mkdir -p "$TARGET"

seeded=0
skipped=0
for src in "$BUNDLE_DIR"/data/*.yaml; do
    name="$(basename "$src")"
    if [ "$FORCE" != "1" ] && docker exec "$CONTAINER" test -f "$TARGET/$name"; then
        echo "  = $name already present — skipped (use --force to overwrite)"
        skipped=$((skipped + 1))
        continue
    fi
    docker exec -i -u abc "$CONTAINER" sh -c "cat > '$TARGET/$name'" < "$src"
    echo "  + $name seeded"
    seeded=$((seeded + 1))
done

if [ "$seeded" -gt 0 ]; then
    docker exec -u abc -w "$GRAV_ROOT" "$CONTAINER" bin/grav clearcache >/dev/null
    echo "✓ sample-content: $seeded file(s) seeded, $skipped skipped; cache cleared."
else
    echo "✓ sample-content: nothing to do ($skipped file(s) already present)."
fi
