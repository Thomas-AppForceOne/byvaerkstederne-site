#!/usr/bin/env bash
#
# Shell-level probe for deploy/bump-version.sh.
#
# Local mktemp git fixtures; BV_RELEASE_REPO points the script at each.
#
# Coverage (success + every failure path, per CLAUDE.md testing discipline):
#   Success:
#     * grav patch  → config/www/VERSION bumped + committed on a feature branch
#     * landing minor → apex/VERSION bumped; grav file untouched
#     * --no-commit → file edited, NO commit
#     * suffix drop → 1.3.0-dev patch → 1.3.1
#   Failure:
#     * commit on develop/main → refuse (protected)
#     * missing part argument → refuse
#     * unparseable VERSION → refuse
#     * unknown component → refuse

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BV_SH="$PROJECT_ROOT/deploy/bump-version.sh"

PASS=0; FAIL=0
check() { [ "$2" = ok ] && { echo "  ✓ $1"; PASS=$((PASS+1)); } || { echo "  ✗ $1" >&2; FAIL=$((FAIL+1)); }; }

echo "Probe: bump-version.sh"
echo "---"

STUB_PREFIX="bv-bump-version."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 -exec rm -rf {} + 2>/dev/null || true
STUB_DIR="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

# Fresh repo on a feature branch (so committing is allowed).
mk_repo() {
    local dir="$1" gravver="$2" landingver="$3" branch="${4:-feature/x}"
    rm -rf "$dir"; git init -q "$dir"
    git -C "$dir" config user.email t@example.com
    git -C "$dir" config user.name Test
    git -C "$dir" config commit.gpgsign false
    mkdir -p "$dir/config/www" "$dir/apex"
    printf '%s\n' "$gravver"    > "$dir/config/www/VERSION"
    printf '%s\n' "$landingver" > "$dir/apex/VERSION"
    git -C "$dir" add -A; git -C "$dir" commit -qm init
    git -C "$dir" branch -M "$branch"
}
run_bv() { local repo="$1"; shift; local rc=0
    BV_RELEASE_REPO="$repo" bash "$BV_SH" "$@" >/dev/null 2>&1 || rc=$?; return "$rc"; }
filev() { tr -d '[:space:]' < "$1"; }
msg()   { git -C "$1" log -1 --format=%s; }
headsha(){ git -C "$1" rev-parse HEAD; }

# ── grav patch success (committed) ──────────────────────────
R="$STUB_DIR/grav"; mk_repo "$R" 1.3.2 0.2.0
if run_bv "$R" patch grav; then
    ok=ok
    [ "$(filev "$R/config/www/VERSION")" = "1.3.3" ]                   || ok=fail
    [ "$(msg "$R")" = "chore: bump grav version 1.3.2 → 1.3.3" ]       || ok=fail
    check "grav patch: 1.3.2 → 1.3.3, committed" "$ok"
else
    check "grav patch should succeed on a feature branch" fail
fi

# ── landing minor success; grav untouched ──────────────────
R="$STUB_DIR/landing"; mk_repo "$R" 1.3.2 0.2.0
if run_bv "$R" minor landing; then
    ok=ok
    [ "$(filev "$R/apex/VERSION")" = "0.3.0" ]       || ok=fail
    [ "$(filev "$R/config/www/VERSION")" = "1.3.2" ] || ok=fail
    check "landing minor: 0.2.0 → 0.3.0, grav untouched" "$ok"
else
    check "landing minor should succeed" fail
fi

# ── --no-commit: edits file, no commit ─────────────────────
R="$STUB_DIR/nocommit"; mk_repo "$R" 1.3.2 0.2.0
BEFORE="$(headsha "$R")"
if run_bv "$R" patch grav --no-commit; then
    ok=ok
    [ "$(filev "$R/config/www/VERSION")" = "1.3.3" ] || ok=fail   # file changed
    [ "$(headsha "$R")" = "$BEFORE" ]                || ok=fail   # but no new commit
    check "--no-commit: file edited, HEAD unchanged" "$ok"
else
    check "--no-commit should succeed" fail
fi

# ── suffix drop ────────────────────────────────────────────
R="$STUB_DIR/suffix"; mk_repo "$R" 1.3.0-dev 0.2.0
run_bv "$R" patch grav
check "suffix drop: 1.3.0-dev → 1.3.1" "$([ "$(filev "$R/config/www/VERSION")" = "1.3.1" ] && echo ok || echo fail)"

# ── --pre= re-applies a pre-release suffix (open next dev iteration) ──
R="$STUB_DIR/pre"; mk_repo "$R" 1.3.2 0.2.0
run_bv "$R" minor grav --pre=dev --no-commit
check "pre: minor --pre=dev → 1.4.0-dev" "$([ "$(filev "$R/config/www/VERSION")" = "1.4.0-dev" ] && echo ok || echo fail)"

# ── refuse: commit on develop ──────────────────────────────
R="$STUB_DIR/develop"; mk_repo "$R" 1.3.2 0.2.0 develop
if run_bv "$R" patch grav; then check "commit on develop should be refused" fail; else check "commit on develop → refuse" ok; fi
# but --no-commit on develop is allowed (just edits)
if run_bv "$R" patch grav --no-commit; then check "develop + --no-commit → allowed (edit only)" ok; else check "develop + --no-commit should be allowed" fail; fi

# ── refuse: commit on main ─────────────────────────────────
R="$STUB_DIR/main"; mk_repo "$R" 1.3.2 0.2.0 main
if run_bv "$R" patch grav; then check "commit on main should be refused" fail; else check "commit on main → refuse" ok; fi

# ── refuse: missing part ───────────────────────────────────
R="$STUB_DIR/nopart"; mk_repo "$R" 1.3.2 0.2.0
if run_bv "$R" grav; then check "missing part should be refused" fail; else check "missing part → refuse" ok; fi

# ── refuse: unparseable VERSION ────────────────────────────
R="$STUB_DIR/garbage"; mk_repo "$R" "not-a-version" 0.2.0
if run_bv "$R" patch grav; then check "unparseable VERSION should be refused" fail; else check "unparseable VERSION → refuse" ok; fi

# ── refuse: unknown component ──────────────────────────────
R="$STUB_DIR/badcomp"; mk_repo "$R" 1.3.2 0.2.0
if run_bv "$R" patch bogus; then check "unknown component should be refused" fail; else check "unknown component → refuse" ok; fi

echo "---"
echo "bump-version: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
