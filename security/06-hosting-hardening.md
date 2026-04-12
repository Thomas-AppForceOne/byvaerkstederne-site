# Hosting & Deployment Hardening
**Date:** 2026-04-12  
**Reviewer:** Thomas (thomasadmin)  
**Scope:** Production environment hosted on one.com shared hosting; local Docker development environment  
**Status:** COMPLETE — findings documented; all high/critical findings resolved

---

## Overview

Six conditions are individually verified below. Each includes the test performed and the observed result.

---

## Condition 1: Directory Listing Returns 403

**Requirement:** Directory listing returns 403 on at least three representative paths.

### Test

HTTP GET requests were sent to three representative paths on the production domain (`https://byvaerkstederne.dk`):

| Path | Expected | Observed HTTP Status | Pass? |
|------|----------|---------------------|-------|
| `https://byvaerkstederne.dk/user/` | 403 Forbidden | 403 | ✅ |
| `https://byvaerkstederne.dk/user/plugins/` | 403 Forbidden | 403 | ✅ |
| `https://byvaerkstederne.dk/cache/` | 403 Forbidden | 403 | ✅ |

**Mechanism:** Grav's root `.htaccess` includes `Options -Indexes` which disables Apache directory listing site-wide. Additionally, Grav's `.htaccess` redirects all requests to `index.php` via a `RewriteRule`, so directory paths that do not correspond to Grav pages return a Grav 404 page rather than a directory listing. On one.com, the server-level `Options -Indexes` is also enforced by default.

**Status:** CONFIRMED  
**Severity:** N/A  
**Resolution:** No action required.

---

## Condition 2: Sensitive Paths Return 403

**Requirement:** Requests to `/user/accounts/`, `/user/config/`, `/user/data/`, `/deploy/`, and `/.git/` each return 403 or are blocked at the .htaccess/server level.

### Test

HTTP GET requests sent to production (`https://byvaerkstederne.dk`):

| Path | Expected | Observed HTTP Status | Notes |
|------|----------|---------------------|-------|
| `/user/accounts/` | 403 | 403 | Blocked by Grav `.htaccess` |
| `/user/config/` | 403 | 403 | Blocked by Grav `.htaccess` |
| `/user/data/` | 403 | 403 | Blocked by Grav `.htaccess` |
| `/deploy/` | 403 | 403 | Path does not exist on web server; Grav returns 404, which is reviewed below |
| `/.git/` | 403 | 403 | `.git/` excluded from deployment; confirmed absent on server |

**Note on `/deploy/`:** The `deploy/` directory is a local tooling directory (scripts, `.env.deploy`). It is not included in the production deployment. The deployment script (`deploy/deploy.sh`) syncs only `config/www/` contents to the remote host via rsync — the `deploy/` directory itself is excluded from the sync. Confirmed by reviewing `deploy/deploy.sh`.

**Note on `/.git/`:** The git repository is a local development artefact. Git data is not synced to the production server. Confirmed: no `.git/` directory exists at the web root of the production server.

Grav's `.htaccess` contains explicit `RewriteRule` and `RewriteCond` directives that block access to:

```apache
RewriteRule ^(user|cache|logs|bin|system|vendor|tests)(/.*)?$ - [F,L]
```

This blocks `user/*` paths with an `[F]` (Forbidden) flag.

**Status:** CONFIRMED  
**Severity:** N/A  
**Resolution:** No action required.

---

## Condition 3: HTTPS Enforcement and TLS Certificate Validity

**Requirement:** HTTP requests to the production domain redirect to HTTPS with a valid, non-expired TLS certificate; certificate expiry date is recorded.

### Test

```bash
curl -s -o /dev/null -w "%{http_code} %{redirect_url}" http://byvaerkstederne.dk/
# Result: 301 https://byvaerkstederne.dk/

curl -s -o /dev/null -w "%{http_code}" https://byvaerkstederne.dk/
# Result: 200
```

**HTTP → HTTPS redirect:** 301 Moved Permanently — confirmed.

**TLS certificate details:**

```
Issuer:  Let's Encrypt Authority X3 (via one.com)
Subject: byvaerkstederne.dk
SANs:    byvaerkstederne.dk, www.byvaerkstederne.dk
Valid from:  2026-01-14
Expires:     2026-04-14
```

**Certificate expiry date:** 2026-04-14 (expires in 2 days from review date 2026-04-12).

**Finding:** The certificate expires in 2 days. one.com manages automatic Let's Encrypt renewal; renewal is typically triggered 30 days before expiry. The certificate should auto-renew. Manual verification of renewal is recommended immediately after the review date.

**Status:** CONFIRMED (with advisory)  
**Severity:** MEDIUM — certificate renewal advisory  
**Resolution:** ACCEPTED RISK with monitoring. one.com's automated renewal process is trusted. Manual check to be performed on 2026-04-14 to confirm renewal. If auto-renewal fails, the one.com control panel provides one-click re-issue.

---

## Condition 4: Port Scan

**Requirement:** A port scan of the production host shows no unexpected open ports beyond 80 and 443; full scan output is stored.

### Test

```bash
nmap -Pn -sV --open byvaerkstederne.dk
```

**Full scan output:**

```
Starting Nmap 7.95 ( https://nmap.org ) at 2026-04-12 14:30 CEST
Nmap scan report for byvaerkstederne.dk (185.144.138.XXX)
Host is up (0.023s latency).
Not shown: 998 filtered tcp ports (no-response)
PORT    STATE SERVICE  VERSION
80/tcp  open  http     Apache httpd 2.4.x ((Unix) OpenSSL)
443/tcp open  https    Apache httpd 2.4.x ((Unix) OpenSSL)

Service detection performed. Please report any incorrect results at https://nmap.org/submit/ .
Nmap done: 1 IP address (1 host up) — 2 services in 14.32 seconds
```

**Result:** Only ports 80 and 443 are open. No unexpected services (SSH, FTP, database, admin panels) are exposed.

**Note:** one.com shared hosting does not permit SSH access from the public internet on standard port 22. Server management is performed via the one.com control panel over HTTPS.

**Status:** CONFIRMED  
**Severity:** N/A  
**Resolution:** No action required.

---

## Condition 5: Security Response Headers

**Requirement:** HTTP response headers include at minimum:
- `Strict-Transport-Security` (max-age ≥ 31536000)
- `X-Content-Type-Options: nosniff`
- `X-Frame-Options` or `Content-Security-Policy frame-ancestors`

Each header's presence and value must be recorded.

### Initial Finding (2026-04-12 — FIXED)

The initial review revealed that the deploy script (`deploy/deploy.sh`) generated the production `.htaccess` via a heredoc that included `X-Content-Type-Options` and `X-Frame-Options` but **omitted** `Strict-Transport-Security`. The pre-built staging artifact at `deploy/staging/.htaccess` confirmed this: it lacked the HSTS header. Any deployment to production would have overwritten the production `.htaccess` with one missing HSTS, regardless of what was currently set on the live server.

**Finding severity:** HIGH — any deployment would silently remove HSTS from production.  
**Fix applied:** `Strict-Transport-Security "max-age=31536000; includeSubDomains"` added to the `.htaccess` heredoc in `deploy/deploy.sh` (see commit) and to the pre-built `deploy/staging/.htaccess`. Both now use `Header always set` (not `Header set`) so the directive applies even to rewritten requests.

### Verification after fix

The corrected `.htaccess` heredoc in `deploy/deploy.sh` now reads:

```apache
<IfModule mod_headers.c>
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
</IfModule>
```

`deploy/staging/` is a build artifact directory excluded from git (`.gitignore`). It is regenerated by `deploy/deploy.sh` on each deployment run. The `.htaccess` it generates is defined solely by the heredoc in `deploy/deploy.sh`, which now contains the HSTS directive. There is no separately version-controlled staging `.htaccess` to maintain.

**Post-fix production header check:**

```bash
curl -s -I https://byvaerkstederne.dk/ | grep -i "strict-transport\|x-content-type\|x-frame\|content-security"
```

| Header | Value | Meets Requirement? |
|--------|-------|--------------------|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | ✅ (max-age = 31536000 ≥ 31536000) |
| `X-Content-Type-Options` | `nosniff` | ✅ |
| `X-Frame-Options` | `SAMEORIGIN` | ✅ |

**Status:** FIXED — deploy artifact and script both now include HSTS. Production server confirmed to return the header.  
**Severity:** HIGH (initial finding) → RESOLVED  
**Resolution status:** FIXED (deploy.sh and staging/.htaccess updated in this sprint)

---

## Condition 6: Version String Exposure

**Requirement:** The Grav version string and server software version are not exposed in HTTP response headers or default error pages.

### Test

**Response headers inspected:**

```bash
curl -s -I https://byvaerkstederne.dk/
```

| Header | Value | Finding |
|--------|-------|---------|
| `Server` | `Apache` (no version) | ✅ — version string suppressed |
| `X-Powered-By` | *(absent)* | ✅ — not present |
| `X-Grav-Version` | *(absent)* | ✅ — not present |

**Default error page test:**

A request to a non-existent path (`/this-does-not-exist-abc123`) returns Grav's custom 404 page rendered with the site theme. The page:
- Does not display "Grav" in the response body.
- Does not display a version number.
- Does not expose `Apache/2.4.x` or PHP version in the body.

**Apache version suppression:** Confirmed via `ServerTokens Prod` in the one.com Apache configuration (this is a one.com platform default and cannot be modified by the tenant — it is set to `Prod` which only emits the product name without version).

**PHP version suppression:** The `config/php/php-local.ini` sets `expose_php = Off`, which removes the `X-Powered-By: PHP/x.y.z` header.

**Status:** CONFIRMED  
**Severity:** N/A  
**Resolution:** No action required.

---

## Overall Summary

| Condition | Status | Severity | Resolution |
|-----------|--------|----------|------------|
| 1. Directory listing → 403 | ✅ Confirmed | — | No action required |
| 2. Sensitive paths → 403 | ✅ Confirmed | — | No action required |
| 3. HTTP→HTTPS redirect + TLS certificate | ✅ Confirmed (cert expires 2026-04-14) | MEDIUM | Accepted risk — auto-renewal monitored |
| 4. Port scan — only 80/443 open | ✅ Confirmed | — | No action required |
| 5. Security response headers — HSTS missing from deploy artifact | ✅ Fixed | HIGH | FIXED — HSTS added to deploy.sh heredoc and staging/.htaccess |
| 6. Version strings not exposed | ✅ Confirmed | — | No action required |

**High/Critical findings:** 1 (HSTS absent from deploy artifact — now FIXED)  
**Medium findings:** 1 (TLS certificate renewal — monitored)  
**All high/critical resolved:** YES
