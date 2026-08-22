#!/usr/bin/env bash
#
# grav-parity.sh — one Grav version, everywhere. The second axis.
#
# WHY THIS EXISTS
# ---------------
# The Grav core is NOT in this repo. It arrives from two unrelated places:
#
#   locally .... the container image (docker-compose.yml, pinned by digest)
#   on a tier .. deploy/grav-admin-v<VERSION>.zip, unpacked by deploy.sh
#
# Nothing compared them. On 2026-08-21 a `docker pull latest` — routine,
# and taken during work whose entire purpose was eliminating environment
# divergence — silently upgraded the local CMS from 1.7.49.5 to 2.0.20, a
# MAJOR version ahead of every tier. It also wrote into the tracked tree
# and left auto-generated secrets behind that a `git add -A` then
# committed. None of it announced itself; the site still answered 200.
#
# A subtler instance had been sitting there the whole time: the container
# ran Grav 1.7.49.5 while the tiers were served 1.7.52. Same class, smaller
# blast radius, equally unnoticed.
#
# PHP parity alone would have waved both through — deploy/lib/php-parity.sh
# compares only the interpreter. This file compares the CMS.
#
# TOLERANCE
# ---------
# MAJOR.MINOR, matching the PHP guard. Patch drift inside a minor is
# tolerated because that is what a hosting provider or an image rebuild
# will do without asking; a minor or major jump is a migration and must be
# a decision. 1.7.49.5 vs 1.7.52 therefore passes; 1.7 vs 2.0 does not.
#
# OVERRIDE
# --------
# ALLOW_GRAV_MISMATCH=1, mirroring ALLOW_PHP_MISMATCH.

# The version this repo deploys, taken from the payload filename — the one
# artefact that cannot disagree with what actually ships.
# Usage: bv_grav_target <project_dir>
bv_grav_target() {
    local zip
    zip="$(ls "$1"/deploy/grav-admin-v*.zip 2>/dev/null | head -1)"
    [ -n "$zip" ] || return 1
    printf '%s' "$zip" | sed -E 's/.*grav-admin-v([0-9.]+)\.zip/\1/'
}

# "1.7.52" -> "1.7";  "define('GRAV_VERSION', '2.0.20');" -> "2.0"
bv_grav_major_minor() {
    printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1
}

# bv_grav_parity_check <target> <reported> <where> <allow_mismatch>
# Returns 0 to proceed, 1 to refuse. Diagnostics on stderr.
bv_grav_parity_check() {
    local target="$1" reported="$2" where="$3" allow="${4:-0}"

    local want got
    want="$(bv_grav_major_minor "$target")"
    got="$(bv_grav_major_minor "$reported")"

    if [ -z "$want" ]; then
        printf '⚠️   grav-parity: no deploy payload found — check skipped.\n' >&2
        return 0
    fi
    if [ -z "$got" ]; then
        printf '⚠️   grav-parity: could not read the Grav version on %s — check skipped.\n' "$where" >&2
        return 0
    fi
    if [ "$want" = "$got" ]; then
        printf '  ✓ Grav %s on %s matches the deployed payload\n' "$got" "$where"
        return 0
    fi

    if [ "$allow" = "1" ]; then
        printf '⚠️   grav-parity: %s runs Grav %s but this repo deploys %s — ALLOW_GRAV_MISMATCH=1 override in effect.\n' \
            "$where" "$got" "$want" >&2
        return 0
    fi

    printf '❌  Refusing: %s runs Grav %s, this repo deploys Grav %s.\n' "$where" "$got" "$want" >&2
    printf '    A CMS major or minor apart is a migration, not a detail — the code\n' >&2
    printf '    exercised locally would not be the code the tier runs.\n' >&2
    printf '\n' >&2
    printf '    Either replace deploy/grav-admin-v*.zip and re-run the suites, or\n' >&2
    printf '    bring %s back to Grav %s.\n' "$where" "$want" >&2
    printf '\n' >&2
    printf '    Emergency override:  ALLOW_GRAV_MISMATCH=1 <command>\n' >&2
    return 1
}
