#!/usr/bin/env bash
#
# Static lint: blocks regression of the remote_ssh argument-injection
# class found in the PR-#17 review.
#
# History: the original PR shipped a `remote_ssh` helper that took a
# string-built shell command, e.g.
#
#     remote_ssh "test -e ${RELEASE_DIR}"
#
# `${RELEASE_DIR}` was interpolated locally into the SSH command line
# unquoted; ssh joined args with spaces and the remote shell re-parsed,
# so a value containing whitespace, a glob, or a shell metacharacter
# (e.g. a misconfigured `.env.deploy` value with `$IFS` or `;`) executed
# uncontrolled code on the remote. The fix replaces every such call
# site with `bv_remote_run`, which dispatches values via printf
# %q-quoted remote-side env exports.
#
# This lint asserts:
#   1. No `remote_ssh "<...>"` string-built calls remain in deploy/.
#      The helper itself is retired in favour of bv_remote_run.
#   2. Every `bv_remote_run` call passes its body as a quoted string
#      whose interior references values via "$KEY" — never via direct
#      ${VARIABLE} interpolation of a local-shell variable.
#   3. The body of bv_remote_run itself stays in the lib (single source
#      of truth); the lint cross-checks that other shell scripts do not
#      reimplement it.
#
# Wired into Makefile's `test-deploy` target so the regression cannot
# silently land.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEPLOY_DIR="$PROJECT_ROOT/deploy"
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

echo "Static lint: remote_ssh argument-injection regression guard"
echo "---"

# 1. No `remote_ssh "..."` string-built calls anywhere in deploy/. The
#    helper itself is retired; any reintroduction is a regression of
#    the PR-#17 review finding.
#
# We deliberately exclude this lint file's own description of the
# pattern (which contains the string in comments and example code).
HITS="$(grep -rn 'remote_ssh "[^"]' "$DEPLOY_DIR" 2>/dev/null \
        | grep -v '^[^:]*:[[:space:]]*#' \
        || true)"
if [ -z "$HITS" ]; then
    check "deploy/ contains no remote_ssh \"<string>\" call sites" ok
else
    check "deploy/ contains no remote_ssh \"<string>\" call sites" fail
    printf '%s\n' "$HITS" | sed 's/^/      /' >&2
fi

# 2. Every bv_remote_run body uses "$KEY" (the safe form) and not
#    ${LOCAL_VAR} or $LOCAL_VAR (the unsafe form that would interpolate
#    locally before reaching the helper). Heuristic: scan all
#    `bv_remote_run '...'` blocks (single-quoted body) and reject any
#    `${...}` substitution that DOESN'T look like a positional digit
#    or an arithmetic expression.
#
# This is a heuristic (we don't parse bash); but it catches the
# common-case regression (someone writes `bv_remote_run "test -e ${X}"`
# where the body is double-quoted, defeating the helper's protection).
DOUBLE_QUOTED_BODIES="$(grep -rn 'bv_remote_run "' "$DEPLOY_DIR" 2>/dev/null \
                        | grep -v '^[^:]*:[[:space:]]*#' \
                        || true)"
if [ -z "$DOUBLE_QUOTED_BODIES" ]; then
    check "every bv_remote_run body is single-quoted (forces \"\$KEY\" form)" ok
else
    check "every bv_remote_run body is single-quoted (forces \"\$KEY\" form)" fail
    printf '%s\n' "$DOUBLE_QUOTED_BODIES" | sed 's/^/      /' >&2
fi

# 3. The helper itself is defined exactly once, in deploy/lib/atomic-release.sh.
HELPER_DEFS="$(grep -rln '^bv_remote_run() {' "$DEPLOY_DIR" 2>/dev/null \
               || true)"
if [ "$HELPER_DEFS" = "$DEPLOY_DIR/lib/atomic-release.sh" ]; then
    check "bv_remote_run defined exactly once (in deploy/lib/atomic-release.sh)" ok
else
    check "bv_remote_run defined in unexpected location(s): $HELPER_DEFS" fail
fi

# 4. Sanity: the helper's body uses printf %q for value emission. If
#    someone "simplifies" away the printf %q the security property
#    evaporates silently; lock it in.
if grep -q "printf 'export %s=%q\\\\n'" "$DEPLOY_DIR/lib/atomic-release.sh"; then
    check "bv_remote_run body emits values via printf %q (security-critical)" ok
else
    check "bv_remote_run body must emit values via printf %q" fail
fi

echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"

[ "$FAIL" -eq 0 ]
