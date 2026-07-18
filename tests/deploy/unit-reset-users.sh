#!/usr/bin/env bash
#
# Unit test for deploy/reset-users.sh — same sandbox shape as
# unit-activate-user.sh: a copy of the script runs against its own
# .env.deploy, and the `ssh` stub executes the "remote" command locally
# against a fake tier tree. Exercises the classification (only members are
# deleted; admins, pw-test-* seeds, and unclassifiable accounts are kept),
# the dry-run, the prod gate, and the friendly empty/no-dir paths.

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

echo "Unit test: reset-users.sh (sandboxed, stub ssh/php)"
echo "---"

STUB_PREFIX="bv-unit-reset-users."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# ── Sandbox project ──────────────────────────────────────────────────
mkdir -p "$SB/proj/deploy/lib" "$SB/bin" "$SB/remotebin"
cp "$PROJECT_ROOT/deploy/reset-users.sh" "$SB/proj/deploy/"
cp "$PROJECT_ROOT/deploy/lib/ssh-auth.sh" "$SB/proj/deploy/lib/"

cat > "$SB/proj/.env.deploy" <<EOF
DEPLOY_HOST=fakehost
DEPLOY_USER=fakeuser
DEPLOY_PATH=$SB/remote
DEPLOY_PORT=22
EOF

# ── Fake tier tree ───────────────────────────────────────────────────
ACC="$SB/remote/dev/user/accounts"
IDX="$SB/remote/dev/user/data/flex/indexes"
mkdir -p "$ACC" "$IDX"
touch "$IDX/accounts.yaml"

cat > "$ACC/thomasadmin.yaml" <<'EOF'
state: enabled
email: thomas@example.dk
access:
  admin:
    super: true
EOF
cat > "$ACC/modadmin.yaml" <<'EOF'
state: enabled
email: mod@example.dk
access:
  admin:
    login: true
EOF
cat > "$ACC/anders.yaml" <<'EOF'
state: enabled
email: anders@example.dk
access:
  site:
    login: true
EOF
cat > "$ACC/bodil.yaml" <<'EOF'
state: disabled
email: bodil@example.dk
access:
  site:
    login: true
EOF
cat > "$ACC/weirdo.yaml" <<'EOF'
state: enabled
email: weirdo@example.dk
EOF
cat > "$ACC/pw-test-user.yaml" <<'EOF'
state: enabled
email: pw-test-user@example.invalid
access:
  site:
    login: true
EOF

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
RU="$SB/proj/deploy/reset-users.sh"
run() { "$RU" "$@" 2>&1; }

# ─────────────────────────────────────────────────────────────────────
# validation failures
# ─────────────────────────────────────────────────────────────────────
if ! run bogus >/dev/null 2>&1; then
    check "invalid tier is refused" ok
else
    check "invalid tier is refused" bad
fi

out="$(run prod --yes)" || true
if printf '%s' "$out" | grep -q -- '--i-mean-it'; then
    check "prod without --i-mean-it is refused" ok
else
    check "prod without --i-mean-it is refused" bad
fi

out="$(run dev --bogus-flag)" || true
if printf '%s' "$out" | grep -q 'Unknown arg'; then
    check "unknown option is refused" ok
else
    check "unknown option is refused" bad
fi

# ─────────────────────────────────────────────────────────────────────
# dry-run: correct classification, nothing touched
# ─────────────────────────────────────────────────────────────────────
out="$(run dev --dry-run)" || true
if printf '%s' "$out" | grep -q 'Would delete 2 member account(s)' \
   && printf '%s' "$out" | grep -q 'anders' \
   && printf '%s' "$out" | grep -q 'bodil' \
   && printf '%s' "$out" | grep -q 'playwright-seed' \
   && printf '%s' "$out" | grep -q 'unclassified' \
   && printf '%s' "$out" | grep -q 'dry-run: nothing deleted' \
   && [ -f "$ACC/anders.yaml" ] && [ -f "$ACC/bodil.yaml" ] \
   && [ ! -f "$SB/cache-cleared" ]; then
    check "dry-run lists exactly the two members and deletes nothing" ok
else
    check "dry-run lists exactly the two members and deletes nothing" bad
fi

# ─────────────────────────────────────────────────────────────────────
# the real reset
# ─────────────────────────────────────────────────────────────────────
rm -f "$SB/cache-cleared"
out="$(run dev --yes)" || true
if printf '%s' "$out" | grep -q 'Deleted 2 member account(s) from dev' \
   && [ ! -f "$ACC/anders.yaml" ] && [ ! -f "$ACC/bodil.yaml" ] \
   && [ -f "$ACC/thomasadmin.yaml" ] && [ -f "$ACC/modadmin.yaml" ] \
   && [ -f "$ACC/weirdo.yaml" ] && [ -f "$ACC/pw-test-user.yaml" ] \
   && [ ! -f "$IDX/accounts.yaml" ] \
   && [ -f "$SB/cache-cleared" ]; then
    check "reset deletes members only, keeps admins/seed/unclassified, drops flex index, clears cache" ok
else
    check "reset deletes members only, keeps admins/seed/unclassified, drops flex index, clears cache" bad
fi

# ─────────────────────────────────────────────────────────────────────
# friendly no-op paths
# ─────────────────────────────────────────────────────────────────────
rm -f "$SB/cache-cleared"
out="$(run dev --yes)" || true
if printf '%s' "$out" | grep -q 'No member accounts to delete' \
   && [ ! -f "$SB/cache-cleared" ]; then
    check "re-run with nothing to delete is a friendly no-op (no cache clear)" ok
else
    check "re-run with nothing to delete is a friendly no-op (no cache clear)" bad
fi

out="$(run test --yes)" || true
if printf '%s' "$out" | grep -q 'No accounts dir on test'; then
    check "missing accounts dir (undeployed tier) is a friendly no-op" ok
else
    check "missing accounts dir (undeployed tier) is a friendly no-op" bad
fi

# ─────────────────────────────────────────────────────────────────────
echo "---"
echo "reset-users: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
