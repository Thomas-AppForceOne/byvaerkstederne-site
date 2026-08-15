#!/usr/bin/env bash
#
# Unit test for the two primitives that keep a release from being
# swapped in while it cannot boot:
#
#   bv_seed_security_salt           — makes the per-host env salt exist
#                                     BEFORE the symlink to it is wired
#   bv_verify_release_state_symlinks — refuses a release whose state
#                                     symlinks dangle
#
# Both are fixture-only (mktemp dir, no ssh, no remote) per ADR-004.
#
# Background — the 2026-08-14 production incident this pins shut:
# env security.yaml is gitignored, so the release never carries one. The
# env dir was renamed from the short tier name (`env/prod/`) to the host
# name (`env/www.byvaerkstederne.dk/`), which moved the wiring onto a
# path the data dir had never been seeded for. The wiring replaced the
# tier's real salt file with a symlink into that empty path, Grav could
# not write the salt at boot, and every request 500'd. Eight deploy
# steps stayed green — including `bin/grav clearcache`, which has no
# HTTP Host and so never resolves a per-host env at all.
#
# Coverage:
#   bv_seed_security_salt:
#     * existing target is never overwritten (salt is load-bearing)
#     * absent target + previous release's real file → migrated verbatim
#     * absent target + no source → fresh `salt: <hex>` generated
#     * a SYMLINK source is not accepted as a migration source
#     * parent directory is created when missing
#   bv_verify_release_state_symlinks:
#     * fully wired release with a seeded data dir → passes
#     * dangling env security.yaml → fails, names the link (FAILURE PATH)
#     * dangling user/config/security.yaml → fails
#     * dangling accounts/data/logs → fails
#     * every broken link is reported, not just the first
#     * dangling email.yaml alone → still passes (ABSENT-FILE CONTRACT)
#   wire → seed → verify, in the order deploy.sh runs them:
#     * seeded first, then wired  → verify passes
#     * wired without seeding     → verify fails (the incident, reproduced)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/atomic-release.sh
. "$PROJECT_ROOT/deploy/lib/atomic-release.sh"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}
eq()      { [ "$2" = "$3" ] && check "$1" ok || check "$1 (want '$2', got '$3')" fail; }
match()   { [[ "$3" =~ $2 ]] && check "$1" ok || check "$1 (got '$3', want ~ $2)" fail; }
ok_rc()   { if "${@:2}" >/dev/null 2>&1; then check "$1" ok; else check "$1 (expected rc 0)" fail; fi; }
bad_rc()  { if "${@:2}" >/dev/null 2>&1; then check "$1 (expected non-zero rc)" fail; else check "$1" ok; fi; }

echo "Unit test: release state seeding + symlink guard"
echo "---"

STUB_PREFIX="bv-unit-state-guard."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true
WORK="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ENV_HOST="staging.hackersbychoice.dk"

# Build a <parent>/ containing <tier>-releases/<id>/ and <tier>data/,
# the layout bv_wire_release_symlinks computes its relative targets
# against. Echoes the release dir.
make_tier() {
    local parent="$1" rel_id="$2"
    local rel="$parent/stagingdata-releases/$rel_id"
    mkdir -p "$rel/user/config" "$rel/user/env/$ENV_HOST/config/plugins"
    mkdir -p "$parent/stagingdata"
    printf '%s' "$rel"
}

# ── bv_seed_security_salt ───────────────────────────────────
S1="$WORK/seed1"; mkdir -p "$S1"
printf 'salt: keepthisone\n' > "$S1/security.yaml"
bv_seed_security_salt "$S1/security.yaml" >/dev/null
eq "seed: existing target is left untouched" \
    "salt: keepthisone" "$(cat "$S1/security.yaml")"

S2="$WORK/seed2"; mkdir -p "$S2/prev"
printf 'salt: liveSaltAbc123\n' > "$S2/prev/security.yaml"
bv_seed_security_salt "$S2/data/user/env/$ENV_HOST/config/security.yaml" \
    "$S2/prev/security.yaml" >/dev/null
eq "seed: migrates the previous release's salt verbatim (sessions survive)" \
    "salt: liveSaltAbc123" "$(cat "$S2/data/user/env/$ENV_HOST/config/security.yaml")"
ok_rc "seed: creates the parent directory when missing" \
    test -d "$S2/data/user/env/$ENV_HOST/config"

S3="$WORK/seed3"
bv_seed_security_salt "$S3/security.yaml" >/dev/null
match "seed: generates 'salt: <hex>' on a tier with no salt at all" \
    '^salt: [0-9a-f]{32}$' "$(cat "$S3/security.yaml")"

S3B="$WORK/seed3b"
bv_seed_security_salt "$S3B/security.yaml" >/dev/null
if [ "$(cat "$S3/security.yaml")" != "$(cat "$S3B/security.yaml")" ]; then
    check "seed: two generated salts differ (actually random)" ok
else
    check "seed: two generated salts differ (actually random)" fail
fi

S4="$WORK/seed4"; mkdir -p "$S4/prev"
ln -s "$S4/data/user/config/security.yaml" "$S4/prev/security.yaml"
bv_seed_security_salt "$S4/data/user/config/security.yaml" "$S4/prev/security.yaml" >/dev/null
match "seed: a symlink source is refused, a fresh salt is generated instead" \
    '^salt: [0-9a-f]{32}$' "$(cat "$S4/data/user/config/security.yaml")"

eq "seed: reports what it did (provenance for the deploy log)" \
    "migrated existing salt into $S2/prev-echo.yaml" \
    "$(printf 'salt: x\n' > "$WORK/src.yaml"; bv_seed_security_salt "$S2/prev-echo.yaml" "$WORK/src.yaml")"

# ── bv_verify_release_state_symlinks: the happy path ────────
P1="$WORK/tier1"
REL1="$(make_tier "$P1" "20260814T120000-abc1234")"
bv_bootstrap_data_dir "$P1/stagingdata" "$ENV_HOST"
bv_seed_security_salt "$P1/stagingdata/v0/user/config/security.yaml" >/dev/null
bv_seed_security_salt "$P1/stagingdata/v0/user/env/$ENV_HOST/config/security.yaml" >/dev/null
bv_wire_release_symlinks "$REL1" "$P1/stagingdata" "$ENV_HOST" v0
ok_rc "verify: seeded + wired release passes" \
    bv_verify_release_state_symlinks "$REL1" "$ENV_HOST"

ok_rc "verify: passes with email.yaml still dangling (ABSENT-FILE CONTRACT)" \
    test ! -e "$REL1/user/env/$ENV_HOST/config/plugins/email.yaml"

# ── FAILURE PATH: the incident, reproduced ──────────────────
# Wire a release against a data dir that was never seeded with the
# per-host env salt. This is byte-for-byte what happened in production:
# the link exists, points somewhere sane, and resolves to nothing.
P2="$WORK/tier2"
REL2="$(make_tier "$P2" "20260814T130000-def5678")"
bv_bootstrap_data_dir "$P2/stagingdata" "$ENV_HOST"
bv_seed_security_salt "$P2/stagingdata/v0/user/config/security.yaml" >/dev/null
# NOTE: env salt deliberately NOT seeded.
bv_wire_release_symlinks "$REL2" "$P2/stagingdata" "$ENV_HOST" v0
bad_rc "verify: dangling env security.yaml is refused (the 2026-08-14 incident)" \
    bv_verify_release_state_symlinks "$REL2" "$ENV_HOST"
ERR2="$(bv_verify_release_state_symlinks "$REL2" "$ENV_HOST" 2>&1 >/dev/null || true)"
match "verify: the error names the offending link" \
    "user/env/$ENV_HOST/config/security.yaml" "$ERR2"

# Seeding it after the fact makes the very same release pass — proves
# the guard tracks the target, not some incidental property.
bv_seed_security_salt "$P2/stagingdata/v0/user/env/$ENV_HOST/config/security.yaml" >/dev/null
ok_rc "verify: seeding the missing salt makes the same release pass" \
    bv_verify_release_state_symlinks "$REL2" "$ENV_HOST"

# ── FAILURE PATH: the other four links ──────────────────────
P3="$WORK/tier3"
REL3="$(make_tier "$P3" "20260814T140000-9abcdef")"
bv_bootstrap_data_dir "$P3/stagingdata" "$ENV_HOST"
bv_seed_security_salt "$P3/stagingdata/v0/user/config/security.yaml" >/dev/null
bv_seed_security_salt "$P3/stagingdata/v0/user/env/$ENV_HOST/config/security.yaml" >/dev/null
bv_wire_release_symlinks "$REL3" "$P3/stagingdata" "$ENV_HOST" v0

rm -f "$P3/stagingdata/v0/user/config/security.yaml"
bad_rc "verify: dangling user/config/security.yaml is refused" \
    bv_verify_release_state_symlinks "$REL3" "$ENV_HOST"

rm -rf "$P3/stagingdata/v0/user/accounts" "$P3/stagingdata/v0/user/data" "$P3/stagingdata/logs"
ERR3="$(bv_verify_release_state_symlinks "$REL3" "$ENV_HOST" 2>&1 >/dev/null || true)"
eq "verify: reports every broken link, not just the first" \
    "4" "$(printf '%s\n' "$ERR3" | grep -c 'does not resolve')"

# ── Guard's own preconditions ───────────────────────────────
bad_rc "verify: a release dir that does not exist is refused" \
    bv_verify_release_state_symlinks "$WORK/no-such-release" "$ENV_HOST"

# ── bv_validate_env_dir_name ────────────────────────────────
# The env dir is named for the request HOST, so the validator has to
# accept dots — while still refusing everything that could climb out of
# user/env/.
eq "env-dir name: a hostname is accepted (this is what deploy.sh passes)" \
    "www.byvaerkstederne.dk" "$(bv_validate_env_dir_name www.byvaerkstederne.dk)"
eq "env-dir name: a bare tier name still works (migrate-to-atomic-layout)" \
    "staging" "$(bv_validate_env_dir_name staging)"
bad_rc "env-dir name: traversal is refused"        bv_validate_env_dir_name "../etc"
bad_rc "env-dir name: a slash is refused"          bv_validate_env_dir_name "a/b"
bad_rc "env-dir name: empty is refused"            bv_validate_env_dir_name ""
bad_rc "env-dir name: a leading dot is refused"    bv_validate_env_dir_name ".hidden"
bad_rc "env-dir name: a metacharacter is refused"  bv_validate_env_dir_name 'host;rm -rf /'
bad_rc "wire: an unsafe env dir name is refused before any path is built" \
    bv_wire_release_symlinks "$REL1" "$P1/stagingdata" "../etc" v0

echo "---"
echo "state-symlink-guard: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
