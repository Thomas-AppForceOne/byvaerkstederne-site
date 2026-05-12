#!/usr/bin/env bash
#
# Operator-laptop privacy-hygiene banner.
#
# Both backup.sh and restore.sh can materialise PII (account hashes,
# flex objects, uploaded files) on the operator's machine. The paths
# they actually write to are:
#
#   $LOCAL_BACKUP_DIR          — backup.sh --keep-local + upload-failure
#                                fallback. Default ~/.byvaerkstederne/backups
#                                (machine-wide; once-per-machine
#                                tmutil exclusion). Override via
#                                BV_KEEP_LOCAL_DIR.
#   <restore.sh --to TARGET>   — operator-chosen scratch dir (varies)
#   $RESTORE_LOCAL_TIER_DIR    — operator-chosen tier dir for the
#                                local-tier restore mode (varies)
#
# Of those, only the local-keep dir has a stable location across
# invocations. The other two are operator-chosen at invocation time,
# so the banner can't pre-list `tmutil addexclusion` commands for
# them — instead it warns the operator to remember to exclude their
# chosen target path the first time they pass --to <dir> or set
# RESTORE_LOCAL_TIER_DIR.
#
# (An earlier draft listed `./deploy/staging-stage/` and
# `./deploy/prod-stage/` here. The implementation never writes to
# those — restore.sh uses `/tmp/bv-restore-tier.*` for SSH-mode scratch
# and the operator's RESTORE_LOCAL_TIER_DIR for local-tier mode. The
# banner used to mention those ghost paths anyway, which was
# misleading: operators following the recommendation would exclude
# directories the script never creates.)
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

    # Resolve the local-keep dir for the banner copy. Caller has
    # already loaded backup.sh/restore.sh which set LOCAL_BACKUP_DIR;
    # we read it via the env so the banner reflects the current
    # value (default or BV_KEEP_LOCAL_DIR override).
    local kept_dir="${LOCAL_BACKUP_DIR:-$HOME/.byvaerkstederne/backups}"

    # Print the banner to stderr. We use printf rather than a heredoc
    # so the indentation in source doesn't bleed into the output.
    {
        printf '\n'
        printf '────────────────────────────────────────────────────────────────\n'
        printf '  Byværkstederne backup/restore — operator-laptop hygiene\n'
        printf '────────────────────────────────────────────────────────────────\n'
        printf '  This is the first time backup.sh or restore.sh has written\n'
        printf '  into a privacy-sensitive path on this machine. These paths\n'
        printf '  can carry user account hashes, Flex Objects, and uploaded\n'
        printf '  files. Please exclude them from Time Machine.\n'
        printf '\n'
        printf '  The persistent path is `%s`\n' "$kept_dir"
        printf '  (local-keep archives + upload-fallback copies). It is\n'
        printf '  machine-wide — every worktree of this repo + every\n'
        printf '  GAN-run worktree shares it, so the exclusion is\n'
        printf '  once-per-machine, not once-per-worktree:\n'
        printf '\n'
        printf '    tmutil addexclusion %s\n' "$kept_dir"
        printf '\n'
        printf '  If you also use:\n'
        printf '    - `restore.sh --to <dir>` for scratch inspection, or\n'
        printf '    - `RESTORE_LOCAL_TIER_DIR=<dir>` for the local-tier\n'
        printf '      restore mode,\n'
        printf '  remember to `tmutil addexclusion` whichever path you chose\n'
        printf '  for those, too. This banner can'\''t pre-list them because\n'
        printf '  they vary per invocation.\n'
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
