#!/usr/bin/env bash
#
# SSH-auth helpers for backup.sh / restore.sh — picks between
# password-auth (sshpass + DEPLOY_PASS / DEPLOY_PROD_PASS) and key-auth
# (bare ssh + BatchMode=yes) per tier.
#
# Why this exists: deploy.sh / rollback.sh / migrate.sh use
# bv_remote_run (in atomic-release.sh) which always wraps in sshpass.
# backup.sh / restore.sh predate that helper and were written assuming
# SSH key authentication — they invoke `ssh -o BatchMode=yes ...`
# directly, which disables password prompts entirely. Result: against
# password-auth hosting (e.g. one.com), the SSH probe fails immediately
# with "ssh to host:port failed" and there is no path to recovery
# without a script change.
#
# This helper closes that gap. Tier-specific password resolution
# (DEPLOY_PROD_PASS for prod, DEPLOY_PASS for staging/test/dev) plus
# ssh_cmd() / rsync_ssh_e() wrappers that prefer sshpass when a
# password is set and fall back to BatchMode=yes key-auth when it
# isn't. Both paths preserve the existing ConnectTimeout and the
# StrictHostKeyChecking semantics the rest of the PR adopts.
#
# Source contract:
#   * Source this file AFTER .env.deploy has been loaded (so
#     DEPLOY_PASS / DEPLOY_PROD_PASS are visible).
#   * Source it AFTER $TIER is known (the resolver dispatches on it).
#   * The caller may set BV_SSH_AUTH_REQUIRE_SSHPASS=1 to force the
#     sshpass path even when DEPLOY_PASS is empty (used by the unit
#     test to assert the require_bin error is readable).
#
# Reserved env vars (touched by this helper, not by callers):
#   * SSHPASS — the sshpass-via-env credential channel (set inline at
#     the moment of the ssh / rsync invocation, never persisted).

# shellcheck shell=bash

# Resolve the tier-specific SSH password. Returns the empty string if
# no password is configured for the active tier (caller falls back to
# key-auth).
#
# Resolution order, per tier:
#   1. Direct env var (DEPLOY_PASS / DEPLOY_PROD_PASS) — caller-
#      controlled. Wins if set, even to empty? No — only wins if
#      non-empty. Allows tests and one-off overrides without touching
#      Keychain or .env.deploy.
#   2. macOS Keychain via the `security` CLI, when DEPLOY_PASS_KEYCHAIN
#      / DEPLOY_PROD_PASS_KEYCHAIN names the Keychain item. The
#      operator stores the password once with `security
#      add-generic-password -a "$USER" -s "<item>" -w "<password>"`;
#      the script fetches it at runtime. macOS prompts on first access
#      ("Always Allow" unblocks subsequent runs in the same Keychain
#      unlock window).
#   3. Empty string — caller's fallback path is bare-ssh + BatchMode=yes
#      (key-auth). When no auth is configured at all and the host
#      requires a password, the SSH connection fails fast.
bv_resolve_ssh_password() {
    local env_var keychain_var pw kc_item

    case "${TIER:-}" in
        prod)
            env_var="DEPLOY_PROD_PASS"
            keychain_var="DEPLOY_PROD_PASS_KEYCHAIN"
            ;;
        staging|test|dev)
            env_var="DEPLOY_PASS"
            keychain_var="DEPLOY_PASS_KEYCHAIN"
            ;;
        *)
            printf ''
            return 0
            ;;
    esac

    # 1. Direct env-var override.
    pw="$(eval "printf '%s' \"\${$env_var:-}\"")"
    if [ -n "$pw" ]; then
        printf '%s' "$pw"
        return 0
    fi

    # 2. macOS Keychain lookup, when configured.
    kc_item="$(eval "printf '%s' \"\${$keychain_var:-}\"")"
    if [ -n "$kc_item" ]; then
        if ! command -v security >/dev/null 2>&1; then
            # Surface the misconfiguration loudly. macOS-only — Linux
            # operators can populate the env var directly or use a
            # secret manager that exports to env.
            echo "⚠️  $keychain_var is set ('$kc_item') but the 'security' CLI is not on PATH." >&2
            echo "    macOS Keychain integration only works on macOS. Either set $env_var directly," >&2
            echo "    or unset $keychain_var to fall back to key-auth." >&2
            printf ''
            return 0
        fi
        if pw="$(security find-generic-password -a "${USER:-}" -s "$kc_item" -w 2>/dev/null)"; then
            printf '%s' "$pw"
            return 0
        else
            echo "⚠️  Keychain item '$kc_item' (account='$USER') not found." >&2
            echo "    Add it once with:" >&2
            echo "      security add-generic-password -a \"\$USER\" -s \"$kc_item\" -w" >&2
            echo "    (the -w with no value will prompt for the password without echoing)." >&2
            printf ''
            return 0
        fi
    fi

    # 3. Nothing configured — key-auth fallback.
    printf ''
}

# Run an SSH command. Args after $@ are forwarded to ssh verbatim
# (e.g. "-p" "22" "user@host" "true").
#
# When the active tier has a password configured (DEPLOY_PASS for
# staging/test/dev or DEPLOY_PROD_PASS for prod), the password flows
# via the SSHPASS env var — never on the command line. Otherwise the
# call falls back to bare `ssh -o BatchMode=yes` which fails fast
# (rather than prompting interactively) when key-auth isn't set up.
#
# Both paths set ConnectTimeout=10 to match the existing SSH probe.
bv_ssh_cmd() {
    local pw
    pw="$(bv_resolve_ssh_password)"
    if [ -n "$pw" ]; then
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "❌  sshpass not installed but DEPLOY_PASS is set." >&2
            echo "    Install: brew install esolitos/ipa/sshpass" >&2
            return 1
        fi
        SSHPASS="$pw" sshpass -e ssh \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=no \
            "$@"
    else
        ssh -o BatchMode=yes -o ConnectTimeout=10 "$@"
    fi
}

# Build the value for rsync's `-e` argument. Caller passes the SSH
# port; this returns either `sshpass -e ssh -p <port>` (when password
# is configured) or `ssh -p <port> -o BatchMode=yes` (key-auth).
#
# Usage:
#   rsync -az -e "$(bv_rsync_ssh_e "$SSH_PORT")" src/ dest/
#
# When the password path is taken, the caller must export SSHPASS for
# rsync's child process. The bv_rsync_with_pass wrapper below handles
# the export at invocation time so callers don't have to manage env
# state manually.
bv_rsync_ssh_e() {
    local port="${1:-22}"
    local pw
    pw="$(bv_resolve_ssh_password)"
    if [ -n "$pw" ]; then
        # Validate sshpass is on PATH at lookup time, not later when
        # rsync would surface a misleading "remote command failed".
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "❌  sshpass not installed but DEPLOY_PASS is set." >&2
            echo "    Install: brew install esolitos/ipa/sshpass" >&2
            return 1
        fi
        printf 'sshpass -e ssh -p %s -o ConnectTimeout=10 -o StrictHostKeyChecking=no' "$port"
    else
        printf 'ssh -p %s -o ConnectTimeout=10 -o BatchMode=yes' "$port"
    fi
}

# Wrap an rsync invocation, exporting SSHPASS for the child process
# when password-auth is configured, and forwarding all rsync args
# verbatim. Callers use this instead of bare rsync for any SSH-bearing
# transfer.
#
# Usage:
#   bv_rsync_via_ssh -az -e "$(bv_rsync_ssh_e "$SSH_PORT")" \
#       src/ "${SSH_USER}@${SSH_HOST}:${SSH_PATH}/"
bv_rsync_via_ssh() {
    local pw
    pw="$(bv_resolve_ssh_password)"
    if [ -n "$pw" ]; then
        SSHPASS="$pw" rsync "$@"
    else
        rsync "$@"
    fi
}
