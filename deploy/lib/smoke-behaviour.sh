#!/usr/bin/env bash
#
# smoke-behaviour.sh — post-deploy probes that only the real tier can answer.
#
# WHY A SEPARATE LAYER
# -------------------
# Every other guard in this repo runs against a local container: same OS,
# same webserver, same PHP, same filesystem. That makes them blind to the
# half of production that is not our code — the host's Apache/LiteSpeed
# defaults, its PHP build, its MIME handling. The 2026-08-21 audit found two
# defects living exactly there, on every tier, for months:
#
#   * https://<host>/logs/grav.log returned 200 with 81 KB of operational
#     detail. The generated .htaccess denied .yaml/.md/.twig, never .log.
#   * Pages were served Cache-Control: max-age=604800. `ExpiresActive On`
#     enabled the HOST's ExpiresDefault for any MIME type we had not
#     enumerated, and text/html was not enumerated. A member saw a week-old
#     calendar; a developer never did, because developers hard-refresh and
#     only production has returning visitors.
#
# Both are fixed in deploy/lib/htaccess.sh and unit-tested there. These
# probes exist so that if a host changes its defaults, or a hand-edited
# .htaccess loses a rule, the deploy that introduces it says so.
#
# CONTRACT
# --------
# Matches the version smoke probe above it: fail LOUD, never auto-rollback.
# The release stays live; the operator decides. Returns non-zero if any
# probe fails, having printed each result.

# Fetch just the headers for a URL. Echoes nothing on transport failure.
bv_probe_headers() {
    curl -s -o /dev/null -D - -m 20 -A 'byv-deploy-smoke/1' "$1" 2>/dev/null || true
}

bv_probe_status() {
    curl -s -o /dev/null -w '%{http_code}' -m 20 -A 'byv-deploy-smoke/1' "$1" 2>/dev/null || echo 000
}

# bv_post_deploy_smoke <base_url>
# Probes behaviour the local test suite structurally cannot see.
bv_post_deploy_smoke() {
    local base="${1%/}"
    local failures=0

    # 1. The Grav log must not be readable over the web.
    local log_status
    log_status="$(bv_probe_status "$base/logs/grav.log")"
    if [ "$log_status" = "200" ]; then
        printf '  ✗ /logs/grav.log is publicly readable (HTTP 200)\n' >&2
        printf '      The .htaccess deny rules are not in effect on this host.\n' >&2
        failures=$((failures + 1))
    else
        printf '  ✓ /logs/grav.log is not readable (HTTP %s)\n' "$log_status"
    fi

    # 2. Pages must revalidate. Anything beyond a minute means a visitor can
    #    be served stale content after a deploy — the deploy this probe is
    #    reporting on would be invisible to them.
    local headers max_age
    headers="$(bv_probe_headers "$base/")"
    max_age="$(printf '%s' "$headers" | tr -d '\r' \
        | grep -i '^cache-control:' | grep -oE 'max-age=[0-9]+' | head -1 | cut -d= -f2)"
    if [ -n "$max_age" ] && [ "$max_age" -gt 60 ] 2>/dev/null; then
        printf '  ✗ HTML is cached for %ss (Cache-Control: max-age=%s)\n' "$max_age" "$max_age" >&2
        printf '      Returning visitors will not see this release for up to that long.\n' >&2
        failures=$((failures + 1))
    else
        printf '  ✓ HTML revalidates (max-age=%s)\n' "${max_age:-unset}"
    fi

    # 3. The tier answers at all. Cheap, and it catches a swap that wired a
    #    release nothing can serve.
    local home_status
    home_status="$(bv_probe_status "$base/")"
    if [ "$home_status" != "200" ]; then
        printf '  ✗ homepage returned HTTP %s\n' "$home_status" >&2
        failures=$((failures + 1))
    else
        printf '  ✓ homepage answers 200\n'
    fi

    [ "$failures" -eq 0 ]
}
