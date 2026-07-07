#!/usr/bin/env bash
#
# Unit test for deploy/manage-groups.sh + deploy/lib/account-groups.php.
#
# Shape follows unit-ssh-auth.sh: everything runs in a mktemp sandbox with
# stub binaries prepended to PATH. The sandbox holds a COPY of the script
# (so PROJECT_DIR resolves to the sandbox: its own .env.deploy and repo
# groups.yaml fixture), and the `ssh` stub executes the "remote" command
# locally with `sh -c` against a fake tier tree — so path composition,
# email resolution, preflights and the status-token handling are exercised
# for real. A fake `php` inside the remote PATH returns canned tokens; the
# REAL account-groups.php YAML logic is tested separately with an actual
# PHP (host php, or the checkout's Grav container).

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

echo "Unit test: manage-groups.sh (sandboxed, stub ssh/php)"
echo "---"

STUB_PREFIX="bv-unit-manage-groups."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# ── Sandbox project: script copy + fixtures ──────────────────────────
mkdir -p "$SB/proj/deploy/lib" "$SB/proj/config/www/user/config" "$SB/bin" "$SB/remote"
cp "$PROJECT_ROOT/deploy/manage-groups.sh" "$SB/proj/deploy/"
cp "$PROJECT_ROOT/deploy/lib/ssh-auth.sh" "$SB/proj/deploy/lib/"
cp "$PROJECT_ROOT/deploy/lib/user-resolve.sh" "$SB/proj/deploy/lib/"
cp "$PROJECT_ROOT/deploy/lib/account-groups.php" "$SB/proj/deploy/lib/"

cat > "$SB/proj/config/www/user/config/groups.yaml" <<'EOF'
organizers:
  readableName: 'Arrangør'
  description: 'Can create and edit own events from the public site.'
  access:
    site:
      login: true
moderators:
  readableName: 'Moderator'
  description: 'Fixture second group.'
  access:
    site:
      login: true
EOF

# Key-auth path (no DEPLOY_PASS) so bv_ssh_cmd uses the `ssh` stub.
cat > "$SB/proj/.env.deploy" <<EOF
DEPLOY_HOST=fakehost
DEPLOY_USER=fakeuser
DEPLOY_PATH=$SB/remote
DEPLOY_PORT=22
EOF

# ── Fake tier tree (what the "remote" sees) ──────────────────────────
mkdir -p "$SB/remote/dev/user/accounts" "$SB/remote/dev/user/config" "$SB/remote/dev/user/data/flex/indexes"
cat > "$SB/remote/dev/user/config/groups.yaml" <<'EOF'
organizers:
  readableName: 'Arrangør'
EOF
cat > "$SB/remote/dev/user/accounts/anders.yaml" <<'EOF'
state: enabled
email: anders@example.dk
access:
  site:
    login: true
EOF
cat > "$SB/remote/dev/user/accounts/bodil.yaml" <<'EOF'
state: enabled
email: shared@example.dk
access:
  site:
    login: true
EOF
cat > "$SB/remote/dev/user/accounts/carla.yaml" <<'EOF'
state: enabled
email: shared@example.dk
access:
  site:
    login: true
EOF
cat > "$SB/remote/dev/user/accounts/pw-test-org.yaml" <<'EOF'
state: enabled
email: pw-test-org@example.invalid
groups:
  - organizers
EOF

# ── Stubs ────────────────────────────────────────────────────────────
LOG="$SB/invocations.log"

# ssh stub: run the remote command locally, with the remote PATH set so the
# fake `php` below shadows any real one. Preserves stdin (the piped
# account-groups.php).
cat > "$SB/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh:\$*" >> "$LOG"
# The remote command is the last argument.
for cmd in "\$@"; do :; done
PATH="$SB/remotebin:\$PATH" sh -c "\$cmd"
EOF
chmod +x "$SB/bin/ssh"

# Fake remote php: log; canned token for the group edit, marker for clearcache.
mkdir -p "$SB/remotebin"
cat > "$SB/remotebin/php" <<EOF
#!/usr/bin/env bash
echo "php:\$*" >> "$LOG"
case "\$*" in
    *clearcache*) touch "$SB/cache-cleared"; exit 0 ;;
    # Only the group-edit invocation is fed the PHP source on stdin; drain
    # it there (finite — it's a file). The clearcache call must NOT read
    # stdin: it inherits the test's, which never closes in background runs.
    *) cat > /dev/null; echo "\${FAKE_PHP_RESULT:-changed}"; exit 0 ;;
esac
EOF
chmod +x "$SB/remotebin/php"

export PATH="$SB/bin:$PATH"
MG="$SB/proj/deploy/manage-groups.sh"
run() { "$MG" "$@" 2>&1; }

# ─────────────────────────────────────────────────────────────────────
# list
# ─────────────────────────────────────────────────────────────────────
out="$(run list)" || true
if printf '%s' "$out" | grep -q 'organizers' && printf '%s' "$out" | grep -q 'moderators' \
   && printf '%s' "$out" | grep -q 'Arrangør'; then
    check "list (no tier) prints every repo group with readable names" ok
else
    check "list (no tier) prints every repo group with readable names" bad
fi

out="$(run list dev)" || true
if printf '%s' "$out" | grep -q 'deployed on dev' && printf '%s' "$out" | grep -q 'organizers' \
   && ! printf '%s' "$out" | grep -q 'moderators'; then
    check "list dev reads the TIER's deployed groups.yaml (repo-only group absent)" ok
else
    check "list dev reads the TIER's deployed groups.yaml (repo-only group absent)" bad
fi

out="$(run list bogus)" || true
if printf '%s' "$out" | grep -q 'Invalid tier'; then
    check "list rejects an invalid tier" ok
else
    check "list rejects an invalid tier" bad
fi

# ─────────────────────────────────────────────────────────────────────
# grant/revoke — argument validation failures
# ─────────────────────────────────────────────────────────────────────
if ! run grant dev anders >/dev/null; then
    check "grant without a group fails" ok
else
    check "grant without a group fails" bad
fi

out="$(run grant dev anders 'nope;rm')" || true
if printf '%s' "$out" | grep -q 'unsafe group name'; then
    check "grant rejects an unsafe group name" ok
else
    check "grant rejects an unsafe group name" bad
fi

out="$(run grant dev anders no-such-group)" || true
if printf '%s' "$out" | grep -q 'not defined'; then
    check "grant rejects a group missing from the repo groups.yaml" ok
else
    check "grant rejects a group missing from the repo groups.yaml" bad
fi

out="$(run grant dev 'ha/xx' organizers)" || true
if printf '%s' "$out" | grep -q 'unsafe user id'; then
    check "grant rejects an unsafe user id" ok
else
    check "grant rejects an unsafe user id" bad
fi

out="$(run grant prod anders organizers --yes)" || true
if printf '%s' "$out" | grep -q -- '--i-mean-it'; then
    check "prod without --i-mean-it is refused" ok
else
    check "prod without --i-mean-it is refused" bad
fi

out="$(run revoke dev pw-test-org organizers --yes)" || true
if printf '%s' "$out" | grep -q 'protected Playwright seed'; then
    check "protected pw-test-* account is refused without --i-mean-it" ok
else
    check "protected pw-test-* account is refused without --i-mean-it" bad
fi

# ─────────────────────────────────────────────────────────────────────
# grant/revoke — remote preflights
# ─────────────────────────────────────────────────────────────────────
out="$(run grant dev nobody organizers --yes)" || true
if printf '%s' "$out" | grep -q "No account 'nobody'"; then
    check "grant against a missing account fails with a clear message" ok
else
    check "grant against a missing account fails with a clear message" bad
fi

out="$(run grant dev anders moderators --yes)" || true
if printf '%s' "$out" | grep -q 'NOT in dev'; then
    check "grant refuses a group the tier has not deployed yet" ok
else
    check "grant refuses a group the tier has not deployed yet" bad
fi

out="$(run grant dev anders@example.dk organizers --dry-run)" || true
if printf '%s' "$out" | grep -q "resolved email 'anders@example.dk' to username 'anders'" \
   && printf '%s' "$out" | grep -q 'dry-run'; then
    check "email resolves to the username; dry-run stops before any change" ok
else
    check "email resolves to the username; dry-run stops before any change" bad
fi

out="$(run grant dev missing@example.dk organizers --yes)" || true
if printf '%s' "$out" | grep -q 'No account on dev has email'; then
    check "unknown email fails with a clear message" ok
else
    check "unknown email fails with a clear message" bad
fi

out="$(run grant dev shared@example.dk organizers --yes)" || true
if printf '%s' "$out" | grep -q 'more than one account'; then
    check "ambiguous email (two accounts) is refused" ok
else
    check "ambiguous email (two accounts) is refused" bad
fi

# ─────────────────────────────────────────────────────────────────────
# grant/revoke — mutation orchestration (fake remote php)
# ─────────────────────────────────────────────────────────────────────
rm -f "$SB/cache-cleared" "$LOG"
out="$(run grant dev anders organizers --yes)" || true
if printf '%s' "$out" | grep -q "Granted 'organizers' to 'anders' on dev" \
   && [ -f "$SB/cache-cleared" ] \
   && grep -q 'php:-- .*anders.yaml organizers grant' "$LOG"; then
    check "grant runs the remote PHP edit with the right args and clears the cache" ok
else
    check "grant runs the remote PHP edit with the right args and clears the cache" bad
fi

rm -f "$SB/cache-cleared"
out="$(FAKE_PHP_RESULT=already-member run grant dev anders organizers --yes)" || true
if printf '%s' "$out" | grep -q 'already has group' && [ ! -f "$SB/cache-cleared" ]; then
    check "already-member is a friendly no-op (no cache clear)" ok
else
    check "already-member is a friendly no-op (no cache clear)" bad
fi

out="$(FAKE_PHP_RESULT=not-a-member run revoke dev anders organizers --yes)" || true
if printf '%s' "$out" | grep -q 'does not have group'; then
    check "revoking an absent membership is a friendly no-op" ok
else
    check "revoking an absent membership is a friendly no-op" bad
fi

out="$(FAKE_PHP_RESULT='error: cannot parse account YAML' run grant dev anders organizers --yes)" || true
if printf '%s' "$out" | grep -q 'Remote group edit failed'; then
    check "a remote PHP error surfaces and fails the command" ok
else
    check "a remote PHP error surfaces and fails the command" bad
fi

# revoke works for a group that is NOT in the repo groups.yaml (stale cleanup)
out="$(run revoke dev anders retired-group --yes)" || true
if printf '%s' "$out" | grep -q "Revoked 'retired-group'"; then
    check "revoke allows a group no longer defined in the repo" ok
else
    check "revoke allows a group no longer defined in the repo" bad
fi

# ─────────────────────────────────────────────────────────────────────
# account-groups.php — the REAL YAML edit logic
# ─────────────────────────────────────────────────────────────────────
# Needs a real PHP with symfony/yaml. Prefer host php + the feature-flags
# plugin's vendored symfony/yaml; else the checkout's Grav dev container.
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

run_groups_php() {
    # $1 = account yaml (host path), $2 = group, $3 = action
    if [ "$PHP_MODE" = "host" ]; then
        ( cd "$PHP_AUTOLOAD_DIR" \
          && php -- "$1" "$2" "$3" < "$PROJECT_ROOT/deploy/lib/account-groups.php" )
    else
        docker cp "$1" "$GRAV_CONTAINER:/tmp/acct-under-test.yaml" >/dev/null
        docker exec -i -w /app/www/public "$GRAV_CONTAINER" php -- /tmp/acct-under-test.yaml "$2" "$3" \
            < "$PROJECT_ROOT/deploy/lib/account-groups.php"
        docker cp "$GRAV_CONTAINER:/tmp/acct-under-test.yaml" "$1" >/dev/null
    fi
}

if [ -z "$PHP_MODE" ]; then
    echo "  ✗ account-groups.php logic: no PHP available (install php, or start the Grav container: make start)" >&2
    FAIL=$((FAIL+1))
else
    ACCT="$SB/acct.yaml"
    cat > "$ACCT" <<'EOF'
state: enabled
email: anders@example.dk
hashed_password: '$2y$10$abcdefghijklmnopqrstuv'
access:
  site:
    login: true
EOF

    out="$(run_groups_php "$ACCT" organizers grant)" || true
    if [ "$out" = "changed" ] && grep -q '^groups:' "$ACCT" && grep -qE '^[[:space:]]+- organizers$' "$ACCT" \
       && grep -q 'hashed_password: .2y.10' "$ACCT" && grep -q 'login: true' "$ACCT"; then
        check "php grant appends groups and preserves every other field (via $PHP_MODE php)" ok
    else
        check "php grant appends groups and preserves every other field (via $PHP_MODE php)" bad
    fi

    out="$(run_groups_php "$ACCT" organizers grant)" || true
    if [ "$out" = "already-member" ]; then
        check "php grant is idempotent (already-member)" ok
    else
        check "php grant is idempotent (already-member)" bad
    fi

    out="$(run_groups_php "$ACCT" moderators grant)" || true
    out2="$(run_groups_php "$ACCT" organizers revoke)" || true
    if [ "$out" = "changed" ] && [ "$out2" = "changed" ] \
       && grep -q 'moderators' "$ACCT" && ! grep -q 'organizers' "$ACCT"; then
        check "php revoke removes only the named group" ok
    else
        check "php revoke removes only the named group" bad
    fi

    out="$(run_groups_php "$ACCT" moderators revoke)" || true
    if [ "$out" = "changed" ] && ! grep -q '^groups:' "$ACCT"; then
        check "php revoke of the last group drops the empty groups key" ok
    else
        check "php revoke of the last group drops the empty groups key" bad
    fi

    out="$(run_groups_php "$ACCT" organizers revoke)" || true
    if [ "$out" = "not-a-member" ]; then
        check "php revoke is idempotent (not-a-member)" ok
    else
        check "php revoke is idempotent (not-a-member)" bad
    fi
fi

# ─────────────────────────────────────────────────────────────────────
echo "---"
echo "manage-groups: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
