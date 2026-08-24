#!/usr/bin/env bash
#
# Unit test for deploy/reset-data.sh — same sandbox shape as
# unit-reset-users.sh: a copy of the script runs against its own
# .env.deploy, and the `ssh` stub executes the "remote" command locally
# against a fake versioned data tree (<tier>data/v0/user/data/flex-objects,
# the dir push-data.sh writes into). Exercises the dry-run, the delete
# (YAML only — other files stay), the unsafe-filename refusal, the prod
# gate, and the friendly empty/no-dir paths.

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

echo "Unit test: reset-data.sh (sandboxed, stub ssh/php)"
echo "---"

STUB_PREFIX="bv-unit-reset-data."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# ── Sandbox project ──────────────────────────────────────────────────
mkdir -p "$SB/proj/deploy/lib" "$SB/bin" "$SB/remotebin"
cp "$PROJECT_ROOT/deploy/reset-data.sh" "$SB/proj/deploy/"
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

# ── Fake versioned data tree (matches push-data.sh's layout) ─────────
DATA="$SB/remote/devdata/v0/user/data/flex-objects"
mkdir -p "$DATA" "$SB/remote/dev"
printf 'a: 1\n' > "$DATA/events.yaml"
printf 'b: 2\n' > "$DATA/bug-reports.yaml"
printf 'c: 3\n' > "$DATA/event-rsvps.yaml"
printf 'not yaml\n' > "$DATA/README.txt"

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
RD="$SB/proj/deploy/reset-data.sh"
run() { "$RD" "$@" 2>&1; }

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
    check "prod is not gated behind an --i-mean-it ceremony" bad
else
    check "prod is not gated behind an --i-mean-it ceremony" ok
fi

# ─────────────────────────────────────────────────────────────────────
# unsafe remote filename aborts the whole run
# ─────────────────────────────────────────────────────────────────────
touch "$DATA/bad name.yaml"
out="$(run dev --yes)" || true
if printf '%s' "$out" | grep -q 'unsafe filename' \
   && [ -f "$DATA/events.yaml" ]; then
    check "an unsafe remote filename aborts before anything is deleted" ok
else
    check "an unsafe remote filename aborts before anything is deleted" bad
fi
rm -f "$DATA/bad name.yaml"

# ─────────────────────────────────────────────────────────────────────
# dry-run: lists all YAML, deletes nothing
# ─────────────────────────────────────────────────────────────────────
out="$(run dev --dry-run)" || true
if printf '%s' "$out" | grep -q 'Would delete 3 data file(s)' \
   && printf '%s' "$out" | grep -q 'events.yaml' \
   && printf '%s' "$out" | grep -q 'bug-reports.yaml' \
   && printf '%s' "$out" | grep -q 'event-rsvps.yaml' \
   && [ -f "$DATA/events.yaml" ] \
   && [ ! -f "$SB/cache-cleared" ]; then
    check "dry-run lists the three YAML files and deletes nothing" ok
else
    check "dry-run lists the three YAML files and deletes nothing" bad
fi

# ─────────────────────────────────────────────────────────────────────
# the real reset
# ─────────────────────────────────────────────────────────────────────
rm -f "$SB/cache-cleared"
out="$(run dev --yes)" || true
if printf '%s' "$out" | grep -q 'Deleted 3 flex-objects data file(s) from dev' \
   && [ ! -f "$DATA/events.yaml" ] && [ ! -f "$DATA/bug-reports.yaml" ] \
   && [ ! -f "$DATA/event-rsvps.yaml" ] \
   && [ -f "$DATA/README.txt" ] \
   && [ -f "$SB/cache-cleared" ]; then
    check "reset deletes YAML only, keeps other files, clears cache" ok
else
    check "reset deletes YAML only, keeps other files, clears cache" bad
fi

# ─────────────────────────────────────────────────────────────────────
# friendly no-op paths
# ─────────────────────────────────────────────────────────────────────
rm -f "$SB/cache-cleared"
out="$(run dev --yes)" || true
if printf '%s' "$out" | grep -q 'No flex-objects data on dev' \
   && [ ! -f "$SB/cache-cleared" ]; then
    check "re-run with nothing to delete is a friendly no-op (no cache clear)" ok
else
    check "re-run with nothing to delete is a friendly no-op (no cache clear)" bad
fi

out="$(run test --yes)" || true
if printf '%s' "$out" | grep -q 'No flex-objects data dir on test'; then
    check "missing data dir (undeployed tier) is a friendly no-op" ok
else
    check "missing data dir (undeployed tier) is a friendly no-op" bad
fi

# ─────────────────────────────────────────────────────────────────────
# prod layout: data at <docroot>/proddata/v0, cache clear from the docroot
# ─────────────────────────────────────────────────────────────────────
PDATA="$SB/remote-prod/proddata/v0/user/data/flex-objects"
mkdir -p "$PDATA" "$SB/remote-prod"
printf 'x: 1\n' > "$PDATA/events.yaml"

rm -f "$SB/cache-cleared"
out="$(run prod --yes)" || true
if printf '%s' "$out" | grep -q 'Deleted 1 flex-objects data file(s) from prod' \
   && [ ! -f "$PDATA/events.yaml" ] \
   && [ -f "$SB/cache-cleared" ]; then
    check "prod resolves proddata/v0 under the docroot and clears cache from the docroot" ok
else
    check "prod resolves proddata/v0 under the docroot and clears cache from the docroot" bad
fi

# ─────────────────────────────────────────────────────────────────────
echo "---"
echo "reset-data: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
