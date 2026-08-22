#!/usr/bin/env bash
#
# php-handler.sh — read, validate and PRESERVE a tier's PHP handler line.
#
# WHY THIS IS "PRESERVE AND VALIDATE", NOT "GENERATE"
# ---------------------------------------------------
# On cPanel the PHP version a domain is served with is chosen in MultiPHP
# Manager, and cPanel expresses that choice by writing an AddHandler line
# into the domain's .htaccess:
#
#     AddHandler application/x-httpd-ea-php85 .php .php8 .phtml
#
# That file is also generated and shipped by every deploy of this repo, so
# a deploy overwrote the operator's choice and dropped the domain back to
# the system default — silently. Found on 2026-08-22, when prod had just
# been moved to ea-php85 and the pending deploy would have reverted it.
#
# The first fix generated the line ourselves from .php-version. That was
# the wrong shape, and the reason is worth keeping:
#
#   * The .htaccess line is cPanel's OUTPUT, not our configuration. The
#     source of truth is cPanel's own config. Writing the line ourselves
#     forges a value another system believes it owns, so the UI can say one
#     thing while the file says another.
#   * An EasyApache rebuild or an operator pressing Apply rewrites it, and
#     the next deploy writes ours back — a ping-pong nobody asked for.
#   * If PHP-FPM is ever enabled for the domain, AddHandler stops being the
#     mechanism at all. We would have been maintaining a decoration while
#     believing we controlled the version.
#
# So: cPanel remains the source of truth, the deploy CARRIES the line
# forward instead of destroying it, and the repo's job is to notice when
# the tier disagrees with .php-version and refuse.
#
# A deploy therefore cannot FIX a wrong version — it refuses, and the
# operator changes it where the setting actually lives. That is the point.

# Extract the handler line from .htaccess content on stdin (or $1).
# Echoes the whole directive, or nothing when absent.
bv_php_handler_line() {
    local content="${1:-$(cat)}"
    printf '%s\n' "$content" \
        | grep -E '^[[:space:]]*AddHandler[[:space:]]+application/x-httpd-(ea-)?php[0-9]+' \
        | head -1
}

# "AddHandler application/x-httpd-ea-php85 .php" -> "8.5"
# Echoes nothing when the line carries no recognisable version.
bv_php_handler_version() {
    local line="$1" digits
    digits="$(printf '%s' "$line" | grep -oE 'php[0-9]+' | head -1 | tr -cd '0-9')"
    [ -n "$digits" ] || return 0
    # 85 -> 8.5, 84 -> 8.4. Two digits is the cPanel convention.
    printf '%s.%s' "${digits%${digits#?}}" "${digits#?}"
}

# bv_php_handler_check <declared_target> <handler_line> <tier> <allow_mismatch>
#
# Returns 0 to proceed, 1 to refuse. A tier with no handler line is reported,
# not failed: only cPanel tiers have one, and on the others its absence is
# correct.
bv_php_handler_check() {
    local target="$1" line="$2" tier="$3" allow="${4:-0}"

    if [ -z "$line" ]; then
        printf '  · %s has no PHP handler line (not a cPanel tier, or inheriting the system default)\n' "$tier"
        return 0
    fi

    local want got
    want="$(printf '%s' "$target" | grep -oE '[0-9]+\.[0-9]+' | head -1)"
    got="$(bv_php_handler_version "$line")"

    if [ -z "$want" ] || [ -z "$got" ]; then
        printf '⚠️   php-handler: could not compare (%s declares %s, tier reports %s) — check skipped.\n' \
            "$tier" "${want:-none}" "${got:-none}" >&2
        return 0
    fi

    if [ "$want" = "$got" ]; then
        printf '  ✓ %s serves PHP %s (handler matches .php-version)\n' "$tier" "$got"
        return 0
    fi

    if [ "$allow" = "1" ]; then
        printf '⚠️   php-handler: %s serves PHP %s but .php-version declares %s — ALLOW_PHP_MISMATCH=1 override in effect.\n' \
            "$tier" "$got" "$want" >&2
        return 0
    fi

    printf '❌  Refusing to deploy: %s serves PHP %s, this repo targets PHP %s.\n' "$tier" "$got" "$want" >&2
    printf '    Read from the handler line the hosting panel writes:\n' >&2
    printf '      %s\n' "$line" >&2
    printf '\n' >&2
    printf '    This deploy will NOT change it. The setting lives in the hosting\n' >&2
    printf '    panel, and writing it from here would forge a value cPanel owns —\n' >&2
    printf '    its UI would then disagree with the file. Change it where it lives:\n' >&2
    printf '      cPanel → MultiPHP Manager → set PHP %s for the domain\n' "$want" >&2
    printf '\n' >&2
    printf '    Or change the target in .php-version, and re-run CI on it first.\n' >&2
    printf '\n' >&2
    printf '    Emergency override:  ALLOW_PHP_MISMATCH=1 make deploy tier=%s\n' "$tier" >&2
    return 1
}
