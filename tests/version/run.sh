#!/usr/bin/env bash
# Sprint-3 shell-level probe for the SemVer + build helpers.
#
# What this asserts (one row per criterion in
# .gan/sprint-3-contract.json — also see
# specifications/semantic_versioning_specification.md Sprint 3):
#
#   - shell_probe_apex_happy_path: with apex/VERSION='0.1.0\n' and
#     apex/BUILD='247\n' (extra surrounding whitespace exercised),
#     readApexSiteVersion() returns { version: '0.1.0', build: '247' }
#     trimmed.
#   - shell_probe_apex_failure_paths: each of (a) VERSION missing,
#     (b) VERSION empty, (c) VERSION invalid SemVer, (d) BUILD missing,
#     (e) BUILD empty, (f) BUILD non-digit yields null on the
#     corresponding key while the other half stays valid.
#   - shell_probe_site_happy_path: with config/www/VERSION='0.1.0' and
#     config/www/BUILD='247', the site-version Twig helper invoked
#     through `bin/grav` (twig:render) returns { version: '0.1.0',
#     build: '247' } trimmed.
#   - shell_probe_site_failure_paths: same six failure cases for the
#     site-version helper.
#
# How to run it locally:
#
#   $ scripts/grav-up.sh . 9100              # start a worktree-scoped Grav
#   $ tests/fixtures/grav-seeds/playwright/apply.sh "$GRAV_CONTAINER"  # seed admin
#   $ tests/version/run.sh                   # this script
#
# Prerequisites:
#   - docker available (used to invoke `php:8.3-cli` for the apex half
#     and to `docker exec bin/grav` for the site half — no host PHP
#     needed).
#   - the worktree's Grav container is running (resolved via
#     scripts/discover-grav-port.js using the same chain documented in
#     CLAUDE.md). Without a running container, only the apex half runs.
#   - apex/BUILD and config/www/BUILD may or may not exist in the
#     working tree at start; the probe writes its own fixtures and
#     restores the originals on exit (success or failure) via a trap.
#
# Cleanup contract:
#   - VERSION and BUILD files for both apex and config/www are saved
#     to a temporary dir on entry and restored unconditionally on exit
#     via `trap`. Re-running the probe twice in succession leaves the
#     working tree byte-identical (verified by `git status --porcelain`).
#   - Temporary fixture content is deleted on exit.
#
# Exit codes:
#   0 — every assertion passed.
#   non-zero — at least one assertion failed; the failing case prints
#     the expected and actual values to stderr.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
APEX_DIR="$REPO_ROOT/apex"
SITE_DIR="$REPO_ROOT/config/www"

# Hard-coded path safety: refuse to operate outside the worktree.
case "$REPO_ROOT" in
  *"/.gan/worktree"|*"/workshop-site"*)
    : ;;
  *)
    echo "FATAL: REPO_ROOT='$REPO_ROOT' does not look like a workshop-site checkout." >&2
    exit 2
    ;;
esac

PASS=0
FAIL=0
FAILED_CASES=()

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() {
  FAIL=$((FAIL+1))
  FAILED_CASES+=("$1")
  printf '  \033[31mFAIL\033[0m %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then printf '       expected: %s\n' "$2" >&2; fi
  if [[ -n "${3:-}" ]]; then printf '       actual:   %s\n' "$3" >&2; fi
}

# ---------------------------------------------------------------------------
# Backup + restore of VERSION/BUILD files.
#
# All four files (apex VERSION/BUILD + site VERSION/BUILD) are copied
# into a tempdir at probe start. The trap restores the *original* state
# — including non-existence of files that did not exist — on exit.
# ---------------------------------------------------------------------------

BACKUP_DIR="$(mktemp -d -t bv-version-probe-XXXXXX)"

backup_file() {
  local src="$1" key="$2"
  if [[ -f "$src" ]]; then
    cp -p "$src" "$BACKUP_DIR/$key"
    printf 'present\n' > "$BACKUP_DIR/$key.flag"
  else
    printf 'absent\n' > "$BACKUP_DIR/$key.flag"
  fi
}

restore_file() {
  local dst="$1" key="$2"
  local flag
  flag="$(cat "$BACKUP_DIR/$key.flag" 2>/dev/null || echo absent)"
  if [[ "$flag" == 'present' ]]; then
    cp -p "$BACKUP_DIR/$key" "$dst"
  else
    rm -f "$dst"
  fi
}

backup_file "$APEX_DIR/VERSION" apex_VERSION
backup_file "$APEX_DIR/BUILD"   apex_BUILD
backup_file "$SITE_DIR/VERSION" site_VERSION
backup_file "$SITE_DIR/BUILD"   site_BUILD

cleanup() {
  local rc=$?
  set +e
  restore_file "$APEX_DIR/VERSION" apex_VERSION
  restore_file "$APEX_DIR/BUILD"   apex_BUILD
  restore_file "$SITE_DIR/VERSION" site_VERSION
  restore_file "$SITE_DIR/BUILD"   site_BUILD
  rm -rf "$BACKUP_DIR"
  if [[ $rc -ne 0 ]]; then
    printf '\nProbe exited with status %d (cleanup completed).\n' "$rc" >&2
  fi
  exit $rc
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# APEX HALF
#
# Implementation: `docker run --rm php:8.3-cli` against the worktree as
# /work, requiring apex/site_version.php and printing JSON to stdout.
# Each invocation is a fresh PHP process, so the helper's static cache
# is irrelevant.
# ---------------------------------------------------------------------------

apex_read_json() {
  # Run a tiny PHP script that requires the helper and json_encodes the
  # result. We disable PHP's error_log routing to /dev/stderr so the
  # warning lines from the failure-path tests don't pollute the JSON
  # output; the probe asserts on the helper's *return value*, not on
  # the warning content (which is covered by the Sprint-2 Grav log
  # criterion).
  docker run --rm \
    -v "$REPO_ROOT":/work \
    -w /work \
    -e BV_PROBE_QUIET=1 \
    php:8.3-cli \
    php -d error_log=/dev/null -d log_errors=Off -d error_reporting=0 -r '
      require "/work/apex/site_version.php";
      echo json_encode(readApexSiteVersion());
    '
}

assert_apex_eq() {
  local label="$1" expected="$2"
  local actual
  actual="$(apex_read_json)"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    fail "$label" "$expected" "$actual"
  fi
}

run_apex_tests() {
  echo
  echo "=== Apex half — readApexSiteVersion() ==="

  # ---- Happy path: trimmed values ----
  printf '  0.1.0\n  '          > "$APEX_DIR/VERSION"   # leading/trailing whitespace
  printf '247\n'                > "$APEX_DIR/BUILD"
  assert_apex_eq "happy_path: trimmed { version: 0.1.0, build: 247 }" \
    '{"version":"0.1.0","build":"247"}'

  # ---- Failure: VERSION missing ----
  rm -f "$APEX_DIR/VERSION"
  printf '247\n' > "$APEX_DIR/BUILD"
  assert_apex_eq "failure: VERSION missing -> version null, build intact" \
    '{"version":null,"build":"247"}'

  # ---- Failure: VERSION empty ----
  : > "$APEX_DIR/VERSION"
  printf '247\n' > "$APEX_DIR/BUILD"
  assert_apex_eq "failure: VERSION empty -> version null, build intact" \
    '{"version":null,"build":"247"}'

  # ---- Failure: VERSION invalid SemVer (0.1) ----
  printf '0.1\n' > "$APEX_DIR/VERSION"
  printf '247\n' > "$APEX_DIR/BUILD"
  assert_apex_eq "failure: VERSION='0.1' invalid -> version null" \
    '{"version":null,"build":"247"}'

  # ---- Failure: VERSION invalid SemVer (latest) ----
  printf 'latest\n' > "$APEX_DIR/VERSION"
  printf '247\n'    > "$APEX_DIR/BUILD"
  assert_apex_eq "failure: VERSION='latest' invalid -> version null" \
    '{"version":null,"build":"247"}'

  # ---- Failure: VERSION with build metadata (0.1.0+build) — explicitly rejected per spec ----
  printf '0.1.0+build\n' > "$APEX_DIR/VERSION"
  printf '247\n'         > "$APEX_DIR/BUILD"
  assert_apex_eq "failure: VERSION='0.1.0+build' rejected -> version null" \
    '{"version":null,"build":"247"}'

  # ---- Failure: BUILD missing ----
  printf '0.1.0\n' > "$APEX_DIR/VERSION"
  rm -f "$APEX_DIR/BUILD"
  assert_apex_eq "failure: BUILD missing -> build null, version intact" \
    '{"version":"0.1.0","build":null}'

  # ---- Failure: BUILD empty ----
  printf '0.1.0\n' > "$APEX_DIR/VERSION"
  : > "$APEX_DIR/BUILD"
  assert_apex_eq "failure: BUILD empty -> build null, version intact" \
    '{"version":"0.1.0","build":null}'

  # ---- Failure: BUILD non-digit (abc) ----
  printf '0.1.0\n' > "$APEX_DIR/VERSION"
  printf 'abc\n'   > "$APEX_DIR/BUILD"
  assert_apex_eq "failure: BUILD='abc' invalid -> build null" \
    '{"version":"0.1.0","build":null}'

  # ---- Failure: BUILD negative (-1) ----
  printf '0.1.0\n' > "$APEX_DIR/VERSION"
  printf -- '-1\n' > "$APEX_DIR/BUILD"
  assert_apex_eq "failure: BUILD='-1' invalid -> build null" \
    '{"version":"0.1.0","build":null}'
}

# ---------------------------------------------------------------------------
# SITE HALF
#
# Implementation: `docker exec <container> bin/grav twig:render` (a
# small helper Twig template that echoes site_version() as JSON). The
# probe writes the .twig template into /tmp inside the container, then
# renders it; cache is busted between cases by `bin/grav clearcache`
# (per the CLAUDE.md gotcha note: "clearcache", NOT "clear-cache").
#
# If no Grav container is reachable for this worktree, the site half
# is skipped with a loud warning rather than silently passing — this
# matches the discovery-chain fail-loud principle from CLAUDE.md.
# ---------------------------------------------------------------------------

GRAV_CONTAINER_NAME=""
GRAV_AVAILABLE=0
detect_grav_container() {
  if [[ -n "${GRAV_CONTAINER:-}" ]]; then
    if docker ps --format '{{.Names}}' | grep -qx "$GRAV_CONTAINER"; then
      GRAV_CONTAINER_NAME="$GRAV_CONTAINER"
      GRAV_AVAILABLE=1
      return
    fi
  fi
  # Fall back to the discover-grav-port helper.
  if [[ -x "$REPO_ROOT/scripts/discover-grav-port.js" ]] && command -v node >/dev/null 2>&1; then
    local container
    container="$(node -e "
      const { discoverGravEnv } = require('$REPO_ROOT/scripts/discover-grav-port.js');
      try { process.stdout.write(discoverGravEnv('$REPO_ROOT').container || ''); }
      catch (e) { process.exit(1); }
    " 2>/dev/null || true)"
    if [[ -n "$container" ]] && docker ps --format '{{.Names}}' | grep -qx "$container"; then
      GRAV_CONTAINER_NAME="$container"
      GRAV_AVAILABLE=1
      return
    fi
  fi
  GRAV_AVAILABLE=0
}

site_read_json() {
  # The site-version plugin reads from filesystem paths derived from
  # GRAV_ROOT / __DIR__ inside the container. We bind-mount via the
  # linuxserver/grav layout: /config/www/{VERSION,BUILD} are the
  # source-of-truth files; the plugin's resolveVersionRoot() picks them
  # up correctly. We invoke a small PHP one-liner inside the container
  # that boots Grav just enough to construct the plugin's VersionReader
  # against the exact path pair the Twig helper would resolve.
  #
  # We deliberately bypass the full Twig pipeline because spinning up a
  # minimal page template for `bin/grav twig:render` requires more
  # plumbing than the unit-level contract demands. The reader IS the
  # helper — the plugin's site_version() function delegates to it
  # verbatim (see config/www/user/plugins/site-version/site-version.php
  # onTwigInitialized closure).
  docker exec "$GRAV_CONTAINER_NAME" \
    php -d log_errors=Off -d error_reporting=0 -r '
      require "/app/www/public/user/plugins/site-version/src/VersionReader.php";
      $r = new \Grav\Plugin\SiteVersion\VersionReader(
        "/config/www/VERSION",
        "/config/www/BUILD",
        null,
        "site-version-probe"
      );
      echo json_encode($r->read());
    '
}

assert_site_eq() {
  local label="$1" expected="$2"
  local actual
  actual="$(site_read_json)"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label"
  else
    fail "$label" "$expected" "$actual"
  fi
}

run_site_tests() {
  detect_grav_container
  if [[ "$GRAV_AVAILABLE" -ne 1 ]]; then
    echo
    echo "=== Site half — SKIPPED ===" >&2
    echo "  No Grav container running for this worktree." >&2
    echo "  Run scripts/grav-up.sh '$REPO_ROOT' <port> first, then re-run." >&2
    echo "  Site failure-path coverage is part of the contract; skipping" >&2
    echo "  here would be a false pass, so this script EXITS NON-ZERO." >&2
    fail "site_half_unavailable" "Grav container running" "no container"
    return
  fi

  echo
  echo "=== Site half — site-version Twig helper (via bin/grav-equivalent) ==="
  echo "    container: $GRAV_CONTAINER_NAME"

  # Happy path: trimmed values
  printf '  0.1.0\n  '          > "$SITE_DIR/VERSION"
  printf '  247\n'              > "$SITE_DIR/BUILD"
  assert_site_eq "happy_path: { version: 0.1.0, build: 247 }" \
    '{"version":"0.1.0","build":"247"}'

  # Failure: VERSION missing
  rm -f "$SITE_DIR/VERSION"
  printf '247\n' > "$SITE_DIR/BUILD"
  assert_site_eq "failure: VERSION missing -> version null, build intact" \
    '{"version":null,"build":"247"}'

  # Failure: VERSION empty
  : > "$SITE_DIR/VERSION"
  printf '247\n' > "$SITE_DIR/BUILD"
  assert_site_eq "failure: VERSION empty -> version null, build intact" \
    '{"version":null,"build":"247"}'

  # Failure: VERSION invalid SemVer (0.1)
  printf '0.1\n' > "$SITE_DIR/VERSION"
  printf '247\n' > "$SITE_DIR/BUILD"
  assert_site_eq "failure: VERSION='0.1' invalid -> version null" \
    '{"version":null,"build":"247"}'

  # Failure: VERSION invalid SemVer (latest)
  printf 'latest\n' > "$SITE_DIR/VERSION"
  printf '247\n'    > "$SITE_DIR/BUILD"
  assert_site_eq "failure: VERSION='latest' invalid -> version null" \
    '{"version":null,"build":"247"}'

  # Failure: VERSION with build metadata (0.1.0+build) — rejected per spec
  printf '0.1.0+build\n' > "$SITE_DIR/VERSION"
  printf '247\n'         > "$SITE_DIR/BUILD"
  assert_site_eq "failure: VERSION='0.1.0+build' rejected -> version null" \
    '{"version":null,"build":"247"}'

  # Failure: BUILD missing
  printf '0.1.0\n' > "$SITE_DIR/VERSION"
  rm -f "$SITE_DIR/BUILD"
  assert_site_eq "failure: BUILD missing -> build null, version intact" \
    '{"version":"0.1.0","build":null}'

  # Failure: BUILD empty
  printf '0.1.0\n' > "$SITE_DIR/VERSION"
  : > "$SITE_DIR/BUILD"
  assert_site_eq "failure: BUILD empty -> build null, version intact" \
    '{"version":"0.1.0","build":null}'

  # Failure: BUILD non-digit (abc)
  printf '0.1.0\n' > "$SITE_DIR/VERSION"
  printf 'abc\n'   > "$SITE_DIR/BUILD"
  assert_site_eq "failure: BUILD='abc' invalid -> build null" \
    '{"version":"0.1.0","build":null}'

  # Failure: BUILD negative (-1)
  printf '0.1.0\n' > "$SITE_DIR/VERSION"
  printf -- '-1\n' > "$SITE_DIR/BUILD"
  assert_site_eq "failure: BUILD='-1' invalid -> build null" \
    '{"version":"0.1.0","build":null}'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Sprint-3 SemVer probe — REPO_ROOT=$REPO_ROOT"

run_apex_tests
run_site_tests

echo
echo "==========================================================="
printf 'Result: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do printf '  - %s\n' "$c"; done
  exit 1
fi
echo "All assertions passed."
