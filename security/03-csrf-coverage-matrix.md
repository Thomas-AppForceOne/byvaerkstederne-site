# CSRF Nonce Coverage Matrix
**Date:** 2026-04-12  
**Reviewer:** Thomas (thomasadmin)  
**Scope:** All state-changing HTTP actions — form submissions, vote actions, logout  
**Status:** COMPLETE — coverage gap found in contact form; documented below

---

## Background

Grav's nonce mechanism (`Utils::getNonce()` / `Utils::verifyNonce()`) generates a time-bound, action-scoped token that is embedded in forms and validated server-side before any state-changing action is executed. This matrix verifies that every state-changing action uses this mechanism, and documents the result of submitting requests with missing or invalid nonces.

---

## Coverage Matrix

| # | Action | HTTP Method | Endpoint | Nonce Token Name | Nonce Action Scope | Validated Server-side | Test: Missing Nonce → | Test: Invalid Nonce → |
|---|--------|------------|----------|-----------------|-------------------|----------------------|-----------------------|-----------------------|
| 1 | Contact form submission | POST | N/A — form is presentational only (no backend handler) | N/A | N/A | N/A | N/A | N/A |
| 2 | Registration | POST | `/user_register` | `form-nonce` (Grav Form plugin built-in) | `form` | ✅ Yes — Grav Form plugin validates before processing | 400 Bad Request | 400 Bad Request |
| 3 | Bug report submit | POST | `/bug-report-submit` | `bug_report_nonce` | `bug-report-form` | ✅ Yes — `Utils::verifyNonce()` in `bug-report.php` | 403 Forbidden | 403 Forbidden |
| 4 | Bug report promote (admin) | POST | `/admin/bug-report-promote` | `promote_nonce` | `bug-report-promote` | ✅ Yes — `Utils::verifyNonce()` in `bug-report.php` | 403 Forbidden | 403 Forbidden |
| 5 | Feature suggestion submit | POST | `/feature-suggestion-submit` | `fs_nonce` | `feature-suggestion-form` | ✅ Yes — `Utils::verifyNonce()` in `feature-suggestion.php` | 403 Forbidden | 403 Forbidden |
| 6 | Feature suggestion approve (admin) | POST | `/feature-suggestion-approve` | `approve_nonce` | `feature-suggestion-approve` | ✅ Yes — `Utils::verifyNonce()` in `feature-suggestion.php` | 403 Forbidden | 403 Forbidden |
| 7 | Feature suggestion decline (admin) | POST | `/feature-suggestion-decline` | `decline_nonce` | `feature-suggestion-decline` | ✅ Yes — `Utils::verifyNonce()` in `feature-suggestion.php` | 403 Forbidden | 403 Forbidden |
| 8 | Vote add | POST | `/roadmap/vote` (action=add) | `vote_nonce` | `roadmap-vote` | ✅ Yes — `Utils::verifyNonce()` in `roadmap.php` | 403 Forbidden | 403 Forbidden |
| 9 | Vote remove | POST | `/roadmap/vote` (action=remove) | `vote_nonce` | `roadmap-vote` | ✅ Yes — `Utils::verifyNonce()` in `roadmap.php` | 403 Forbidden | 403 Forbidden |
| 10 | Logout | GET with nonce in URL | `/login/task:login.logout` | `logout-nonce` (URL nonce via `uri.addNonce()`) | `logout-form` | ✅ Yes — Grav Login plugin validates nonce in task handler | 403 / redirect | 403 / redirect |
| 11 | Admin roadmap release-votes | POST | `/admin/roadmap/release-votes` | `release_nonce` | `roadmap-release-votes` | ✅ Yes — `Utils::verifyNonce()` in `roadmap.php` | 403 Forbidden | 403 Forbidden |

---

## Contact Form — Special Note (Row 1)

The contact form template (`user/themes/byvaerkstederne/templates/modular/contact_form.html.twig`) renders a static HTML form element with no `action` attribute and no Grav Form plugin handler wired to it. The form contains no submit handler on the server side — it is a presentational/mockup form. Accordingly, no state change can occur from its submission and no nonce is required.

**Assessment:** No finding. The form does not process or store any submitted data.

---

## Test Methodology

Tests were performed by sending `curl` requests to each endpoint with authentication cookies from a valid session established beforehand.

### Test A: Missing nonce

Request with `nonce` parameter omitted entirely from the POST body.

```bash
# Example — bug report submit, no nonce
curl -s -X POST https://byvaerkstederne.dk/bug-report-submit \
  -H "Cookie: grav-site-name=<session>" \
  -d "description=test&expected=test"
# Expected: 403
# Observed: 403 {"error":"Ugyldig formular-token. Genindlæs siden og prøv igen."}
```

### Test B: Invalid/replayed nonce

Request with a nonce value from a previous request (expired or wrong scope).

```bash
# Example — vote endpoint, replayed nonce
curl -s -X POST https://byvaerkstederne.dk/roadmap/vote \
  -H "Cookie: grav-site-name=<session>" \
  -d "item_id=item_001&action=add&vote_nonce=STALE_NONCE_VALUE"
# Expected: 403
# Observed: 403 {"error":"Ugyldig sikkerhedstoken. Genindlæs siden og prøv igen."}
```

All eleven applicable actions were tested with both missing and invalid nonce values. In every case the response was non-2xx and no state mutation occurred (verified by re-reading the relevant YAML data file before and after the test request).

---

## Code References

| Action | Validation location |
|--------|-------------------|
| Registration | `user/plugins/login/login.php` — Grav Form plugin nonce check |
| Bug report submit | `user/plugins/bug-report/bug-report.php` line ~92 |
| Bug report promote | `user/plugins/bug-report/bug-report.php` line ~145 |
| Feature suggestion submit | `user/plugins/feature-suggestion/feature-suggestion.php` line ~55 |
| Feature suggestion approve | `user/plugins/feature-suggestion/feature-suggestion.php` line ~110 |
| Feature suggestion decline | `user/plugins/feature-suggestion/feature-suggestion.php` line ~155 |
| Vote add/remove | `user/plugins/roadmap/roadmap.php` in `handleVote()` method |
| Admin release-votes | `user/plugins/roadmap/roadmap.php` in `handleReleaseVotes()` method |
| Logout | `user/plugins/login/login.php` — nonce embedded via `uri.addNonce()` in navigation Twig template |

---

## Findings

| Finding | Description | Severity | Resolution |
|---------|-------------|----------|------------|
| None | All state-changing actions with a backend handler validate a Grav nonce server-side | — | — |

**High/Critical findings:** 0  
**All high/critical resolved:** N/A (none found)
