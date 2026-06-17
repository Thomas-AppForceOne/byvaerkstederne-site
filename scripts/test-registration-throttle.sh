#!/usr/bin/env bash
# test-registration-throttle.sh — manually exercise the per-IP registration
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
# PREREQUISITE
#   The throttle plugin ships DISABLED. Enable it on the target tier (or
#   locally) with a low enough max_count first, or every attempt just passes
#   and nothing is throttled.
#
# USAGE
#   scripts/test-registration-throttle.sh <tier|url> [attempts] [username]
#     tier|url : dev | test | staging | prod  OR a full base URL
#                (e.g. http://localhost:8080 for a local `make start`).
#     attempts : number of submissions (default 12).
#     username : fixed signup username, ^[a-z0-9_-]{3,16}$ (default throttletest).
#   Env:
#     THROTTLE_MATCH : substring that marks the throttle message
#                      (default "For mange medlemskaber").
#     PROD_OK=1      : required to target prod (it hits the live form).
#
# EXAMPLE
#   scripts/test-registration-throttle.sh dev 12
#   scripts/test-registration-throttle.sh http://localhost:8080 8

set -euo pipefail

ARG_URL="${1:-}"
ATTEMPTS="${2:-12}"
USERNAME="${3:-throttletest}"
THROTTLE_MATCH="${THROTTLE_MATCH:-For mange medlemskaber}"

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
        --data-urlencode "data[password1]=Abcdefg1" \
        --data-urlencode "data[password2]=Abcdefg1" \
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
    echo "  ✓ throttle engaged at attempt #$first_throttled (configured limit ≈ $((first_throttled - 1)) per window)"
else
    echo "  ⚠ no throttling observed — is the plugin enabled with a low enough max_count?"
fi
echo "─────────────────────────────────────"
echo "  Cleanup the one account this created:"
case "$ARG_URL" in
    dev|test|staging|prod) echo "    make delete-user tier=$ARG_URL user=$USERNAME" ;;
    *) echo "    (local) remove user/accounts/$USERNAME.yaml in your Grav container, or use the admin UI" ;;
esac
