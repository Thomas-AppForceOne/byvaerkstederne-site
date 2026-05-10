#!/usr/bin/env bash
#
# Operator CLI for managing age keypairs used by deploy/backup.sh and
# deploy/restore.sh. Public keys live in deploy/age-recipients.txt
# (committed). Private keys live in macOS Keychain. Cap of 5 active
# recipients enforced by the `generate` subcommand and by backup.sh.
#
# Subcommands:
#   generate <label>   Generate a new keypair, store private in
#                      Keychain as bv-age-identity-<label>, and
#                      append the public key to age-recipients.txt.
#   list               Show every recipient in age-recipients.txt;
#                      mark which ones have a corresponding private
#                      key in YOUR local Keychain.
#   retire <label>     Remove the public key from age-recipients.txt.
#                      Optionally pass --delete-keychain to ALSO
#                      remove the private key from your local
#                      Keychain (otherwise it stays — useful for
#                      decrypting old backups encrypted to the now-
#                      retired key).
#
# Usage examples:
#   ./deploy/manage-age-keys.sh generate thomas
#   ./deploy/manage-age-keys.sh list
#   ./deploy/manage-age-keys.sh retire alice --delete-keychain

set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "❌  bash 4+ required (this is bash ${BASH_VERSION:-?}). On macOS:" >&2
    echo "      brew install bash" >&2
    echo "    Then ensure /opt/homebrew/bin is on PATH ahead of /usr/bin." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=deploy/lib/age-keychain.sh
. "$SCRIPT_DIR/lib/age-keychain.sh"

usage() {
    cat <<USAGE
Usage:
  $(basename "$0") generate <label>
  $(basename "$0") list
  $(basename "$0") retire <label> [--delete-keychain]

Subcommands:
  generate   Create a new age keypair, store private in macOS
             Keychain (bv-age-identity-<label>), append public key
             to deploy/age-recipients.txt. Cap of $BV_AGE_RECIPIENTS_CAP
             active recipients enforced.
  list       Show every recipient in deploy/age-recipients.txt and
             whether you hold a private key for it in Keychain.
  retire     Remove a public key from deploy/age-recipients.txt.
             With --delete-keychain, also delete the private key
             from your Keychain.

Examples:
  $(basename "$0") generate thomas
  $(basename "$0") list
  $(basename "$0") retire alice --delete-keychain
USAGE
}

require_age() {
    command -v age          >/dev/null 2>&1 || { echo "❌  age not installed. brew install age" >&2; exit 1; }
    command -v age-keygen   >/dev/null 2>&1 || { echo "❌  age-keygen not installed (ships with age). brew install age" >&2; exit 1; }
}

cmd_generate() {
    local label="$1"
    [ -n "$label" ] || { echo "❌  generate requires a label argument" >&2; usage >&2; exit 1; }
    case "$label" in
        *[!a-zA-Z0-9_-]*) echo "❌  label '$label' contains invalid characters (allowed: A-Z a-z 0-9 _ -)" >&2; exit 1 ;;
    esac

    require_age
    bv_age_keychain_available

    local rf
    rf="$(bv_age_recipients_file)"

    # Cap check: refuse if adding would exceed the cap.
    local current_count
    current_count="$(bv_age_recipients_count)"
    if [ "$current_count" -ge "$BV_AGE_RECIPIENTS_CAP" ]; then
        echo "❌  Recipients file already has $current_count active keys (cap: $BV_AGE_RECIPIENTS_CAP)." >&2
        echo "    Retire one with \`$(basename "$0") retire <label>\` before adding another." >&2
        exit 1
    fi

    # Refuse if a Keychain item with this label already exists.
    if [ -n "$(bv_age_keychain_get_identity "$label" 2>/dev/null || true)" ]; then
        echo "❌  Keychain item '${BV_AGE_KEYCHAIN_PREFIX}${label}' already exists." >&2
        echo "    Pick a different label or retire the existing one first:" >&2
        echo "      $(basename "$0") retire $label --delete-keychain" >&2
        exit 1
    fi

    # Generate keypair into a tempfile, then store in Keychain. We
    # never write the identity to a persistent file on disk — it goes
    # straight from age-keygen to Keychain.
    local tmp_dir tmp_identity
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/bv-age-gen.XXXXXXXX")"
    trap 'rm -rf "$tmp_dir"' EXIT
    tmp_identity="$tmp_dir/identity.txt"

    age-keygen -o "$tmp_identity" 2>"$tmp_dir/keygen.stderr"
    chmod 600 "$tmp_identity"

    local pubkey
    pubkey="$(awk '/^# public key:/ {print $4; exit}' "$tmp_identity")"
    if [ -z "$pubkey" ]; then
        echo "❌  age-keygen did not emit a public-key line; aborting" >&2
        cat "$tmp_dir/keygen.stderr" >&2
        exit 1
    fi

    bv_age_keychain_store_identity "$label" "$tmp_identity"

    # Append public key to recipients file with a comment naming the
    # label so list / retire can find it later.
    if [ ! -f "$rf" ]; then
        printf '# Byværkstederne age recipients — committed; per-operator\n# private keys live in macOS Keychain.\n#\n' > "$rf"
    fi
    {
        printf '\n# bv-age-identity-%s   (added %s by %s@%s)\n' \
            "$label" "$(date -u +%Y-%m-%dT%H:%MZ)" "${USER:-?}" "$(hostname -s 2>/dev/null || hostname || echo '?')"
        printf '%s\n' "$pubkey"
    } >> "$rf"

    echo ""
    echo "✓ Generated keypair, stored private in Keychain as ${BV_AGE_KEYCHAIN_PREFIX}${label}"
    echo "✓ Appended public key to $rf"
    echo ""
    echo "  Public key: $pubkey"
    echo ""
    echo "Next step: review the diff to $rf, commit it, open a PR."
    echo "After merge, future backups will be encrypted to your key (and existing operators' keys) — any of those operators can decrypt."
}

cmd_list() {
    bv_age_keychain_available

    local rf
    rf="$(bv_age_recipients_file)"
    if [ ! -f "$rf" ]; then
        echo "(no recipients file at $rf)"
        return 0
    fi

    echo "Recipients in $rf:"
    echo ""

    # Walk the file matching `# bv-age-identity-<label>` markers
    # immediately followed by the corresponding age1... line.
    local label="" pubkey="" line
    while IFS= read -r line; do
        case "$line" in
            \#\ bv-age-identity-*)
                # Extract label
                label="${line#\# bv-age-identity-}"
                label="${label%% *}"
                ;;
            age1*)
                pubkey="$line"
                if [ -n "$label" ]; then
                    local marker="" kc_pub
                    kc_pub="$(bv_age_keychain_get_pubkey "$label" 2>/dev/null || true)"
                    if [ -n "$kc_pub" ] && [ "$kc_pub" = "$pubkey" ]; then
                        marker="✓ private key in YOUR Keychain"
                    elif [ -n "$kc_pub" ]; then
                        marker="⚠ Keychain pubkey mismatches recipient — stale Keychain item?"
                    else
                        marker="(another operator holds the private key)"
                    fi
                    printf '  %-25s %s\n      %s\n\n' "$label" "$pubkey" "$marker"
                else
                    printf '  %-25s %s\n      ⚠ no `# bv-age-identity-<label>` marker; managed elsewhere?\n\n' "(unlabeled)" "$pubkey"
                fi
                label=""
                pubkey=""
                ;;
        esac
    done < "$rf"

    local count cap_state
    count="$(bv_age_recipients_count)"
    if [ "$count" -ge "$BV_AGE_RECIPIENTS_CAP" ]; then
        cap_state="(at cap — retire one before adding another)"
    else
        cap_state="(can add $((BV_AGE_RECIPIENTS_CAP - count)) more)"
    fi
    echo "Total active recipients: $count / $BV_AGE_RECIPIENTS_CAP $cap_state"
}

cmd_retire() {
    local label="$1"
    local delete_keychain="no"
    shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --delete-keychain) delete_keychain="yes" ;;
            *) echo "❌  unknown flag: $1" >&2; usage >&2; exit 1 ;;
        esac
        shift
    done

    [ -n "$label" ] || { echo "❌  retire requires a label argument" >&2; usage >&2; exit 1; }

    local rf
    rf="$(bv_age_recipients_file)"
    [ -f "$rf" ] || { echo "❌  recipients file $rf not found" >&2; exit 1; }

    if ! grep -q "^# bv-age-identity-${label}\b" "$rf"; then
        echo "❌  No `# bv-age-identity-${label}` marker in $rf — nothing to retire." >&2
        echo "    Run \`$(basename "$0") list\` to see the active set." >&2
        exit 1
    fi

    # Strip the comment line + the next `age1...` line. awk pass that
    # walks line-by-line; when we see the marker, skip it, set a
    # flag to also skip the very next age1 line, then resume.
    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/bv-age-retire.XXXXXXXX")/recipients.txt"
    awk -v target="# bv-age-identity-${label}" '
        BEGIN { skip_next_age = 0 }
        {
            if (index($0, target) == 1) {
                # Comment line — drop, and prime to drop next age1 too.
                skip_next_age = 1
                next
            }
            if (skip_next_age && match($0, /^age1[a-z0-9]+$/)) {
                skip_next_age = 0
                next
            }
            print
        }
    ' "$rf" > "$tmp"
    mv "$tmp" "$rf"
    rm -rf "$(dirname "$tmp")"

    echo "✓ Removed ${label}'s public key from $rf"

    if [ "$delete_keychain" = "yes" ]; then
        if bv_age_keychain_delete "$label" 2>/dev/null; then
            echo "✓ Deleted private key from Keychain (bv-age-identity-${label})"
            echo ""
            echo "⚠  Old backups encrypted to ${label}'s public key are now unrecoverable on THIS machine."
            echo "   They remain decryptable by any operator who still holds the private key for that public."
        else
            echo "ℹ  No Keychain item bv-age-identity-${label} to delete (already absent)."
        fi
    else
        echo ""
        echo "ℹ  Private key kept in Keychain (so you can still decrypt old backups encrypted to it)."
        echo "   To also delete from Keychain: $(basename "$0") retire $label --delete-keychain"
    fi

    echo ""
    echo "Next step: review the diff to $rf, commit it, open a PR."
}

main() {
    local subcmd="${1:-}"
    shift || true
    case "$subcmd" in
        generate) cmd_generate "${1:-}" ;;
        list)     cmd_list ;;
        retire)   cmd_retire "$@" ;;
        ""|-h|--help|help) usage; exit 0 ;;
        *) echo "❌  unknown subcommand: $subcmd" >&2; usage >&2; exit 1 ;;
    esac
}

main "$@"
