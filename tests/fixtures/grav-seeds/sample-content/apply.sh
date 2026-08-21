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

# ── Relative dates ───────────────────────────────────────────────────
#
# Event fixtures carry `@today±N` tokens instead of absolute dates, and
# are expanded here at seed time.
#
# WHY: they used to be hardcoded ISO dates. Every one of them drifted into
# the past, `event_is_stale()` filtered them out, and the calendar rendered
# EMPTY on every developer machine and in CI — silently, and permanently.
# Every assertion about an event card was therefore vacuous, which is how
# the flag-off card path (a signup button linking to a page that does not
# exist) reached production untested. A fixture that rots is worse than no
# fixture: it looks like coverage.
#
# Two events sit in the past on purpose, so the stale filter itself stays
# exercised; the remaining eight are always ahead of today.

# Resolve a signed day offset to YYYY-MM-DD, on GNU date and BSD/macOS date.
date_offset() {
    local n="$1"
    if date -u -d '@0' >/dev/null 2>&1; then
        date -u -d "$n days" +%Y-%m-%d                     # GNU
    else
        local sign='+' mag="$n"
        case "$n" in -*) sign='-'; mag="${n#-}" ;; *) mag="${n#+}" ;; esac
        date -u -v"${sign}${mag}d" +%Y-%m-%d               # BSD / macOS
    fi
}

# Expand every @today±N token on stdin. A file with no tokens passes
# through untouched, so non-event fixtures are unaffected.
expand_dates() {
    local body token offset resolved
    body="$(cat)"
    # LONGEST TOKEN FIRST. '@today+1' is a prefix of '@today+11', so
    # substituting in sort order rewrites the prefix and leaves the trailing
    # digit behind ('2026-08-221'). Ordering by descending length makes the
    # replacements unambiguous without needing word boundaries sed cannot
    # portably express.
    for token in $(printf '%s' "$body" | grep -oE '@today[+-][0-9]+' | sort -u \
                   | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-); do
        offset="${token#@today}"
        resolved="$(date_offset "$offset")"
        if [ -z "$resolved" ]; then
            echo "FATAL: could not resolve date token '$token'" >&2
            exit 1
        fi
        body="$(printf '%s' "$body" | sed "s/${token}/${resolved}/g")"
    done
    printf '%s\n' "$body"
}

seeded=0
skipped=0
for src in "$BUNDLE_DIR"/data/*.yaml; do
    name="$(basename "$src")"
    if [ "$FORCE" != "1" ] && docker exec "$CONTAINER" test -f "$TARGET/$name"; then
        echo "  = $name already present — skipped (use --force to overwrite)"
        skipped=$((skipped + 1))
        continue
    fi
    expand_dates < "$src" | docker exec -i -u abc "$CONTAINER" sh -c "cat > '$TARGET/$name'"
    echo "  + $name seeded"
    seeded=$((seeded + 1))
done

if [ "$seeded" -gt 0 ]; then
    docker exec -u abc -w "$GRAV_ROOT" "$CONTAINER" bin/grav clearcache >/dev/null
    echo "✓ sample-content: $seeded file(s) seeded, $skipped skipped; cache cleared."
else
    echo "✓ sample-content: nothing to do ($skipped file(s) already present)."
fi
