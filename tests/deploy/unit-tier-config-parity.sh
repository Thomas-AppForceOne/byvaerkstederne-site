#!/usr/bin/env bash
#
# Tier config parity — divergence must be DECLARED, not discovered.
#
# THE FAILURE THIS PINS
# ---------------------
# Grav resolves per-tier config from user/env/<canonical-host>/. dev, test
# and staging each pinned custom_base_url and session.path in a system.yaml
# there. Production had no system.yaml at all — and nobody had decided that;
# the per-tier login.yaml still carried a NOTE asking someone to CONFIRM
# prod's canonical host before relying on it for activation mail.
#
# That is the shape of every "works on dev, breaks on prod" bug in this
# repo's history: prod differs from the tiers you test on, in ways nobody
# wrote down. A difference someone chose and documented is fine. A
# difference that simply exists is a latent incident.
#
# So: every tracked file under a tier's env config directory must exist for
# every tier, unless this file declares why not. Adding a per-tier override
# now forces a one-line decision instead of silent drift.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_ROOT="$PROJECT_ROOT/config/www/user/env"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}

echo "Tier config parity: per-tier divergence must be declared"
echo "---"

# The four tiers that serve the site. Non-canonical hosts (the apex, the
# one.com account root, the flags-off fixture) are deliberately minimal and
# are not part of this comparison.
TIERS="dev.hackersbychoice.dk test.hackersbychoice.dk staging.hackersbychoice.dk www.byvaerkstederne.dk"

# ── Declared divergence ──────────────────────────────────────────────
#
# Some config is deliberately tier-specific. Declare it here as
#   <relative-path>|<owning-host>|<why only that tier>
# Every OTHER tier is then allowed to lack it. A path missing from a tier
# without an entry here fails the test — which is the point: adding a
# per-tier override becomes a one-line decision instead of silent drift.
ONLY_ON="
site.yaml|dev.hackersbychoice.dk|dev points author.email at the operator test mailbox, so a tester following the contact address in a mail does not write to the association for real. The other tiers use the committed production address.
features.yaml.example|staging.hackersbychoice.dk|staging keeps a worked example of the flag profile beside the live one as operator documentation; a second copy on every tier would just be four things to keep in sync.
"

owner_of() {
    printf '%s\n' "$ONLY_ON" | grep "^$1|" | head -1 | cut -d'|' -f2
}
reason_for() {
    printf '%s\n' "$ONLY_ON" | grep "^$1|" | head -1 | cut -d'|' -f3-
}

# Union of every tracked config path across the four tiers.
ALL_PATHS="$(
    for t in $TIERS; do
        git -C "$PROJECT_ROOT" ls-files "config/www/user/env/$t/config/" \
            | sed "s|config/www/user/env/$t/config/||"
    done | sort -u
)"

[ -n "$ALL_PATHS" ] || { echo "  ✗ no tracked tier config found — is this a git checkout?" >&2; exit 1; }

undeclared=0
for t in $TIERS; do
    for p in $ALL_PATHS; do
        if [ -f "$ENV_ROOT/$t/config/$p" ]; then
            continue
        fi
        owner="$(owner_of "$p")"
        if [ -n "$owner" ] && [ "$owner" != "$t" ]; then
            echo "  · $t lacks $p — declared ${owner}-only: $(reason_for "$p")"
        else
            echo "  ✗ $t lacks $p with NO declared reason" >&2
            undeclared=$((undeclared + 1))
        fi
    done
done
check "every tier's missing config is declared" \
    "$([ "$undeclared" -eq 0 ] && echo ok || echo no)"

# ── The specific pins that must not silently disappear ───────────────
#
# Every serving tier resolves its own absolute base URL. Losing this on one
# tier is invisible in a browser (Grav derives it from the request) and fatal
# in a CLI context, where there is no request — which is where the scheduler
# and the mail jobs run.
missing_base=0
for t in $TIERS; do
    f="$ENV_ROOT/$t/config/system.yaml"
    if [ ! -f "$f" ] || ! grep -q "^custom_base_url:" "$f"; then
        echo "  ✗ $t does not pin custom_base_url" >&2
        missing_base=$((missing_base + 1))
    fi
done
check "every serving tier pins custom_base_url" \
    "$([ "$missing_base" -eq 0 ] && echo ok || echo no)"

# A tier's pinned base URL must be its own host — a copy/paste from another
# tier would send activation links to the wrong site.
wrong_host=0
for t in $TIERS; do
    f="$ENV_ROOT/$t/config/system.yaml"
    [ -f "$f" ] || continue
    if ! grep -q "custom_base_url:.*$t" "$f"; then
        echo "  ✗ $t pins a base URL that is not its own host" >&2
        wrong_host=$((wrong_host + 1))
    fi
done
check "each tier's base URL names its own host" \
    "$([ "$wrong_host" -eq 0 ] && echo ok || echo no)"

# login.yaml's site_host builds the activation/reset links. It must agree
# with custom_base_url or mail points somewhere the browser does not.
mismatch=0
for t in $TIERS; do
    sys="$ENV_ROOT/$t/config/system.yaml"
    lg="$ENV_ROOT/$t/config/plugins/login.yaml"
    [ -f "$sys" ] && [ -f "$lg" ] || continue
    a="$(grep '^custom_base_url:' "$sys" | sed "s/.*'\(.*\)'.*/\1/")"
    b="$(grep '^site_host:' "$lg" | sed "s/.*'\(.*\)'.*/\1/")"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
        echo "  ✗ $t: custom_base_url ($a) != login site_host ($b)" >&2
        mismatch=$((mismatch + 1))
    fi
done
check "custom_base_url and login site_host agree per tier" \
    "$([ "$mismatch" -eq 0 ] && echo ok || echo no)"

echo "---"
echo "tier config parity: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
