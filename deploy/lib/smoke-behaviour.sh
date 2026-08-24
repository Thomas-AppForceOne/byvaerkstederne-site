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
    #
    # TWO measurements, because a tier behind Varnish (one.com fronts dev,
    # test and staging) can answer differently at the edge and at the origin.
    # The first deploy of the deny rules to test proved it: the origin
    # returned 403 while Varnish replayed a cached 200 from before the fix,
    # age 73s. Probing only the edge reports a failure that is not the
    # deploy's, and probing only the origin misses that visitors can still
    # read the file until the entry expires.
    #
    # The cache-busted request is the GATE — it asks whether THIS deploy
    # configured the host correctly, which is what the deploy is responsible
    # for. The plain request is a WARNING: the config is right, but the edge
    # is still handing out the old answer and wants a purge.
    local origin_status edge_status
    origin_status="$(bv_probe_status "$base/logs/grav.log?cache-bust=$$")"
    edge_status="$(bv_probe_status "$base/logs/grav.log")"

    if [ "$origin_status" = "200" ]; then
        printf '  ✗ /logs/grav.log is publicly readable at the origin (HTTP 200)\n' >&2
        printf '      The .htaccess deny rules are not in effect on this host.\n' >&2
        failures=$((failures + 1))
    else
        printf '  ✓ /logs/grav.log is not readable (origin HTTP %s)\n' "$origin_status"
        if [ "$edge_status" = "200" ]; then
            printf '  ⚠  but an upstream cache is still serving it (edge HTTP 200).\n' >&2
            printf '      The origin is fixed; visitors keep reading the old answer until\n' >&2
            printf '      the entry expires. Purge the CDN/Varnish cache for this host.\n' >&2
        fi
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

    # 4. A CONTENT page answers too — not just the homepage.
    #
    # The homepage is modular and does not run a page body through Grav's
    # markdown pipeline, so it survives failures that break every ordinary
    # page. On 2026-08-24 that is exactly what happened: after a Grav
    # 1.7 → 2.0 deploy `/` answered 200 and this probe passed, while
    # /login, /vaerksteder and /kontakt were all returning 500 from
    # onMarkdownInitialized. A green deploy on a broken tier.
    #
    # So probe something that renders a real markdown body. The default is
    # ungated on every tier — verified 200 on dev, test, staging and prod —
    # which matters because a flag-gated path would 404 on the tiers where
    # its flag is off and this check would fail for the wrong reason.
    local content_path content_status
    content_path="${BV_SMOKE_CONTENT_PATH:-/vaerksteder}"
    content_status="$(bv_probe_status "$base$content_path")"
    if [ "$content_status" != "200" ]; then
        printf '  ✗ content page %s returned HTTP %s\n' "$content_path" "$content_status" >&2
        printf '    The homepage can answer 200 while every markdown-rendered page is\n' >&2
        printf '    broken — that is the shape this check exists to catch.\n' >&2
        failures=$((failures + 1))
    else
        printf '  ✓ content page %s answers 200 (markdown renders)\n' "$content_path"
    fi

    [ "$failures" -eq 0 ]
}
