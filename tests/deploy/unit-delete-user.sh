#!/usr/bin/env bash
#
# Unit test for deploy/delete-user.sh — same sandbox shape as
# unit-reset-users.sh: a copy of the script runs against its own
# .env.deploy, and the `ssh` stub executes the "remote" command locally
# against a fake tier tree. Exercises the success path (account YAML +
# flex index + remember-me token file deleted, other users' tokens kept,
# cache cleared), the dry-run, and the refusal paths (unknown user, prod
# gate, protected seed accounts).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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

echo "Unit test: delete-user.sh (sandboxed, stub ssh/php)"
echo "---"

STUB_PREFIX="bv-unit-delete-user."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# ── Sandbox project ──────────────────────────────────────────────────
mkdir -p "$SB/proj/deploy/lib" "$SB/bin" "$SB/remotebin"
cp "$PROJECT_ROOT/deploy/delete-user.sh" "$SB/proj/deploy/"
cp "$PROJECT_ROOT/deploy/lib/ssh-auth.sh" "$SB/proj/deploy/lib/"
# php-parity.sh is sourced by the scripts under test (bv_php_remote_bin);
# without it the sandboxed copy dies at source time.
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

# ── Fake tier tree ───────────────────────────────────────────────────
ACC="$SB/remote/dev/user/accounts"
IDX="$SB/remote/dev/user/data/flex/indexes"
RMD="$SB/remote/dev/user/data/rememberme"
mkdir -p "$ACC" "$IDX" "$RMD"
touch "$IDX/accounts.yaml"

sha1() { printf '%s' "$1" | shasum | awk '{print $1}'; }

cat > "$ACC/anders.yaml" <<'EOF'
state: enabled
email: anders@example.dk
EOF
cat > "$ACC/bodil.yaml" <<'EOF'
state: enabled
email: bodil@example.dk
EOF
cat > "$ACC/pw-test-user.yaml" <<'EOF'
state: enabled
email: pw-test-user@example.invalid
EOF

# Remember-me token files for anders (to be deleted with the account) and
# bodil (must survive anders' deletion untouched).
echo "sometoken: [x]" > "$RMD/$(sha1 anders).yaml"
echo "sometoken: [x]" > "$RMD/$(sha1 bodil).yaml"

# ── Stubs ────────────────────────────────────────────────────────────
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
echo "php:\$*" >> "$LOG"
case "\$*" in
    *clearcache*) touch "$SB/cache-cleared"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$SB/remotebin/php"

export PATH="$SB/bin:$PATH"
DU="$SB/proj/deploy/delete-user.sh"
run() { "$DU" "$@" 2>&1; }

# ─────────────────────────────────────────────────────────────────────
# validation failures
# ─────────────────────────────────────────────────────────────────────
if ! run bogus anders >/dev/null 2>&1; then
    check "invalid tier is refused" ok
else
    check "invalid tier is refused" bad
fi

# --dry-run, deliberately: with the prod ceremony gone this call no longer
# stops early, and a real run here would delete the fixture and clear the
# sandbox cache out from under the later assertions.
out="$(run prod anders --yes --dry-run)" || true
if printf '%s' "$out" | grep -q -- '--i-mean-it'; then
    check "prod is not gated behind an --i-mean-it ceremony" bad
else
    check "prod is not gated behind an --i-mean-it ceremony" ok
fi

# --dry-run for the same reason as the prod case above: the seed guard warns
# now instead of refusing, so a plain run would really delete pw-test-user
# and clear the sandbox cache before the assertions below look at it.
out="$(run dev pw-test-user --yes --dry-run)" || true
if printf '%s' "$out" | grep -q 'protected Playwright seed' \
   && printf '%s' "$out" | grep -q 'Re-seed afterwards'; then
    check "protected seed account warns and continues (no longer refused)" ok
else
    check "protected seed account warns and continues (no longer refused)" bad
fi

out="$(run dev '../evil' --yes)" || true
if printf '%s' "$out" | grep -q 'unsafe username'; then
    check "path-traversal username is refused" ok
else
    check "path-traversal username is refused" bad
fi

out="$(run dev ghost --yes)" || true
if printf '%s' "$out" | grep -q "No account 'ghost'"; then
    check "nonexistent user fails the preflight" ok
else
    check "nonexistent user fails the preflight" bad
fi

# ─────────────────────────────────────────────────────────────────────
# dry-run: mentions remember-me, deletes nothing
# ─────────────────────────────────────────────────────────────────────
out="$(run dev anders --dry-run)" || true
if printf '%s' "$out" | grep -q 'remember-me' \
   && [ -f "$ACC/anders.yaml" ] \
   && [ -f "$RMD/$(sha1 anders).yaml" ] \
   && [ ! -f "$SB/cache-cleared" ]; then
    check "dry-run announces remember-me cleanup and deletes nothing" ok
else
    check "dry-run announces remember-me cleanup and deletes nothing" bad
fi

# ─────────────────────────────────────────────────────────────────────
# success path: account + flex index + remember-me tokens gone, others kept
# ─────────────────────────────────────────────────────────────────────
out="$(run dev anders --yes)" || true
if printf '%s' "$out" | grep -q "Deleted 'anders'" \
   && [ ! -f "$ACC/anders.yaml" ] \
   && [ ! -f "$IDX/accounts.yaml" ] \
   && [ ! -f "$RMD/$(sha1 anders).yaml" ]; then
    check "delete removes account YAML + flex index + remember-me tokens" ok
else
    check "delete removes account YAML + flex index + remember-me tokens" bad
fi

if [ -f "$RMD/$(sha1 bodil).yaml" ] && [ -f "$ACC/bodil.yaml" ]; then
    check "other users' accounts and remember-me tokens survive" ok
else
    check "other users' accounts and remember-me tokens survive" bad
fi

if [ -f "$SB/cache-cleared" ]; then
    check "cache is cleared after delete" ok
else
    check "cache is cleared after delete" bad
fi

# ─────────────────────────────────────────────────────────────────────
echo "---"
echo "delete-user unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
