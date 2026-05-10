#!/usr/bin/env bash
#
# Age-key Keychain helpers — public keys live in
# deploy/age-recipients.txt (committed), private keys live in macOS
# Keychain as generic-password items named bv-age-identity-<label>.
#
# Why this shape:
#   * Public keys are public. Committing them makes "who can decrypt
#     our backups" reviewable in PR.
#   * Private keys are per-operator. Each operator's Mac holds only
#     THEIR own private key, in macOS Keychain. The Keychain item
#     value is the full age identity file format (multi-line:
#     `# created at: …`, `# public key: age1…`, `AGE-SECRET-KEY-…`).
#   * Multi-recipient: backup.sh encrypts to ALL public keys in
#     deploy/age-recipients.txt; ANY operator's private key decrypts.
#   * Cap of 5: enforced by backup.sh on the recipients file. Five
#     active operators max.
#
# This helper is macOS-only (depends on `security` CLI). Linux / CI
# operators use AGE_IDENTITY_FILE env-var as a fallback (handled in
# restore.sh).

# shellcheck shell=bash

# All Keychain items the helper manages share this prefix. The full
# item name is "<prefix><label>" — labels are operator-chosen, e.g.
# `bv-age-identity-thomas`.
BV_AGE_KEYCHAIN_PREFIX="bv-age-identity-"

# Maximum number of public keys allowed in deploy/age-recipients.txt.
# Mirrored in backup.sh's enforcement; kept here so the manage CLI
# can fail-fast at `generate` time before anyone takes a backup with
# a too-many-recipients file.
BV_AGE_RECIPIENTS_CAP=5

# Recipients file path resolution. Defaults to the in-repo
# deploy/age-recipients.txt (committed); override via
# BV_AGE_RECIPIENTS_FILE for tests / non-default layouts.
bv_age_recipients_file() {
    printf '%s\n' "${BV_AGE_RECIPIENTS_FILE:-${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/age-recipients.txt}"
}

# Detect macOS `security` CLI. Returns 0 if available, 1 with a
# diagnostic on stderr otherwise.
bv_age_keychain_available() {
    if command -v security >/dev/null 2>&1; then
        return 0
    fi
    echo "❌  macOS 'security' CLI not on PATH. Keychain integration is macOS-only." >&2
    echo "    On Linux / CI, set AGE_IDENTITY_FILE to a path holding the operator's age private key." >&2
    return 1
}

# List labels for every bv-age-identity-* item in the user's Keychain.
# One label per line (sorted, deduplicated). Empty output if none.
#
# `security dump-keychain` is too expensive for routine use; instead
# we probe known labels by walking deploy/age-recipients.txt and
# matching against `# bv-age-identity-<label>` comment lines that
# `bv_age_keychain_generate` writes. That avoids enumerating the
# entire Keychain.
#
# Caller pattern: this returns labels you MIGHT have in Keychain; for
# each, attempt `bv_age_keychain_get_identity` and check the return
# code to confirm presence.
bv_age_keychain_known_labels() {
    local rf
    rf="$(bv_age_recipients_file)"
    [ -f "$rf" ] || return 0
    awk '
        /^# bv-age-identity-/ {
            # Strip the marker prefix, then take the first
            # whitespace-delimited token as the label. Anything after
            # (timestamps, operator names, parentheticals) is comment
            # metadata for humans, not part of the label.
            sub(/^# bv-age-identity-/, "", $0)
            split($0, parts, /[[:space:]]/)
            if (length(parts[1]) > 0) print parts[1]
        }
    ' "$rf" | sort -u
}

# Read the full identity-file content from Keychain item
# bv-age-identity-<label>. Echoes the multi-line content on stdout.
# Returns 0 on success; non-zero (and empty stdout) if the item is
# not present.
bv_age_keychain_get_identity() {
    local label="$1"
    [ -n "$label" ] || { echo "FATAL: bv_age_keychain_get_identity requires a label" >&2; return 1; }
    bv_age_keychain_available || return 1
    security find-generic-password \
        -a "${USER:-}" \
        -s "${BV_AGE_KEYCHAIN_PREFIX}${label}" \
        -w \
        2>/dev/null
}

# Extract the public-key line (`age1...`) from a Keychain item's
# stored identity content. Empty output if the item is missing or
# malformed.
bv_age_keychain_get_pubkey() {
    local label="$1"
    local identity
    identity="$(bv_age_keychain_get_identity "$label")" || return 1
    printf '%s\n' "$identity" \
        | awk '/^# public key:/ { print $4; exit }' \
        | tr -d '[:space:]'
}

# Try every Keychain identity until one decrypts $1 (an age-encrypted
# file) into $2 (target plaintext path). On success, returns 0 and
# leaves $2 with the plaintext. On failure (no identity matched),
# returns 1 and leaves $2 absent.
#
# Each Keychain `find-generic-password -w` may prompt the user for
# Keychain unlock the first time; "Always Allow" once and subsequent
# tries skip the prompt.
bv_age_keychain_try_decrypt() {
    local enc_archive="$1"
    local plaintext_out="$2"
    local labels label identity tmp_identity
    bv_age_keychain_available || return 1

    labels="$(bv_age_keychain_known_labels)"
    if [ -z "$labels" ]; then
        return 1
    fi

    while IFS= read -r label; do
        [ -n "$label" ] || continue
        identity="$(bv_age_keychain_get_identity "$label" 2>/dev/null || true)"
        [ -n "$identity" ] || continue

        # age -i wants a path to an identity file. Materialise the
        # Keychain content into a tempfile that lives only for the
        # duration of one decryption attempt. (mktemp -d is BSD-safe;
        # see lint-remote-ssh.sh's check 6b for why we don't use
        # -t/.suffix patterns.)
        tmp_identity="$(mktemp -d "${TMPDIR:-/tmp}/bv-age-id.XXXXXXXX")/identity"
        printf '%s\n' "$identity" > "$tmp_identity"
        chmod 600 "$tmp_identity"

        if age -d -i "$tmp_identity" -o "$plaintext_out" "$enc_archive" 2>/dev/null; then
            rm -rf "$(dirname "$tmp_identity")"
            return 0
        fi
        rm -rf "$(dirname "$tmp_identity")"
    done <<<"$labels"

    return 1
}

# Store an age identity file (its full content) into Keychain under
# bv-age-identity-<label>. Refuses to overwrite an existing item by
# default; pass --overwrite to replace.
bv_age_keychain_store_identity() {
    local label="$1"
    local identity_file="$2"
    local overwrite="${3:-no-overwrite}"

    [ -n "$label" ]         || { echo "FATAL: bv_age_keychain_store_identity requires a label" >&2; return 1; }
    [ -f "$identity_file" ] || { echo "FATAL: identity file '$identity_file' not found" >&2; return 1; }
    bv_age_keychain_available || return 1

    local existing
    existing="$(bv_age_keychain_get_identity "$label" 2>/dev/null || true)"
    if [ -n "$existing" ] && [ "$overwrite" != "--overwrite" ]; then
        echo "❌  Keychain item '${BV_AGE_KEYCHAIN_PREFIX}${label}' already exists. Pass --overwrite to replace." >&2
        return 1
    fi

    if [ -n "$existing" ]; then
        # Delete existing item so the add doesn't return 45 ("already
        # exists" — security CLI's bizarre overwrite-via-delete idiom).
        security delete-generic-password \
            -a "${USER:-}" \
            -s "${BV_AGE_KEYCHAIN_PREFIX}${label}" \
            >/dev/null 2>&1 || true
    fi

    # security add-generic-password reads the password from a file
    # via -w with a "no-value-here" trick (interactive prompt). Multi-
    # line input requires a different approach: write the identity
    # via stdin redirection. Use the -X form which reads from stdin.
    # NOTE: the security man page lists -w with mandatory value; for
    # multi-line we use printf | security with -w "$(cat ...)" — bash
    # handles the multi-line value just fine.
    local identity_content
    identity_content="$(cat "$identity_file")"
    security add-generic-password \
        -a "${USER:-}" \
        -s "${BV_AGE_KEYCHAIN_PREFIX}${label}" \
        -l "Byværkstederne age identity ($label)" \
        -j "Generated by deploy/manage-age-keys.sh. Holds the full age identity file (public + private)." \
        -w "$identity_content"
}

# Delete a Keychain item by label. Returns 0 if removed, non-zero if
# the item didn't exist (callers can check or ignore).
bv_age_keychain_delete() {
    local label="$1"
    [ -n "$label" ] || { echo "FATAL: bv_age_keychain_delete requires a label" >&2; return 1; }
    bv_age_keychain_available || return 1
    security delete-generic-password \
        -a "${USER:-}" \
        -s "${BV_AGE_KEYCHAIN_PREFIX}${label}" \
        >/dev/null 2>&1
}

# Count active (non-comment, non-blank) recipient lines in the
# recipients file. Used by backup.sh and the manage CLI to enforce
# the cap of BV_AGE_RECIPIENTS_CAP.
bv_age_recipients_count() {
    local rf
    rf="$(bv_age_recipients_file)"
    [ -f "$rf" ] || { printf '0\n'; return 0; }
    grep -cE '^age1[a-z0-9]+$' "$rf" || true
}
