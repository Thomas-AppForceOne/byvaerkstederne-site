#!/usr/bin/env bash
#
# Byværkstederne — .htaccess renderer for the Grav tiers.
#
# Extracted from deploy.sh so the file can be asserted by a fixture-only
# unit test (ADR-004). deploy.sh renders it into the deploy package; this
# library is the single source of its content.
#
# Usage:
#   bv_render_htaccess <canonical-host> <tier>      # prints to stdout
#
#   canonical-host  the one hostname this tier answers on, e.g.
#                   www.byvaerkstederne.dk. Everything else 301s to it.
#   tier            dev|test|staging|prod — only prod is left indexable.

# Render the tier's .htaccess to stdout.
#
# Returns 1 (printing nothing) on an unusable host, so a caller that
# redirects stdout into a file cannot silently produce an .htaccess whose
# redirect target is empty — that would send every request to `https:///`.
bv_render_htaccess() {
    # Deliberately NOT ${1:?...}: that aborts the calling shell instead of
    # returning, so a caller testing the refusal path would be killed by the
    # refusal itself. This function's contract is "refuse cleanly".
    local host="${1:-}"
    local tier="${2:-}"

    if [ -z "$tier" ]; then
        echo "FATAL: bv_render_htaccess: tier required (dev|test|staging|prod)" >&2
        return 1
    fi

    # The host is interpolated into a redirect target and a RewriteCond, so
    # it must be a bare hostname: letters, digits, dots and dashes, starting
    # alphanumeric. No scheme, no path, no whitespace, no metacharacters.
    if ! printf '%s' "$host" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9.-]*$'; then
        echo "FATAL: bv_render_htaccess: '$host' is not a bare hostname" >&2
        return 1
    fi

    cat << 'HTACCESS_HEAD'
# Grav CMS .htaccess for one.com shared hosting (Varnish → Apache).

SetEnvIf X-Forwarded-Proto https HTTPS=on

<IfModule mod_rewrite.c>
    RewriteEngine On

HTACCESS_HEAD

    # ── Canonical host ─────────────────────────────────────────────────
    # Every tier is reachable under a second name: prod as the bare apex
    # (byvaerkstederne.dk), the one.com tiers as a folder under
    # hackersbychoice.dk. Grav resolves its environment from the Host
    # header, so those names match no user/env/<host>/ directory and fall
    # back to the all-on developer defaults — on 2026-08-15 the apex
    # answered 200 for /vedtaegter, /privatlivspolitik, /referater and
    # /presse while www 404'd all four. One canonical name per tier; the
    # rest are a 301.
    #
    # This is a PER-DIRECTORY rule: the pattern matches the path relative
    # to the directory holding this file, so a tier's folder prefix
    # (/test, /staging) is already stripped and must not be re-added —
    # hackersbychoice.dk/test/x lands on test.hackersbychoice.dk/x, not
    # /test/x. That is also why it cannot reuse %{REQUEST_URI} the way the
    # http→https rule below does.
    #
    # It runs BEFORE that rule so a wrong-host plain-http request takes one
    # hop rather than two. Two hops through one.com's Varnish is how the
    # earlier redirect loop started (see the X-Forwarded-Proto gate).
    cat << HTACCESS_CANONICAL
    RewriteCond %{HTTP_HOST} !=${host} [NC]
    RewriteRule ^(.*)\$ https://${host}/\$1 [R=301,L]

HTACCESS_CANONICAL

    cat << 'HTACCESS_REWRITE'
    RewriteCond %{HTTP:X-Forwarded-Proto} !=https
    RewriteCond %{HTTPS} !=on
    RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]

    RewriteCond %{REQUEST_FILENAME} !-f
    RewriteCond %{REQUEST_FILENAME} !-d
    RewriteRule ^(.*)$ index.php [QSA,L]
</IfModule>

<IfModule mod_headers.c>
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
HTACCESS_REWRITE

    if [ "$tier" != "prod" ]; then
        cat << 'NOINDEX'
    Header always set X-Robots-Tag "noindex, nofollow, noarchive"
NOINDEX
    fi

    cat << 'HTACCESS_REST'
</IfModule>

<FilesMatch "(^\.git|\.yaml$|\.md$|\.twig$|\.log$|\.jsonl$)">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
</FilesMatch>

# The Grav log directory. `.log$` above covers the files by extension, but the
# directory is denied outright so a rotated or oddly-named log cannot leak
# either. Found live on 2026-08-21: https://<host>/logs/grav.log served 81 KB
# of production operational detail with a 200, on every tier.
<IfModule mod_alias.c>
    RedirectMatch 404 ^/logs(/|$)
</IfModule>

<IfModule mod_expires.c>
    ExpiresActive On
    # HTML FIRST, and explicitly. `ExpiresActive On` activates the host's own
    # ExpiresDefault for every MIME type not named here — on both one.com and
    # chosting that default is a week, so pages were served with
    # `Cache-Control: max-age=604800`. A member who saw the calendar today
    # would not see a newly published event for seven days, and nobody
    # noticed because developers hard-refresh and only production has
    # returning visitors. Pages must always revalidate.
    ExpiresByType text/html "access plus 0 seconds"
    ExpiresDefault "access plus 0 seconds"
    ExpiresByType image/jpeg "access plus 1 month"
    ExpiresByType image/png "access plus 1 month"
    ExpiresByType image/svg+xml "access plus 1 month"
    ExpiresByType image/webp "access plus 1 month"
    ExpiresByType text/css "access plus 1 week"
    ExpiresByType application/javascript "access plus 1 week"
    ExpiresByType font/woff2 "access plus 1 month"
</IfModule>

<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/html text/css application/javascript application/json image/svg+xml
</IfModule>

<Files "version.json">
    <IfModule mod_authz_core.c>
        Require all denied
    </IfModule>
</Files>

HTACCESS_REST
}
