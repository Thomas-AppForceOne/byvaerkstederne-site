#!/usr/bin/env bash
#
# Unit test for deploy/lib/php-parity.sh and the repo-wide agreement it
# enforces.
#
# THE FAILURE THIS PINS
# ---------------------
# The 2026-08-21 audit found five PHP versions in play with no overlap:
# the container ran 8.3, CI tested 8.1–8.3, one.com served 8.5 and prod
# served 8.4. No version that ran the code was tested and no tested
# version ran anywhere — and nothing in the repo compared the numbers, so
# it stayed invisible until production behaved differently from every
# other tier.
#
# Two halves are asserted here:
#   1. the CHECK behaves (match / mismatch / override / soft cases), and
#   2. the REPO agrees with itself — .php-version, the CI matrix and the
#      pinned container image cannot drift apart silently.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/php-parity.sh
. "$PROJECT_ROOT/deploy/lib/php-parity.sh"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}

echo "Unit test: PHP version parity"
echo "---"

# ── 1. Version normalisation ─────────────────────────────────────────
check "bare version normalises" \
    "$([ "$(bv_php_major_minor '8.3')" = "8.3" ] && echo ok || echo no)"
check "patch version reduces to major.minor" \
    "$([ "$(bv_php_major_minor '8.3.15')" = "8.3" ] && echo ok || echo no)"
check "a full 'php -v' banner is parsed" \
    "$([ "$(bv_php_major_minor 'PHP 8.4.24 (cli) (built: Aug 12 2026 00:00:00) (NTS)')" = "8.4" ] && echo ok || echo no)"
check "empty input yields empty, not garbage" \
    "$([ -z "$(bv_php_major_minor '')" ] && echo ok || echo no)"

# ── 2. The check itself ──────────────────────────────────────────────
run_check() { bv_php_parity_check "$1" "$2" "$3" "${4:-0}" >/dev/null 2>&1; }

check "matching major.minor passes" \
    "$(run_check '8.3' 'PHP 8.3.15 (cli)' dev && echo ok || echo no)"
check "patch drift within the same minor still passes" \
    "$(run_check '8.3' 'PHP 8.3.99 (cli)' dev && echo ok || echo no)"
check "prod on 8.4 against a 8.3 target is REFUSED" \
    "$(run_check '8.3' 'PHP 8.4.24 (cli)' prod && echo no || echo ok)"
check "one.com on 8.5 against a 8.3 target is REFUSED" \
    "$(run_check '8.3' 'PHP 8.5.9' test && echo no || echo ok)"
check "an older minor is refused too (drift is drift)" \
    "$(run_check '8.3' 'PHP 8.1.2' dev && echo no || echo ok)"
check "ALLOW_PHP_MISMATCH=1 overrides the refusal" \
    "$(run_check '8.3' 'PHP 8.4.24 (cli)' prod 1 && echo ok || echo no)"
check "an unreadable remote version soft-skips rather than blocking" \
    "$(run_check '8.3' '' prod && echo ok || echo no)"
check "no declared target soft-skips" \
    "$(run_check '' 'PHP 8.4.24 (cli)' prod && echo ok || echo no)"

# The refusal must be actionable, not just a number mismatch.
msg="$(bv_php_parity_check '8.3' 'PHP 8.4.24' prod 0 2>&1 || true)"
check "refusal names both versions" \
    "$(printf '%s' "$msg" | grep -q '8.4' && printf '%s' "$msg" | grep -q '8.3' && echo ok || echo no)"
check "refusal tells a prod operator where to change it" \
    "$(printf '%s' "$msg" | grep -qi 'MultiPHP' && echo ok || echo no)"
check "refusal names the override" \
    "$(printf '%s' "$msg" | grep -q 'ALLOW_PHP_MISMATCH' && echo ok || echo no)"
msg_dev="$(bv_php_parity_check '8.3' 'PHP 8.5.9' test 0 2>&1 || true)"
check "refusal points a one.com tier at the right control panel" \
    "$(printf '%s' "$msg_dev" | grep -qi 'one.com' && echo ok || echo no)"

# ── 3. The repo agrees with itself ───────────────────────────────────
TARGET="$(bv_php_target "$PROJECT_ROOT" || true)"
check ".php-version exists and declares a version" \
    "$([ -n "$TARGET" ] && echo ok || echo no)"
check ".php-version is a bare MAJOR.MINOR" \
    "$(printf '%s' "$TARGET" | grep -qE '^[0-9]+\.[0-9]+$' && echo ok || echo no)"

COMPOSE="$PROJECT_ROOT/docker-compose.yml"
DOCKERFILE="$PROJECT_ROOT/Dockerfile"

# The container is BUILT, not pulled, so PHP and Grav can be pinned
# separately. A single prebuilt image welded them: pulling a newer one to
# get a newer PHP dragged the local CMS a major version ahead of every tier.
check "the container is built from a Dockerfile, not a prebuilt image" \
    "$(grep -qE '^\s*build:' "$COMPOSE" && echo ok || echo no)"
check "the PHP base is pinned by digest, not a floating tag" \
    "$(grep -qE '^ARG PHP_BASE=.*@sha256:[0-9a-f]{64}' "$DOCKERFILE" && echo ok || echo no)"
check "the PHP base is NOT :latest" \
    "$(grep -qE '^ARG PHP_BASE=.*:latest' "$DOCKERFILE" && echo no || echo ok)"
check "the image carries a Grav version argument" \
    "$(grep -qE '^ARG GRAV_VERSION=' "$DOCKERFILE" && echo ok || echo no)"

# The declared target must be one CI actually exercises, or the guard
# points every tier at a version nothing has tested.
MIGRATIONS_WF="$PROJECT_ROOT/.github/workflows/migrations.yml"
if [ -f "$MIGRATIONS_WF" ]; then
    check "the declared target appears in the CI PHP matrix" \
        "$(grep -E "php-version:\s*\[" "$MIGRATIONS_WF" | grep -q "'$TARGET'" && echo ok || echo no)"
else
    echo "  · migrations workflow absent — CI matrix check skipped"
fi

check "deploy.sh sources the parity lib" \
    "$(grep -q 'lib/php-parity.sh' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"
check "deploy.sh actually calls the check" \
    "$(grep -q 'bv_php_parity_check' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"

# ── The remote binary (cPanel's two PHP settings) ────────────────────
#
# prod is cPanel, where the version a DOMAIN is served with and the version
# the SHELL gets are separate settings. The domain runs ea-php85; the system
# default is 8.4 and is "set by the system administrator" — not changeable
# from the account. So plain `php` over SSH is 8.4 there while pages render
# on 8.5.
#
# Everything triggered over HTTP already runs 8.5, including Grav's
# scheduler (prod's crontab is empty; the scheduler-trigger plugin fires it
# via HTTP). Only what we invoke over SSH was left behind.
PRODBIN="$(bv_php_remote_bin prod "$PROJECT_ROOT")"
DEVBIN="$(bv_php_remote_bin dev "$PROJECT_ROOT")"

check "prod resolves a versioned cPanel binary" \
    "$(printf '%s' "$PRODBIN" | grep -q 'ea-php' && echo ok || echo no)"
check "the prod binary carries the declared target" \
    "$(printf '%s' "$PRODBIN" | grep -q "ea-php$(tr -d '.\n' < "$PROJECT_ROOT/.php-version")" && echo ok || echo no)"
# A plain path, not a shell expression: callers interpolate it into remote
# commands and deploy.sh passes it through bv_remote_run's %q-quoted
# dispatch, which an expression would defeat (lint-remote-ssh.sh refuses it).
check "prod resolves to a plain path, not a shell expression" \
    "$(printf '%s' "$PRODBIN" | grep -qE '^/[A-Za-z0-9/._-]+$' && echo ok || echo no)"
check "one.com tiers keep plain php (not cPanel)" \
    "$([ "$DEVBIN" = "php" ] && echo ok || echo no)"
check "staging and test keep plain php too" \
    "$([ "$(bv_php_remote_bin staging "$PROJECT_ROOT")" = "php" ] && [ "$(bv_php_remote_bin test "$PROJECT_ROOT")" = "php" ] && echo ok || echo no)"

# Every remote PHP invocation must go through the resolved binary, or the
# tier silently runs a different PHP than the one the guard checked.
BARE=0
for f in "$PROJECT_ROOT"/deploy/*.sh; do
    # Skip comments and advice text — an echo suggesting a command a human
    # might type is not an invocation this tooling makes.
    # Exclude comments and lines that ARE advice text (starting with echo or
    # printf). Not lines that merely contain printf — `printf %q` is how these
    # scripts quote remote arguments, and excluding those hid two real call
    # sites in the promote scripts.
    grep -vE '^[[:space:]]*(#|echo|printf)[[:space:]]' "$f" \
        | grep -qE '[^A-Z_$/-]php (bin/|-- )' \
        && { echo "     bare php in $(basename "$f")" >&2; BARE=$((BARE+1)); }
done
check "no deploy script invokes a bare remote php" \
    "$([ "$BARE" -eq 0 ] && echo ok || echo no)"

# ── The binary must exist before we compare versions ─────────────────
#
# bv_php_remote_bin derives a versioned cPanel path from .php-version. Bump
# the target to a version the host has not installed and every remote
# command breaks with "no such file or directory", from sixteen call sites,
# none of which explain it. Fail once, early, with the reason.
bchk() { bv_php_binary_check "$1" "$2" "$3" >/dev/null 2>&1; }

check "a present binary passes" \
    "$(bchk present /opt/cpanel/ea-php85/root/usr/bin/php prod && echo ok || echo no)"
check "an ABSENT binary is refused" \
    "$(bchk absent /opt/cpanel/ea-php99/root/usr/bin/php prod && echo no || echo ok)"
check "plain php needs no check (resolved via PATH)" \
    "$(bchk absent php dev && echo ok || echo no)"

bmsg="$(bv_php_binary_check absent /opt/cpanel/ea-php99/root/usr/bin/php prod 2>&1 || true)"
check "the refusal names the missing path" \
    "$(printf '%s' "$bmsg" | grep -q 'ea-php99' && echo ok || echo no)"
check "the refusal says where the path came from" \
    "$(printf '%s' "$bmsg" | grep -q '.php-version' && echo ok || echo no)"
check "the refusal explains why it does not fall back" \
    "$(printf '%s' "$bmsg" | grep -qi 'drift' && echo ok || echo no)"

# ── The version refusal must read correctly during a rollout ─────────
#
# .php-version moves once; the tiers move one at a time. Every tier still on
# the old version disagrees until you reach it, so the refusal has to tell a
# rollout apart from unintended drift or it reads as "something is broken".
rmsg="$(bv_php_parity_check '8.6' 'PHP 8.5.9' dev 0 2>&1 || true)"
check "the refusal recognises a rollout" \
    "$(printf '%s' "$rmsg" | grep -qi 'IF THIS IS A ROLLOUT' && echo ok || echo no)"
check "the refusal gives the tier order" \
    "$(printf '%s' "$rmsg" | grep -q 'dev, test,' && echo ok || echo no)"
check "the refusal spells out the rollout command" \
    "$(printf '%s' "$rmsg" | grep -q 'ALLOW_PHP_MISMATCH=1 make deploy tier=' && echo ok || echo no)"
check "deploy.sh checks the binary before comparing versions" \
    "$(awk '/bv_php_binary_check/{b=NR} /bv_php_parity_check/{p=NR} END{exit !(b && p && b<p)}' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"

echo "---"
echo "php parity unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
