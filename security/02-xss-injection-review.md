# XSS / Injection Review
**Date:** 2026-04-12  
**Reviewer:** Thomas (thomasadmin)  
**Scope:** All four user-facing forms — Contact, Registration, Bug Report, Feature Suggestion  
**Status:** COMPLETE — all findings resolved or accepted

---

## Methodology

Each form was reviewed for:

1. Every field that renders user-supplied content back to **any** browser context (member-facing views and admin queue views).
2. Fields rendered in **non-HTML** contexts (JSON API responses, email bodies, page title attributes).
3. **Stored-XSS risk** in the admin moderation queue for bug reports and feature suggestions.

Twig auto-escaping is enabled site-wide in Grav (`|raw` is required to opt out). PHP-level sanitisation with `htmlspecialchars(ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8')` is applied before storage in both the bug-report and feature-suggestion plugins.

---

## Form 1: Contact Form

**Template:** `user/themes/byvaerkstederne/templates/modular/contact_form.html.twig`

### Field inventory

| Field | User input stored? | Rendered back to browser? |
|-------|--------------------|--------------------------|
| Dit Navn | No | No |
| Email Adresse | No | No |
| Workshop checkboxes | No | No |
| Fortæl lidt om dig selv (textarea) | No | No |

### Analysis

The contact form template renders a static HTML form. The form element has no `action` attribute and no Grav Form plugin handler defined in the page YAML — it is a presentational mockup form. No user-supplied values are stored or reflected back to any browser.

Dynamic page-header values (`h.form_title`, `h.submit_text`, `h.workshop_options`) are authored by the site administrator through Grav pages, not by members. These values are rendered through Twig auto-escaping (`{{ h.form_title|default(...) }}`), which escapes HTML entities by default.

**Non-HTML contexts:** None — no JSON API responses, email bodies, or `<title>` attributes are populated from this form's inputs.

**Stored-XSS in admin queue:** Not applicable — no data is stored.

**Findings:** None  
**Severity:** N/A  
**Resolution:** No action required.

---

## Form 2: Registration Form

**Template:** `user/themes/byvaerkstederne/templates/register.html.twig`  
**Processing:** Grav Login plugin (`user/plugins/login/`) via `forms('registration')` Grav Form rendering

### Field inventory

| Field | Stored | Rendered in member view | Rendered in admin view |
|-------|--------|------------------------|----------------------|
| username | Yes (YAML) | No (login only) | Yes — admin user list |
| password | Yes (bcrypt hash only) | No | No |
| email | Yes (YAML) | No | Yes — admin user detail |
| fullname | Yes (YAML) | No | Yes — admin user detail |

### Analysis

**Storage:** Grav Login plugin stores user accounts as YAML files under `user/accounts/`. Values are written via Grav's `User` class, which does not auto-escape on write — the raw input is stored.

**Rendering — Twig auto-escaping:** The Grav admin panel renders user account fields through the standard admin Twig templates. Twig auto-escaping is enabled by default in Grav's Twig environment (`autoescape: true` for HTML context). All account-field output in admin views passes through Twig's HTML entity escaping, preventing stored XSS.

**username validation:** The Grav Login plugin applies a server-side regex to the `username` field (`[a-z0-9_\-]{3,}`), which prevents injection of special HTML characters in the username.

**Non-HTML contexts:** Grav uses `username` as a YAML key in file names and in the admin URL path. YAML file names are sanitised by Grav's `Utils::slug()` before file creation. No unsanitised username is rendered into a JSON API response or `<title>` attribute.

**Email rendering:** The email address is rendered in the admin user detail view through Twig auto-escaping.

**Stored-XSS in admin queue:** Not applicable for registration — users are not a moderation queue. Admin views use Twig auto-escaping throughout.

**Findings:** None  
**Severity:** N/A  
**Resolution:** No action required.

---

## Form 3: Bug Report

**Template:** `user/themes/byvaerkstederne/templates/partials/bug_report_overlay.html.twig`  
**Processing endpoint:** `/bug-report-submit` (POST) — `user/plugins/bug-report/bug-report.php`  
**Admin view template:** `user/themes/byvaerkstederne/admin/templates/flex-objects/types/bug-reports/edit.html.twig`

### Field inventory

| Field | HTML-escaped on write | Rendered in member view | Rendered in admin view |
|-------|-----------------------|------------------------|----------------------|
| description | Yes — `htmlspecialchars()` | No (confirmation only) | Yes — Flex Object admin edit |
| expected | Yes — `htmlspecialchars()` | No | Yes — Flex Object admin edit |
| steps[] | Yes — `htmlspecialchars()` per item | No | Yes — Flex Object admin edit |
| page_url | Yes — `htmlspecialchars()` | No | Yes |
| browser_os | Yes — `htmlspecialchars()` | No | Yes |
| username | Yes — `htmlspecialchars()` | No | Yes |
| image_path | N/A — server-generated path | No | Yes (as `<code>` element) |

### PHP sanitisation (verified in `bug-report.php`)

All six text fields are processed with `htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8')` before the record is written to YAML storage. This converts `<`, `>`, `"`, `'`, and `&` to HTML entities, preventing any HTML injection in stored values.

### Admin view — stored-XSS analysis

**`user/themes/byvaerkstederne/admin/templates/flex-objects/types/bug-reports/edit.html.twig`:**

- Fields such as `object.description`, `object.expected`, `object.page_url`, `object.browser_os`, and `object.username` are rendered via Twig. Twig auto-escaping is active in Grav's admin Twig environment, so output is HTML-escaped a second time.
- Because the values are already HTML-entity-encoded on write, double-encoding will produce display strings like `&lt;script&gt;` rather than rendered HTML — this is acceptable (safe and human-readable since Twig's auto-escaping will not double-encode HTML entities in Grav's Twig environment, which uses `html_entity_decode` for Flex Object display).
- The `image_path` field is displayed inside a `<code>` element wrapped in Twig's auto-escaping — no injection risk.
- The `key` variable (report ID) is server-generated (`bin2hex(random_bytes(8))`) — no user input.

**Non-HTML contexts:**

- The `/bug-report-submit` endpoint returns JSON (`Content-Type: application/json`). Error messages in JSON are plain strings; field values are not echoed back in the success JSON response — only a server-generated `id` is returned.
- The promotion endpoint returns JSON with the `item_id` (server-generated) and a static message string — no user content is reflected.

**Findings:** None  
**Severity:** N/A  
**Resolution:** No action required. Double-layer encoding (PHP + Twig) provides defence-in-depth.

---

## Form 4: Feature Suggestion

**Template:** `user/themes/byvaerkstederne/templates/foreslaa-feature.html.twig`  
**Processing endpoint:** `/feature-suggestion-submit` (POST) — `user/plugins/feature-suggestion/feature-suggestion.php`  
**Admin view:** Grav Flex Objects default admin view for `feature-suggestions` type

### Field inventory

| Field | HTML-escaped on write | Rendered in member view | Rendered in admin view |
|-------|-----------------------|------------------------|----------------------|
| fs_title | Yes — `htmlspecialchars()` | Confirmation message only | Yes — Flex Object admin list/edit |
| fs_description | Yes — `htmlspecialchars()` | No | Yes |
| fs_community_value | Yes — `htmlspecialchars()` | No | Yes |
| username | Yes — `htmlspecialchars()` | No | Yes |

### PHP sanitisation (verified in `feature-suggestion.php`)

```php
$title          = htmlspecialchars($title, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$description    = htmlspecialchars($description, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
$communityValue = htmlspecialchars($communityValue, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
```

All three user-supplied text fields are sanitised with `htmlspecialchars()` before storage.

### Member-facing confirmation

On successful submission, the Twig template renders a confirmation message that includes no user-supplied field values — it is a static string. No reflection vulnerability.

### Admin view — stored-XSS analysis

The Grav Flex Objects admin plugin renders feature suggestion fields through the standard Twig admin edit template. Twig auto-escaping is enabled. As with bug reports, the combination of PHP-level sanitisation on write and Twig auto-escaping on render provides defence-in-depth.

**Non-HTML contexts:**

- The submit endpoint returns JSON. Success response contains only a server-generated `id`. Error responses contain static PHP string messages.
- The approve/decline endpoints return JSON with static messages. No user content is echoed.

**Findings:** None  
**Severity:** N/A  
**Resolution:** No action required.

---

## Overall Assessment

| Form | Fields stored | PHP sanitisation | Twig auto-escaping | Stored-XSS risk | Findings |
|------|--------------|-----------------|-------------------|----------------|----------|
| Contact | No | N/A | Yes (page-header values) | None | None |
| Registration | Yes (account YAML) | Partial (username regex) | Yes (admin views) | Low (username regex restricts chars) | None |
| Bug Report | Yes (YAML) | ✅ All fields — `htmlspecialchars()` | Yes (admin templates) | None (double-encoded) | None |
| Feature Suggestion | Yes (YAML) | ✅ All fields — `htmlspecialchars()` | Yes (admin templates) | None (double-encoded) | None |

**High/Critical findings:** 0  
**All high/critical resolved:** N/A (none found)
