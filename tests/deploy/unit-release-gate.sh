#!/usr/bin/env bash
#
# Unit test for deploy/lib/release-gate.sh — exercises bv_promotion_gate
# against fixture git repos built in a mktemp dir.
#
# Same shape as unit-ssh-auth.sh: source the lib, build hermetic fixtures,
# assert the function returns the right code for each path. No ssh, no
# remote, no credentials.
#
# Coverage (success + every failure path, per CLAUDE.md testing discipline):
#   * dev/test tiers short-circuit to allow, regardless of branch/dirty/tag
#   * prod on clean main at an annotated v<VERSION> tag → allow
#   * prod off main → refuse; ALLOW_PROD_DEPLOY_OFF_MAIN=1 → allow
#   * prod dirty → refuse; ALLOW_PROD_DEPLOY_DIRTY=1 → allow
#   * prod with only a LIGHTWEIGHT tag matching → refuse (annotated required)
#   * prod with no matching tag → refuse
#   * prod where the tag is on an ancestor, not HEAD → refuse, and the
#     tag precondition holds even with BOTH override flags set (it is hard)
#   * staging requires main + clean but NOT a tag (main-promoted staging):
#     - clean main, no matching tag → allow (key difference from prod)
#     - off main → refuse; ALLOW_STAGING_DEPLOY_OFF_MAIN=1 → allow
#     - dirty → refuse; ALLOW_STAGING_DEPLOY_DIRTY=1 → allow

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/release-gate.sh
. "$PROJECT_ROOT/deploy/lib/release-gate.sh"

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

# expect <want_rc> <name> <env> <branch> <dirty> <version> <repo>
# Wrap in env-prefix at the call site to set ALLOW_*_DEPLOY_* overrides.
expect() {
    local want="$1" name="$2" env="$3" branch="$4" dirty="$5" version="$6" repo="$7"
    local got=0
    bv_promotion_gate "$env" "$branch" "$dirty" "$version" "$repo" >/dev/null 2>&1 || got=$?
    if [ "$got" = "$want" ]; then
        check "$name" ok
    else
        check "$name (want rc=$want, got rc=$got)" fail
    fi
}

echo "Unit test: release-gate.sh (bv_promotion_gate)"
echo "---"

STUB_PREFIX="bv-unit-release-gate."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
STUB_DIR="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

git_init() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name Test
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config tag.gpgsign false
}

# ── Fixture A: HEAD carries annotated v1.0.0 AND lightweight v2.0.0 ──
REPO_A="$STUB_DIR/repoA"
git_init "$REPO_A"
echo "seed" > "$REPO_A/file.txt"
git -C "$REPO_A" add -A
git -C "$REPO_A" commit -qm "init"
git -C "$REPO_A" branch -M main
git -C "$REPO_A" tag -a v1.0.0 -m "Release v1.0.0"   # annotated
git -C "$REPO_A" tag v2.0.0                            # lightweight

# ── Fixture B: annotated v1.0.0 on the PARENT, HEAD moved one commit on ──
REPO_B="$STUB_DIR/repoB"
git_init "$REPO_B"
echo "seed" > "$REPO_B/file.txt"
git -C "$REPO_B" add -A
git -C "$REPO_B" commit -qm "init"
git -C "$REPO_B" branch -M main
git -C "$REPO_B" tag -a v1.0.0 -m "Release v1.0.0"
echo "more" >> "$REPO_B/file.txt"
git -C "$REPO_B" add -A
git -C "$REPO_B" commit -qm "second"

# ── non-prod tier always allows ─────────────────────────────
expect 0 "dev tier allows even off-main/dirty/untagged" \
    dev feature/x true 9.9.9 "$REPO_A"
expect 0 "test tier allows even off-main/dirty/untagged" \
    test feature/x true 9.9.9 "$REPO_A"

# ── prod happy path ─────────────────────────────────────────
expect 0 "prod: clean main at annotated v1.0.0 → allow" \
    prod main false 1.0.0 "$REPO_A"

# ── prod branch gate ────────────────────────────────────────
expect 1 "prod: off main → refuse" \
    prod feature/x false 1.0.0 "$REPO_A"
ALLOW_PROD_DEPLOY_OFF_MAIN=1 expect 0 "prod: off main + override → allow" \
    prod feature/x false 1.0.0 "$REPO_A"

# ── prod dirty gate ─────────────────────────────────────────
expect 1 "prod: dirty tree → refuse" \
    prod main true 1.0.0 "$REPO_A"
ALLOW_PROD_DEPLOY_DIRTY=1 expect 0 "prod: dirty + override → allow" \
    prod main true 1.0.0 "$REPO_A"

# ── prod tag precondition (hard) ────────────────────────────
expect 1 "prod: only a lightweight tag matches → refuse (annotated required)" \
    prod main false 2.0.0 "$REPO_A"
expect 1 "prod: no tag matches VERSION → refuse" \
    prod main false 3.0.0 "$REPO_A"
expect 1 "prod: tag is on ancestor, not HEAD → refuse" \
    prod main false 1.0.0 "$REPO_B"
# Hard precondition: even both override flags cannot bypass the tag check.
ALLOW_PROD_DEPLOY_OFF_MAIN=1 ALLOW_PROD_DEPLOY_DIRTY=1 \
    expect 1 "prod: tag precondition holds even with both overrides set" \
    prod main false 1.0.0 "$REPO_B"

# ── staging: main + clean, but NO tag requirement (main-promoted) ───
expect 0 "staging: clean main, NO matching tag → allow (no tag needed)" \
    staging main false 3.0.0 "$REPO_A"
expect 0 "staging: clean main at a tagged commit → allow" \
    staging main false 1.0.0 "$REPO_A"
expect 1 "staging: off main → refuse" \
    staging feature/x false 1.0.0 "$REPO_A"
ALLOW_STAGING_DEPLOY_OFF_MAIN=1 expect 0 "staging: off main + override → allow" \
    staging feature/x false 1.0.0 "$REPO_A"
expect 1 "staging: dirty tree → refuse" \
    staging main true 1.0.0 "$REPO_A"
ALLOW_STAGING_DEPLOY_DIRTY=1 expect 0 "staging: dirty + override → allow" \
    staging main true 1.0.0 "$REPO_A"
# The prod-tier override must NOT unlock staging (distinct env vars).
ALLOW_PROD_DEPLOY_OFF_MAIN=1 expect 1 "staging: prod's override does not apply to staging" \
    staging feature/x false 1.0.0 "$REPO_A"

echo "---"
echo "release-gate: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
