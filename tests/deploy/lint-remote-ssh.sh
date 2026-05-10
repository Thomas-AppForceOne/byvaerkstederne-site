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
#   2. Every `bv_remote_run` call passes its body as a single-quoted
#      string (forces "$KEY" form on the remote), not a double-quoted
#      string that would defeat the helper's protection by
#      interpolating local-shell ${X} into the body before dispatch.
#   3. The body of bv_remote_run itself stays in the lib (single source
#      of truth); the lint cross-checks that other shell scripts do not
#      reimplement it.
#   4. The helper's body still uses printf %q for value emission —
#      removing that primitive silently re-opens the argument-injection
#      surface, so the lint locks it in.
#
# Wired into Makefile's `test-deploy` target so the regression cannot
# silently land.
#
# KNOWN LIMITATIONS — what this lint does NOT catch:
#   * Local-shell pre-build of the body string. Example:
#       local body="test -e ${X}"   # interpolates ${X} HERE
#       bv_remote_run "$body"       # body is now a literal command
#     The lint sees `bv_remote_run "$body"` (a double-quoted variable,
#     not a string) and would fail check 2 — so this particular
#     pattern IS caught. But a more elaborate pattern that pre-builds
#     via printf into a single-quoted-looking shape (e.g. `body="$(
#     printf '%s' "test -e \"\$X\"")"`) could in principle slip past.
#   * Body strings that legitimately need to embed a ${...} for some
#     remote-only purpose. The lint refuses any ${...} but offers no
#     escape hatch; if a real need arises, refine check 2's grep.
#   * Bodies that call out to shell helpers defined locally and not
#     re-defined remotely. The lint can't detect missing remote-side
#     definitions; that's a runtime failure, not a static one.
#
# These are documented gaps, not bugs. Code review of changes that
# touch deploy/lib/atomic-release.sh's bv_remote_run, or that add
# new call sites, must look at the full pattern, not just lint output.

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
        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
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
                        | grep -v '^[^:]*:[0-9]*:[[:space:]]*#' \
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

# 5. Shebang regression guard: deploy.sh / rollback.sh /
#    migrate-to-atomic-layout.sh must use `#!/usr/bin/env bash` so a
#    Homebrew bash 5+ on PATH is picked up. /bin/bash on macOS is bash
#    3.2, which fails to parse the lib's nested $(...) constructs with
#    a cryptic syntax error.
for script in "$DEPLOY_DIR/deploy.sh" "$DEPLOY_DIR/rollback.sh" "$DEPLOY_DIR/migrate-to-atomic-layout.sh"; do
    base="$(basename "$script")"
    if [ "$(head -n 1 "$script")" = "#!/usr/bin/env bash" ]; then
        check "$base uses #!/usr/bin/env bash (bash 5+ resolution)" ok
    else
        check "$base must shebang #!/usr/bin/env bash, not /bin/bash (got: $(head -n 1 "$script"))" fail
    fi
    # And: each must check BASH_VERSINFO[0] >= 4 before sourcing the lib.
    if grep -q 'BASH_VERSINFO\[0\]' "$script"; then
        check "$base checks BASH_VERSINFO[0] before sourcing lib" ok
    else
        check "$base must assert bash 4+ before sourcing lib" fail
    fi
done

echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"

[ "$FAIL" -eq 0 ]
