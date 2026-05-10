#!/usr/bin/env bash
#
# Unit test: exercises bv_remote_run end-to-end against a stub
# ssh/sshpass pair. The static lint at lint-remote-ssh.sh ensures the
# helper exists with the right shape; this test ensures it actually
# WORKS — including the failure paths (malformed KEY=VALUE, reserved
# key, lower-case key, empty body) that the static lint can't reach.
#
# How: a stub `sshpass` strips its `-p <pass>` and execs the rest. A
# stub `ssh` strips its options and the user@host arg, then execs
# `bash -s` (or whatever command was passed). Both stubs sit in a
# mktemp dir prepended to PATH, so the helper's real `sshpass ... ssh
# ... bash -s <<<"$script_input"` becomes "run bash -s locally with
# the script_input on stdin" — exercising every line of the helper
# (printf %q quoting, export emission, set -euo pipefail prefix,
# body execution) without any network or credentials.
#
# This is the regression fence finding 11 of the post-PR-#17 review
# asked for. It catches:
#   * bv_remote_run regressions in the printf %q value emission
#   * value-flow bugs (e.g. an export that doesn't survive to the body)
#   * the failure paths refusing what they claim to refuse
#   * the success path actually echoing what it claims

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/atomic-release.sh
. "$PROJECT_ROOT/deploy/lib/atomic-release.sh"

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

echo "Unit test: bv_remote_run (against stub ssh/sshpass)"
echo "---"

# ─────────────────────────────────────────────────────────────────────
# Set up stub PATH so bv_remote_run's `sshpass -p ... ssh ... bash -s`
# resolves to local-only execution.
#
# Stub dirs use a recognizable prefix so a SIGKILL-leaked dir from a
# prior run can be cleaned up at startup. EXIT trap covers normal exit;
# the prefix-sweep below covers the SIGKILL / Ctrl-C-during-trap case.
# ─────────────────────────────────────────────────────────────────────
STUB_PREFIX="bv-unit-remote-run."
# Best-effort cleanup of stale stub-dirs from prior crashed runs.
# Older than 1 hour to avoid stomping on a parallel test run that's
# happening right now.
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

STUB_DIR="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

cat > "$STUB_DIR/sshpass" <<'EOF'
#!/usr/bin/env bash
# Stub sshpass: strip `-p <password>` if present, then exec the rest.
# This mirrors real sshpass for our usage pattern.
if [ "${1:-}" = "-p" ]; then
    shift 2
fi
exec "$@"
EOF
chmod +x "$STUB_DIR/sshpass"

cat > "$STUB_DIR/ssh" <<'EOF'
#!/usr/bin/env bash
# Stub ssh: consume ssh options (-o key=value, -p port), then the
# user@host arg, then exec the remaining args (which is `bash -s` for
# bv_remote_run). stdin is inherited — that's the script_input.
while [ $# -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        -p) shift 2 ;;
        -*) shift ;;
        *) break ;;   # First non-option is user@host
    esac
done
shift || true   # drop user@host
exec "$@"
EOF
chmod +x "$STUB_DIR/ssh"

PATH="$STUB_DIR:$PATH"
export PATH

# Set the four env vars bv_remote_run insists on. Values are arbitrary
# (the stubs don't read them) but must be non-empty.
export DEPLOY_HOST=stub-host
export DEPLOY_USER=stub-user
export DEPLOY_PASS=stub-pass
export DEPLOY_PORT=22

# ─────────────────────────────────────────────────────────────────────
# Test group A: success path
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "A. success path"

# A.1 — simplest possible body, no KEY=VALUE.
out="$(bv_remote_run 'echo hello' 2>/dev/null || true)"
if [ "$out" = "hello" ]; then
    check "empty-args body executes and echoes 'hello'" ok
else
    check "empty-args body executes (got: '$out')" fail
fi

# A.2 — single KEY=VALUE round-trip.
out="$(bv_remote_run 'printf %s "$X"' X="round-trip" 2>/dev/null || true)"
if [ "$out" = "round-trip" ]; then
    check "single KEY=VALUE round-trips through printf %q + export" ok
else
    check "single KEY=VALUE round-trip (got: '$out')" fail
fi

# A.3 — value with spaces survives.
out="$(bv_remote_run 'printf %s "$X"' X="value with spaces" 2>/dev/null || true)"
if [ "$out" = "value with spaces" ]; then
    check "value containing spaces survives quoting" ok
else
    check "value with spaces (got: '$out')" fail
fi

# A.4 — value with shell metacharacters survives literally (this is
# the load-bearing test for the security fix).
HOSTILE='; echo PWNED ; rm -rf /tmp/x ; $(echo metachar) `bt` # comment'
out="$(bv_remote_run 'printf %s "$X"' X="$HOSTILE" 2>/dev/null || true)"
if [ "$out" = "$HOSTILE" ]; then
    check "value containing shell metacharacters survives literally (NO injection)" ok
else
    check "metacharacter-bearing value (got: '$out')" fail
fi

# A.5 — value with a literal newline survives.
WITH_NEWLINE="line one
line two"
out="$(bv_remote_run 'printf %s "$X"' X="$WITH_NEWLINE" 2>/dev/null || true)"
if [ "$out" = "$WITH_NEWLINE" ]; then
    check "value containing a newline survives" ok
else
    check "newline-bearing value (got: $(printf %q "$out"))" fail
fi

# A.6 — multiple KEY=VALUE pairs, body uses both.
out="$(bv_remote_run 'printf "%s|%s" "$A" "$B"' A=alpha B=beta 2>/dev/null || true)"
if [ "$out" = "alpha|beta" ]; then
    check "multiple KEY=VALUE pairs all reach the body" ok
else
    check "multiple KEYs (got: '$out')" fail
fi

# A.7 — body's exit code propagates.
if bv_remote_run 'exit 0' 2>/dev/null; then
    check "body exit 0 → helper returns 0" ok
else
    check "body exit 0 → helper returns 0" fail
fi
if bv_remote_run 'exit 7' 2>/dev/null; then
    check "body exit 7 → helper returns non-zero" fail
else
    rc=$?
    if [ "$rc" != 0 ]; then
        check "body exit 7 → helper returns non-zero" ok
    else
        check "body exit 7 → helper returns non-zero (got rc=$rc)" fail
    fi
fi

# A.8 — set -euo pipefail is in effect on the remote (we prepend it).
# Body that pipes through a failing tool should exit non-zero because
# of pipefail, even though the LAST command in the pipe succeeded.
if bv_remote_run 'false | true' 2>/dev/null; then
    check "remote body honours pipefail (false | true → non-zero)" fail
else
    check "remote body honours pipefail (false | true → non-zero)" ok
fi

# ─────────────────────────────────────────────────────────────────────
# Test group B: failure paths (the malformed-input rejections)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "B. failure paths"

# Helper: assert that a rejection path returns non-zero AND prints a
# specific substring to stderr. Catches refactors that drop the
# diagnostic text (silent rejections are bad operator UX).
check_reject_with_msg() {
    local name="$1" expected_substring="$2"; shift 2
    local err rc=0
    err="$(bv_remote_run "$@" 2>&1 >/dev/null)" || rc=$?
    if [ "$rc" = 0 ]; then
        check "$name (returned 0; expected non-zero)" fail
        return
    fi
    case "$err" in
        *"$expected_substring"*)
            check "$name" ok
            ;;
        *)
            check "$name (no '$expected_substring' in stderr)" fail
            ;;
    esac
}

# B.1 — empty body is rejected with a specific diagnostic.
check_reject_with_msg "empty body rejected (with diagnostic)" \
    "requires a body argument" \
    ""

# B.2 — argument missing the '=' is rejected with a specific diagnostic.
check_reject_with_msg "malformed KEY=VALUE (no '=') rejected (with diagnostic)" \
    "must be KEY=VALUE" \
    'true' "MALFORMED_NO_EQUALS"

# B.3 — lower-case key is rejected by the allowlist with a specific diagnostic.
check_reject_with_msg "lower-case key rejected (with diagnostic)" \
    "must match [A-Z_][A-Z0-9_]*" \
    'true' "lowercase=value"

# B.4 — mixed-case key is rejected.
if bv_remote_run 'true' "MixedCase=value" 2>/dev/null; then
    check "mixed-case key rejected" fail
else
    check "mixed-case key rejected" ok
fi

# B.5 — leading-digit key is rejected.
if bv_remote_run 'true' "1ABC=value" 2>/dev/null; then
    check "leading-digit key rejected (not a valid identifier)" fail
else
    check "leading-digit key rejected (not a valid identifier)" ok
fi

# B.5b — bare underscore key is rejected (the throwaway-name convention).
check_reject_with_msg "bare underscore '_' key rejected (with diagnostic)" \
    "bare '_' rejected" \
    'true' "_=value"

# B.6 — key containing a dash / dot / space is rejected.
for bad_key in "FOO-BAR" "FOO.BAR" "FOO BAR"; do
    if bv_remote_run 'true' "${bad_key}=value" 2>/dev/null; then
        check "non-identifier key '$bad_key' rejected" fail
    else
        check "non-identifier key '$bad_key' rejected" ok
    fi
done

# B.7 — every reserved key is rejected, individually. The first three
# additionally assert the specific "reserved / dangerous" diagnostic so
# a refactor that swaps the denylist branch for a generic message gets
# caught.
check_reject_with_msg "reserved key 'SSHPASS' rejected (with diagnostic)" \
    "reserved / dangerous" \
    'true' "SSHPASS=value"
check_reject_with_msg "reserved key 'PATH' rejected (with diagnostic)" \
    "reserved / dangerous" \
    'true' "PATH=value"
check_reject_with_msg "reserved key 'IFS' rejected (with diagnostic)" \
    "reserved / dangerous" \
    'true' "IFS=value"

for reserved in HOME USER SHELL SHELLOPTS BASHOPTS \
                BASH_ENV PROMPT_COMMAND PS1 PS2 PS3 PS4 CDPATH ENV \
                LD_LIBRARY_PATH LD_PRELOAD DYLD_INSERT_LIBRARIES \
                BASH_FUNC_X; do
    if bv_remote_run 'true' "${reserved}=value" 2>/dev/null; then
        check "reserved key '$reserved' rejected" fail
    else
        check "reserved key '$reserved' rejected" ok
    fi
done

# B.8 — empty key (`=value`) is rejected.
if bv_remote_run 'true' "=value" 2>/dev/null; then
    check "empty key '=value' rejected" fail
else
    check "empty key '=value' rejected" ok
fi

# B.9 — missing DEPLOY_HOST is rejected (the four env-var asserts).
(
    unset DEPLOY_HOST
    if bv_remote_run 'true' 2>/dev/null; then
        echo "fail" >&2
    else
        echo "ok"
    fi
) > /tmp/_bv_unit_$$.out 2>/dev/null
if grep -q '^ok$' /tmp/_bv_unit_$$.out; then
    check "missing DEPLOY_HOST rejected" ok
else
    check "missing DEPLOY_HOST rejected" fail
fi
rm -f /tmp/_bv_unit_$$.out

# ─────────────────────────────────────────────────────────────────────
# Test group C: integration-shape (matches real call-site shapes)
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "C. integration shapes (real call-site patterns)"

# C.1 — capture-stdout pattern (DOCROOT_STATE-style).
TARGET="$(mktemp -d)/some-tier"
mkdir -p "$TARGET"
out="$(bv_remote_run '
    if [ -L "$T" ]; then
        echo symlink
    elif [ -d "$T" ]; then
        echo dir
    else
        echo absent
    fi
' T="$TARGET" 2>/dev/null || true)"
if [ "$out" = "dir" ]; then
    check "capture-stdout pattern (real -d/-L/absent dispatch)" ok
else
    check "capture-stdout pattern (got: '$out')" fail
fi
rm -rf "$(dirname "$TARGET")"

# C.2 — multiline body, multiple values, side-effecting (mkdir).
TMP_PARENT="$(mktemp -d)"
bv_remote_run '
    mkdir -p "$RD/user/accounts" "$RD/user/data" "$RD/logs"
    [ -d "$RD/user/accounts" ] && [ -d "$RD/user/data" ] && [ -d "$RD/logs" ]
' RD="$TMP_PARENT/release-A" 2>/dev/null
if [ -d "$TMP_PARENT/release-A/user/accounts" ] \
   && [ -d "$TMP_PARENT/release-A/user/data" ] \
   && [ -d "$TMP_PARENT/release-A/logs" ]; then
    check "multiline side-effecting body (mkdir -p chain)" ok
else
    check "multiline side-effecting body" fail
fi
rm -rf "$TMP_PARENT"

# C.3 — value containing the literal string `$X` (must NOT be expanded
# locally OR remotely — printf %q quotes it as `\$X` for the export).
LIT='${RELEASE_DIR} should stay literal'
out="$(bv_remote_run 'printf %s "$Y"' Y="$LIT" 2>/dev/null || true)"
if [ "$out" = "$LIT" ]; then
    check 'value containing literal `${...}` survives unmodified' ok
else
    check 'value containing literal `${...}`' fail
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"

[ "$FAIL" -eq 0 ]
