#!/usr/bin/env bash
#
# Unit test for deploy/lib/htaccess.sh — the tier .htaccess renderer.
#
# Fixture-only (ADR-004): renders to stdout and asserts the text. No deploy,
# no ssh, no Apache. What Apache actually does with these directives is the
# documented gap — the rules below are the ones a reviewer can check by eye,
# and the ordering/shape assertions are what a careless edit would break.
#
# Why the canonical-host rule exists: every tier answers on a second name —
# production as the bare apex (byvaerkstederne.dk), the one.com tiers as a
# folder under hackersbychoice.dk. Grav picks its environment from the Host
# header, so those names load NO env profile and fall back to the all-on
# developer defaults. On 2026-08-15 production's apex served /vedtaegter,
# /privatlivspolitik, /referater and /presse with 200 while www 404'd all
# four.
#
# Coverage:
#   * canonical rule names the tier's own host, in both the condition and
#     the redirect target
#   * it precedes the http→https rule (one hop for wrong-host + plain http)
#   * it uses a per-directory relative target ($1), NOT %{REQUEST_URI} —
#     re-adding the stripped folder prefix would send
#     hackersbychoice.dk/test/x to test.hackersbychoice.dk/test/x
#   * the condition is negated, so the canonical host never redirects to
#     itself (loop guard)
#   * prod stays indexable; every other tier carries X-Robots-Tag noindex
#   * an unusable host is refused with no output at all (FAILURE PATH) —
#     a rendered-but-empty target would 301 the whole tier to https:///
#   * deploy.sh renders through this library rather than its own copy

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/htaccess.sh
. "$PROJECT_ROOT/deploy/lib/htaccess.sh"
DEPLOY_SH="$PROJECT_ROOT/deploy/deploy.sh"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}
has()     { printf '%s' "$3" | grep -qF -- "$2" && check "$1" ok || check "$1 (missing: $2)" fail; }
has_not() { printf '%s' "$3" | grep -qF -- "$2" && check "$1 (unexpected: $2)" fail || check "$1" ok; }

echo "Unit test: .htaccess renderer"
echo "---"

PROD="$(bv_render_htaccess www.byvaerkstederne.dk prod)"
TEST="$(bv_render_htaccess test.hackersbychoice.dk test)"
STAGING="$(bv_render_htaccess staging.hackersbychoice.dk staging)"

# ── Canonical host ──────────────────────────────────────────
has "prod: condition names the prod host" \
    'RewriteCond %{HTTP_HOST} !=www.byvaerkstederne.dk [NC]' "$PROD"
has "prod: redirect target is the prod host" \
    'RewriteRule ^(.*)$ https://www.byvaerkstederne.dk/$1 [R=301,L]' "$PROD"
has "test: condition names the test host" \
    'RewriteCond %{HTTP_HOST} !=test.hackersbychoice.dk [NC]' "$TEST"
has "staging: redirect target is the staging host" \
    'RewriteRule ^(.*)$ https://staging.hackersbychoice.dk/$1 [R=301,L]' "$STAGING"

# A tier must never carry another tier's host.
has_not "prod carries no hackersbychoice.dk host" 'hackersbychoice.dk' "$PROD"
has_not "test carries no byvaerkstederne.dk host" 'byvaerkstederne.dk' "$TEST"

# ── Ordering: canonical before http→https ───────────────────
canon_line="$(printf '%s\n' "$PROD" | grep -n 'RewriteCond %{HTTP_HOST}' | head -1 | cut -d: -f1)"
https_line="$(printf '%s\n' "$PROD" | grep -n 'RewriteCond %{HTTP:X-Forwarded-Proto}' | head -1 | cut -d: -f1)"
if [ -n "$canon_line" ] && [ -n "$https_line" ] && [ "$canon_line" -lt "$https_line" ]; then
    check "canonical rule precedes the http→https rule (one hop, not two)" ok
else
    check "canonical rule must precede the http→https rule (got $canon_line vs $https_line)" fail
fi

# The rewrite engine has to be on before either rule runs.
engine_line="$(printf '%s\n' "$PROD" | grep -n 'RewriteEngine On' | head -1 | cut -d: -f1)"
if [ -n "$engine_line" ] && [ "$engine_line" -lt "$canon_line" ]; then
    check "RewriteEngine On precedes the canonical rule" ok
else
    check "RewriteEngine On must precede the canonical rule" fail
fi

# ── The per-directory prefix trap ───────────────────────────
# In a per-directory context the tier folder is already stripped from the
# match, so the target must be built from $1. %{REQUEST_URI} still holds
# /test/x and would produce test.hackersbychoice.dk/test/x.
canon_rule="$(printf '%s\n' "$TEST" | grep 'https://test.hackersbychoice.dk/' | head -1)"
has_not "canonical rule does not use %{REQUEST_URI} (would re-add the folder)" \
    '%{REQUEST_URI}' "$canon_rule"
has "canonical rule builds its target from the relative match" '$1' "$canon_rule"

# ── Loop guard ──────────────────────────────────────────────
# The condition is negated: the canonical host itself never matches, so it
# cannot redirect to itself.
if printf '%s\n' "$PROD" | grep -q 'RewriteCond %{HTTP_HOST} !=www.byvaerkstederne.dk'; then
    check "canonical host is excluded by a negated condition (no self-redirect)" ok
else
    check "canonical condition must be negated (=, not !=, is an infinite loop)" fail
fi

# ── Indexability ────────────────────────────────────────────
has_not "prod is indexable (no X-Robots-Tag)" 'X-Robots-Tag' "$PROD"
has "test carries X-Robots-Tag noindex" 'X-Robots-Tag "noindex, nofollow, noarchive"' "$TEST"
has "staging carries X-Robots-Tag noindex" 'X-Robots-Tag "noindex, nofollow, noarchive"' "$STAGING"

# ── Everything the file carried before is still there ───────
has "still gates .yaml/.md/.twig from the web"  'FilesMatch "(^\.git|\.yaml$|\.md$|\.twig$)"' "$PROD"
has "still denies version.json"                 '<Files "version.json">' "$PROD"
has "still sets HSTS"                           'Strict-Transport-Security' "$PROD"
has "still routes unmatched paths to index.php" 'RewriteRule ^(.*)$ index.php [QSA,L]' "$PROD"
has "still trusts X-Forwarded-Proto (Varnish)"  'SetEnvIf X-Forwarded-Proto https HTTPS=on' "$PROD"

# ── FAILURE PATH: an unusable host is refused, not rendered ─
for bad in "" "https://www.example.com" "www.example.com/path" "a host" 'host;rm -rf /' "-leading-dash"; do
    # `if` context, not `out=$(…) || true`: a refusal must be observable
    # without set -e taking the test down with it.
    if out="$(bv_render_htaccess "$bad" prod 2>/dev/null)"; then :; else out=""; fi
    if [ -z "$out" ]; then
        check "refuses host '${bad:-<empty>}' with no output" ok
    else
        check "host '${bad:-<empty>}' must be refused, but a file was rendered" fail
    fi
done
if bv_render_htaccess "www.example.com" prod >/dev/null 2>&1; then
    check "a plain hostname is accepted" ok
else
    check "a plain hostname must be accepted" fail
fi

# ── deploy.sh renders through this library ──────────────────
if grep -q 'bv_render_htaccess "\$ENV_HOST" "\$ENV"' "$DEPLOY_SH"; then
    check "deploy.sh renders via bv_render_htaccess (single source)" ok
else
    check "deploy.sh must render via bv_render_htaccess" fail
fi
if grep -q "cat > \"\$STAGING_DIR/.htaccess\" << 'HTACCESS'" "$DEPLOY_SH"; then
    check "deploy.sh keeps no second copy of the .htaccess body" fail
else
    check "deploy.sh keeps no second copy of the .htaccess body" ok
fi

echo "---"
echo "htaccess: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
