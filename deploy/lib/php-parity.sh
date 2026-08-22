#!/usr/bin/env bash
#
# php-parity.sh — one PHP version, everywhere.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-21 an audit found FIVE PHP versions in play, none of them
# overlapping:
#
#   local Docker (grav:latest, unpinned) ... 8.3.15
#   CI migrations matrix ................... 8.1, 8.2, 8.3
#   dev / test / staging (one.com) ......... 8.5.9
#   prod (chosting) ........................ 8.4.24
#
# So no PHP version that RUNS the code was ever tested, and no tested
# version ran anywhere. That is the "works on dev, breaks on prod" failure
# class in its purest form — and it was invisible because nothing compared
# the numbers.
#
# The repo now declares ONE target in `.php-version` at the repo root.
# Every consumer reads that file:
#
#   docker-compose.yml   pinned by digest to an image carrying that version
#   .github/workflows/*  sets up that version
#   deploy.sh preflight  refuses a deploy to a tier running anything else
#
# WHY 8.3
# -------
# Grav 1.7.52 declares `^7.3.6 || ^8.0`, so upstream permits any PHP 8.
# But 8.4 deprecated implicit nullable parameters, which Grav core uses
# throughout: production emits ~570 deprecation notices per request cycle
# and has accumulated a 12.5 MB error_log. 8.3 is the newest version on
# which this Grav runs clean, and it is what the container and CI already
# execute. Changing the target is a one-line edit here; the guards then
# follow automatically.
#
# HOW TO CHANGE A TIER'S PHP (operator action, not automatable from here)
#   one.com (dev/test/staging): control panel → PHP version
#   chosting (prod):            cPanel → MultiPHP Manager → select for domain
#
# OVERRIDE
# --------
# `ALLOW_PHP_MISMATCH=1 make deploy tier=<t>` proceeds anyway, matching the
# ALLOW_STAGING_DEPLOY_OFF_MAIN / ALLOW_STAGING_DEPLOY_DIRTY idiom already
# used by the release gate. It warns loudly rather than failing.

# Absolute path to the repo's declared PHP target file.
# Usage: bv_php_target_file <project_dir>
bv_php_target_file() {
    printf '%s/.php-version' "$1"
}

# Read the declared target, trimmed. Empty (and rc 1) when absent/blank.
# Usage: bv_php_target <project_dir>
bv_php_target() {
    local f
    f="$(bv_php_target_file "$1")"
    [ -f "$f" ] || return 1
    local v
    v="$(tr -d '[:space:]' < "$f")"
    [ -n "$v" ] || return 1
    printf '%s' "$v"
}

# Reduce a full PHP version string to MAJOR.MINOR.
# "8.3.15" -> "8.3";  "PHP 8.4.24 (cli) ..." -> "8.4"
bv_php_major_minor() {
    printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# Compare a tier's reported PHP against the declared target.
#
# Usage: bv_php_parity_check <target> <reported> <tier> <allow_mismatch>
# Returns 0 to proceed, 1 to refuse. Diagnostics on stderr.
bv_php_parity_check() {
    local target="$1" reported="$2" tier="$3" allow="${4:-0}"

    local want got
    want="$(bv_php_major_minor "$target")"
    got="$(bv_php_major_minor "$reported")"

    if [ -z "$want" ]; then
        printf '⚠️   php-parity: no target declared in .php-version — skipping check.\n' >&2
        return 0
    fi
    if [ -z "$got" ]; then
        # A tier that will not tell us its version is not a pass; say so, but
        # do not block a deploy on an unreadable `php -v` (some hosts hide the
        # CLI). This is the one soft case, and it is reported.
        printf '⚠️   php-parity: could not read PHP version on %s — check skipped.\n' "$tier" >&2
        return 0
    fi
    if [ "$want" = "$got" ]; then
        printf '  ✓ PHP %s on %s matches .php-version\n' "$got" "$tier"
        return 0
    fi

    if [ "$allow" = "1" ]; then
        printf '⚠️   php-parity: %s runs PHP %s but .php-version declares %s — ALLOW_PHP_MISMATCH=1 override in effect.\n' \
            "$tier" "$got" "$want" >&2
        return 0
    fi

    printf '❌  Refusing to deploy: %s runs PHP %s, this repo targets PHP %s.\n' "$tier" "$got" "$want" >&2
    printf '    Untested-version drift is the failure class this guard exists for —\n' >&2
    printf '    code exercised on %s and served on %s is code nobody has run.\n' "$want" "$got" >&2
    printf '\n' >&2
    printf '    Fix the tier (operator action):\n' >&2
    case "$tier" in
        prod) printf '      chosting cPanel → MultiPHP Manager → set %s for the domain\n' "$want" >&2 ;;
        *)    printf '      one.com control panel → PHP version → set %s\n' "$want" >&2 ;;
    esac
    printf '    Or change the target in .php-version (and re-run CI on it first).\n' >&2
    printf '\n' >&2
    printf '    Emergency override:  ALLOW_PHP_MISMATCH=1 make deploy tier=%s\n' "$tier" >&2
    return 1
}
