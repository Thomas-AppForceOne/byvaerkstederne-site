#!/usr/bin/env bash
#
# Unit test for deploy/lib/php-handler.sh — preserve and validate, never
# generate.
#
# THE FAILURE THIS PINS
# ---------------------
# On cPanel the PHP version a domain is served with is chosen in MultiPHP
# Manager, and the panel expresses that choice as an AddHandler line in the
# domain's .htaccess. This repo also generates and ships that file, so a
# deploy overwrote the choice and dropped the domain to the system default.
# Caught on 2026-08-22, the day prod was moved to ea-php85: the pending
# deploy would have reverted it, and the parity guard — which reads the
# SHELL PHP, a separate cPanel setting that does not move — would have
# reported drift, been dismissed as a false alarm, and then caused it.
#
# WHY NOT JUST GENERATE THE LINE
# ------------------------------
# The first attempt did, from .php-version. It was the wrong shape: the
# line is cPanel's OUTPUT, not our configuration. Writing it forges a value
# another system owns, so its UI can disagree with the file; an EasyApache
# rebuild rewrites it and the next deploy writes ours back; and if PHP-FPM
# is ever enabled the directive stops being the mechanism at all, leaving
# us maintaining a decoration while believing we control the version.
#
# So the panel stays the source of truth, the deploy carries the line
# forward, and the repo's job is to refuse when the tier disagrees with
# .php-version.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/php-handler.sh
. "$PROJECT_ROOT/deploy/lib/php-handler.sh"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}

echo "Unit test: PHP handler — preserve and validate"
echo "---"

REAL='# Set the “ea-php85” package as the default “PHP” programming language.
  AddHandler application/x-httpd-ea-php85 .php .php8 .phtml'
NONE='RewriteEngine On
<FilesMatch "\.yaml$">
    Require all denied
</FilesMatch>'

# ── Extraction ───────────────────────────────────────────────────────
LINE="$(bv_php_handler_line "$REAL")"
check "the handler line is found in real cPanel output" \
    "$(printf '%s' "$LINE" | grep -q 'ea-php85' && echo ok || echo no)"
check "the comment above it is not mistaken for the directive" \
    "$(printf '%s' "$LINE" | grep -q '^[[:space:]]*AddHandler' && echo ok || echo no)"
check "an .htaccess without a handler yields nothing" \
    "$([ -z "$(bv_php_handler_line "$NONE")" ] && echo ok || echo no)"

check "ea-php85 reads as 8.5" \
    "$([ "$(bv_php_handler_version "$LINE")" = "8.5" ] && echo ok || echo no)"
check "ea-php84 reads as 8.4" \
    "$([ "$(bv_php_handler_version 'AddHandler application/x-httpd-ea-php84 .php')" = "8.4" ] && echo ok || echo no)"
check "a non-ea handler is parsed too" \
    "$([ "$(bv_php_handler_version 'AddHandler application/x-httpd-php83 .php')" = "8.3" ] && echo ok || echo no)"
check "an unparseable line yields nothing, not garbage" \
    "$([ -z "$(bv_php_handler_version 'AddHandler application/x-httpd-php .php')" ] && echo ok || echo no)"

# ── The check ────────────────────────────────────────────────────────
run() { bv_php_handler_check "$1" "$2" "$3" "${4:-0}" >/dev/null 2>&1; }

check "a matching handler passes" \
    "$(run '8.5' 'AddHandler application/x-httpd-ea-php85 .php' prod && echo ok || echo no)"
check "a MISMATCHED handler is refused" \
    "$(run '8.5' 'AddHandler application/x-httpd-ea-php84 .php' prod && echo no || echo ok)"
check "no handler at all is reported, not failed (non-cPanel tiers)" \
    "$(run '8.5' '' dev && echo ok || echo no)"
check "ALLOW_PHP_MISMATCH=1 overrides" \
    "$(run '8.5' 'AddHandler application/x-httpd-ea-php84 .php' prod 1 && echo ok || echo no)"
check "an unparseable handler soft-skips rather than blocking" \
    "$(run '8.5' 'AddHandler application/x-httpd-php .php' prod && echo ok || echo no)"

msg="$(bv_php_handler_check '8.5' 'AddHandler application/x-httpd-ea-php84 .php' prod 0 2>&1 || true)"
check "the refusal quotes the offending line" \
    "$(printf '%s' "$msg" | grep -q 'ea-php84' && echo ok || echo no)"
check "the refusal says the deploy will NOT change it" \
    "$(printf '%s' "$msg" | grep -qi 'will NOT change' && echo ok || echo no)"
check "the refusal points at the hosting panel, not a file in this repo" \
    "$(printf '%s' "$msg" | grep -qi 'MultiPHP Manager' && echo ok || echo no)"
check "the refusal names the override" \
    "$(printf '%s' "$msg" | grep -q 'ALLOW_PHP_MISMATCH' && echo ok || echo no)"

# ── The renderer must NOT invent a handler ───────────────────────────
#
# This is the assertion that keeps the design honest: if someone reaches
# for "just generate it" again, the suite says no.
# shellcheck source=deploy/lib/htaccess.sh
. "$PROJECT_ROOT/deploy/lib/htaccess.sh"
for tier_host in "prod:www.byvaerkstederne.dk" "staging:staging.hackersbychoice.dk" "dev:dev.hackersbychoice.dk"; do
    t="${tier_host%%:*}"; h="${tier_host#*:}"
    rendered="$(bv_render_htaccess "$h" "$t" 2>/dev/null || true)"
    check "$t: the generated .htaccess invents no PHP handler" \
        "$(printf '%s' "$rendered" | grep -q 'AddHandler application/x-httpd' && echo no || echo ok)"
done

check "deploy.sh preserves the tier's handler line" \
    "$(grep -q 'PRESERVED_PHP_HANDLER' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"
check "deploy.sh validates it" \
    "$(grep -q 'bv_php_handler_check' "$PROJECT_ROOT/deploy/deploy.sh" && echo ok || echo no)"

# ── A failed read is not an answer about the tier ────────────────────
#
# The handler read used to be one pipeline ending in `2>/dev/null |
# bv_php_handler_line || true`, so the parser's status masked the SSH
# status and a connection failure looked exactly like "this tier has no
# handler line". Empty passes the check, the re-attach is skipped, and the
# .htaccess ships without an AddHandler — on prod, a silent downgrade to
# the system default PHP.
# Comment lines are stripped: the block's own prose names the very
# patterns it forbids, and a lint that cannot tell code from the
# explanation of code is worse than none.
READ_BLOCK="$(awk '/3a4\. PHP handler line/,/^PRESERVED_PHP_HANDLER=/' "$PROJECT_ROOT/deploy/deploy.sh" \
    | grep -v '^[[:space:]]*#')"

check "the handler read's own exit status is checked" \
    "$(printf '%s' "$READ_BLOCK" | grep -q 'if ! HTACCESS_RAW=' && echo ok || echo no)"
check "a failed read aborts instead of continuing" \
    "$(printf '%s' "$READ_BLOCK" | grep -q 'exit 1' && echo ok || echo no)"
check "the read does not discard stderr" \
    "$(printf '%s' "$READ_BLOCK" | grep -q '2>/dev/null' && echo no || echo ok)"
check "the read is not piped straight into the parser" \
    "$(printf '%s' "$READ_BLOCK" | grep -qE "bv_remote_run.*\\| *bv_php_handler_line" && echo no || echo ok)"
# The empty case must still be reachable for a tier that genuinely has no
# line — the abort is about transport, not about absence.
check "a successful read of an absent line still yields empty, not an abort" \
    "$([ -z "$(bv_php_handler_line </dev/null || true)" ] && echo ok || echo no)"

echo "---"
echo "php handler unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
