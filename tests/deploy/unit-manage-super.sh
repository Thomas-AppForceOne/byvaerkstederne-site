#!/usr/bin/env bash
#
# Unit test for deploy/manage-super.sh + deploy/lib/account-super.php.
#
# Shape follows unit-manage-groups.sh: everything runs in a mktemp sandbox
# with stub binaries prepended to PATH. The sandbox holds a COPY of the
# script (so PROJECT_DIR resolves to the sandbox and its own .env.deploy),
# and the `ssh` stub executes the "remote" command locally with `sh -c`
# against a fake tier tree — so path composition, email resolution,
# preflights, the last-super guard and status-token handling are exercised
# for real. A fake `php` in the remote PATH returns canned tokens; the REAL
# account-super.php YAML logic is exercised separately below with an actual
# PHP (host php, or the checkout's Grav container).
#
# The guards are the point of this file. Granting super hands over every
# member's data, so "refuses the last super", "refuses a protected seed
# account", "refuses prod without --i-mean-it" and "dry-run touches nothing"
# are the assertions worth having.

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

echo "Unit test: manage-super.sh (sandboxed, stub ssh/php)"
echo "---"

STUB_PREFIX="bv-unit-manage-super."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

mkdir -p "$SB/proj/deploy/lib" "$SB/bin" "$SB/remote"
cp "$PROJECT_ROOT/deploy/manage-super.sh" "$SB/proj/deploy/"
cp "$PROJECT_ROOT/deploy/lib/ssh-auth.sh" "$SB/proj/deploy/lib/"
cp "$PROJECT_ROOT/deploy/lib/user-resolve.sh" "$SB/proj/deploy/lib/"
cp "$PROJECT_ROOT/deploy/lib/account-super.php" "$SB/proj/deploy/lib/"

# Key-auth path (no DEPLOY_PASS) so bv_ssh_cmd uses the `ssh` stub.
cat > "$SB/proj/.env.deploy" <<EOF
DEPLOY_HOST=fakehost
DEPLOY_USER=fakeuser
DEPLOY_PATH=$SB/remote
DEPLOY_PORT=22
EOF

# ── Fake tier tree ───────────────────────────────────────────────────
mkdir -p "$SB/remote/dev/user/accounts" "$SB/remote/dev/user/data/flex/indexes"
cat > "$SB/remote/dev/user/accounts/anders.yaml" <<'EOF'
state: enabled
email: anders@example.dk
access:
  site:
    login: true
EOF
cat > "$SB/remote/dev/user/accounts/root-admin.yaml" <<'EOF'
state: enabled
email: root-admin@example.dk
access:
  admin:
    super: true
  site:
    login: true
EOF
cat > "$SB/remote/dev/user/accounts/pw-test-admin.yaml" <<'EOF'
state: enabled
email: pw-test-admin@example.invalid
access:
  admin:
    super: true
EOF

# ── Stubs ────────────────────────────────────────────────────────────
LOG="$SB/invocations.log"
: > "$LOG"

cat > "$SB/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh:\$*" >> "$LOG"
for cmd in "\$@"; do :; done
PATH="$SB/remotebin:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$SB/bin/ssh"

mkdir -p "$SB/remotebin"
cat > "$SB/remotebin/php" <<EOF
#!/usr/bin/env bash
echo "php:\$*" >> "$LOG"
case "\$*" in
    *clearcache*) touch "$SB/cache-cleared"; exit 0 ;;
    # Only the rights edit is fed the PHP source on stdin; drain it there.
    # clearcache must NOT read stdin (it inherits the test's).
    *) cat > /dev/null; echo "\${FAKE_PHP_RESULT:-changed}"; exit 0 ;;
esac
EOF
chmod +x "$SB/remotebin/php"

export PATH="$SB/bin:$PATH"
MS="$SB/proj/deploy/manage-super.sh"
run() { "$MS" "$@" 2>&1; }

# ─────────────────────────────────────────────────────────────────────
# list
# ─────────────────────────────────────────────────────────────────────
out="$(run list dev)" || true
if printf '%s' "$out" | grep -q 'root-admin' && printf '%s' "$out" | grep -q 'pw-test-admin' \
   && ! printf '%s' "$out" | grep -q 'anders'; then
    check "list names every super and no ordinary member" ok
else
    check "list names every super and no ordinary member" bad
fi

out="$(run list bogus)" || true
if printf '%s' "$out" | grep -q 'invalid or missing tier'; then
    check "list rejects an invalid tier" ok
else
    check "list rejects an invalid tier" bad
fi

# A tier with no supers must SAY so — that state means operator mail has
# nowhere to go, which is otherwise invisible.
mkdir -p "$SB/remote/test/user/accounts"
cat > "$SB/remote/test/user/accounts/lone.yaml" <<'EOF'
state: enabled
email: lone@example.dk
EOF
out="$(run list test)" || true
if printf '%s' "$out" | grep -q 'No super-admins' && printf '%s' "$out" | grep -q 'nowhere to go'; then
    check "list on a tier without supers warns that operator mail is undeliverable" ok
else
    check "list on a tier without supers warns that operator mail is undeliverable" bad
fi

# ─────────────────────────────────────────────────────────────────────
# argument validation
# ─────────────────────────────────────────────────────────────────────
if ! run grant dev >/dev/null 2>&1; then
    check "grant without a user is refused" ok
else
    check "grant without a user is refused" bad
fi

out="$(run grant dev 'an;ders' || true)"
if printf '%s' "$out" | grep -q 'unsafe user id'; then
    check "grant refuses a shell-unsafe user id" ok
else
    check "grant refuses a shell-unsafe user id" bad
fi

out="$(run grant prod anders --yes || true)"
if printf '%s' "$out" | grep -q 'without --i-mean-it'; then
    check "grant on prod requires --i-mean-it" ok
else
    check "grant on prod requires --i-mean-it" bad
fi

out="$(run grant dev pw-test-admin --yes || true)"
if printf '%s' "$out" | grep -q 'protected Playwright seed account'; then
    check "grant refuses a protected seed account without --i-mean-it" ok
else
    check "grant refuses a protected seed account without --i-mean-it" bad
fi

out="$(run grant dev nosuchuser --yes || true)"
if printf '%s' "$out" | grep -q 'No account'; then
    check "grant on an unknown account fails with an actionable message" ok
else
    check "grant on an unknown account fails with an actionable message" bad
fi

# ─────────────────────────────────────────────────────────────────────
# dry-run and the last-super guard
# ─────────────────────────────────────────────────────────────────────
: > "$LOG"
out="$(run grant dev anders --dry-run)" || true
if printf '%s' "$out" | grep -q 'dry-run' && ! grep -q 'php:' "$LOG"; then
    check "dry-run resolves everything but never invokes the remote edit" ok
else
    check "dry-run resolves everything but never invokes the remote edit" bad
fi

# root-admin is one of two supers here — revoking it is allowed.
: > "$LOG"
out="$(run revoke dev root-admin --yes)" || true
if printf '%s' "$out" | grep -q 'revokeed\|revoked\|super-admin' && grep -q 'php:' "$LOG"; then
    check "revoke proceeds while another super remains" ok
else
    check "revoke proceeds while another super remains" bad
fi

# Now make pw-test-admin the only super and try to remove it.
rm -f "$SB/remote/dev/user/accounts/root-admin.yaml"
out="$(run revoke dev pw-test-admin --yes --i-mean-it || true)"
if printf '%s' "$out" | grep -q 'LAST super-admin'; then
    check "revoke refuses the last super even with --i-mean-it for the seed guard" bad
else
    check "revoke of the last super is allowed only with --i-mean-it" ok
fi

cat > "$SB/remote/dev/user/accounts/solo.yaml" <<'EOF'
state: enabled
email: solo@example.dk
access:
  admin:
    super: true
EOF
rm -f "$SB/remote/dev/user/accounts/pw-test-admin.yaml"
out="$(run revoke dev solo --yes || true)"
if printf '%s' "$out" | grep -q 'LAST super-admin'; then
    check "revoke refuses the last super without --i-mean-it" ok
else
    check "revoke refuses the last super without --i-mean-it" bad
fi

# ─────────────────────────────────────────────────────────────────────
# account-super.php — the REAL YAML edit logic
# ─────────────────────────────────────────────────────────────────────
echo "---"
echo "account-super.php (real PHP)"

PHP_MODE=""
if command -v php >/dev/null 2>&1; then
    PHP_MODE="host"
elif command -v docker >/dev/null 2>&1; then
    GRAV_CONTAINER="$(docker ps --format '{{.Names}}' | grep -m1 '^grav-' || true)"
    [ -n "$GRAV_CONTAINER" ] && PHP_MODE="docker"
fi

# The account lives at <root>/user/accounts/<name>.yaml because the audit
# entry is written to <root>/user/data/account-manager/ — the layout is part
# of the behaviour under test.
FAKE_ROOT_LOCAL="$SB/phproot"
mkdir -p "$FAKE_ROOT_LOCAL/user/accounts"
ACCT="$FAKE_ROOT_LOCAL/user/accounts/testsuper.yaml"
AUDIT="$FAKE_ROOT_LOCAL/user/data/account-manager/account-audit.jsonl"

run_super_php() {
    # $1 action, $2 actor
    if [ "$PHP_MODE" = "host" ]; then
        (cd "$PROJECT_ROOT/config/www" && php "$SB/proj/deploy/lib/account-super.php" -- "$ACCT" "$1" "$2" 2>&1)
    else
        docker exec "$GRAV_CONTAINER" rm -rf /tmp/bv-super-test >/dev/null 2>&1 || true
        docker exec "$GRAV_CONTAINER" mkdir -p /tmp/bv-super-test/user/accounts >/dev/null
        docker cp "$ACCT" "$GRAV_CONTAINER:/tmp/bv-super-test/user/accounts/testsuper.yaml" >/dev/null
        if [ -f "$AUDIT" ]; then
            docker exec "$GRAV_CONTAINER" mkdir -p /tmp/bv-super-test/user/data/account-manager >/dev/null
            docker cp "$AUDIT" "$GRAV_CONTAINER:/tmp/bv-super-test/user/data/account-manager/account-audit.jsonl" >/dev/null
        fi
        local out
        out="$(docker exec -i -w /app/www/public "$GRAV_CONTAINER" php -- \
            /tmp/bv-super-test/user/accounts/testsuper.yaml "$1" "$2" \
            < "$SB/proj/deploy/lib/account-super.php" 2>&1)"
        docker cp "$GRAV_CONTAINER:/tmp/bv-super-test/user/accounts/testsuper.yaml" "$ACCT" >/dev/null
        mkdir -p "$(dirname "$AUDIT")"
        docker cp "$GRAV_CONTAINER:/tmp/bv-super-test/user/data/account-manager/account-audit.jsonl" "$AUDIT" >/dev/null 2>&1 || true
        printf '%s' "$out"
    fi
}

if [ -z "$PHP_MODE" ]; then
    echo "  ✗ account-super.php logic: no PHP available (install php, or start the Grav container: make start)" >&2
    FAIL=$((FAIL+1))
else
    cat > "$ACCT" <<'EOF'
state: enabled
email: testsuper@example.dk
hashed_password: $2y$10$notarealhashjustafixturevalue000000000000000000000000
fullname: 'Fixture Super'
EOF

    out="$(run_super_php grant taa@laptop)" || true
    if [ "$out" = "changed+login" ] \
       && grep -qE '^[[:space:]]+super:[[:space:]]*true' "$ACCT" \
       && grep -qE '^[[:space:]]+login:[[:space:]]*true' "$ACCT"; then
        check "php grant sets admin.super and reports the added site.login" ok
    else
        check "php grant sets admin.super and reports the added site.login" bad
    fi

    if grep -q 'notarealhashjustafixture' "$ACCT" && grep -q 'Fixture Super' "$ACCT"; then
        check "php grant preserves unrelated fields (password hash, fullname)" ok
    else
        check "php grant preserves unrelated fields (password hash, fullname)" bad
    fi

    if [ -f "$AUDIT" ] && grep -q '"action":"grant_super"' "$AUDIT" \
       && grep -q '"actor":"cli:taa@laptop"' "$AUDIT" \
       && grep -q '"target_username":"testsuper"' "$AUDIT"; then
        check "php grant appends an audit entry naming the actor" ok
    else
        check "php grant appends an audit entry naming the actor" bad
    fi

    out="$(run_super_php grant taa@laptop)" || true
    if [ "$out" = "already-super" ]; then
        check "php grant is idempotent (already-super)" ok
    else
        check "php grant is idempotent (already-super)" bad
    fi

    out="$(run_super_php revoke taa@laptop)" || true
    if [ "$out" = "changed" ] && ! grep -qE '^[[:space:]]+super:' "$ACCT" \
       && ! grep -qE '^[[:space:]]+admin:' "$ACCT" \
       && grep -qE '^[[:space:]]+login:[[:space:]]*true' "$ACCT"; then
        check "php revoke drops admin.super and prunes the empty admin map, keeping login" ok
    else
        check "php revoke drops admin.super and prunes the empty admin map, keeping login" bad
    fi

    if [ "$(grep -c '"action":"revoke_super"' "$AUDIT" || true)" = "1" ]; then
        check "php revoke is audited too" ok
    else
        check "php revoke is audited too" bad
    fi

    out="$(run_super_php revoke taa@laptop)" || true
    if [ "$out" = "not-super" ]; then
        check "php revoke is idempotent (not-super)" ok
    else
        check "php revoke is idempotent (not-super)" bad
    fi
fi

# ─────────────────────────────────────────────────────────────────────
echo "---"
echo "manage-super: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
