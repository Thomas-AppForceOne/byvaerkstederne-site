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
