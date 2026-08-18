#!/usr/bin/env bash
#
# Unit test for the mailer gate in deploy/promote-to-staging.sh.
#
# WHAT IT PROTECTS
# ----------------
# promote-to-staging copies prod member data to staging UNANONYMISED
# (ADR-002). Staging's mailer is meant to be a Mailtrap sandbox, which
# accepts the send and captures it. email.yaml is live state under
# <tier>data/, outside the deploy payload, so a delivering transport put
# there once survives every deploy and every promote — and the promote is
# what turns fixture rows into real member addresses. The gate stands
# between those two facts.
#
# Runs entirely in local mode (PROMOTE_LOCAL_TIER_DIR) against a temp
# tier tree: no network, no real tier, no credentials. The gate fires at
# step 1, so the refusal cases exit before anything else is touched; the
# pass cases are asserted on the gate's own output rather than on the
# script's overall exit, since a minimal fixture legitimately fails later
# for reasons that are not this test's business.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROMOTE_SH="$PROJECT_ROOT/deploy/promote-to-staging.sh"

PASS=0
FAIL=0

check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then
        echo "  ✓ $name"; PASS=$((PASS+1))
    else
        echo "  ✗ $name" >&2; FAIL=$((FAIL+1))
    fi
}

echo "Unit test: promote-to-staging mailer gate (local mode, no network)"
echo "---"

STUB_PREFIX="bv-unit-promote-mailer."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

MAIL_REL="user/env/staging.hackersbychoice.dk/config/plugins/email.yaml"

# Build a tier tree whose live mailer is $1 ("" = no email.yaml at all).
# Mirrors the real layout: stagingdata/v0 with `current` pointing at it.
make_tier() {
    local server="$1" dir
    dir="$SB/tier-$(printf '%s' "${server:-none}" | tr -c 'a-zA-Z0-9' '_')"
    rm -rf "$dir"
    mkdir -p "$dir/stagingdata/v0/user/config"
    ln -sfn v0 "$dir/stagingdata/current"
    if [ -n "$server" ]; then
        mkdir -p "$dir/stagingdata/v0/$(dirname "$MAIL_REL")"
        cat > "$dir/stagingdata/v0/$MAIL_REL" <<EOF
mailer:
  engine: smtp
  smtp:
    server: '$server'
    port: 587
    encryption: tls
    user: 'someone'
    password: 'secret'
EOF
    fi
    printf '%s' "$dir"
}

# Run the promote in local mode; capture output and exit code.
run_promote() {
    local dir="$1"; shift
    set +e
    PROMOTE_LOCAL_TIER_DIR="$dir" "$PROMOTE_SH" --yes "$@" >"$SB/out.log" 2>&1
    RC=$?
    set -e
}

REFUSAL='Refusing to promote: staging delivers real email'

# ── 1. No mailer provisioned → safe, gate lets it through ────────────
run_promote "$(make_tier '')"
check "no mailer: gate does not refuse" \
    "$(grep -q "$REFUSAL" "$SB/out.log" && echo no || echo ok)"
check "no mailer: says nothing can be delivered" \
    "$(grep -q 'no SMTP transport provisioned' "$SB/out.log" && echo ok || echo no)"

# ── 2. Mailtrap sandbox → safe, gate lets it through ─────────────────
run_promote "$(make_tier 'sandbox.smtp.mailtrap.io')"
check "mailtrap: gate does not refuse" \
    "$(grep -q "$REFUSAL" "$SB/out.log" && echo no || echo ok)"
check "mailtrap: names it as captured, not delivered" \
    "$(grep -q 'captured, not delivered' "$SB/out.log" && echo ok || echo no)"

# Case must not matter — a host is a host.
run_promote "$(make_tier 'SANDBOX.SMTP.MAILTRAP.IO')"
check "mailtrap uppercase: still recognised as a sandbox" \
    "$(grep -q "$REFUSAL" "$SB/out.log" && echo no || echo ok)"

# ── 3. Delivering transport → REFUSED ────────────────────────────────
run_promote "$(make_tier 'send.one.com')"
check "delivering transport: exits non-zero" \
    "$([ "$RC" -ne 0 ] && echo ok || echo no)"
check "delivering transport: refusal names the server" \
    "$(grep -q "staging mailer server: send.one.com" "$SB/out.log" && echo ok || echo no)"
check "delivering transport: refusal cites the unanonymised-data reason" \
    "$(grep -q 'UNANONYMISED' "$SB/out.log" && echo ok || echo no)"
check "delivering transport: refusal points at push-email.sh" \
    "$(grep -q 'push-email.sh staging' "$SB/out.log" && echo ok || echo no)"
check "delivering transport: refusal names the override" \
    "$(grep -q -- '--i-mean-it' "$SB/out.log" && echo ok || echo no)"
check "delivering transport: refused BEFORE any backup was taken" \
    "$(grep -q 'Step 2/11' "$SB/out.log" && echo no || echo ok)"

# A second delivering host, to prove the check is not a one-host denylist.
run_promote "$(make_tier 'mail.byvaerkstederne.dk')"
check "a different delivering host is refused too" \
    "$([ "$RC" -ne 0 ] && grep -q "$REFUSAL" "$SB/out.log" && echo ok || echo no)"

# ── 4. Delivering transport + --i-mean-it → allowed, loudly ──────────
run_promote "$(make_tier 'send.one.com')" --i-mean-it
check "override: gate does not refuse" \
    "$(grep -q "$REFUSAL" "$SB/out.log" && echo no || echo ok)"
check "override: warns that real addresses land on a delivering tier" \
    "$(grep -q 'DELIVERS to real inboxes' "$SB/out.log" && echo ok || echo no)"
check "override: records that --i-mean-it was the reason" \
    "$(grep -q 'Proceeding because --i-mean-it' "$SB/out.log" && echo ok || echo no)"

# ── Summary ──────────────────────────────────────────────────────────
echo "---"
echo "promote mailer gate unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
