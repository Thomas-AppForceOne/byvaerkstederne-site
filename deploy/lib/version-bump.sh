#!/usr/bin/env bash
#
# Semver bump helper for deploy/bump-version.sh.
#
# bv_bump_semver increments one component (major|minor|patch) of a
# version's NUMERIC CORE. Any pre-release / build suffix on the input
# (e.g. -dev, -rc.1, +build) is dropped — "bump patch" means the
# numeric triplet, and the result is a clean MAJOR.MINOR.PATCH. The
# caller prints old → new so the suffix drop is visible.
#
#   major:  X.Y.Z  → (X+1).0.0
#   minor:  X.Y.Z  → X.(Y+1).0
#   patch:  X.Y.Z  → X.Y.(Z+1)
#
# Pure function → unit-tested directly.

# bv_bump_semver <current> <major|minor|patch> [pre]
#
# Echoes the bumped version on stdout. With a non-empty [pre] label, a
# pre-release suffix is appended: e.g. `bv_bump_semver 1.1.0 minor dev`
# → 1.2.0-dev (the "open the next development iteration" convention —
# Maven's -SNAPSHOT, npm's -dev). Without it, a clean release number.
#
# Returns non-zero (diagnostic on stderr) when <current> has no
# parseable X.Y.Z core, <part> is bogus, or [pre] is not a valid SemVer
# pre-release label.
bv_bump_semver() {
    local current="$1" part="$2" pre="${3:-}"

    # Core = everything before the first '-' (pre-release) or '+' (build).
    local core="${current%%[-+]*}"
    if ! printf '%s' "$core" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        printf 'bv_bump_semver: no valid X.Y.Z core in %s\n' "$current" >&2
        return 1
    fi

    local major minor patch
    IFS=. read -r major minor patch <<< "$core"
    # Force base-10 so a stray leading zero never reads as octal.
    major=$((10#$major)); minor=$((10#$minor)); patch=$((10#$patch))

    case "$part" in
        major) major=$((major + 1)); minor=0; patch=0 ;;
        minor) minor=$((minor + 1)); patch=0 ;;
        patch) patch=$((patch + 1)) ;;
        *) printf 'bv_bump_semver: unknown part %s (major|minor|patch)\n' "$part" >&2; return 1 ;;
    esac

    local result; result="$(printf '%d.%d.%d' "$major" "$minor" "$patch")"

    if [ -n "$pre" ]; then
        # SemVer pre-release: dot/dash-separated alphanumeric identifiers.
        if ! printf '%s' "$pre" | grep -Eq '^[0-9A-Za-z]+([.-][0-9A-Za-z]+)*$'; then
            printf 'bv_bump_semver: invalid pre-release label %s\n' "$pre" >&2
            return 1
        fi
        result="${result}-${pre}"
    fi

    printf '%s\n' "$result"
}

# bv_semver_compare <a> <b>
#
# Compares two CLEAN release SemVers (X.Y.Z, no pre-release/build
# suffix) componentwise and echoes -1 (a<b), 0 (a==b), or 1 (a>b) on
# stdout. This is the comparison primitive `release-pr-guard`'s
# "version is bumped" check (rule 4) needs — `bv_bump_semver` bumps but
# cannot compare, and the repo's other comparator lived un-sourceably
# inside `deploy/migrate.sh`.
#
# Returns non-zero (diagnostic on stderr, nothing on stdout) when
# EITHER argument is not a clean X.Y.Z. The caller must screen
# pre-release values out first (rule 3 before rule 4); feeding a
# `-dev`/`-rc.N` value is a caller bug, not a silent "they're equal".
bv_semver_compare() {
    local a="$1" b="$2"
    local re='^[0-9]+\.[0-9]+\.[0-9]+$'
    if ! printf '%s' "$a" | grep -Eq "$re"; then
        printf 'bv_semver_compare: not a clean X.Y.Z version: %s\n' "$a" >&2
        return 1
    fi
    if ! printf '%s' "$b" | grep -Eq "$re"; then
        printf 'bv_semver_compare: not a clean X.Y.Z version: %s\n' "$b" >&2
        return 1
    fi

    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<< "$a"
    IFS=. read -r b1 b2 b3 <<< "$b"
    # Force base-10 so a stray leading zero never reads as octal.
    a1=$((10#$a1)); a2=$((10#$a2)); a3=$((10#$a3))
    b1=$((10#$b1)); b2=$((10#$b2)); b3=$((10#$b3))

    local x y
    for pair in "$a1:$b1" "$a2:$b2" "$a3:$b3"; do
        x="${pair%:*}"; y="${pair#*:}"
        if   [ "$x" -lt "$y" ]; then printf '%s\n' -1; return 0
        elif [ "$x" -gt "$y" ]; then printf '%s\n'  1; return 0
        fi
    done
    printf '%s\n' 0
}
