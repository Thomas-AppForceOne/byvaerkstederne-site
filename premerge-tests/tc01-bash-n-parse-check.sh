#!/usr/bin/env bash
# =============================================================================
# TC-01 — Deploy/test script syntax (bash -n)   [applies to #53 and #54]
#
# Parses every deploy/test shell script in full. Catches syntax errors that
# `make test-deploy` can miss (its --dry-run paths exit before a broken block
# runs) — e.g. an unescaped apostrophe inside a single-quoted bv_remote_run
# body. Mirrors the CI "Syntax-check deploy scripts (bash -n)" step.
#
# Preconditions: bash 4+.   Exit: 0 PASS · 1 FAIL · 2 BLOCKED.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
echo "TC-01 bash -n parse-check  (branch: $(git branch --show-current 2>/dev/null || echo '?'))"

# --- precondition: bash 4+ ---------------------------------------------------
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "BLOCKED: bash 4+ required (have ${BASH_VERSION:-?}). macOS: brew install bash" >&2
    exit 2
fi

# --- step 1: enumerate -------------------------------------------------------
shopt -s nullglob
files=( deploy/*.sh deploy/lib/*.sh tests/deploy/*.sh scripts/*.sh )
shopt -u nullglob
if [ "${#files[@]}" -eq 0 ]; then
    echo "BLOCKED: no scripts found (wrong directory?)" >&2
    exit 2
fi
echo "  scanning ${#files[@]} scripts"

# --- steps 2-3: parse each, aggregate ---------------------------------------
fail=0
for f in "${files[@]}"; do
    if ! bash -n "$f" 2>/tmp/tc01.err; then
        echo "  ✗ $f"
        sed 's/^/      /' /tmp/tc01.err
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo "TC-01 FAIL: one or more scripts have a syntax error (see above)" >&2
    exit 1
fi
echo "TC-01 PASS: all ${#files[@]} scripts parse clean"
exit 0
