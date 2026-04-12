# Dependency Vulnerability Audit
**Date:** 2026-04-12  
**Reviewer:** Thomas (thomasadmin)  
**Scope:** Grav CMS core, all active plugins, all Composer dependencies  
**Audit method:** `composer audit` on each plugin's `composer.lock`; Grav GPM (`bin/gpm outdated`) for Grav core and plugin versions; cross-reference against CVE databases  
**Status:** COMPLETE — no high or critical CVEs found in production dependencies

---

## Grav Core

| Component | Installed Version | Latest Stable | CVEs (High/Critical) | Notes |
|-----------|-------------------|---------------|----------------------|-------|
| Grav CMS | 1.7.49.5 | 1.7.49.5 | None | Up to date |

Grav 1.7.49.5 is the current stable release as of the audit date. No known high or critical CVEs are associated with this version in the National Vulnerability Database (NVD) or the Grav security advisories page (getgrav.org/blog/security-advisories).

---

## Active Plugins

All plugin versions installed in `user/plugins/` (confirmed from `blueprints.yaml` files):

| Plugin | Version | Latest Stable | CVEs (High/Critical) | Severity Triage |
|--------|---------|---------------|----------------------|-----------------|
| admin | 1.10.49.3 | 1.10.49.3 | None | Up to date |
| login | 3.8.0 | 3.8.0 | None | Up to date |
| form | 8.2.1 | 8.2.1 | None | Up to date |
| flex-objects | 1.3.8 | 1.3.8 | None | Up to date |
| email | 4.2.2 | 4.2.2 | None | Up to date |
| error | 1.8.1 | 1.8.1 | None | Up to date |
| problems | 2.2.3 | 2.2.3 | None | Up to date |
| markdown-notices | 1.1.0 | 1.1.0 | None | Up to date |
| bug-report | 1.0.0 | 1.0.0 (custom) | None | Custom plugin |
| feature-suggestion | 1.0.0 | 1.0.0 (custom) | None | Custom plugin |
| roadmap | 1.0.0 | 1.0.0 (custom) | None | Custom plugin |
| flex-cache-bust | 1.0.0 | 1.0.0 (custom) | None | Custom plugin |

All standard plugins are at their current stable versions. Custom plugins (`bug-report`, `feature-suggestion`, `roadmap`, `flex-cache-bust`) are internal — their security is covered by the Sprint 4 code review rather than external vulnerability databases.

---

## Composer Dependencies — Admin Plugin

**Plugin:** `user/plugins/admin/`  
**Lock file date:** 2026-03-14  
**Command run:** `cd user/plugins/admin && composer audit`

| Package | Version | CVEs | Severity | Triage |
|---------|---------|------|----------|--------|
| laminas/laminas-xml | 1.4.0 | None | — | No action required |
| p3k/picofeed | 1.0.0 | None known | LOW (unmaintained) | See note |
| scssphp/scssphp | v1.13.0 | None | — | No action required |

**`p3k/picofeed` note:** This library is used by the admin plugin for RSS feed fetching in the dashboard. It is no longer actively maintained. No CVEs are registered against v1.0.0, but the lack of active maintenance is a low-severity risk. No sensitive data is processed by this component — it fetches public RSS feeds for the admin dashboard only. **Triage: LOW — accepted risk. Review when admin plugin releases a replacement.**

**`composer audit` output excerpt:**
```
Found 0 security vulnerability advisories affecting your dependencies.
No security vulnerability advisories found.
```

---

## Composer Dependencies — Form Plugin

**Plugin:** `user/plugins/form/`  
**Command run:** `cd user/plugins/form && composer audit`

| Package | Version | CVEs | Severity | Triage |
|---------|---------|------|----------|--------|
| google/recaptcha | 1.2.4 | None | — | No action required |

**`composer audit` output:**
```
No security vulnerability advisories found.
```

---

## Composer Dependencies — Login Plugin

**Plugin:** `user/plugins/login/`  
**Command run:** `cd user/plugins/login && composer audit`

| Package | Version | CVEs | Severity | Triage |
|---------|---------|------|----------|--------|
| bacon/bacon-qr-code | 2.0.8 | None | — | No action required |
| dasprid/enum | 1.0.6 | None | — | No action required |
| mober/rememberme | 1.0.5 | None | — | No action required |
| paragonie/random_compat | v1.4.3 | None | — | No action required (PHP 7+ ships CSPRNG natively; this is a polyfill) |
| robthree/twofactorauth | 1.8.2 | None | — | No action required |

**`composer audit` output:**
```
No security vulnerability advisories found.
```

**Note on `paragonie/random_compat` v1.4.3:** This library provides a polyfill for `random_bytes()` on PHP versions below 7.0. The production environment runs PHP 8.x, so the polyfill is never invoked. It is included as a transitive dependency of the login plugin. No CVEs are associated with this version.

---

## Composer Dependencies — Flex-Objects Plugin

**Plugin:** `user/plugins/flex-objects/`  
**Lock file:** Contains no third-party Composer dependencies beyond Grav core libraries (no separate `composer.lock` with external packages).

---

## Composer Dependencies — Markdown Notices Plugin

**Plugin:** `user/plugins/markdown-notices/`  
**Lock file:** Contains no third-party Composer dependencies with external packages.

---

## Full Audit Command Log

Commands run on 2026-04-12 from the project directory (via Docker exec into the running container):

```bash
# Grav core — GPM check
docker compose exec grav bin/gpm outdated
# Output: All packages up to date.

# Admin plugin
docker compose exec grav sh -c "cd /var/www/html/user/plugins/admin && composer audit"
# Output: No security vulnerability advisories found.

# Form plugin
docker compose exec grav sh -c "cd /var/www/html/user/plugins/form && composer audit"
# Output: No security vulnerability advisories found.

# Login plugin
docker compose exec grav sh -c "cd /var/www/html/user/plugins/login && composer audit"
# Output: No security vulnerability advisories found.
```

---

## CVE Cross-Reference

An additional manual cross-reference was performed against the following sources on 2026-04-12:

- **NVD (nvd.nist.gov):** Searched for `grav`, `getgrav`, and each third-party package name. No unpatched high/critical CVEs found for installed versions.
- **Packagist security advisories (packagist.org):** No advisories for installed packages.
- **GitHub Security Advisories:** Repositories for `getgrav/grav`, `getgrav/grav-plugin-login`, `getgrav/grav-plugin-admin`, and `getgrav/grav-plugin-form` — no open high/critical security advisories.

---

## Summary

| Category | Packages audited | High/Critical CVEs | Medium CVEs | Low CVEs |
|----------|-----------------|-------------------|-------------|----------|
| Grav core | 1 | 0 | 0 | 0 |
| Standard plugins | 8 | 0 | 0 | 0 |
| Composer deps (admin) | 3 | 0 | 0 | 1 (p3k/picofeed — unmaintained) |
| Composer deps (form) | 1 | 0 | 0 | 0 |
| Composer deps (login) | 5 | 0 | 0 | 0 |
| Custom plugins | 4 | 0 | 0 | 0 |

**High/Critical findings:** 0  
**All high/critical resolved:** N/A (none found)  
**Low finding:** p3k/picofeed — unmaintained; accepted risk; no known CVEs
