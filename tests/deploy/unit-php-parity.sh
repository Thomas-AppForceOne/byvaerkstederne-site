#!/usr/bin/env bash
#
# Unit test for deploy/lib/php-parity.sh and the repo-wide agreement it
# enforces.
#
# THE FAILURE THIS PINS
# ---------------------
# The 2026-08-21 audit found five PHP versions in play with no overlap:
# the container ran 8.3, CI tested 8.1–8.3, one.com served 8.5 and prod
# served 8.4. No version that ran the code was tested and no tested
# version ran anywhere — and nothing in the repo compared the numbers, so
# it stayed invisible until production behaved differently from every
# other tier.
#
# Two halves are asserted here:
#   1. the CHECK behaves (match / mismatch / override / soft cases), and
#   2. the REPO agrees with itself — .php-version, the CI matrix and the
#      pinned container image cannot drift apart silently.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/php-parity.sh
. "$PROJECT_ROOT/deploy/lib/php-parity.sh"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}

echo "Unit test: PHP version parity"
echo "---"

# ── 1. Version normalisation ─────────────────────────────────────────
check "bare version normalises" \
    "$([ "$(bv_php_major_minor '8.3')" = "8.3" ] && echo ok || echo no)"
check "patch version reduces to major.minor" \
    "$([ "$(bv_php_major_minor '8.3.15')" = "8.3" ] && echo ok || echo no)"
check "a full 'php -v' banner is parsed" \
    "$([ "$(bv_php_major_minor 'PHP 8.4.24 (cli) (built: Aug 12 2026 00:00:00) (NTS)')" = "8.4" ] && echo ok || echo no)"
check "empty input yields empty, not garbage" \
    "$([ -z "$(bv_php_major_minor '')" ] && echo ok || echo no)"

# ── 2. The check itself ──────────────────────────────────────────────
run_check() { bv_php_parity_check "$1" "$2" "$3" "${4:-0}" >/dev/null 2>&1; }

check "matching major.minor passes" \
    "$(run_check '8.3' 'PHP 8.3.15 (cli)' dev && echo ok || echo no)"
check "patch drift within the same minor still passes" \
    "$(run_check '8.3' 'PHP 8.3.99 (cli)' dev && echo ok || echo no)"
check "prod on 8.4 against a 8.3 target is REFUSED" \
    "$(run_check '8.3' 'PHP 8.4.24 (cli)' prod && echo no || echo ok)"
check "one.com on 8.5 against a 8.3 target is REFUSED" \
    "$(run_check '8.3' 'PHP 8.5.9' test && echo no || echo ok)"
check "an older minor is refused too (drift is drift)" \
    "$(run_check '8.3' 'PHP 8.1.2' dev && echo no || echo ok)"
check "ALLOW_PHP_MISMATCH=1 overrides the refusal" \
    "$(run_check '8.3' 'PHP 8.4.24 (cli)' prod 1 && echo ok || echo no)"
check "an unreadable remote version soft-skips rather than blocking" \
    "$(run_check '8.3' '' prod && echo ok || echo no)"
check "no declared target soft-skips" \
    "$(run_check '' 'PHP 8.4.24 (cli)' prod && echo ok || echo no)"

# The refusal must be actionable, not just a number mismatch.
msg="$(bv_php_parity_check '8.3' 'PHP 8.4.24' prod 0 2>&1 || true)"
check "refusal names both versions" \
    "$(printf '%s' "$msg" | grep -q '8.4' && printf '%s' "$msg" | grep -q '8.3' && echo ok || echo no)"
check "refusal tells a prod operator where to change it" \
    "$(printf '%s' "$msg" | grep -qi 'MultiPHP' && echo ok || echo no)"
check "refusal names the override" \
    "$(printf '%s' "$msg" | grep -q 'ALLOW_PHP_MISMATCH' && echo ok || echo no)"
msg_dev="$(bv_php_parity_check '8.3' 'PHP 8.5.9' test 0 2>&1 || true)"
check "refusal points a one.com tier at the right control panel" \
    "$(printf '%s' "$msg_dev" | grep -qi 'one.com' && echo ok || echo no)"

# ── 3. The repo agrees with itself ───────────────────────────────────
TARGET="$(bv_php_target "$PROJECT_ROOT" || true)"
check ".php-version exists and declares a version" \
    "$([ -n "$TARGET" ] && echo ok || echo no)"
check ".php-version is a bare MAJOR.MINOR" \
    "$(printf '%s' "$TARGET" | grep -qE '^[0-9]+\.[0-9]+$' && echo ok || echo no)"

COMPOSE="$PROJECT_ROOT/docker-compose.yml"
check "the Grav image is pinned by digest, not a floating tag" \
    "$(grep -qE 'image:\s*lscr\.io/linuxserver/grav@sha256:[0-9a-f]{64}' "$COMPOSE" && echo ok || echo no)"
check "the Grav image is NOT :latest" \
    "$(grep -qE 'image:\s*lscr\.io/linuxserver/grav:latest' "$COMPOSE" && echo no || echo ok)"

# The declared target must be one CI actually exercises, or the guard
# points every tier at a version nothing has tested.
MIGRATIONS_WF="$PROJECT_ROOT/.github/workflows/migrations.yml"
if [ -f "$MIGRATIONS_WF" ]; then
    check "the declared target appears in the CI PHP matrix" \
        "$(grep -E "php-version:\s*\[" "$MIGRATIONS_WF" | grep -q "'$TARGET'" && echo ok || echo no)"
else
    echo "  · migrations workflow absent — CI matrix check skipped"
fi

check "deploy.sh sources the parity lib" \
    "$(grep -q 'lib/php-parity.sh' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"
check "deploy.sh actually calls the check" \
    "$(grep -q 'bv_php_parity_check' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"

echo "---"
echo "php parity unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
