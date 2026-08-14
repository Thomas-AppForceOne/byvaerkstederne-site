#!/usr/bin/env bash
# =============================================================================
# Byvaerkstederne — Data-schema migration runner
#
# Usage:
#     deploy/migrate.sh <data-dir> [--to <version>]
#
# Reads the from-version from <data-dir>/user/data-version.yaml
# (falling back to "0.1.0" with a warning when the file is missing or
# lacks a parseable `data_version` field — see spec §Pre-spec backups).
# Computes the to-version from --to, or from the deploy bundle's
# git-tracked config/www/user/data-version.yaml when --to is absent.
# Selects every migration whose target is strictly greater than from
# and less than or equal to to, sorts them by SemVer (not lex), and
# applies them in order. Verifies the post-condition (the migration
# wrote the expected data_version) after each invocation; refuses to
# continue if it didn't.
#
# Exits 0 on success or when no migrations are needed.
# Exits non-zero on any failure mode (missing migration, throwing
# migration, post-condition violation).
#
# See specifications/data_versioning_and_migrations_specification.md
# (or its archived form once shipped) for the authoritative contract.
# =============================================================================
set -euo pipefail
# macOS dev convenience: surface Homebrew binaries when present. The
# directory is absent on the linux prod tier so this is a no-op there.
[ -d /opt/homebrew/bin ] && export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MIGRATIONS_DIR="${BV_MIGRATIONS_DIR:-$PROJECT_DIR/migrations}"
# The PHP bootstrap + composer-installed vendor/ always live in the
# project's main migrations/ dir, even when BV_MIGRATIONS_DIR points
# at a synthetic test-scoped dir. Test harness fixtures don't need to
# duplicate the bootstrap.
BOOTSTRAP_DIR="${BV_MIGRATE_BOOTSTRAP_DIR:-$PROJECT_DIR/migrations}"
BUNDLE_MARKER="${BV_BUNDLE_DATA_VERSION_YAML:-$PROJECT_DIR/config/www/user/data-version.yaml}"

# PHP invocation: an array of arguments that, when the migration file
# and data dir are appended, runs run-migration.php.
#
# Resolution order:
#   1. BV_MIGRATE_PHP env var (space-separated invocation) — set by the
#      test harness and CI to point at a known PHP.
#   2. `php` on PATH.
#   3. `docker run --rm -v <repo>:<repo> -w <repo> php:8.3-cli php` so
#      operators on hosts without a system PHP (e.g. macOS dev boxes)
#      can still run the runner end-to-end.
#
# When all three are absent we fail loud rather than silently skip.
if [ -n "${BV_MIGRATE_PHP:-}" ]; then
    # Operator-supplied invocation as a space-separated string; split
    # via $IFS into BV_MIGRATE_PHP_CMD[].
    read -r -a BV_MIGRATE_PHP_CMD <<<"$BV_MIGRATE_PHP"
elif command -v php >/dev/null 2>&1; then
    BV_MIGRATE_PHP_CMD=(php)
elif command -v docker >/dev/null 2>&1; then
    # Set BV_USE_DOCKER_PHP=1 so the per-invocation logic below knows
    # to mount $DATA_DIR_ABS as well — the data dir is often outside
    # $PROJECT_DIR (a freshly-unpacked backup snapshot, for example).
    BV_USE_DOCKER_PHP=1
    BV_MIGRATE_PHP_CMD=()  # filled in lazily after we know DATA_DIR
else
    echo "❌  no PHP toolchain found: set BV_MIGRATE_PHP, install php, or install Docker." >&2
    exit 8
fi

# ----------------------------------------------------------------------
# CLI parsing
# ----------------------------------------------------------------------

DATA_DIR=""
TARGET_VERSION=""
SAW_TO=0
while [ $# -gt 0 ]; do
    case "$1" in
        --to)
            if [ $# -lt 2 ]; then
                echo "❌  --to requires an argument" >&2
                exit 2
            fi
            TARGET_VERSION="$2"
            SAW_TO=1
            shift 2
            ;;
        --to=*)
            TARGET_VERSION="${1#--to=}"
            SAW_TO=1
            shift
            ;;
        -h|--help)
            sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            echo "❌  unknown flag: $1" >&2
            exit 2
            ;;
        *)
            if [ -z "$DATA_DIR" ]; then
                DATA_DIR="$1"
            else
                echo "❌  unexpected positional argument: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [ -z "$DATA_DIR" ]; then
    echo "❌  usage: deploy/migrate.sh <data-dir> [--to <version>]" >&2
    exit 2
fi
if [ ! -d "$DATA_DIR" ]; then
    echo "❌  data dir does not exist: $DATA_DIR" >&2
    exit 2
fi
# Normalise to absolute path (PHP side wants an absolute path; bash's
# realpath is the cheap way to get one and dereferences symlinks
# consistently with `cd`).
DATA_DIR_ABS="$(cd "$DATA_DIR" && pwd)"

# Runtime PHP-version guard. migrations/composer.json requires PHP
# >= 8.1 (Symfony YAML 6.x). On a tier whose runtime is older the
# autoload would throw a Composer "platform requirements" error
# mid-migration; we'd rather refuse up-front with a clear message
# than corrupt the data dir partway through.
#
# Only enforce when we have a directly-callable PHP (not the Docker
# fallback — `php:8.3-cli` already satisfies the floor). Skipped for
# Docker mode because BV_USE_DOCKER_PHP=1 means we control the
# image.
if [ "${BV_USE_DOCKER_PHP:-0}" != "1" ]; then
    if ! "${BV_MIGRATE_PHP_CMD[@]}" -r '
        if (PHP_VERSION_ID < 80100) {
            fwrite(STDERR, sprintf("FATAL: migrate.sh requires PHP >= 8.1; found %s\n", PHP_VERSION));
            exit(1);
        }
    ' 2>/dev/null; then
        actual_version="$("${BV_MIGRATE_PHP_CMD[@]}" -r 'echo PHP_VERSION;' 2>/dev/null || echo 'unknown')"
        echo "❌  deploy/migrate.sh requires PHP >= 8.1 (migrations/composer.json platform floor); found ${actual_version}." >&2
        echo "    Either install a newer PHP on the host, or set BV_MIGRATE_PHP to a known-good binary." >&2
        exit 9
    fi
fi

# Lazy-init the Docker invocation now that we have $DATA_DIR_ABS.
# We mount $PROJECT_DIR (covers $BOOTSTRAP_DIR/vendor for autoload),
# the data dir (target of the migration), and — when set — the
# $BV_MIGRATIONS_DIR override (the test harness points it at a
# synthetic /tmp dir whose contents must be visible from inside the
# container too).
if [ "${BV_USE_DOCKER_PHP:-0}" = "1" ]; then
    BV_MIGRATE_PHP_CMD=(
        docker run --rm -i
        -u "$(id -u):$(id -g)"
        -v "$PROJECT_DIR:$PROJECT_DIR"
        -v "$DATA_DIR_ABS:$DATA_DIR_ABS"
    )
    if [ -n "${BV_MIGRATIONS_DIR:-}" ] && [ -d "$BV_MIGRATIONS_DIR" ]; then
        bv_migrations_abs="$(cd "$BV_MIGRATIONS_DIR" && pwd)"
        if [ "$bv_migrations_abs" != "$PROJECT_DIR" ] && [ "$bv_migrations_abs" != "$DATA_DIR_ABS" ]; then
            BV_MIGRATE_PHP_CMD+=( -v "$bv_migrations_abs:$bv_migrations_abs" )
        fi
        unset bv_migrations_abs
    fi
    BV_MIGRATE_PHP_CMD+=(
        -w "$PROJECT_DIR"
        php:8.3-cli
        php
    )
fi

# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

# Extract the `data_version:` field from a YAML file. Echoes the value
# (without surrounding quotes), or empty when the field is absent /
# the file is missing. Accepts quoted or unquoted values.
extract_data_version() {
    local path="$1"
    if [ ! -f "$path" ]; then
        printf ''
        return 0
    fi
    awk '
        /^[[:space:]]*#/ { next }
        /^data_version:[[:space:]]*/ {
            v = $0
            sub(/^data_version:[[:space:]]*/, "", v)
            gsub(/^["'\'']|["'\'']$/, "", v)
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print v
            exit
        }
    ' "$path"
}

# Validate a value as SemVer (major.minor.patch, no pre-release tags
# for our purposes). Returns 0 (true) iff the string matches.
#
# Canonical equivalent: bv_is_clean_semver in deploy/lib/version-bump.sh.
# This copy is intentional — migrate.sh is an executable script, never
# sourced as a library, so it cannot reach the shared predicate; keep the
# two shapes in sync if the clean-SemVer rule ever changes.
is_semver() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Compare two SemVer strings componentwise. Prints -1, 0, or 1 so the
# caller can branch on it.
semver_compare() {
    local a="$1" b="$2"
    local -a as bs
    IFS=. read -r -a as <<<"$a"
    IFS=. read -r -a bs <<<"$b"
    for i in 0 1 2; do
        local an="${as[$i]:-0}"
        local bn="${bs[$i]:-0}"
        if   [ "$an" -lt "$bn" ]; then printf -- '-1\n'; return 0
        elif [ "$an" -gt "$bn" ]; then printf -- '1\n';  return 0
        fi
    done
    printf -- '0\n'
}

# Discover every migration in $MIGRATIONS_DIR and print one record per
# line as `<target_version>\t<absolute_path>`. The list is sorted by
# SemVer (componentwise numeric, NOT lex), so `0.10.0` correctly
# comes after `0.2.0`. Fails (non-zero exit) if two files declare the
# same target version.
discover_migrations() {
    local dir="$1"
    local f base ver
    local -a records=()
    shopt -s nullglob
    for f in "$dir"/*.php; do
        base="$(basename "$f")"
        # Filename shape: <semver>_<slug>.php. The semver is everything
        # up to the first underscore; the slug is the rest before .php.
        ver="${base%%_*}"
        # Skip helper files that don't follow the contract.
        if [ "$ver" = "$base" ]; then
            continue
        fi
        if ! is_semver "$ver"; then
            continue
        fi
        records+=("$ver"$'\t'"$f")
    done
    shopt -u nullglob

    if [ "${#records[@]}" -eq 0 ]; then
        return 0
    fi

    # Sort componentwise. Use `sort` with multiple numeric keys after
    # tab-splitting the version on dots; this is the canonical
    # "SemVer ordering without writing a full comparator in awk"
    # idiom.
    printf '%s\n' "${records[@]}" \
        | awk -F'\t' 'BEGIN { OFS="\t" } { split($1, a, "."); print a[1], a[2], a[3], $1, $2 }' \
        | sort -k1,1n -k2,2n -k3,3n \
        | awk -F'\t' 'BEGIN { OFS="\t" } { print $4, $5 }'
}

# Refuse duplicates: scan the migrations dir and fail if any two files
# share the same <target_version> prefix.
check_no_duplicate_targets() {
    local dir="$1"
    local f base ver
    local -a seen=()
    shopt -s nullglob
    for f in "$dir"/*.php; do
        base="$(basename "$f")"
        ver="${base%%_*}"
        if [ "$ver" = "$base" ] || ! is_semver "$ver"; then
            continue
        fi
        seen+=("$ver"$'\t'"$base")
    done
    shopt -u nullglob

    if [ "${#seen[@]}" -lt 2 ]; then
        return 0
    fi

    local dupes
    dupes="$(printf '%s\n' "${seen[@]}" | awk -F'\t' '{print $1}' | sort | uniq -d || true)"
    if [ -n "$dupes" ]; then
        echo "❌  duplicate migration target version(s) detected:" >&2
        local v
        while IFS= read -r v; do
            echo "    ${v}:" >&2
            printf '%s\n' "${seen[@]}" | awk -F'\t' -v V="$v" '$1 == V { print "      - " $2 }' >&2
        done <<<"$dupes"
        return 1
    fi
    return 0
}

# ----------------------------------------------------------------------
# Resolve from / to
# ----------------------------------------------------------------------

PRE_SPEC_FALLBACK=0
MARKER_PATH="$DATA_DIR_ABS/user/data-version.yaml"
FROM_VERSION="$(extract_data_version "$MARKER_PATH")"
if [ -z "$FROM_VERSION" ]; then
    PRE_SPEC_FALLBACK=1
    FROM_VERSION="0.1.0"
    echo "⚠️  pre-spec backup convention: ${MARKER_PATH} is missing or lacks a data_version field; treating from-version as ${FROM_VERSION}" >&2
fi
if ! is_semver "$FROM_VERSION"; then
    echo "❌  from-version ${FROM_VERSION} is not a valid SemVer (major.minor.patch)" >&2
    exit 3
fi

if [ "$SAW_TO" -eq 0 ]; then
    TARGET_VERSION="$(extract_data_version "$BUNDLE_MARKER")"
    if [ -z "$TARGET_VERSION" ]; then
        echo "❌  --to omitted and bundle marker ${BUNDLE_MARKER} has no data_version field" >&2
        exit 3
    fi
fi
if ! is_semver "$TARGET_VERSION"; then
    echo "❌  target version ${TARGET_VERSION} is not a valid SemVer (major.minor.patch)" >&2
    exit 3
fi

CMP="$(semver_compare "$FROM_VERSION" "$TARGET_VERSION")"
case "$CMP" in
    0)
        echo "already at ${TARGET_VERSION}, nothing to do"
        exit 0
        ;;
    1)
        echo "❌  from-version ${FROM_VERSION} is ahead of target ${TARGET_VERSION}; this runner is forward-only" >&2
        exit 3
        ;;
    -1)
        : # forward migration needed
        ;;
esac

# ----------------------------------------------------------------------
# Discover + filter migrations
# ----------------------------------------------------------------------

if ! check_no_duplicate_targets "$MIGRATIONS_DIR"; then
    exit 4
fi

if [ ! -d "$MIGRATIONS_DIR" ]; then
    echo "❌  migrations dir does not exist: ${MIGRATIONS_DIR}" >&2
    exit 3
fi

# All known migrations, sorted by SemVer.
ALL_LIST="$(discover_migrations "$MIGRATIONS_DIR" || true)"

# Build the chain: every migration whose target satisfies
# from < target <= to. The list is already SemVer-sorted ascending,
# so we just filter.
declare -a CHAIN_VERS=() CHAIN_PATHS=()
if [ -n "$ALL_LIST" ]; then
    while IFS=$'\t' read -r ver path; do
        [ -z "$ver" ] && continue
        local_lo="$(semver_compare "$ver" "$FROM_VERSION")"
        local_hi="$(semver_compare "$ver" "$TARGET_VERSION")"
        if [ "$local_lo" = "1" ] && { [ "$local_hi" = "-1" ] || [ "$local_hi" = "0" ]; }; then
            CHAIN_VERS+=("$ver")
            CHAIN_PATHS+=("$path")
        fi
    done <<<"$ALL_LIST"
fi

# Walk the chain stepwise. After each applied migration, the next
# required target is the immediately-following SemVer; if the chain
# skips it (e.g. from 0.2.0 to 0.4.0 with no 0.3.0_*.php), the runner
# refuses per spec §Missing migration.
#
# In practical terms: every migration's target must be strictly the
# "next" version we expect — but the spec doesn't define what "next"
# means in SemVer space (there's no canonical successor function for
# minor/patch). What it DOES require is that we refuse if we can't
# reach the target. We model that as: the LAST migration's target
# must equal the requested target_version. If it doesn't, the
# requested target is unreachable.
if [ "${#CHAIN_VERS[@]}" -eq 0 ]; then
    echo "no migration to ${TARGET_VERSION} found; cannot proceed from ${FROM_VERSION}" >&2
    exit 5
fi

LAST_TARGET="${CHAIN_VERS[${#CHAIN_VERS[@]}-1]}"
if [ "$(semver_compare "$LAST_TARGET" "$TARGET_VERSION")" != "0" ]; then
    echo "no migration to ${TARGET_VERSION} found; cannot proceed from ${LAST_TARGET}" >&2
    exit 5
fi

# ----------------------------------------------------------------------
# Apply the chain
# ----------------------------------------------------------------------

declare -a APPLIED=()
CURRENT_VERSION="$FROM_VERSION"
for idx in "${!CHAIN_VERS[@]}"; do
    ver="${CHAIN_VERS[$idx]}"
    path="${CHAIN_PATHS[$idx]}"
    name="$(basename "$path")"
    echo "applying ${name}"

    # Run the migration via the PHP bootstrap. Capture stdout so we
    # can pick out the POST_DATA_VERSION line; stderr passes through
    # to the operator. The bootstrap and vendor/ live in
    # $BOOTSTRAP_DIR (default: $PROJECT_DIR/migrations), which can
    # differ from $MIGRATIONS_DIR — that's how the test harness keeps
    # synthetic migration sets lean.
    bootstrap="$BOOTSTRAP_DIR/run-migration.php"
    if [ ! -f "$bootstrap" ]; then
        echo "❌  missing PHP bootstrap: ${bootstrap}" >&2
        exit 6
    fi

    out_tmp="$(mktemp)"
    rc=0
    "${BV_MIGRATE_PHP_CMD[@]}" "$bootstrap" "$path" "$DATA_DIR_ABS" >"$out_tmp" || rc=$?
    if [ "$rc" -ne 0 ]; then
        cat "$out_tmp" || true
        rm -f "$out_tmp"
        echo "❌  migration ${name} failed (exit ${rc})" >&2
        # Surface a stable non-zero rc to callers; preserve the
        # PHP-side exit code when it's already non-zero, otherwise
        # default to 70 (the "migration throw" sentinel).
        if [ "$rc" -eq 0 ]; then rc=70; fi
        exit "$rc"
    fi

    post_version="$(awk -F= '/^POST_DATA_VERSION=/ { print $2 }' "$out_tmp" | tail -n1)"
    # Pass through any non-POST_DATA_VERSION stdout lines so migrations
    # can still log progress.
    grep -v '^POST_DATA_VERSION=' "$out_tmp" || true
    rm -f "$out_tmp"

    if [ -z "$post_version" ]; then
        echo "❌  migration ${name} did not emit POST_DATA_VERSION" >&2
        exit 7
    fi
    if [ "$post_version" != "$ver" ]; then
        echo "❌  migration ${name} wrote data_version=${post_version}; expected ${ver}" >&2
        exit 7
    fi

    APPLIED+=("$name")
    CURRENT_VERSION="$ver"
done

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------

echo ""
echo "migration summary"
echo "  from:   ${FROM_VERSION}"
echo "  to:     ${TARGET_VERSION}"
echo "  applied:"
for name in "${APPLIED[@]}"; do
    echo "    - ${name}"
done
if [ "$PRE_SPEC_FALLBACK" -eq 1 ]; then
    echo "  note: from-version was inferred via the pre-spec convention"
fi
exit 0
