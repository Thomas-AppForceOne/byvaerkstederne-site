#!/usr/bin/env bash
#
# Unit test for deploy/list-users.sh — the GROUPS column in particular.
#
# Shape follows unit-manage-groups.sh: everything runs in a mktemp sandbox
# with stub binaries prepended to PATH. The sandbox holds a COPY of the
# script (so PROJECT_DIR resolves to the sandbox and its own .env.deploy),
# and the `ssh` stub executes the "remote" command locally with `sh -c`
# against a fake tier tree — so the remote extraction runs for real
# against real account YAML, which is the whole point: the groups reader
# is remote shell, and a test that stubbed it out would assert nothing.
#
# Covered both ways, per the repo's testing rule:
#   success — block-form groups, flow-form groups, multiple groups
#   failure — no groups key, empty accounts dir, missing accounts dir,
#             SSH failure, a bad tier argument

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

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

# Assert that the row for <user> carries exactly <expected> in GROUPS.
row_groups() {
    local out="$1" user="$2"
    printf '%s\n' "$out" | awk -v u="$user" '$1 == u { print $NF }'
}

echo "Unit test: list-users.sh (sandboxed, stub ssh)"
echo "---"

STUB_PREFIX="bv-unit-list-users."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

SB="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$SB"' EXIT

# ── Sandbox project: script copy + fixtures ──────────────────────────
mkdir -p "$SB/proj/deploy/lib" "$SB/bin" "$SB/remote"
cp "$PROJECT_ROOT/deploy/list-users.sh" "$SB/proj/deploy/"
cp "$PROJECT_ROOT/deploy/lib/ssh-auth.sh" "$SB/proj/deploy/lib/"

# Key-auth path (no DEPLOY_PASS) so bv_ssh_cmd uses the `ssh` stub.
cat > "$SB/proj/.env.deploy" <<EOF
DEPLOY_HOST=fakehost
DEPLOY_USER=fakeuser
DEPLOY_PATH=$SB/remote
DEPLOY_PORT=22
EOF

# ── Fake tier tree (what the "remote" sees) ──────────────────────────
ACC="$SB/remote/dev/user/accounts"
mkdir -p "$ACC"

# Block form — what Symfony's dumper writes (manage-groups.sh's output).
cat > "$ACC/anders.yaml" <<'EOF'
state: enabled
email: anders@example.dk
access:
  site:
    login: true
groups:
  - organizers
EOF

# Block form, several groups, with a following top-level key so the range
# end matters: a reader that ran to EOF would swallow `fullname`.
cat > "$ACC/bodil.yaml" <<'EOF'
state: enabled
email: bodil@example.dk
groups:
  - organizers
  - moderators
fullname: Bodil Bang
access:
  site:
    login: true
EOF

# Flow form — what a hand edit may leave behind.
cat > "$ACC/carla.yaml" <<'EOF'
state: enabled
email: carla@example.dk
groups: [organizers, moderators]
access:
  site:
    login: true
EOF

# Quoted flow form.
cat > "$ACC/dorte.yaml" <<'EOF'
state: enabled
email: dorte@example.dk
groups: ['organizers']
access:
  site:
    login: true
EOF

# No groups key at all — the failure path the column must render as `-`.
cat > "$ACC/erik.yaml" <<'EOF'
state: enabled
email: erik@example.dk
access:
  site:
    login: true
EOF

# Super-admin with no groups: TYPE and GROUPS are independent.
cat > "$ACC/frida.yaml" <<'EOF'
state: enabled
email: frida@example.dk
access:
  admin:
    super: true
EOF

# ── Stubs ────────────────────────────────────────────────────────────
LOG="$SB/invocations.log"

cat > "$SB/bin/ssh" <<EOF
#!/usr/bin/env bash
echo "ssh:\$*" >> "$LOG"
if [ -n "\${BV_SSH_STUB_FAIL:-}" ]; then exit 255; fi
# The remote command is the last argument.
for cmd in "\$@"; do :; done
sh -c "\$cmd"
EOF
chmod +x "$SB/bin/ssh"

run_list() {
    ( cd "$SB/proj" && PATH="$SB/bin:$PATH" bash deploy/list-users.sh "$@" 2>&1 )
}

# ── 1. Success path: the GROUPS column ───────────────────────────────
out="$(run_list dev || true)"

check "block-form groups are listed" \
    "$([ "$(row_groups "$out" anders)" = "organizers" ] && echo ok || echo no)"

check "several block-form groups are comma-joined" \
    "$([ "$(row_groups "$out" bodil)" = "organizers,moderators" ] && echo ok || echo no)"

check "the block range stops at the next top-level key" \
    "$(printf '%s\n' "$out" | grep -q 'Bodil' && echo no || echo ok)"

check "flow-form groups are listed" \
    "$([ "$(row_groups "$out" carla)" = "organizers,moderators" ] && echo ok || echo no)"

check "quoted flow-form groups lose their quotes" \
    "$([ "$(row_groups "$out" dorte)" = "organizers" ] && echo ok || echo no)"

check "an account with no groups renders as -" \
    "$([ "$(row_groups "$out" erik)" = "-" ] && echo ok || echo no)"

check "a super-admin with no groups still renders as -" \
    "$([ "$(row_groups "$out" frida)" = "-" ] && echo ok || echo no)"

check "the header carries a GROUPS column" \
    "$(printf '%s\n' "$out" | grep -qE '^USERNAME.*GROUPS' && echo ok || echo no)"

check "the pre-existing columns survive" \
    "$(printf '%s\n' "$out" | grep -qE '^anders +member +enabled +anders@example\.dk' && echo ok || echo no)"

check "super-admin is still typed super-admin" \
    "$(printf '%s\n' "$out" | grep -qE '^frida +super-admin' && echo ok || echo no)"

check "the account count is reported" \
    "$(printf '%s\n' "$out" | grep -q '(6 account(s))' && echo ok || echo no)"

check "no hashed password is ever printed" \
    "$(printf '%s\n' "$out" | grep -qi 'hashed_password' && echo no || echo ok)"

# ── 2. Failure paths ─────────────────────────────────────────────────
mkdir -p "$SB/remote/test/user/accounts"
out_empty="$(run_list test || true)"
check "an empty accounts dir reports no accounts" \
    "$(printf '%s\n' "$out_empty" | grep -q 'No member accounts on test' && echo ok || echo no)"

out_nodir="$(run_list staging || true)"
check "a missing accounts dir says the tier is not deployed" \
    "$(printf '%s\n' "$out_nodir" | grep -q 'No accounts dir on staging' && echo ok || echo no)"

set +e
out_badtier="$( ( cd "$SB/proj" && PATH="$SB/bin:$PATH" bash deploy/list-users.sh bogus ) 2>&1 )"
rc_badtier=$?
set -e
check "an unknown tier is refused non-zero" \
    "$([ "$rc_badtier" -ne 0 ] && echo ok || echo no)"
check "the unknown-tier refusal names the argument" \
    "$(printf '%s\n' "$out_badtier" | grep -q 'Unknown arg: bogus' && echo ok || echo no)"

set +e
out_sshfail="$( ( cd "$SB/proj" && PATH="$SB/bin:$PATH" BV_SSH_STUB_FAIL=1 bash deploy/list-users.sh dev ) 2>&1 )"
rc_sshfail=$?
set -e
check "an SSH failure exits non-zero" \
    "$([ "$rc_sshfail" -ne 0 ] && echo ok || echo no)"
check "an SSH failure is reported, not silently empty" \
    "$(printf '%s\n' "$out_sshfail" | grep -q 'SSH to fakeuser@fakehost' && echo ok || echo no)"

# ── Summary ──────────────────────────────────────────────────────────
echo "---"
echo "list-users unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
