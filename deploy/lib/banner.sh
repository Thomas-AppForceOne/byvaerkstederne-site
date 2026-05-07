#!/usr/bin/env bash
#
# Operator-laptop privacy-hygiene banner.
#
# Both backup.sh and restore.sh write into a small set of paths that
# can carry user PII (account hashes, flex objects, uploaded files):
#
#   ./backups/               — local-keep archives + upload-fallback
#   ./deploy/staging-stage/  — restore-to-tier scratch staging
#   ./deploy/prod-stage/     — restore-to-tier scratch staging
#
# These paths must be excluded from Time Machine and never live inside
# a Dropbox/iCloud/Google-Drive synced root. The first time either
# script writes into one of them on a given laptop, we print a
# one-shot reminder banner to stderr listing the corresponding
# `tmutil addexclusion` commands and the cloud-sync warning.
#
# "First time on this machine" is tracked by a sentinel file at:
#
#   ${XDG_CONFIG_HOME:-$HOME/.config}/byvaerksted/backup-banner-shown
#
# Once the sentinel exists, the banner is suppressed on every
# subsequent run. Operators who want to re-see the reminder can `rm`
# the sentinel.
#
# The banner ALWAYS goes to stderr so stdout remains a parseable
# URL/path channel for cron friendliness.
#
# Usage:
#   . "$SCRIPT_DIR/lib/banner.sh"
#   bv_show_first_write_banner_if_needed   # call before the first
#                                          # write into a sensitive path

# shellcheck shell=bash

bv_banner_sentinel_path() {
    local cfg_root="${XDG_CONFIG_HOME:-$HOME/.config}"
    printf '%s/byvaerksted/backup-banner-shown\n' "$cfg_root"
}

bv_show_first_write_banner_if_needed() {
    local sentinel
    sentinel="$(bv_banner_sentinel_path)"
    if [ -e "$sentinel" ]; then
        return 0
    fi

    # Print the banner to stderr. We use printf rather than a heredoc
    # so the indentation in source doesn't bleed into the output.
    {
        printf '\n'
        printf '────────────────────────────────────────────────────────────────\n'
        printf '  Byværkstederne backup/restore — operator-laptop hygiene\n'
        printf '────────────────────────────────────────────────────────────────\n'
        printf '  This is the first time backup.sh or restore.sh has written\n'
        printf '  into one of the privacy-sensitive paths on this machine:\n'
        printf '\n'
        printf '    ./backups/\n'
        printf '    ./deploy/staging-stage/\n'
        printf '    ./deploy/prod-stage/\n'
        printf '\n'
        printf '  These directories may carry user account hashes, Flex\n'
        printf '  Objects, and uploaded files. Please exclude them from Time\n'
        printf '  Machine by running:\n'
        printf '\n'
        printf '    tmutil addexclusion ./backups\n'
        printf '    tmutil addexclusion ./deploy/staging-stage\n'
        printf '    tmutil addexclusion ./deploy/prod-stage\n'
        printf '\n'
        printf '  Cloud-sync warning: do NOT keep this checkout inside a\n'
        printf '  Dropbox / iCloud Drive / Google Drive / OneDrive synced\n'
        printf '  root — those services would replicate the PII to a\n'
        printf '  third-party service. Move the checkout to a non-synced\n'
        printf '  location (e.g. ~/code/) before running these scripts.\n'
        printf '\n'
        printf '  This banner is shown once; remove the sentinel to see it\n'
        printf '  again:\n'
        printf '\n'
        printf '    rm %s\n' "$sentinel"
        printf '────────────────────────────────────────────────────────────────\n'
        printf '\n'
    } >&2

    # Create the sentinel. Errors here (read-only $HOME, permission
    # denied) are warned but not fatal — the banner already showed.
    local dir
    dir="$(dirname "$sentinel")"
    if ! mkdir -p "$dir" 2>/dev/null; then
        printf '[backup/restore] WARN: could not create sentinel dir %s; banner will reappear next run\n' "$dir" >&2
        return 0
    fi
    if ! : > "$sentinel" 2>/dev/null; then
        printf '[backup/restore] WARN: could not create sentinel %s; banner will reappear next run\n' "$sentinel" >&2
        return 0
    fi
    # Restrictive perms so the sentinel can't be tampered with by
    # other users on a shared box.
    chmod 0644 "$sentinel" 2>/dev/null || true
    return 0
}
