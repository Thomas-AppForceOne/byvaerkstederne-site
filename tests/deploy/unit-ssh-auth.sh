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
