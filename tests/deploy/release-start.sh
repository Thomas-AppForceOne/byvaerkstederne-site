#!/usr/bin/env bash
#
# Shell-level probe for deploy/release-start.sh.
#
# Local mktemp git fixtures, SKIP_REMOTE_CHECK=1 throughout (no origin),
# BV_RELEASE_REPO points the script at each fixture.
#
# Coverage (success + every refusal, per CLAUDE.md testing discipline):
#   Success:
#     * grav    → release/v<X> off develop, config/www/VERSION bumped, committed
#     * landing → release/landing-v<X> off develop, apex/VERSION bumped
#     * pending back-merge + ALLOW_PENDING_BACKMERGE=1 → proceeds
#   Refusal:
#     * main ahead of develop (back-merge pending) → refuse
#     * dirty working tree → refuse
#     * release tag already exists → refuse
#     * VERSION already at requested value → refuse
#     * invalid semver → refuse
#     * unknown component → refuse

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RS_SH="$PROJECT_ROOT/deploy/release-start.sh"

PASS=0; FAIL=0
check() { [ "$2" = ok ] && { echo "  ✓ $1"; PASS=$((PASS+1)); } || { echo "  ✗ $1" >&2; FAIL=$((FAIL+1)); }; }

echo "Probe: release-start.sh"
echo "---"

STUB_PREFIX="bv-release-start."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 -exec rm -rf {} + 2>/dev/null || true
STUB_DIR="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

# Fresh repo: on develop, clean, main == develop (no pending back-merge).
mk_repo() {
    local dir="$1" gravver="$2" landingver="$3"
    rm -rf "$dir"; git init -q "$dir"
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name Test
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config tag.gpgsign false
    mkdir -p "$dir/config/www" "$dir/apex"
    printf '%s\n' "$gravver"    > "$dir/config/www/VERSION"
    printf '%s\n' "$landingver" > "$dir/apex/VERSION"
    git -C "$dir" add -A; git -C "$dir" commit -qm init
    git -C "$dir" branch -M develop
    git -C "$dir" branch main
    git -C "$dir" checkout -q develop
}
# Add a commit to main so it leads develop (simulates a missing back-merge).
main_ahead() {
    git -C "$1" checkout -q main
    echo hotfix > "$1/hotfix.txt"; git -C "$1" add -A; git -C "$1" commit -qm hotfix
    git -C "$1" checkout -q develop
}
run_rs() { local repo="$1"; shift; local rc=0
    BV_RELEASE_REPO="$repo" SKIP_REMOTE_CHECK=1 bash "$RS_SH" "$@" >/dev/null 2>&1 || rc=$?
    return "$rc"; }
br()   { git -C "$1" rev-parse --abbrev-ref HEAD; }
filev(){ tr -d '[:space:]' < "$1"; }
msg()  { git -C "$1" log -1 --format=%s; }

# ── grav success ────────────────────────────────────────────
R="$STUB_DIR/grav"; mk_repo "$R" 1.0.1 0.2.0
if run_rs "$R" 1.2.0 grav; then
    ok=ok
    [ "$(br "$R")" = "release/v1.2.0" ]                 || ok=fail
    [ "$(filev "$R/config/www/VERSION")" = "1.2.0" ]    || ok=fail
    [ "$(msg "$R")" = "chore(release): grav 1.2.0" ]    || ok=fail
    check "grav: release/v1.2.0 off develop, VERSION bumped + committed" "$ok"
else
    check "grav: should succeed on clean develop with no pending back-merge" fail
fi

# ── landing success ─────────────────────────────────────────
R="$STUB_DIR/landing"; mk_repo "$R" 1.0.1 0.2.0
if run_rs "$R" 0.3.0 landing; then
    ok=ok
    [ "$(br "$R")" = "release/landing-v0.3.0" ]      || ok=fail
    [ "$(filev "$R/apex/VERSION")" = "0.3.0" ]       || ok=fail
    [ "$(filev "$R/config/www/VERSION")" = "1.0.1" ] || ok=fail   # grav file untouched
    check "landing: release/landing-v0.3.0 off develop, apex/VERSION bumped" "$ok"
else
    check "landing: should succeed" fail
fi

# ── refuse: pending back-merge; allow with override ─────────
R="$STUB_DIR/pending"; mk_repo "$R" 1.0.1 0.2.0; main_ahead "$R"
if run_rs "$R" 1.2.0 grav; then
    check "pending back-merge should be refused" fail
else
    check "pending back-merge → refuse" ok
fi
if ALLOW_PENDING_BACKMERGE=1 run_rs "$R" 1.2.0 grav; then
    [ "$(br "$R")" = "release/v1.2.0" ] \
        && check "pending back-merge + ALLOW_PENDING_BACKMERGE=1 → proceeds" ok \
        || check "override ran but branch missing" fail
else
    check "override should let it proceed" fail
fi

# ── refuse: dirty tree ──────────────────────────────────────
R="$STUB_DIR/dirty"; mk_repo "$R" 1.0.1 0.2.0
echo dirty >> "$R/config/www/VERSION"
if run_rs "$R" 1.2.0 grav; then check "dirty tree should be refused" fail; else check "dirty tree → refuse" ok; fi

# ── refuse: tag already exists ──────────────────────────────
R="$STUB_DIR/duptag"; mk_repo "$R" 1.0.1 0.2.0
git -C "$R" tag -a v1.2.0 -m "already shipped"
if run_rs "$R" 1.2.0 grav; then check "existing tag should be refused" fail; else check "existing tag → refuse" ok; fi

# ── refuse: VERSION already at requested value ──────────────
R="$STUB_DIR/noop"; mk_repo "$R" 1.2.0 0.2.0
if run_rs "$R" 1.2.0 grav; then check "no-op bump should be refused" fail; else check "VERSION already at value → refuse" ok; fi

# ── refuse: invalid semver ──────────────────────────────────
R="$STUB_DIR/badver"; mk_repo "$R" 1.0.1 0.2.0
if run_rs "$R" not-a-version grav; then check "invalid semver should be refused" fail; else check "invalid semver → refuse" ok; fi

# ── refuse: unknown component ───────────────────────────────
R="$STUB_DIR/badcomp"; mk_repo "$R" 1.0.1 0.2.0
if run_rs "$R" 1.2.0 bogus; then check "unknown component should be refused" fail; else check "unknown component → refuse" ok; fi

echo "---"
echo "release-start: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
