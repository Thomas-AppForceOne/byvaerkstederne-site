#!/usr/bin/env bash
#
# Unit test for deploy/lib/grav-parity.sh — the second version axis.
#
# THE FAILURE THIS PINS
# ---------------------
# The Grav core is not in this repo: locally it comes from the container
# image, on a tier from deploy/grav-admin-v*.zip. Nothing compared them.
# A routine `docker pull latest` — taken during work whose whole purpose
# was removing environment divergence — swapped the local CMS from 1.7.49.5
# to 2.0.20, a major version ahead of every tier, in silence. The site
# still answered 200. Two tests then failed for reasons that looked like
# PHP and were not.
#
# A quieter instance had been there all along: container 1.7.49.5 vs
# deployed 1.7.52. Same class, no symptoms, nobody looking.
#
# PHP parity alone waves both through — it compares only the interpreter.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/grav-parity.sh
. "$PROJECT_ROOT/deploy/lib/grav-parity.sh"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}

echo "Unit test: Grav version parity"
echo "---"

# ── Normalisation ────────────────────────────────────────────────────
check "a plain version reduces to major.minor" \
    "$([ "$(bv_grav_major_minor '1.7.52')" = "1.7" ] && echo ok || echo no)"
check "a four-part version reduces too" \
    "$([ "$(bv_grav_major_minor '1.7.49.5')" = "1.7" ] && echo ok || echo no)"
check "a defines.php line is parsed" \
    "$([ "$(bv_grav_major_minor "define('GRAV_VERSION', '2.0.20');")" = "2.0" ] && echo ok || echo no)"
check "empty input yields empty" \
    "$([ -z "$(bv_grav_major_minor '')" ] && echo ok || echo no)"

# ── The check ────────────────────────────────────────────────────────
run() { bv_grav_parity_check "$1" "$2" "$3" "${4:-0}" >/dev/null 2>&1; }

check "same minor passes" \
    "$(run '1.7.52' "define('GRAV_VERSION', '1.7.52');" dev && echo ok || echo no)"
check "patch drift inside a minor is tolerated (1.7.49.5 vs 1.7.52)" \
    "$(run '1.7.52' "define('GRAV_VERSION', '1.7.49.5');" local && echo ok || echo no)"
check "a MAJOR jump is REFUSED (the 2.0.20 accident)" \
    "$(run '1.7.52' "define('GRAV_VERSION', '2.0.20');" local && echo no || echo ok)"
check "a minor jump is refused too" \
    "$(run '1.7.52' "define('GRAV_VERSION', '1.8.0');" test && echo no || echo ok)"
check "ALLOW_GRAV_MISMATCH=1 overrides" \
    "$(run '1.7.52' "define('GRAV_VERSION', '2.0.20');" prod 1 && echo ok || echo no)"
check "an unreadable remote version soft-skips rather than blocking" \
    "$(run '1.7.52' '' prod && echo ok || echo no)"
check "no payload found soft-skips" \
    "$(run '' "define('GRAV_VERSION', '2.0.20');" prod && echo ok || echo no)"

msg="$(bv_grav_parity_check '1.7.52' "define('GRAV_VERSION', '2.0.20');" prod 0 2>&1 || true)"
check "the refusal names both versions" \
    "$(printf '%s' "$msg" | grep -q '2\.0' && printf '%s' "$msg" | grep -q '1\.7' && echo ok || echo no)"
check "the refusal calls it a migration, not a detail" \
    "$(printf '%s' "$msg" | grep -qi 'migration' && echo ok || echo no)"
check "the refusal names the override" \
    "$(printf '%s' "$msg" | grep -q 'ALLOW_GRAV_MISMATCH' && echo ok || echo no)"

# ── The repo agrees with itself ──────────────────────────────────────
TARGET="$(bv_grav_target "$PROJECT_ROOT" || true)"
check "a deploy payload exists and its version parses" \
    "$([ -n "$TARGET" ] && printf '%s' "$TARGET" | grep -qE '^[0-9]+\.[0-9.]+$' && echo ok || echo no)"
check "deploy.sh sources the Grav parity lib" \
    "$(grep -q 'lib/grav-parity.sh' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"
check "deploy.sh actually calls the check" \
    "$(grep -q 'bv_grav_parity_check' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"
check "grav-up.sh warns about drift where it happens" \
    "$(grep -q 'grav-parity.sh' "$PROJECT_ROOT/scripts/grav-up.sh" && echo ok || echo no)"

echo "---"
echo "grav parity unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
