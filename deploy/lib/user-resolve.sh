#!/usr/bin/env bash
#
# user-resolve.sh — shared email→username resolution for the per-user tier
# tooling (manage-groups.sh, activate-user.sh, reset-password.sh).
#
# Source contract (same style as ssh-auth.sh):
#   * Source AFTER ssh-auth.sh and after the tier's SSH vars are resolved:
#     TIER, ACCOUNTS_DIR, PORT_SSH, USER_SSH, HOST_SSH must be set.
#   * bv_resolve_username <username|email>
#       - prints the resolved username on stdout (info lines go to stderr)
#       - an email must match exactly one account on the tier
#       - the result is re-validated as a path-safe component
#       - returns non-zero with an actionable message on any failure
#
# shellcheck shell=bash

bv_resolve_username() {
    local userid="$1" matches match_count username email_re

    if printf '%s' "$userid" | grep -q '@'; then
        # Escape regex specials so the email is matched literally.
        email_re="$(printf '%s' "$userid" | sed 's/[.[\\*^$+]/\\&/g')"
        matches="$(bv_ssh_cmd -p "$PORT_SSH" "$USER_SSH@$HOST_SSH" "
            d=\"$ACCOUNTS_DIR\"
            [ -d \"\$d\" ] || { echo __NODIR__; exit 0; }
            grep -lE \"^email:[[:space:]]*['\\\"]?${email_re}['\\\"]?[[:space:]]*\$\" \"\$d\"/*.yaml 2>/dev/null \
                | while read -r f; do b=\$(basename \"\$f\"); echo \"\${b%.yaml}\"; done
        " 2>/dev/null || echo __SSHFAIL__)"
        if printf '%s' "$matches" | grep -q '__SSHFAIL__'; then
            echo "✗ SSH to $USER_SSH@$HOST_SSH:$PORT_SSH failed." >&2
            bv_ssh_diagnose "$USER_SSH" "$HOST_SSH" "$PORT_SSH" >&2
            return 1
        fi
        if printf '%s' "$matches" | grep -q '__NODIR__'; then
            echo "✗ No accounts dir on $TIER ($ACCOUNTS_DIR) — tier not deployed yet, or fresh." >&2
            return 1
        fi
        matches="$(printf '%s\n' "$matches" | sed '/^$/d')"
        match_count="$(printf '%s' "$matches" | grep -c . || true)"
        if [ "$match_count" -eq 0 ]; then
            echo "✗ No account on $TIER has email '$userid'. Try: make list-users tier=$TIER" >&2
            return 1
        fi
        if [ "$match_count" -gt 1 ]; then
            echo "✗ Email '$userid' matches more than one account on $TIER:" >&2
            printf '%s\n' "$matches" | sed 's/^/      - /' >&2
            echo "    Re-run with the username instead." >&2
            return 1
        fi
        username="$(printf '%s' "$matches" | head -1)"
        echo "→ resolved email '$userid' to username '$username'" >&2
    else
        username="$userid"
    fi

    # The resolved username becomes a remote path component — re-validate.
    case "$username" in
        *[!A-Za-z0-9._-]*|*..*|.*|"")
            echo "❌  Resolved username '$username' is not path-safe; aborting." >&2
            return 1
            ;;
    esac

    printf '%s\n' "$username"
}
