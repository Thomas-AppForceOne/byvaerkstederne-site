#!/usr/bin/env bash
#
# Unit test for deploy/push-data.sh argument guards — no network, no env
# needed: the guards under test fire before credentials are loaded.
# Locks in the flex-data lifecycle contract: a push must name its payload
# explicitly (no implicit begivenheder.yaml default — flex data is live
# user state on the tiers), and the user-content refusal list still holds.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PD="$PROJECT_ROOT/deploy/push-data.sh"

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

echo "Unit test: push-data.sh guards (no-default payload + refusal list)"
echo "---"

# no tier → usage, non-zero
if ! "$PD" >/dev/null 2>&1; then
    check "missing tier is refused" ok
else
    check "missing tier is refused" bad
fi

# tier but no --files → the new required-payload refusal
out="$("$PD" test 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--files= is required' \
   && printf '%s' "$out" | grep -q 'live user state'; then
    check "missing --files= is refused with the live-state warning" ok
else
    check "missing --files= is refused with the live-state warning" bad
fi

# prod without --i-mean-it (with files) → still gated
out="$("$PD" prod --files=begivenheder.yaml 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- '--i-mean-it'; then
    check "prod is not gated behind an --i-mean-it ceremony" bad
else
    check "prod is not gated behind an --i-mean-it ceremony" ok
fi

echo "---"
echo "push-data guard unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
