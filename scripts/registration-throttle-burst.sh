#!/usr/bin/env bash
# registration-throttle-burst.sh — manually exercise the per-IP registration
# throttle (the registration-throttle plugin).
#
# WHAT IT DOES
#   Submits the membership registration form repeatedly from THIS machine (one
#   IP), each time with a fresh CSRF nonce in a coherent session, and reports
#   for each attempt whether it passed or was THROTTLED. Use it to confirm the
#   throttle engages at the configured limit.
#
#   It uses ONE fixed username, so only the FIRST non-throttled submission
#   creates a (disabled) account — every later attempt hits the duplicate-user
#   guard and creates nothing, while the throttle still counts each attempt.
#   The recipient is *@example.invalid, a reserved TLD that never delivers, so
#   no real inbox is mailed. Clean up the one account afterwards:
#       make delete-user tier=<tier> user=<username>
#
# READ-ONLY — changes NO config. It reports the throttle's CURRENT state on the
# target: throttle on → THROTTLE ACTIVE (attempts blocked); throttle off →
# THROTTLE INACTIVE (all pass). Use it both ways — to confirm the trip-wire
# fires where it should be on, and that it's off where it should be off.
#
# USAGE
#   scripts/registration-throttle-burst.sh <tier|url> [attempts] [username]
#     tier|url : dev | test | staging | prod  OR a full base URL
#                (e.g. http://localhost:8080 for a local `make start`).
#     attempts : number of submissions (default 6 — one past a 5/window limit).
#     username : fixed signup username, ^[a-z0-9_-]{3,16}$ (default throttletest).
#   Env:
#     THROTTLE_MATCH : substring that marks the throttle message
#                      (default "For mange medlemskaber").
#     PROD_OK=1      : required to target prod (it hits the live form).
#
# EXAMPLE
#   scripts/registration-throttle-burst.sh dev 12
#   scripts/registration-throttle-burst.sh http://localhost:8080 8

set -euo pipefail

ARG_URL="${1:-}"
ATTEMPTS="${2:-6}"
USERNAME="${3:-throttletest}"
THROTTLE_MATCH="${THROTTLE_MATCH:-For mange medlemskaber}"

# The signup password, and the check that keeps it honest.
#
# WHY THE CHECK EXISTS
# --------------------
# This was `Abcdefg1` — 8 characters with an upper and a digit, a minimal fit
# for the policy of the day (>=8, >=1 upper, >=1 lower, >=1 digit) when this
# script was written on 2026-06-17. Commit 1aa5e0d then moved the policy to
# `.{12,}` — 12 characters, no character-class rules — and this line was not
# moved with it.
#
# From then on every submission failed FIELD validation, and the throttle
# never saw it: the plugin hooks onFormValidationProcessed, which Form.php
# fires at line 946, while $this->data->validate() throws at line 913. Same
# try-block, so line 946 is never reached. The counter stayed at zero and the
# burst reported "THROTTLE INACTIVE" on every tier, whatever the setting.
#
# So the password is no longer allowed to drift silently. It is validated
# against the repo's own pwd_regex, and a mismatch aborts loudly instead of
# producing a confident, meaningless result.
PASSWORD="${THROTTLE_PASSWORD:-tretten-graeskar-paa-hylden}"

_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
_sysyaml="$_repo_root/config/www/user/config/system.yaml"
_amyaml="$_repo_root/config/www/user/config/plugins/account-manager.yaml"

# There are TWO password policies, and a password has to clear both. Checking
# only the regex is how the second one bit us: `en-...-adgangskode` is 34
# characters and sails through pwd_regex, then the guessable-word blocklist
# rejects it for containing "adgangskode" — and the burst reported INACTIVE
# again, for a completely different reason than the first time.
if [ -f "$_amyaml" ]; then
    _lower="$(printf '%s' "$PASSWORD" | tr '[:upper:]' '[:lower:]')"
    _hit="$(sed -n '/^  blocklist:/,/^  [a-z_]*:/p' "$_amyaml" \
            | sed -n 's/^[[:space:]]*-[[:space:]]*//p' \
            | while IFS= read -r w; do
                  [ -n "$w" ] || continue
                  case "$_lower" in *"$w"*) printf '%s' "$w"; break ;; esac
              done)"
    if [ -n "$_hit" ]; then
        echo "❌  The burst password contains a blocklisted word: '$_hit'" >&2
        echo "    (account-manager.yaml blocklist — the guessable-word policy)" >&2
        echo "" >&2
        echo "    Registration would be refused before the throttle is reached, so the" >&2
        echo "    burst would report THROTTLE INACTIVE whatever the tier is set to." >&2
        echo "    Pick a password with no blocklisted substring, or pass THROTTLE_PASSWORD=..." >&2
        exit 1
    fi
fi

if [ -f "$_sysyaml" ]; then
    _pwd_regex="$(sed -n "s/^pwd_regex:[[:space:]]*'\(.*\)'[[:space:]]*$/\1/p" "$_sysyaml" | head -1)"
    if [ -n "$_pwd_regex" ]; then
        if ! printf '%s' "$PASSWORD" | grep -qE "^${_pwd_regex}$"; then
            echo "❌  The burst password does not satisfy this repo's password policy." >&2
            echo "    policy (system.yaml pwd_regex): ${_pwd_regex}" >&2
            echo "    password length: $(printf '%s' "$PASSWORD" | wc -c | tr -d ' ')" >&2
            echo "" >&2
            echo "    Every submission would fail field validation, and the throttle would" >&2
            echo "    never be reached — the burst would report THROTTLE INACTIVE on every" >&2
            echo "    tier regardless of configuration. Fix PASSWORD (or pass" >&2
            echo "    THROTTLE_PASSWORD=...) so it matches the policy." >&2
            exit 1
        fi
    fi
fi

usage() { sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

if [ -z "$ARG_URL" ] || [ "$ARG_URL" = "--help" ] || [ "$ARG_URL" = "-h" ]; then
    usage >&2; exit 1
fi

# Resolve a base URL from a tier name, or take a full URL as-is.
case "$ARG_URL" in
    http://*|https://*) BASE="${ARG_URL%/}" ;;
    dev)     BASE="https://dev.hackersbychoice.dk" ;;
    test)    BASE="https://test.hackersbychoice.dk" ;;
    staging) BASE="https://staging.hackersbychoice.dk" ;;
    prod)
        if [ "${PROD_OK:-0}" != "1" ]; then
            echo "❌  Refusing to hit prod's live registration form. Re-run with PROD_OK=1 if you mean it." >&2
            exit 1
        fi
        BASE="https://www.byvaerkstederne.dk" ;;
    *)
        echo "❌  First arg must be dev|test|staging|prod or a full http(s) URL (got '$ARG_URL')." >&2
        exit 1 ;;
esac

case "$ATTEMPTS" in ''|*[!0-9]*) echo "❌  attempts must be a whole number (got '$ATTEMPTS')." >&2; exit 1 ;; esac
case "$USERNAME" in
    *[!a-z0-9_-]*|'') echo "❌  username must match ^[a-z0-9_-]{3,16}\$ (got '$USERNAME')." >&2; exit 1 ;;
esac
if [ "${#USERNAME}" -lt 3 ] || [ "${#USERNAME}" -gt 16 ]; then
    echo "❌  username must be 3–16 chars (got '${USERNAME}')." >&2; exit 1
fi

EMAIL="${USERNAME}@example.invalid"
FORM_URL="$BASE/opret-medlemskab"
JAR="$(mktemp)"; BODY="$(mktemp)"
cleanup() { rm -f "$JAR" "$BODY"; }
trap cleanup EXIT

echo "→ throttle test against $FORM_URL"
echo "  attempts: $ATTEMPTS   username: $USERNAME   match: \"$THROTTLE_MATCH\""
echo ""

first_throttled=""
passed=0
throttled=0

for i in $(seq 1 "$ATTEMPTS"); do
    # Fresh form load in the SAME session so the nonce is valid for the POST.
    nonce="$(curl -fsS -c "$JAR" -b "$JAR" "$FORM_URL" 2>/dev/null \
        | grep -oE 'name="form-nonce"[^>]*value="[^"]*"' | head -1 \
        | sed -E 's/.*value="([^"]*)".*/\1/' || true)"
    if [ -z "$nonce" ]; then
        printf '  attempt %2d: ✗ could not read form-nonce (form present? signup enabled?)\n' "$i"
        continue
    fi
    ufid="$(curl -fsS -c "$JAR" -b "$JAR" "$FORM_URL" 2>/dev/null \
        | grep -oE 'name="__unique_form_id__"[^>]*value="[^"]*"' | head -1 \
        | sed -E 's/.*value="([^"]*)".*/\1/' || true)"

    code="$(curl -s -b "$JAR" -c "$JAR" -o "$BODY" -w '%{http_code}' \
        --data-urlencode "__form-name__=registration" \
        --data-urlencode "form-nonce=$nonce" \
        ${ufid:+--data-urlencode "__unique_form_id__=$ufid"} \
        --data-urlencode "data[fullname]=Throttle Test" \
        --data-urlencode "data[email]=$EMAIL" \
        --data-urlencode "data[username]=$USERNAME" \
        --data-urlencode "data[password1]=$PASSWORD" \
        --data-urlencode "data[password2]=$PASSWORD" \
        --data-urlencode "data[website]=" \
        "$FORM_URL" || echo "000")"

    if grep -qiF "$THROTTLE_MATCH" "$BODY"; then
        throttled=$((throttled + 1))
        [ -z "$first_throttled" ] && first_throttled="$i"
        printf '  attempt %2d: 🛑 THROTTLED (http %s)\n' "$i" "$code"
    elif [ "$code" = 302 ] || [ "$code" = 303 ]; then
        passed=$((passed + 1))
        printf '  attempt %2d: ✓ passed — processed/redirect (http %s)\n' "$i" "$code"
    else
        passed=$((passed + 1))
        printf '  attempt %2d: ✓ passed — re-rendered (http %s; likely duplicate or other)\n' "$i" "$code"
    fi
done

echo ""
echo "─────────────────────────────────────"
echo "  passed: $passed    throttled: $throttled"
if [ -n "$first_throttled" ]; then
    echo "  → THROTTLE ACTIVE on this target — first blocked at attempt #$first_throttled (limit ≈ $((first_throttled - 1))/window)"
else
    echo "  → THROTTLE INACTIVE on this target — no throttling across $ATTEMPTS attempts"
fi
echo "  (read-only: changes no config; reports the target's CURRENT state)"
echo "─────────────────────────────────────"
echo "  Cleanup the one account this created:"
case "$ARG_URL" in
    dev|test|staging|prod) echo "    make delete-user tier=$ARG_URL user=$USERNAME" ;;
    *) echo "    (local) remove user/accounts/$USERNAME.yaml in your Grav container, or use the admin UI" ;;
esac
