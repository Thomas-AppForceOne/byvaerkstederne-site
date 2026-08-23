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

# Resolve the tier's Grav root on the remote. The one.com tiers
# (dev/test/staging/landing) each live in a per-tier subdirectory under
# DEPLOY_PATH; prod's Grav root is the chosting.dk docroot
# (DEPLOY_PROD_PATH) ITSELF — there is no prod/ subdirectory (see
# promote-to-prod.sh: PROD_DOCROOT="$DEPLOY_PROD_PATH"). Every script
# that touches a tier's user/ tree must resolve the root through this
# helper; hardcoding "$base/$tier" silently breaks every command on prod.
#
# Usage:  TIER_DIR="$(bv_tier_root "$PATH_SSH" "$TIER")"
bv_tier_root() {
    local base="$1" tier="$2"
    if [ "$tier" = "prod" ]; then
        printf '%s' "$base"
    else
        printf '%s' "$base/$tier"
    fi
}

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
    # Records how (or whether) the password resolved, for diagnostics:
    # 'env' | 'keychain' | 'keychain-error' | 'none'. Set as a global so
    # same-shell callers (e.g. bv_ssh_diagnose) can read it; note it does
    # NOT survive a $(...) command substitution — the RETURN CODE is the
    # authoritative signal (0 = resolved or legitimately none; 3 = a
    # keychain item is configured but could not be read).
    BV_SSH_PASS_SOURCE='none'

    case "${TIER:-}" in
        prod)
            env_var="DEPLOY_PROD_PASS"
            keychain_var="DEPLOY_PROD_PASS_KEYCHAIN"
            ;;
        landing|staging|test|dev)
            # landing is the apex selector page on the same hosting
            # account as staging/test/dev (hackersbychoice.dk) — shares
            # the same DEPLOY_PASS / DEPLOY_PASS_KEYCHAIN credentials.
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
        BV_SSH_PASS_SOURCE='env'
        printf '%s' "$pw"
        return 0
    fi

    # 2. macOS Keychain lookup, when configured.
    kc_item="$(eval "printf '%s' \"\${$keychain_var:-}\"")"
    if [ -n "$kc_item" ]; then
        if ! command -v security >/dev/null 2>&1; then
            # Cross-platform escape hatch: an item is named but the macOS
            # `security` CLI isn't here (e.g. Linux). Warn and fall back to
            # key-auth rather than hard-fail — Linux operators populate the
            # env var directly or via a secret manager.
            echo "⚠️  $keychain_var is set ('$kc_item') but the 'security' CLI is not on PATH." >&2
            echo "    macOS Keychain integration only works on macOS. Either set $env_var directly," >&2
            echo "    or unset $keychain_var to fall back to key-auth." >&2
            printf ''
            return 0
        fi
        if pw="$(security find-generic-password -a "${USER:-}" -s "$kc_item" -w 2>/dev/null)" && [ -n "$pw" ]; then
            BV_SSH_PASS_SOURCE='keychain'
            printf '%s' "$pw"
            return 0
        fi
        # `security` IS present but the item could not be read: it is
        # missing, the login keychain is LOCKED, access was denied at the
        # prompt, or the stored value is empty. This is a HARD failure —
        # do NOT silently fall back to key-auth (that resurfaces later as a
        # misleading "Permission denied"). Fail loud with rc 3 so callers
        # stop and show the operator what to fix.
        echo "❌  Could not read the SSH password from macOS Keychain item '$kc_item' (account='${USER:-}')." >&2
        echo "    It may be missing, the login keychain may be LOCKED, access was denied, or the value is empty." >&2
        echo "    Fixes:" >&2
        echo "      • Unlock the keychain:  security unlock-keychain" >&2
        echo "      • Grant access when macOS prompts (click 'Always Allow')." >&2
        echo "      • (Re)store the item:   security add-generic-password -a \"\$USER\" -s \"$kc_item\" -w" >&2
        echo "        (the -w with no value prompts for the password without echoing)." >&2
        BV_SSH_PASS_SOURCE='keychain-error'
        printf ''
        return 3
    fi

    # 3. Nothing configured — key-auth fallback.
    printf ''
    return 0
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
# Reuse ONE SSH connection for the whole run.
#
# WHY THIS EXISTS
# ---------------
# Every bv_remote_run and every rsync opened its own TCP connection and
# authenticated from scratch. A deploy does that a dozen-plus times in a
# few seconds, and one.com's shared hosting throttles bursts of
# authentications: the first several succeed, later ones come back
# "Permission denied, please try again." with credentials that are
# perfectly valid — and that are provably valid again a minute later.
#
# It surfaced on 2026-08-23 when four new pre-flight checks (PHP binary,
# PHP parity, Grav parity, handler line) each added a connection ahead of
# the upload. The deploy reached step 3b and was refused. Nothing was
# wrong with the password; there were simply too many logins too quickly.
#
# With ControlMaster the first connection authenticates and every later
# one rides the same socket, so a deploy authenticates ONCE no matter how
# many remote commands it runs. That removes the ceiling rather than
# raising it: adding a pre-flight check no longer costs a login.
#
# ControlPath lives in /tmp, not $TMPDIR: a unix socket path is capped at
# ~104 bytes and macOS $TMPDIR is already ~50. %C is a hash of
# (localhost, remotehost, port, user), so distinct tiers never share a
# socket. ControlPersist outlives the gaps between steps — notably the
# package upload — without leaving a connection open indefinitely.
#
# ControlMaster=auto degrades safely: if the socket is missing or the
# master has gone, ssh just opens a fresh connection.
bv_ssh_mux_opts() {
    printf '%s' "-o ControlMaster=auto -o ControlPath=/tmp/bv-ssh-%C -o ControlPersist=180"
}

bv_ssh_cmd() {
    local pw rc
    pw="$(bv_resolve_ssh_password)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        # A keychain item is configured but unreadable; the resolver already
        # printed an actionable message. Do NOT attempt key-auth — it would
        # fail with a misleading "Permission denied".
        return "$rc"
    fi
    if [ -n "$pw" ]; then
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "❌  sshpass not installed but DEPLOY_PASS is set." >&2
            echo "    Install: brew install esolitos/ipa/sshpass" >&2
            return 1
        fi
        # shellcheck disable=SC2046  # deliberate word-splitting: option list
        SSHPASS="$pw" sshpass -e ssh \
            -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=no \
            $(bv_ssh_mux_opts) \
            "$@"
    else
        # Key-auth path. StrictHostKeyChecking=accept-new lets first
        # connection to a new host (e.g. chosting.dk on prod bring-up)
        # succeed by recording the fingerprint, but rejects a CHANGED
        # fingerprint on subsequent runs — same protection as
        # StrictHostKeyChecking=yes after the first connection. The
        # sshpass path above uses =no because one.com's shared-hosting
        # fingerprints have rotated more than once historically.
        # shellcheck disable=SC2046  # deliberate word-splitting: option list
        ssh -o BatchMode=yes -o ConnectTimeout=10 \
            -o StrictHostKeyChecking=accept-new \
            $(bv_ssh_mux_opts) \
            "$@"
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
    local pw rc
    pw="$(bv_resolve_ssh_password)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    if [ -n "$pw" ]; then
        # Validate sshpass is on PATH at lookup time, not later when
        # rsync would surface a misleading "remote command failed".
        if ! command -v sshpass >/dev/null 2>&1; then
            echo "❌  sshpass not installed but DEPLOY_PASS is set." >&2
            echo "    Install: brew install esolitos/ipa/sshpass" >&2
            return 1
        fi
        printf 'sshpass -e ssh -p %s -o ConnectTimeout=10 -o StrictHostKeyChecking=no %s' \
            "$port" "$(bv_ssh_mux_opts)"
    else
        # Key-auth path — same StrictHostKeyChecking=accept-new
        # rationale as bv_ssh_cmd above. First connection to chosting
        # records the fingerprint; subsequent runs verify it.
        printf 'ssh -p %s -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new %s' \
            "$port" "$(bv_ssh_mux_opts)"
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
    local pw rc
    pw="$(bv_resolve_ssh_password)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi
    if [ -n "$pw" ]; then
        SSHPASS="$pw" rsync "$@"
    else
        rsync "$@"
    fi
}

# Layered diagnosis of why an SSH connection to <user>@<host>:<port>
# failed — DNS, then TCP reachability, then the auth layer. Replaces the
# old catch-all "auth / host / network" message at the call sites so the
# next failure points straight at the cause. Prints to stderr; always
# returns 0 (it is purely informational — the caller decides exit code).
bv_ssh_diagnose() {
    local user="${1:-}" host="${2:-}" port="${3:-22}"
    echo "  Diagnosing SSH to ${user}@${host}:${port} …" >&2

    # 1) DNS resolution. A literal IP needs no lookup (and `host <ip>` would
    # do a reverse-PTR query that often fails — a false negative).
    local dns=unknown
    case "$host" in
        *:*) dns=ok ;;            # IPv6 literal (contains ':')
        *[!0-9.]*)                # has non-IPv4 chars -> hostname, look it up
            if command -v host >/dev/null 2>&1; then
                host "$host" >/dev/null 2>&1 && dns=ok || dns=fail
            elif command -v getent >/dev/null 2>&1; then
                getent hosts "$host" >/dev/null 2>&1 && dns=ok || dns=fail
            elif command -v nslookup >/dev/null 2>&1; then
                nslookup "$host" >/dev/null 2>&1 && dns=ok || dns=fail
            fi
            ;;
        *) dns=ok ;;              # all digits/dots -> IPv4 literal
    esac
    if [ "$dns" = fail ]; then
        echo "  • DNS: '$host' does NOT resolve ✗ — check DEPLOY_HOST in .env.deploy for a typo." >&2
        return 0
    elif [ "$dns" = ok ]; then
        echo "  • DNS: '$host' resolves ✓" >&2
    fi

    # 2) TCP reachability on the SSH port.
    local tcp=fail
    if command -v nc >/dev/null 2>&1; then
        nc -z -w 5 "$host" "$port" >/dev/null 2>&1 && tcp=ok
    else
        # bash /dev/tcp fallback (no nc). 5s connect budget.
        (exec 3<>"/dev/tcp/$host/$port") >/dev/null 2>&1 && tcp=ok
    fi
    if [ "$tcp" = ok ]; then
        echo "  • TCP: $host:$port reachable ✓" >&2
    else
        echo "  • TCP: $host:$port unreachable ✗ — SSH may be disabled on the host, the port wrong, or a firewall / IP allowlist is blocking you." >&2
        return 0
    fi

    # 3) Auth layer. Probe with a trivial command instead of assuming —
    # a remote-command failure (wrong path, missing tool on the tier)
    # must not be misreported as an auth rejection.
    if bv_ssh_cmd -p "$port" "$user@$host" true >/dev/null 2>&1; then
        echo "  • Auth: SSH to ${user}@${host} works ✓ — the failure was in the remote command itself (wrong path or missing tool on the tier), not the connection." >&2
        return 0
    fi
    local pw rc
    pw="$(bv_resolve_ssh_password 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  • Auth: the deploy password could not be read from the Keychain ✗ — unlock it / grant access (see the message above)." >&2
    elif [ -n "$pw" ]; then
        echo "  • Auth: host reachable but password authentication was REJECTED ✗ — the stored password may be wrong or rotated for ${user}." >&2
    else
        echo "  • Auth: no password configured; key-auth was attempted and REJECTED ✗ — no SSH key is authorised for ${user} on this host." >&2
    fi
    return 0
}
