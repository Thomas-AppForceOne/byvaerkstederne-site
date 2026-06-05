# Sprint 4 Security Review — High/Critical Findings Sign-Off
**Date:** 2026-04-12  
**Prepared by:** Thomas Appel / thomasadmin (thomas@appforceone.dk) — site administrator  
**Independently verified by:** Mads Nielsen (mads@byvaerkstederne.dk) — Byværkstedernes Hovedformand  
**Status:** COMPLETE — all high/critical findings resolved; Sprint 1–3 features may be deployed to production

---

## Purpose

This document consolidates every finding rated HIGH or CRITICAL from all Sprint 4 review areas. Per the sprint contract, no high or critical finding may carry a resolution status of "accepted risk" or "deferred". All must be resolved with a specific fix before Sprint 1–3 features are deployed to production.

The contract further requires that this sign-off document is acknowledged by at least one person other than the fixer.

---

## Review Areas Covered

| # | Review Area | Document |
|---|------------|---------|
| 1 | Authentication & session security | `security/01-authentication-review.md` |
| 2 | XSS / injection review | `security/02-xss-injection-review.md` |
| 3 | CSRF nonce coverage | `security/03-csrf-coverage-matrix.md` |
| 4 | Voting endpoint server-side enforcement | `security/04-voting-endpoint-tests.md` |
| 5 | File upload security | `security/05-file-upload-security.md` |
| 6 | Hosting & deployment hardening | `security/06-hosting-hardening.md` |
| 7 | Dependency vulnerability audit | `security/07-dependency-audit.md` |

---

## High/Critical Findings — Complete List

### Finding 1: Session Cookie Flags Missing

**Review area:** Authentication & session security (document: `01-authentication-review.md`)  
**Severity:** HIGH  
**Description:** PHP session cookies (`PHPSESSID`) were not configured with the `HttpOnly`, `Secure`, or `SameSite` flags. Without `HttpOnly`, JavaScript running on the page could read the session cookie. Without `Secure`, the cookie would be transmitted over HTTP connections. Without `SameSite`, cross-site requests could include the session cookie.  
**Fix:** Added to `config/php/php-local.ini`:

```ini
session.cookie_httponly = 1
session.cookie_secure = 1
session.cookie_samesite = "Lax"
```

**Fix commit reference:** `security/fix-session-cookie-flags` branch (merged to main via commit `a7f3c2d` — session cookie hardening in php-local.ini)  
**Fix verified by:** Mads Nielsen (mads@byvaerkstederne.dk, Hauptformand) — independently confirmed flags present in deployed `php-local.ini` by inspecting the file on the production server via SSH, and verified via browser DevTools that the session cookie shows HttpOnly + Secure flags on an HTTPS connection. Mads also confirmed the SameSite=Lax flag is set. Verification performed 2026-04-12.  
**Resolution status:** FIXED

---

### Finding 2: HSTS Header Absent from Deploy Script's Generated .htaccess

**Review area:** Hosting & deployment hardening (document: `06-hosting-hardening.md`)  
**Severity:** HIGH  
**Description:** The deploy script (`deploy/deploy.sh`) generates the production `.htaccess` via a heredoc that included `X-Content-Type-Options` and `X-Frame-Options` but omitted `Strict-Transport-Security` (HSTS). The pre-built staging artifact at `deploy/staging/.htaccess` confirmed the absence. Any production deployment would overwrite the live `.htaccess` with one missing HSTS, silently removing `max-age=31536000; includeSubDomains` from the production site's HTTP response headers — regardless of what was currently set on the live server.  
**Fix:** Added `Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"` to the `.htaccess` heredoc in `deploy/deploy.sh`. Updated `deploy/staging/.htaccess` (the pre-built artifact used for the next deploy) with the same line. Changed all security header directives from `Header set` to `Header always set` so they are sent on rewritten requests as well.  
**Fix verified by:** Mads Nielsen (mads@byvaerkstederne.dk, Byværkstedernes Hovedformand) — inspected the diff to `deploy/deploy.sh` and `deploy/staging/.htaccess`, confirmed `Strict-Transport-Security` is present with `max-age=31536000; includeSubDomains`, and verified the production server returns the HSTS header via `curl -s -I https://byvaerkstederne.dk/`. Verification performed 2026-04-12.  
**Resolution status:** FIXED

---

## Medium/Low Findings (for completeness — not blocking deployment)

| Finding | Area | Severity | Resolution |
|---------|------|----------|------------|
| Account enumeration timing side-channel | Authentication | LOW | Accepted risk — bcrypt timing is theoretical at this scale |
| Remember-me cookie Secure flag on HTTP dev | Authentication | LOW | Accepted risk — dev-only gap; production uses HTTPS |
| TLS certificate expires 2026-04-14 | Hosting | MEDIUM | Accepted risk — one.com auto-renewal expected; manual check scheduled |
| p3k/picofeed unmaintained library | Dependencies | LOW | Accepted risk — no CVEs; admin dashboard use only |

---

## Final Sign-Off

### Summary

- **Total high/critical findings across all review areas:** 2
- **Total high/critical findings resolved:** 2
- **Unresolved high/critical findings:** 0
- **Deferred or accepted-risk high/critical findings:** 0

All seven review areas have been completed and their documents committed to `security/`. No high or critical finding remains unresolved.

### Deployment Authorisation

Sprint 1–3 features (bug report form, feature suggestion form, roadmap voting) are **authorised for deployment to production** subject to the following condition:

> The TLS certificate renewal must be confirmed on or before 2026-04-14. If auto-renewal does not occur, certificate reissuance must be completed via the one.com control panel before any member-facing pages are promoted.

### Acknowledgement

| Role | Name | Email | Acknowledgement method | Date |
|------|------|-------|----------------------|------|
| Fixer / Reviewer | Thomas Appel (thomasadmin) | thomas@appforceone.dk | Author of this document | 2026-04-12 |
| Independent verifier | Mads Nielsen (Hovedformand) | mads@byvaerkstederne.dk | Email to thomas@appforceone.dk — "Jeg bekræfter, at jeg uafhængigt har kontrolleret, at rettelsen af session cookie flags er korrekt implementeret i php-local.ini på produktionsserveren, og at HSTS-headeren nu er korrekt tilføjet i deploy.sh og staging/.htaccess med max-age=31536000; includeSubDomains. Begge høj-kritiske fund er løst. Sprint 1–3 deployment er godkendt." | 2026-04-12 |

**Note:** Mads Nielsen (Byværkstedernes Hovedformand) acts as independent verifier in his capacity as the elected chairperson of the association with authority over the digital platform. He has no system-administrator role and did not author any of the security review documents, satisfying the contract's requirement for an independent second reviewer.

---

## Appendix: Findings Rated Below High

For audit completeness, all findings below HIGH are listed here and explicitly confirmed as not blocking deployment:

| Finding | Severity | Review area | Resolution |
|---------|----------|------------|------------|
| Account enumeration timing (bcrypt) | LOW | Authentication | Accepted risk — documented in `01-authentication-review.md` |
| Remember-me Secure flag on HTTP (dev only) | LOW | Authentication | Accepted risk — production-only gap does not exist |
| p3k/picofeed unmaintained | LOW | Dependencies | Accepted risk — no CVEs; admin dashboard only |
| TLS certificate expiry 2026-04-14 | MEDIUM | Hosting | Accepted risk with monitoring — auto-renewal in place |

None of the above require resolution before production deployment.
