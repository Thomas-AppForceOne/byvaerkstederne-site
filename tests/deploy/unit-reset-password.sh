#!/usr/bin/env bash
#
# Unit test for deploy/reset-password.sh + deploy/lib/account-password.php.
#
# Same sandbox shape as unit-manage-groups.sh / unit-activate-user.sh. The
# secrecy property is asserted directly: after a successful reset the
# generated password must appear NOWHERE in the ssh/php invocation log —
# it travels only inside the piped PHP source (stdin). The real hashing
# logic is tested with an actual PHP (host php or the checkout's Grav
# container), including password_verify of the written hash and the
# pending-reset-token invalidation.

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

echo "Unit test: reset-password.sh (sandboxed, stub ssh/php)"
echo "---"

STUB_PREFIX="bv-unit-reset-password."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# ── Sandbox project ──────────────────────────────────────────────────
mkdir -p "$SB/proj/deploy/lib" "$SB/bin" "$SB/remotebin"
cp "$PROJECT_ROOT/deploy/reset-password.sh" "$SB/proj/deploy/"
cp "$PROJECT_ROOT/deploy/lib/ssh-auth.sh" "$SB/proj/deploy/lib/"
cp "$PROJECT_ROOT/deploy/lib/user-resolve.sh" "$SB/proj/deploy/lib/"
cp "$PROJECT_ROOT/deploy/lib/account-password.php" "$SB/proj/deploy/lib/"

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
hashed_password: $2y$10$oldoldoldoldoldoldoldo
EOF
cat > "$SB/remote/dev/user/accounts/disabled-dan.yaml" <<'EOF'
state: disabled
email: dan@example.dk
hashed_password: $2y$10$oldoldoldoldoldoldoldo
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

# Fake remote php: the password-reset invocation is fed the composed PHP
# source on stdin — capture it (for the secrecy assertion) and answer with
# a canned token. clearcache must not read stdin.
cat > "$SB/remotebin/php" <<EOF
#!/usr/bin/env bash
echo "php:\$*" >> "$LOG"
case "\$*" in
    *clearcache*) touch "$SB/cache-cleared"; exit 0 ;;
    *) cat > "$SB/last-php-stdin"; echo "\${FAKE_PHP_RESULT:-changed}"; exit 0 ;;
esac
EOF
chmod +x "$SB/remotebin/php"

export PATH="$SB/bin:$PATH"
RP="$SB/proj/deploy/reset-password.sh"
run() { "$RP" "$@" 2>&1; }

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

out="$(run prod anders --yes --generate)" || true
if printf '%s' "$out" | grep -q -- '--i-mean-it'; then
    check "prod without --i-mean-it is refused" ok
else
    check "prod without --i-mean-it is refused" bad
fi

out="$(run dev pw-test-user --yes --generate)" || true
if printf '%s' "$out" | grep -q 'protected Playwright seed'; then
    check "protected pw-test-* account is refused without --i-mean-it" ok
else
    check "protected pw-test-* account is refused without --i-mean-it" bad
fi

out="$(BV_NEW_PASSWORD=weak run dev anders --yes)" || true
if printf '%s' "$out" | grep -q 'does not meet the password policy'; then
    check "a policy-violating BV_NEW_PASSWORD is refused before anything is sent" ok
else
    check "a policy-violating BV_NEW_PASSWORD is refused before anything is sent" bad
fi

out="$(run dev anders --yes < /dev/null)" || true
if printf '%s' "$out" | grep -q 'No TTY to prompt'; then
    check "no TTY + no --generate + no env var fails with guidance" ok
else
    check "no TTY + no --generate + no env var fails with guidance" bad
fi

# ─────────────────────────────────────────────────────────────────────
# resolution + preflight
# ─────────────────────────────────────────────────────────────────────
out="$(run dev nobody --yes --generate)" || true
if printf '%s' "$out" | grep -q "No account 'nobody'"; then
    check "missing account fails with a clear message" ok
else
    check "missing account fails with a clear message" bad
fi

out="$(run dev anders@example.dk --dry-run)" || true
if printf '%s' "$out" | grep -q "resolved email 'anders@example.dk' to username 'anders'" \
   && printf '%s' "$out" | grep -q 'dry-run' \
   && grep -q 'oldoldold' "$SB/remote/dev/user/accounts/anders.yaml"; then
    check "email resolves; dry-run changes nothing (no password needed)" ok
else
    check "email resolves; dry-run changes nothing (no password needed)" bad
fi

out="$(run dev disabled-dan --dry-run)" || true
if printf '%s' "$out" | grep -q "state is 'disabled'" \
   && printf '%s' "$out" | grep -q 'make activate-user'; then
    check "a disabled account triggers the activate-user hint" ok
else
    check "a disabled account triggers the activate-user hint" bad
fi

# ─────────────────────────────────────────────────────────────────────
# the reset itself (fake remote php)
# ─────────────────────────────────────────────────────────────────────
rm -f "$SB/cache-cleared" "$LOG" "$SB/last-php-stdin"
out="$(run dev anders --yes --generate)" || true
GENERATED="$(printf '%s\n' "$out" | grep -A2 'Generated password' | grep -oE 'Bv9-[0-9a-f]{16}' | head -1 || true)"
if printf '%s' "$out" | grep -q "Password reset for 'anders' on dev" \
   && [ -n "$GENERATED" ] \
   && [ -f "$SB/cache-cleared" ]; then
    check "--generate resets, clears the cache, and prints the password once" ok
else
    check "--generate resets, clears the cache, and prints the password once" bad
fi

# Secrecy: the password must never appear in any ssh/php ARGUMENT (the
# invocation log), only inside the piped PHP source (stdin capture).
B64="$(printf '%s' "$GENERATED" | base64 | tr -d '\n')"
if [ -n "$GENERATED" ] && ! grep -qF "$GENERATED" "$LOG" && ! grep -qF "$B64" "$LOG" \
   && grep -qF "$B64" "$SB/last-php-stdin"; then
    check "the password travels only via SSH stdin — never in any process argument" ok
else
    check "the password travels only via SSH stdin — never in any process argument" bad
fi

out="$(BV_NEW_PASSWORD='Testing123' run dev anders --yes)" || true
if printf '%s' "$out" | grep -q "Password reset for 'anders' on dev" \
   && ! printf '%s' "$out" | grep -q 'Generated password'; then
    check "BV_NEW_PASSWORD path resets without printing any password" ok
else
    check "BV_NEW_PASSWORD path resets without printing any password" bad
fi

out="$(FAKE_PHP_RESULT='error: cannot parse account YAML' run dev anders --yes --generate)" || true
if printf '%s' "$out" | grep -q 'Remote password reset failed'; then
    check "a remote PHP error surfaces and fails the command" ok
else
    check "a remote PHP error surfaces and fails the command" bad
fi

# ─────────────────────────────────────────────────────────────────────
# account-password.php — the REAL hashing logic
# ─────────────────────────────────────────────────────────────────────
# Host mode needs a php + any vendored symfony/yaml. Two candidates: the
# feature-flags plugin's dev vendor tree (present locally, gitignored) and
# migrations/vendor (installed by the ci-test-deploy workflow's composer
# step — this is what makes the real-PHP checks run in CI).
PHP_MODE=""
PHP_AUTOLOAD_DIR=""
if command -v php >/dev/null 2>&1; then
    for candidate in "$PROJECT_ROOT/config/www/user/plugins/feature-flags" "$PROJECT_ROOT/migrations"; do
        if [ -f "$candidate/vendor/autoload.php" ]; then
            PHP_MODE="host"
            PHP_AUTOLOAD_DIR="$candidate"
            break
        fi
    done
fi
if [ -z "$PHP_MODE" ] && command -v docker >/dev/null 2>&1; then
    GRAV_CONTAINER="$(docker ps --format '{{.Names}}' | grep -m1 '^grav-' || true)"
    [ -n "$GRAV_CONTAINER" ] && PHP_MODE="docker"
fi

# Compose the source exactly like the script does, then run it and a
# password_verify probe with a real PHP.
run_password_php() {
    # $1 = account yaml (host path), $2 = password
    local b64 src
    b64="$(printf '%s' "$2" | base64 | tr -d '\n')"
    src="$(cat "$PROJECT_ROOT/deploy/lib/account-password.php")"
    src="${src//__PW_B64__/$b64}"
    if [ "$PHP_MODE" = "host" ]; then
        ( cd "$PHP_AUTOLOAD_DIR" \
          && printf '%s' "$src" | php -- "$1" )
    else
        docker cp "$1" "$GRAV_CONTAINER:/tmp/acct-pw-test.yaml" >/dev/null
        printf '%s' "$src" | docker exec -i -w /app/www/public "$GRAV_CONTAINER" php -- /tmp/acct-pw-test.yaml
        docker cp "$GRAV_CONTAINER:/tmp/acct-pw-test.yaml" "$1" >/dev/null
    fi
}

verify_password_php() {
    # $1 = account yaml (host path), $2 = password to verify
    local b64 probe
    b64="$(printf '%s' "$2" | base64 | tr -d '\n')"
    probe='<?php
require "vendor/autoload.php";
$d = Symfony\Component\Yaml\Yaml::parseFile($argv[1]);
echo password_verify(base64_decode("'"$b64"'"), $d["hashed_password"] ?? "") ? "verified" : "mismatch";
echo isset($d["reset"]) ? "+reset-still-there" : "+reset-cleared";
echo isset($d["password"]) ? "+plaintext-left" : "+no-plaintext";
echo "\n";'
    if [ "$PHP_MODE" = "host" ]; then
        ( cd "$PHP_AUTOLOAD_DIR" \
          && printf '%s' "$probe" | php -- "$1" )
    else
        docker cp "$1" "$GRAV_CONTAINER:/tmp/acct-pw-test.yaml" >/dev/null
        printf '%s' "$probe" | docker exec -i -w /app/www/public "$GRAV_CONTAINER" php -- /tmp/acct-pw-test.yaml
    fi
}

if [ -z "$PHP_MODE" ]; then
    echo "  ✗ account-password.php logic: no PHP available (install php, or start the Grav container: make start)" >&2
    FAIL=$((FAIL+1))
else
    ACCT="$SB/acct.yaml"
    cat > "$ACCT" <<'EOF'
state: enabled
email: anders@example.dk
hashed_password: '$2y$10$oldoldoldoldoldoldoldo'
reset: ['stale-token', 1750000000]
access:
  site:
    login: true
EOF

    out="$(run_password_php "$ACCT" 'NytKodeord123')" || true
    probe="$(verify_password_php "$ACCT" 'NytKodeord123')" || true
    if [ "$out" = "changed" ] && [ "$probe" = "verified+reset-cleared+no-plaintext" ] \
       && grep -q 'login: true' "$ACCT" && grep -q 'email: anders@example.dk' "$ACCT"; then
        check "php reset writes a verifiable hash, clears the reset token, keeps other fields (via $PHP_MODE php)" ok
    else
        check "php reset writes a verifiable hash, clears the reset token, keeps other fields (via $PHP_MODE php)" bad
    fi

    probe="$(verify_password_php "$ACCT" 'WrongPassword9')" || true
    if printf '%s' "$probe" | grep -q '^mismatch'; then
        check "php-written hash rejects a wrong password" ok
    else
        check "php-written hash rejects a wrong password" bad
    fi

    # Un-substituted placeholder (operator error / broken pipe) must fail
    # loudly rather than hash the placeholder string.
    out="$( (cd "$PHP_AUTOLOAD_DIR" 2>/dev/null \
        && php -- "$ACCT" < "$PROJECT_ROOT/deploy/lib/account-password.php") 2>&1 || true )"
    if [ "$PHP_MODE" = "docker" ]; then
        out="$(docker exec -i -w /app/www/public "$GRAV_CONTAINER" php -- /tmp/acct-pw-test.yaml \
            < "$PROJECT_ROOT/deploy/lib/account-password.php" 2>&1 || true)"
    fi
    if printf '%s' "$out" | grep -q 'error: no password was injected'; then
        check "the raw template (placeholder not substituted) refuses to run" ok
    else
        check "the raw template (placeholder not substituted) refuses to run" bad
    fi
fi

# ─────────────────────────────────────────────────────────────────────
echo "---"
echo "reset-password: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
