#!/usr/bin/env bash
#
# Unit test for deploy/lib/ssh-auth.sh — exercises the password-vs-key
# auth dispatch in bv_ssh_cmd / bv_rsync_ssh_e / bv_rsync_via_ssh /
# bv_resolve_ssh_password against stub ssh / sshpass / rsync binaries.
#
# Same shape as unit-remote-run.sh: stubs in a mktemp dir prepended to
# PATH; stubs report what they were invoked with so the test asserts
# the helper picked the right code path.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/ssh-auth.sh
. "$PROJECT_ROOT/deploy/lib/ssh-auth.sh"

PASS=0
FAIL=0

check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then
        echo "  ✓ $name"
        PASS=$((PASS+1))
    else
        echo "  ✗ $name" >&2
        FAIL=$((FAIL+1))
    fi
}

echo "Unit test: ssh-auth.sh (against stub ssh/sshpass/rsync)"
echo "---"

# ─────────────────────────────────────────────────────────────────────
# Stub PATH
# ─────────────────────────────────────────────────────────────────────
STUB_PREFIX="bv-unit-ssh-auth."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

STUB_DIR="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
LOG="$STUB_DIR/invocations.log"
trap 'rm -rf "$STUB_DIR"' EXIT

# ssh stub: log "ssh:<args>" and exit 0.
cat > "$STUB_DIR/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh:\$*" >> "$LOG"
echo "ssh-stub-stdout"
exit 0
EOF
chmod +x "$STUB_DIR/ssh"

# sshpass stub: log "sshpass:<args> SSHPASS=<env>" then exec the real
# command after the recognised flags. We support `-e` (read from
# SSHPASS env) which is what bv_ssh_cmd and bv_rsync_via_ssh use.
cat > "$STUB_DIR/sshpass" <<EOF
#!/usr/bin/env bash
echo "sshpass:\$* SSHPASS=\${SSHPASS:-<unset>}" >> "$LOG"
if [ "\${1:-}" = "-e" ]; then
    shift
fi
exec "\$@"
EOF
chmod +x "$STUB_DIR/sshpass"

# rsync stub: log "rsync:<args>" and exit 0.
cat > "$STUB_DIR/rsync" <<EOF
#!/usr/bin/env bash
echo "rsync:\$*" >> "$LOG"
exit 0
EOF
chmod +x "$STUB_DIR/rsync"

# security (Keychain) stub. Emulates `security find-generic-password
# -a <user> -s <item> -w`. Reads a fake-keychain file at
# $BV_TEST_KEYCHAIN_FILE (lines of "<item>\t<password>"); missing
# items exit 44 like the real CLI.
cat > "$STUB_DIR/security" <<'EOF'
#!/usr/bin/env bash
mode="$1"; shift
case "$mode" in
    find-generic-password)
        item=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -a) shift 2 ;;
                -s) item="$2"; shift 2 ;;
                -w) shift ;;
                *)  shift ;;
            esac
        done
        kc="${BV_TEST_KEYCHAIN_FILE:-/dev/null}"
        if [ -f "$kc" ]; then
            while IFS=$'\t' read -r kc_item kc_pw; do
                if [ "$kc_item" = "$item" ]; then
                    printf '%s' "$kc_pw"
                    exit 0
                fi
            done < "$kc"
        fi
        echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
        exit 44
        ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$STUB_DIR/security"

PATH="$STUB_DIR:$PATH"
export PATH

# ─────────────────────────────────────────────────────────────────────
# Test group A: bv_resolve_ssh_password
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "A. password resolution by tier"

TIER=dev DEPLOY_PASS="dev-secret" DEPLOY_PROD_PASS="prod-secret"
out="$(bv_resolve_ssh_password)"
[ "$out" = "dev-secret" ] && check "tier=dev returns DEPLOY_PASS" ok \
    || check "tier=dev returns DEPLOY_PASS (got '$out')" fail

TIER=test DEPLOY_PASS="dev-secret" DEPLOY_PROD_PASS="prod-secret"
out="$(bv_resolve_ssh_password)"
[ "$out" = "dev-secret" ] && check "tier=test returns DEPLOY_PASS" ok \
    || check "tier=test returns DEPLOY_PASS (got '$out')" fail

TIER=staging DEPLOY_PASS="dev-secret" DEPLOY_PROD_PASS="prod-secret"
out="$(bv_resolve_ssh_password)"
[ "$out" = "dev-secret" ] && check "tier=staging returns DEPLOY_PASS" ok \
    || check "tier=staging returns DEPLOY_PASS (got '$out')" fail

TIER=prod DEPLOY_PASS="dev-secret" DEPLOY_PROD_PASS="prod-secret"
out="$(bv_resolve_ssh_password)"
[ "$out" = "prod-secret" ] && check "tier=prod returns DEPLOY_PROD_PASS (not DEPLOY_PASS)" ok \
    || check "tier=prod returns DEPLOY_PROD_PASS (got '$out')" fail

TIER=dev DEPLOY_PASS="" DEPLOY_PROD_PASS="prod-secret"
out="$(bv_resolve_ssh_password)"
[ -z "$out" ] && check "tier=dev with empty DEPLOY_PASS returns empty (key-auth fallback)" ok \
    || check "empty DEPLOY_PASS returns empty (got '$out')" fail

TIER=junk DEPLOY_PASS="dev-secret"
out="$(bv_resolve_ssh_password)"
[ -z "$out" ] && check "tier=junk returns empty (defensive default)" ok \
    || check "tier=junk returns empty (got '$out')" fail

unset TIER DEPLOY_PASS DEPLOY_PROD_PASS

# ─────────────────────────────────────────────────────────────────────
# Test group A2: Keychain fallback for password resolution
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "A2. Keychain fallback (macOS security CLI stub)"

# Set up a fake keychain file with two items.
KC_FILE="$STUB_DIR/keychain.tsv"
{
    printf 'bv-deploy-pass-dev\tkeychain-dev-secret\n'
    printf 'bv-deploy-pass-prod\tkeychain-prod-secret\n'
} > "$KC_FILE"
export BV_TEST_KEYCHAIN_FILE="$KC_FILE"

# A2.1 — env var unset, keychain var points at a real item: returns it
unset DEPLOY_PASS
TIER=dev DEPLOY_PASS_KEYCHAIN="bv-deploy-pass-dev"
out="$(bv_resolve_ssh_password 2>/dev/null)"
[ "$out" = "keychain-dev-secret" ] && check "DEPLOY_PASS empty + DEPLOY_PASS_KEYCHAIN set: returns Keychain value" ok \
    || check "Keychain lookup (got '$out')" fail

# A2.2 — direct env var wins over Keychain (precedence test)
TIER=dev DEPLOY_PASS="env-wins" DEPLOY_PASS_KEYCHAIN="bv-deploy-pass-dev"
out="$(bv_resolve_ssh_password 2>/dev/null)"
[ "$out" = "env-wins" ] && check "direct env var takes precedence over DEPLOY_PASS_KEYCHAIN" ok \
    || check "env-var precedence (got '$out')" fail

# A2.3 — prod uses DEPLOY_PROD_PASS_KEYCHAIN, NOT DEPLOY_PASS_KEYCHAIN
unset DEPLOY_PASS DEPLOY_PROD_PASS
TIER=prod DEPLOY_PROD_PASS_KEYCHAIN="bv-deploy-pass-prod" DEPLOY_PASS_KEYCHAIN="bv-deploy-pass-dev"
out="$(bv_resolve_ssh_password 2>/dev/null)"
[ "$out" = "keychain-prod-secret" ] && check "tier=prod uses DEPLOY_PROD_PASS_KEYCHAIN, not DEPLOY_PASS_KEYCHAIN" ok \
    || check "prod Keychain isolation (got '$out')" fail

# A2.4 — Keychain item missing: empty result + readable diagnostic
unset DEPLOY_PASS DEPLOY_PROD_PASS DEPLOY_PROD_PASS_KEYCHAIN
TIER=dev DEPLOY_PASS_KEYCHAIN="never-stored-in-keychain"
err="$(bv_resolve_ssh_password 2>&1 >/dev/null)"
out="$(bv_resolve_ssh_password 2>/dev/null)"
[ -z "$out" ] && check "missing Keychain item: returns empty (caller falls back to key-auth)" ok \
    || check "missing Keychain item should return empty (got '$out')" fail
case "$err" in
    *"not found"*"add-generic-password"*) check "missing Keychain item: diagnostic explains how to add it" ok ;;
    *) check "missing Keychain diagnostic (got: '$err')" fail ;;
esac

# A2.5 — security CLI not on PATH: warning + empty (graceful fallback).
# Use a PATH that contains ONLY the test stub dir (with stub `ssh`,
# `sshpass`, `rsync` — but NO `security`); macOS's real /usr/bin/security
# would otherwise satisfy command -v lookup.
TIER=dev DEPLOY_PASS_KEYCHAIN="bv-deploy-pass-dev"
PATH_BACKUP="$PATH"
NO_SEC_DIR="$(mktemp -d -t "${STUB_PREFIX}nosec.XXXXXX")"
cp "$STUB_DIR/ssh" "$STUB_DIR/sshpass" "$STUB_DIR/rsync" "$NO_SEC_DIR/"
PATH="$NO_SEC_DIR"
err="$(bv_resolve_ssh_password 2>&1 >/dev/null)"
out="$(bv_resolve_ssh_password 2>/dev/null)"
PATH="$PATH_BACKUP"
rm -rf "$NO_SEC_DIR"
[ -z "$out" ] && check "security CLI missing: returns empty (falls back to key-auth)" ok \
    || check "security CLI missing: should be empty (got '$out')" fail
case "$err" in
    *"security"*"not on PATH"*"macOS"*) check "security CLI missing: diagnostic mentions macOS-only" ok ;;
    *) check "security CLI missing diagnostic (got: '$err')" fail ;;
esac

unset TIER DEPLOY_PASS DEPLOY_PROD_PASS DEPLOY_PASS_KEYCHAIN DEPLOY_PROD_PASS_KEYCHAIN

# ─────────────────────────────────────────────────────────────────────
# Test group B: bv_ssh_cmd dispatch
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "B. bv_ssh_cmd dispatch"

# B.1 — password set: invokes sshpass -e ssh, password flows via SSHPASS
> "$LOG"
TIER=dev DEPLOY_PASS="hunter2"
bv_ssh_cmd -p 22 user@host true >/dev/null
if grep -q '^sshpass:' "$LOG" && grep -q 'SSHPASS=hunter2' "$LOG"; then
    check "with DEPLOY_PASS set: sshpass -e is invoked, SSHPASS env carries password" ok
else
    check "with DEPLOY_PASS set: expected sshpass invocation (log: $(cat "$LOG"))" fail
fi

# B.2 — no password set: invokes bare ssh with BatchMode=yes
> "$LOG"
unset DEPLOY_PASS
TIER=dev
bv_ssh_cmd -p 22 user@host true >/dev/null 2>&1 || true
if ! grep -q '^sshpass:' "$LOG" && grep -q 'BatchMode=yes' "$LOG"; then
    check "without DEPLOY_PASS: bare ssh + BatchMode=yes (key-auth, no prompt)" ok
else
    check "without DEPLOY_PASS: expected bare ssh + BatchMode (log: $(cat "$LOG"))" fail
fi

# B.3 — password set, sshpass missing: error message + non-zero
> "$LOG"
TIER=dev DEPLOY_PASS="hunter2"
PATH_BACKUP="$PATH"
# Build a PATH that includes our ssh/rsync stubs but NOT sshpass.
NO_SSHPASS_DIR="$(mktemp -d -t "${STUB_PREFIX}nosshpass.XXXXXX")"
cp "$STUB_DIR/ssh" "$STUB_DIR/rsync" "$NO_SSHPASS_DIR/"
PATH="$NO_SSHPASS_DIR:/usr/bin:/bin"
err="$(bv_ssh_cmd -p 22 user@host true 2>&1 >/dev/null || true)"
PATH="$PATH_BACKUP"
rm -rf "$NO_SSHPASS_DIR"
case "$err" in
    *"sshpass not installed"*) check "DEPLOY_PASS set + sshpass missing: readable diagnostic" ok ;;
    *) check "DEPLOY_PASS set + sshpass missing: expected diagnostic (got: '$err')" fail ;;
esac

# B.4 — host arg flows through to ssh (sshpass path)
> "$LOG"
TIER=dev DEPLOY_PASS="hunter2"
bv_ssh_cmd -p 2222 alice@example.com whoami >/dev/null
if grep -q 'alice@example.com' "$LOG" && grep -q '\-p 2222' "$LOG"; then
    check "user@host and port flow through to ssh (sshpass path)" ok
else
    check "user@host/port forwarding (log: $(cat "$LOG"))" fail
fi

# B.5 — host arg flows through to ssh (bare path)
> "$LOG"
unset DEPLOY_PASS
TIER=dev
bv_ssh_cmd -p 2222 alice@example.com whoami >/dev/null 2>&1 || true
if grep -q 'alice@example.com' "$LOG" && grep -q '\-p 2222' "$LOG"; then
    check "user@host and port flow through to ssh (bare path)" ok
else
    check "user@host/port forwarding (log: $(cat "$LOG"))" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test group C: bv_rsync_ssh_e
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "C. bv_rsync_ssh_e shape"

TIER=dev DEPLOY_PASS="hunter2"
out="$(bv_rsync_ssh_e 22)"
case "$out" in
    *sshpass*ssh*-p*22*) check "with DEPLOY_PASS: returns sshpass-wrapped ssh -e value" ok ;;
    *) check "with DEPLOY_PASS: expected sshpass+ssh (got: '$out')" fail ;;
esac
case "$out" in
    *StrictHostKeyChecking=no*) check "sshpass path includes StrictHostKeyChecking=no" ok ;;
    *) check "sshpass path missing StrictHostKeyChecking=no (got: '$out')" fail ;;
esac

unset DEPLOY_PASS
TIER=dev
out="$(bv_rsync_ssh_e 22)"
case "$out" in
    *BatchMode=yes*) check "without DEPLOY_PASS: returns BatchMode=yes ssh -e value" ok ;;
    *) check "without DEPLOY_PASS: expected BatchMode (got: '$out')" fail ;;
esac
case "$out" in
    *sshpass*) check "key-auth path does NOT include sshpass" fail ;;
    *) check "key-auth path does NOT include sshpass" ok ;;
esac

# ─────────────────────────────────────────────────────────────────────
# Test group D: bv_rsync_via_ssh dispatch
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "D. bv_rsync_via_ssh dispatch"

# D.1 — password set: SSHPASS exported into rsync's env
> "$LOG"
TIER=dev DEPLOY_PASS="hunter2"
bv_rsync_via_ssh -az -e "ssh -p 22" /src/ user@host:/dst/ >/dev/null
# rsync stub doesn't see SSHPASS; what we assert is that the rsync was
# invoked with the right args (the SSHPASS export is verified
# implicitly — bv_rsync_via_ssh's bash sets it inline before exec).
if grep -q '^rsync:' "$LOG" && grep -q '/src/' "$LOG"; then
    check "with DEPLOY_PASS: rsync invoked with caller's args" ok
else
    check "rsync dispatch (log: $(cat "$LOG"))" fail
fi

# D.2 — direct verification that SSHPASS is set in rsync's environment.
# The stub captures env; modify it to log SSHPASS too.
cat > "$STUB_DIR/rsync" <<EOF
#!/usr/bin/env bash
echo "rsync:\$* SSHPASS_ENV=\${SSHPASS:-<unset>}" >> "$LOG"
exit 0
EOF
chmod +x "$STUB_DIR/rsync"
> "$LOG"
TIER=dev DEPLOY_PASS="hunter2"
bv_rsync_via_ssh -az -e "ssh -p 22" /src/ user@host:/dst/ >/dev/null
if grep -q 'SSHPASS_ENV=hunter2' "$LOG"; then
    check "with DEPLOY_PASS: SSHPASS exported into rsync's env" ok
else
    check "SSHPASS export to rsync (log: $(cat "$LOG"))" fail
fi

# D.3 — without password: SSHPASS NOT exported, rsync runs bare
> "$LOG"
unset DEPLOY_PASS SSHPASS
TIER=dev
bv_rsync_via_ssh -az -e "ssh -p 22" /src/ user@host:/dst/ >/dev/null
if grep -q 'SSHPASS_ENV=<unset>' "$LOG"; then
    check "without DEPLOY_PASS: SSHPASS unset in rsync's env" ok
else
    check "SSHPASS unset (log: $(cat "$LOG"))" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"

[ "$FAIL" -eq 0 ]
