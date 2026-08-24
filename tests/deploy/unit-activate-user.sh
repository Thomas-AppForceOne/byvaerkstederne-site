#!/usr/bin/env bash
#
# Unit test for deploy/activate-user.sh — same sandbox shape as
# unit-manage-groups.sh: a copy of the script runs against its own
# .env.deploy, and the `ssh` stub executes the "remote" command locally
# against a fake tier tree. The fake `php` handles the toggle-user CLI by
# actually rewriting the account YAML's state line, so the end-to-end
# state flip and the already-in-state no-op are exercised for real.

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

echo "Unit test: activate-user.sh (sandboxed, stub ssh/php)"
echo "---"

STUB_PREFIX="bv-unit-activate-user."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# ── Sandbox project ──────────────────────────────────────────────────
mkdir -p "$SB/proj/deploy/lib" "$SB/bin" "$SB/remotebin"
cp "$PROJECT_ROOT/deploy/activate-user.sh" "$SB/proj/deploy/"
cp "$PROJECT_ROOT/deploy/lib/ssh-auth.sh" "$SB/proj/deploy/lib/"
# php-parity.sh is sourced by the scripts under test (bv_php_remote_bin);
# without it the sandboxed copy dies at source time.
cp "$PROJECT_ROOT/deploy/lib/php-parity.sh" "$SB/proj/deploy/lib/"
cp "$PROJECT_ROOT/deploy/lib/user-resolve.sh" "$SB/proj/deploy/lib/"

cat > "$SB/proj/.env.deploy" <<EOF
DEPLOY_HOST=fakehost
DEPLOY_USER=fakeuser
DEPLOY_PATH=$SB/remote
DEPLOY_PORT=22
EOF

# ── Fake tier tree ───────────────────────────────────────────────────
mkdir -p "$SB/remote/dev/user/accounts" "$SB/remote/dev/user/data/flex/indexes"
cat > "$SB/remote/dev/user/accounts/anders.yaml" <<'EOF'
state: disabled
email: anders@example.dk
access:
  site:
    login: true
EOF
cat > "$SB/remote/dev/user/accounts/bodil.yaml" <<'EOF'
state: enabled
email: shared@example.dk
EOF
cat > "$SB/remote/dev/user/accounts/carla.yaml" <<'EOF'
state: enabled
email: shared@example.dk
EOF
cat > "$SB/remote/dev/user/accounts/pw-test-user.yaml" <<'EOF'
state: enabled
email: pw-test-user@example.invalid
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

# Fake remote php: implements toggle-user by rewriting the state line
# (mirrors what the real CLI does), and marks clearcache.
cat > "$SB/remotebin/php" <<'PHPEOF'
#!/usr/bin/env bash
LOG_FILE="__LOG__"
echo "php:$*" >> "$LOG_FILE"
case "$*" in
    *clearcache*) touch "__SB__/cache-cleared"; exit 0 ;;
    *toggle-user*)
        user=""; state=""
        while [ $# -gt 0 ]; do
            case "$1" in
                -u) user="$2"; shift 2 ;;
                -s) state="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        f="__SB__/remote/dev/user/accounts/$user.yaml"
        [ -f "$f" ] || { echo "Error: user not found"; exit 1; }
        if [ -n "${FAKE_TOGGLE_FAIL:-}" ]; then echo "Error: simulated CLI failure"; exit 1; fi
        sed -i '' "s/^state:.*/state: $state/" "$f" 2>/dev/null || sed -i "s/^state:.*/state: $state/" "$f"
        echo "Success! User $user state set to .$state"
        exit 0
        ;;
    *) exit 0 ;;
esac
PHPEOF
python3 - "$SB" <<'PYEOF'
import sys
sb = sys.argv[1]
p = f"{sb}/remotebin/php"
s = open(p).read().replace("__LOG__", f"{sb}/invocations.log").replace("__SB__", sb)
open(p, "w").write(s)
PYEOF
chmod +x "$SB/remotebin/php"

export PATH="$SB/bin:$PATH"
AU="$SB/proj/deploy/activate-user.sh"
run() { "$AU" "$@" 2>&1; }

# ─────────────────────────────────────────────────────────────────────
# validation failures
# ─────────────────────────────────────────────────────────────────────
out="$(run bogus anders)" || true
if printf '%s' "$out" | grep -q 'invalid or missing tier'; then
    check "invalid tier is refused" ok
else
    check "invalid tier is refused" bad
fi

if ! run dev >/dev/null 2>&1; then
    check "missing user fails" ok
else
    check "missing user fails" bad
fi

out="$(run dev anders --state=frozen)" || true
if printf '%s' "$out" | grep -q "Invalid state 'frozen'"; then
    check "invalid --state value is refused" ok
else
    check "invalid --state value is refused" bad
fi

out="$(run dev 'ha/xx')" || true
if printf '%s' "$out" | grep -q 'unsafe user id'; then
    check "unsafe user id is refused" ok
else
    check "unsafe user id is refused" bad
fi

out="$(run prod anders --yes)" || true
if printf '%s' "$out" | grep -q -- '--i-mean-it'; then
    check "prod is not gated behind an --i-mean-it ceremony" bad
else
    check "prod is not gated behind an --i-mean-it ceremony" ok
fi

out="$(run dev pw-test-user --state=disabled --yes)" || true
if printf '%s' "$out" | grep -q 'protected Playwright seed'; then
    check "protected pw-test-* account warns and continues (no longer refused)" ok
else
    check "protected pw-test-* account warns and continues (no longer refused)" bad
fi

# ─────────────────────────────────────────────────────────────────────
# resolution + preflight
# ─────────────────────────────────────────────────────────────────────
out="$(run dev nobody --yes)" || true
if printf '%s' "$out" | grep -q "No account 'nobody'"; then
    check "missing account fails with a clear message" ok
else
    check "missing account fails with a clear message" bad
fi

out="$(run dev missing@example.dk --yes)" || true
if printf '%s' "$out" | grep -q 'No account on dev has email'; then
    check "unknown email fails with a clear message" ok
else
    check "unknown email fails with a clear message" bad
fi

out="$(run dev shared@example.dk --state=disabled --yes)" || true
if printf '%s' "$out" | grep -q 'more than one account'; then
    check "ambiguous email (two accounts) is refused" ok
else
    check "ambiguous email (two accounts) is refused" bad
fi

out="$(run dev anders@example.dk --dry-run)" || true
if printf '%s' "$out" | grep -q "resolved email 'anders@example.dk' to username 'anders'" \
   && printf '%s' "$out" | grep -q 'current state: disabled' \
   && printf '%s' "$out" | grep -q 'dry-run' \
   && grep -q '^state: disabled' "$SB/remote/dev/user/accounts/anders.yaml"; then
    check "email resolves; dry-run reports the current state and changes nothing" ok
else
    check "email resolves; dry-run reports the current state and changes nothing" bad
fi

# ─────────────────────────────────────────────────────────────────────
# the state flip
# ─────────────────────────────────────────────────────────────────────
rm -f "$SB/cache-cleared"
out="$(run dev anders --yes)" || true
if printf '%s' "$out" | grep -q "Activated 'anders' on dev" \
   && grep -q '^state: enabled' "$SB/remote/dev/user/accounts/anders.yaml" \
   && [ -f "$SB/cache-cleared" ] \
   && grep -q 'toggle-user -u anders -s enabled' "$LOG"; then
    check "activate flips state to enabled via toggle-user and clears the cache" ok
else
    check "activate flips state to enabled via toggle-user and clears the cache" bad
fi

rm -f "$SB/cache-cleared"
out="$(run dev anders --yes)" || true
if printf '%s' "$out" | grep -q 'already enabled' && [ ! -f "$SB/cache-cleared" ]; then
    check "already-in-target-state is a friendly no-op (no cache clear)" ok
else
    check "already-in-target-state is a friendly no-op (no cache clear)" bad
fi

out="$(run dev anders --state=disabled --yes)" || true
if printf '%s' "$out" | grep -q "Disabled 'anders' on dev" \
   && grep -q '^state: disabled' "$SB/remote/dev/user/accounts/anders.yaml"; then
    check "--state=disabled locks the account back out" ok
else
    check "--state=disabled locks the account back out" bad
fi

out="$(FAKE_TOGGLE_FAIL=1 run dev anders --yes)" || true
if printf '%s' "$out" | grep -q 'Remote toggle-user failed' \
   && grep -q '^state: disabled' "$SB/remote/dev/user/accounts/anders.yaml"; then
    check "a CLI failure surfaces and the account is untouched" ok
else
    check "a CLI failure surfaces and the account is untouched" bad
fi

# ─────────────────────────────────────────────────────────────────────
echo "---"
echo "activate-user: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
