#!/usr/bin/env bash
#
# Unit test for deploy/cleanup-unverified-users.sh — the script that deletes
# unconfirmed member accounts from a tier.
#
# THE FAILURE THIS PINS
# ---------------------
# The script's last statement was
#
#     [ "$APPLY" != "1" ] && echo "(dry-run — re-run with --apply to delete)"
#
# As the FINAL command, that idiom leaks its own status. With --apply the test
# is false, the && chain returns 1, and a cleanup that had just deleted the
# right accounts exited non-zero. Dry-run exited 0 and apply exited 1 —
# exactly backwards, and enough to break any caller under `set -e` or a cron
# wrapper that checks the code.
#
# Found on 2026-08-24 by running it for real against the test tier, where it
# correctly removed 34 orphaned pw-test accounts and then reported failure.
#
# The selection rule is also worth pinning, since this deletes real member
# accounts: state:disabled AND a pending activation_token whose expiry is old
# enough. An enabled account, or a disabled one with no token, must never be
# touched however old it is.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}

echo "Unit test: cleanup-unverified-users.sh (stub ssh)"
echo "---"

STUB_PREFIX="bv-unit-cleanup-unverified."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

mkdir -p "$SB/proj/deploy/lib" "$SB/bin" "$SB/remotebin"
cp "$PROJECT_ROOT/deploy/cleanup-unverified-users.sh" "$SB/proj/deploy/"
cp "$PROJECT_ROOT/deploy/lib/ssh-auth.sh" "$SB/proj/deploy/lib/"
cp "$PROJECT_ROOT/deploy/lib/php-parity.sh" "$SB/proj/deploy/lib/"

cat > "$SB/proj/.env.deploy" <<EOF
DEPLOY_HOST=fakehost
DEPLOY_USER=fakeuser
DEPLOY_PATH=$SB/remote
DEPLOY_PORT=22
DEPLOY_PROD_HOST=fakeprodhost
DEPLOY_PROD_USER=fakeproduser
DEPLOY_PROD_PATH=$SB/remote-prod
DEPLOY_PROD_PORT=22
EOF

ACC="$SB/remote/dev/user/accounts"
mkdir -p "$ACC" "$SB/remote/dev/user/data/flex/indexes"

TOKEN_LIFETIME=604800
NOW="$(date +%s)"
# Registered two hours ago: expiry = reg + lifetime.
STALE_EXP=$(( NOW - 7200 + TOKEN_LIFETIME ))
# Registered one minute ago.
FRESH_EXP=$(( NOW - 60 + TOKEN_LIFETIME ))

cat > "$ACC/stale.yaml" <<EOF
state: disabled
email: stale@example.invalid
activation_token: abc123::${STALE_EXP}
EOF
cat > "$ACC/fresh.yaml" <<EOF
state: disabled
email: fresh@example.invalid
activation_token: def456::${FRESH_EXP}
EOF
cat > "$ACC/active.yaml" <<EOF
state: enabled
email: active@example.invalid
activation_token: ghi789::${STALE_EXP}
EOF
cat > "$ACC/notoken.yaml" <<'EOF'
state: disabled
email: notoken@example.invalid
EOF

LOG="$SB/invocations.log"
cat > "$SB/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh:\$*" >> "$LOG"
for cmd in "\$@"; do :; done
PATH="$SB/remotebin:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$SB/bin/ssh"

cat > "$SB/remotebin/php" <<EOF
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SB/remotebin/php"

export PATH="$SB/bin:$PATH"
CU="$SB/proj/deploy/cleanup-unverified-users.sh"

run() { (cd "$SB/proj" && "$CU" "$@" 2>&1); }

# ── Dry-run ──────────────────────────────────────────────────────────
set +e
out="$(run dev --max-age=60)"; rc=$?
set -e
check "dry-run exits 0" \
    "$([ "$rc" -eq 0 ] && echo ok || echo no)"
check "dry-run reports the stale account" \
    "$(printf '%s' "$out" | grep -q 'stale' && echo ok || echo no)"
check "dry-run says it would remove, not removed" \
    "$(printf '%s' "$out" | grep -q 'would remove' && echo ok || echo no)"
check "dry-run deletes nothing" \
    "$([ -f "$ACC/stale.yaml" ] && echo ok || echo no)"

# ── Apply — the regression ───────────────────────────────────────────
set +e
out="$(run dev --max-age=60 --apply)"; rc=$?
set -e
check "apply exits 0 after a successful delete (the leaked-status bug)" \
    "$([ "$rc" -eq 0 ] && echo ok || echo no)"
check "apply says removed" \
    "$(printf '%s' "$out" | grep -q 'removed' && echo ok || echo no)"
check "apply does NOT print the dry-run hint" \
    "$(printf '%s' "$out" | grep -q 're-run with --apply' && echo no || echo ok)"

# ── Selection: only stale unconfirmed accounts ───────────────────────
check "the stale unconfirmed account is deleted" \
    "$([ -f "$ACC/stale.yaml" ] && echo no || echo ok)"
check "a too-recent unconfirmed account survives" \
    "$([ -f "$ACC/fresh.yaml" ] && echo ok || echo no)"
check "an ENABLED account is never touched, token or not" \
    "$([ -f "$ACC/active.yaml" ] && echo ok || echo no)"
check "a disabled account with no activation token is never touched" \
    "$([ -f "$ACC/notoken.yaml" ] && echo ok || echo no)"

# ── Nothing left to do ───────────────────────────────────────────────
set +e
out="$(run dev --max-age=60 --apply)"; rc=$?
set -e
check "a second apply is a no-op and still exits 0" \
    "$([ "$rc" -eq 0 ] && echo ok || echo no)"
check "the no-op run says there is nothing to clean" \
    "$(printf '%s' "$out" | grep -qi 'no unconfirmed accounts' && echo ok || echo no)"

# ── The idiom itself must not come back ──────────────────────────────
# Comment lines stripped: the script's own header explains the bug.
check "the script does not end on a bare [ … ] && echo" \
    "$(grep -v '^[[:space:]]*#' "$PROJECT_ROOT/deploy/cleanup-unverified-users.sh" \
       | grep -vE '^[[:space:]]*$' | tail -1 | grep -q '^exit 0$' && echo ok || echo no)"

echo "---"
echo "cleanup-unverified unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
