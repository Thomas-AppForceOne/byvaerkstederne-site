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
# The refusal must distinguish the two cases it covers, or an operator
# carrying out a deliberate upgrade reads it as "something is broken".
check "the refusal separates unintended drift from an intended upgrade" \
    "$(printf '%s' "$msg" | grep -qi 'UNINTENDED' && printf '%s' "$msg" | grep -qi 'intended upgrade' && echo ok || echo no)"
check "the refusal spells out the upgrade command" \
    "$(printf '%s' "$msg" | grep -q 'ALLOW_GRAV_MISMATCH=1 make deploy tier=' && echo ok || echo no)"
check "the refusal tells you to rehearse on the lower tiers first" \
    "$(printf '%s' "$msg" | grep -qi 'rehearse' && echo ok || echo no)"

# ── The repo agrees with itself ──────────────────────────────────────
TARGET="$(bv_grav_target "$PROJECT_ROOT" || true)"
# Read from deploy.sh's committed GRAV_VERSION, never from the zip: that
# file is a local download cache and is absent in CI.
check "the deployed version is read from committed source, not a cached zip" \
    "$([ -n "$TARGET" ] && printf '%s' "$TARGET" | grep -qE '^[0-9]+\.[0-9.]+$' && echo ok || echo no)"
# Scoped to bv_grav_target's BODY. The header explains at length why the zip
# is not the source, and the refusal text rightly tells an operator to replace
# it — neither is the function reading it.
check "bv_grav_target does not read the untracked payload zip" \
    "$(awk '/^bv_grav_target\(\)/,/^}/' "$PROJECT_ROOT/deploy/lib/grav-parity.sh" \
       | grep -q 'grav-admin' && echo no || echo ok)"
check "bv_grav_target reads deploy.sh's committed GRAV_VERSION" \
    "$(awk '/^bv_grav_target\(\)/,/^}/' "$PROJECT_ROOT/deploy/lib/grav-parity.sh" \
       | grep -q 'GRAV_VERSION' && echo ok || echo no)"
check "deploy.sh sources the Grav parity lib" \
    "$(grep -q 'lib/grav-parity.sh' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"
check "deploy.sh actually calls the check" \
    "$(grep -q 'bv_grav_parity_check' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"
check "grav-up.sh warns about drift where it happens" \
    "$(grep -q 'grav-parity.sh' "$PROJECT_ROOT/scripts/grav-up.sh" && echo ok || echo no)"

# ── The container's Grav is the deployed Grav ────────────────────────
#
# The local core used to come from a prebuilt image that shipped its own
# Grav — 1.7.49.5 against 1.7.52 on the tiers, and briefly 2.0.20 after a
# routine pull. It is now built from GRAV_VERSION, the same value deploy.sh
# unpacks, so the two cannot drift. The Dockerfile default is a fallback for
# a direct `docker build`; grav-up.sh reads the real value from deploy.sh.
DOCKERFILE="$PROJECT_ROOT/Dockerfile"
DFV="$(sed -n 's/^ARG GRAV_VERSION=\([0-9.]*\).*/\1/p' "$DOCKERFILE" | head -1)"

check "the Dockerfile declares a Grav version" \
    "$([ -n "$DFV" ] && echo ok || echo no)"
check "its default matches deploy.sh's GRAV_VERSION" \
    "$([ "$DFV" = "$TARGET" ] && echo ok || echo no)"
check "the build fetches that exact version" \
    "$(grep -q 'grav-admin-v\${GRAV_VERSION}\.zip' "$DOCKERFILE" && echo ok || echo no)"
check "the build verifies what it unpacked" \
    "$(grep -q "GRAV_VERSION', '\${GRAV_VERSION}'" "$DOCKERFILE" && echo ok || echo no)"
check "grav-up.sh reads GRAV_VERSION from deploy.sh, not a second copy" \
    "$(grep -q 'GRAV_VERSION=.*deploy/deploy.sh' "$PROJECT_ROOT/scripts/grav-up.sh" && echo ok || echo no)"

echo "---"
echo "grav parity unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
