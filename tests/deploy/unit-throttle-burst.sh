#!/usr/bin/env bash
#
# Unit test for scripts/registration-throttle-burst.sh — the instrument behind
# `make test-registration-throttle`.
#
# THE FAILURE THIS PINS
# ---------------------
# The burst signs up with a fixed password. That password has to clear BOTH of
# this repo's password policies, or registration is refused at field validation
# and the throttle is never consulted:
#
#   Form.php:913   $this->data->validate();          <- throws on a bad field
#   Form.php:946   fireEvent('onFormValidationProcessed')  <- where the throttle hooks
#
# Same try-block, so a field failure means line 946 is never reached, the
# throttle's counter never moves, and the burst reports "THROTTLE INACTIVE" —
# on every tier, whatever the tier is actually set to. A confident, meaningless
# green.
#
# It happened twice, for two different reasons:
#
#   1. The password was `Abcdefg1`: 8 characters with an upper and a digit, a
#      minimal fit for the policy in force when the script was written
#      (2026-06-17). Commit 1aa5e0d moved the policy to `.{12,}` and this line
#      did not move with it.
#   2. The obvious repair — a long passphrase ending in "adgangskode" — cleared
#      the regex at 34 characters and was then refused by the guessable-word
#      blocklist, which lists "adgangskode". Same symptom, new cause.
#
# So both policies are asserted here, and the default is asserted to satisfy
# them. That last check is the one that would have caught the original rot.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BURST="$PROJECT_ROOT/scripts/registration-throttle-burst.sh"
SYS="$PROJECT_ROOT/config/www/user/config/system.yaml"
AM="$PROJECT_ROOT/config/www/user/config/plugins/account-manager.yaml"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}

echo "Unit test: registration-throttle burst password policy"
echo "---"

check "the burst script exists" \
    "$([ -f "$BURST" ] && echo ok || echo no)"

# The default the script ships with.
DEFAULT_PW="$(sed -n 's/^PASSWORD="\${THROTTLE_PASSWORD:-\(.*\)}"$/\1/p' "$BURST" | head -1)"
check "a default burst password is declared" \
    "$([ -n "$DEFAULT_PW" ] && echo ok || echo no)"

# ── The default must satisfy BOTH policies ───────────────────────────
# This is the assertion that fails the moment either policy moves and the
# script does not — instead of the burst quietly reporting INACTIVE forever.
PWD_REGEX="$(sed -n "s/^pwd_regex:[[:space:]]*'\(.*\)'[[:space:]]*$/\1/p" "$SYS" | head -1)"
check "pwd_regex is readable from system.yaml" \
    "$([ -n "$PWD_REGEX" ] && echo ok || echo no)"
check "the default password satisfies pwd_regex" \
    "$(printf '%s' "$DEFAULT_PW" | grep -qE "^${PWD_REGEX}$" && echo ok || echo no)"

BLOCKED=""
while IFS= read -r w; do
    [ -n "$w" ] || continue
    case "$(printf '%s' "$DEFAULT_PW" | tr '[:upper:]' '[:lower:]')" in
        *"$w"*) BLOCKED="$w"; break ;;
    esac
done < <(sed -n '/^  blocklist:/,/^  [a-z_]*:/p' "$AM" | sed -n 's/^[[:space:]]*-[[:space:]]*//p')
check "the default password contains no blocklisted word" \
    "$([ -z "$BLOCKED" ] && echo ok || echo no)"
[ -z "$BLOCKED" ] || echo "      contains: '$BLOCKED'" >&2

# ── Both guards must fire, and say why it matters ────────────────────
# The guards run before any network call, so a tier argument is harmless.
short_out="$(THROTTLE_PASSWORD='kort123' bash "$BURST" dev 1 2>&1 || true)"
check "a too-short password is refused" \
    "$(printf '%s' "$short_out" | grep -q 'does not satisfy' && echo ok || echo no)"
check "the refusal names the policy it failed" \
    "$(printf '%s' "$short_out" | grep -q 'pwd_regex' && echo ok || echo no)"
check "the refusal explains it would report INACTIVE falsely" \
    "$(printf '%s' "$short_out" | grep -q 'THROTTLE INACTIVE' && echo ok || echo no)"

blocked_out="$(THROTTLE_PASSWORD='en-meget-lang-adgangskode-her' bash "$BURST" dev 1 2>&1 || true)"
check "a blocklisted password is refused even when long enough" \
    "$(printf '%s' "$blocked_out" | grep -q 'blocklisted word' && echo ok || echo no)"
check "the blocklist refusal names the offending word" \
    "$(printf '%s' "$blocked_out" | grep -q "adgangskode" && echo ok || echo no)"
check "the blocklist refusal explains the false INACTIVE too" \
    "$(printf '%s' "$blocked_out" | grep -q 'THROTTLE INACTIVE' && echo ok || echo no)"

# ── The script must actually use the variable ────────────────────────
# A hardcoded literal in the POST body would sail past every check above.
check "the POST body uses \$PASSWORD, not a literal" \
    "$(grep -q 'data\[password1\]=\$PASSWORD' "$BURST" && echo ok || echo no)"
# Comment lines stripped: the script's header explains at length which
# password rotted and why, and a check that cannot tell code from the
# explanation of code would forbid documenting the bug.
check "no hardcoded old password remains in the CODE" \
    "$(grep -v '^[[:space:]]*#' "$BURST" | grep -q 'Abcdefg1' && echo no || echo ok)"

echo "---"
echo "throttle burst unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
