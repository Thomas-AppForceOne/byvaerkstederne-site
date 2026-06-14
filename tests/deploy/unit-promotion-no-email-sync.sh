#!/usr/bin/env bash
#
# WI-1 promotion no-sync invariant guard.
#
# email.yaml is tier-pinned: it carries per-tier SMTP credentials and MUST
# NEVER be synced across tiers. It shares user/env/<host>/config/ with
# features.yaml, which the promotion scripts deliberately COPY between tiers;
# email.yaml (like security.yaml) must not be copied. The promotion scripts'
# sync allow-lists must never widen to env/<host>/config/*.yaml — only
# features.yaml in that directory is promotable.
#
# This guard asserts, for every promotion script that exists in deploy/,
# that:
#   1. it never names email.yaml in a copy/rsync/sync context, and
#   2. it never uses a broadened env/<host>/config/*.yaml glob.
#
# The promotion scripts (promote-to-staging.sh, promote-to-prod.sh) are not
# yet on develop — they arrive via the promote_to_* specs. When a script is
# absent the corresponding check is reported as "not yet present" (not a
# failure); the invariant activates automatically the moment the script
# lands, so a future allow-list widening that carries SMTP credentials across
# tiers is caught here. (Cross-reference: specifications/promote_to_staging
# and promote_to_prod, which record this invariant in prose.)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_DIR="$REPO_ROOT/deploy"
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

echo "WI-1 promotion no-sync invariant: email.yaml must never cross tiers"
echo "---"

scanned_any=0
for base in promote-to-staging.sh promote-to-prod.sh; do
    script="$DEPLOY_DIR/$base"
    if [ ! -f "$script" ]; then
        echo "  · $base not yet present on this branch — invariant will activate when it lands"
        continue
    fi
    scanned_any=1

    # 1. No non-comment line names email.yaml. (The promotion scripts have no
    #    legitimate reason to mention it at all; the safest invariant is total
    #    absence outside comments.)
    hits="$(grep -nE 'email\.yaml' "$script" 2>/dev/null \
            | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
            || true)"
    if [ -z "$hits" ]; then
        check "$base never references email.yaml in a sync context" ok
    else
        check "$base must not reference email.yaml (would risk cross-tier credential copy)" fail
        printf '%s\n' "$hits" | sed 's/^/      /' >&2
    fi

    # 2. No broadened env/<host>/config/*.yaml glob — only features.yaml is
    #    promotable in that directory.
    glob_hits="$(grep -nE 'env/[^/]+/config/\*\.yaml|env/\$[A-Za-z_]+/config/\*' "$script" 2>/dev/null \
                 | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
                 || true)"
    if [ -z "$glob_hits" ]; then
        check "$base uses no broadened env/<host>/config/*.yaml glob" ok
    else
        check "$base must not glob env/<host>/config/*.yaml (only features.yaml is promotable)" fail
        printf '%s\n' "$glob_hits" | sed 's/^/      /' >&2
    fi
done

if [ "$scanned_any" -eq 0 ]; then
    echo ""
    echo "  No promotion script present yet — invariant documented and armed."
fi

echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"

[ "$FAIL" -eq 0 ]
