#!/usr/bin/env bash
#
# Unit test for tests/fixtures/grav-seeds/sample-content/apply.sh — runs the
# bundle against a stubbed `docker` whose exec/cp operations act on a fake
# container filesystem under the sandbox. Exercises the failure path
# (container not running, unknown option), the success path (all data files
# seeded as the app user + cache cleared), idempotence (second run skips
# everything and does NOT clear cache), and --force overwrite.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUNDLE="$PROJECT_ROOT/tests/fixtures/grav-seeds/sample-content"

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

echo "Unit test: grav-seeds/sample-content apply.sh (stub docker)"
echo "---"

STUB_PREFIX="bv-unit-sample-seed."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

FAKE_FS="$SB/containerfs"
LOG="$SB/invocations.log"
mkdir -p "$FAKE_FS" "$SB/bin"

# ── docker stub ──────────────────────────────────────────────────────
# Emulates the four invocations apply.sh makes: `docker ps`, `docker exec
# test -f`, `docker exec mkdir -p`, `docker exec sh -c 'cat > …'` (stdin
# write), and the clearcache exec. Container files live under $FAKE_FS.
cat > "$SB/bin/docker" <<EOF
#!/usr/bin/env bash
echo "docker:\$*" >> "$LOG"
cmd="\$1"; shift
case "\$cmd" in
    ps)
        echo "running-grav"
        ;;
    exec)
        # strip flags (-i, -u user, -w dir)
        while [ "\$#" -gt 0 ]; do
            case "\$1" in
                -i) shift ;;
                -u|-w) shift 2 ;;
                *) break ;;
            esac
        done
        container="\$1"; shift
        case "\$1" in
            test)   [ -f "$FAKE_FS\$3" ] ;;
            mkdir)  mkdir -p "$FAKE_FS\$3" ;;
            sh)     target=\$(printf '%s' "\$3" | sed "s/^cat > '//;s/'\$//"); cat > "$FAKE_FS\$target" ;;
            bin/grav) echo "clearcache" >> "$LOG.cache" ;;
        esac
        ;;
esac
EOF
chmod +x "$SB/bin/docker"

export PATH="$SB/bin:$PATH"
run() { "$BUNDLE/apply.sh" "$@" 2>&1; }

DATA_COUNT=$(ls "$BUNDLE"/data/*.yaml | wc -l | tr -d ' ')

# ─────────────────────────────────────────────────────────────────────
# failure paths
# ─────────────────────────────────────────────────────────────────────
out="$(run not-running 2>&1)" || true
if printf '%s' "$out" | grep -q "not running"; then
    check "missing container is refused loudly" ok
else
    check "missing container is refused loudly" bad
fi

out="$(run running-grav --bogus 2>&1)" || true
if printf '%s' "$out" | grep -q "unknown option"; then
    check "unknown option is refused" ok
else
    check "unknown option is refused" bad
fi

# ─────────────────────────────────────────────────────────────────────
# success path: everything seeded, cache cleared
# ─────────────────────────────────────────────────────────────────────
out="$(run running-grav)" || true
SEEDED=$(ls "$FAKE_FS/config/www/user/data/flex-objects/" 2>/dev/null | wc -l | tr -d ' ')
if [ "$SEEDED" = "$DATA_COUNT" ] && printf '%s' "$out" | grep -q "$DATA_COUNT file(s) seeded" \
   && [ -f "$LOG.cache" ]; then
    check "first run seeds all $DATA_COUNT data files and clears cache" ok
else
    check "first run seeds all $DATA_COUNT data files and clears cache" bad
fi

if grep -q -- "-u abc" "$LOG"; then
    check "writes run as the app user (abc), never root" ok
else
    check "writes run as the app user (abc), never root" bad
fi

# ─────────────────────────────────────────────────────────────────────
# idempotence: second run skips, no cache clear
# ─────────────────────────────────────────────────────────────────────
rm -f "$LOG.cache"
out="$(run running-grav)" || true
if printf '%s' "$out" | grep -q "nothing to do" && [ ! -f "$LOG.cache" ]; then
    check "second run is a no-op (skips all, no cache clear)" ok
else
    check "second run is a no-op (skips all, no cache clear)" bad
fi

# ─────────────────────────────────────────────────────────────────────
# --force: overwrites and clears cache again
# ─────────────────────────────────────────────────────────────────────
out="$(run running-grav --force)" || true
if printf '%s' "$out" | grep -q "$DATA_COUNT file(s) seeded" && [ -f "$LOG.cache" ]; then
    check "--force reseeds everything" ok
else
    check "--force reseeds everything" bad
fi

echo "---"
echo "sample-content seed unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
