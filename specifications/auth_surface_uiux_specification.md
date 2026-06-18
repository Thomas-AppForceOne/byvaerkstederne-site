# Specification — Auth surface UI/UX (login, account creation, forgotten password)

Status: Planned
Owner: thomas@appforceone.dk
Scope: Presentation/UX of the three self-service auth surfaces — login, account creation, and forgotten-password (and its reset step) — plus a single consistent form-feedback component. Theme templates, CSS, and assets only. No auth behaviour changes.

---

## Goal

The three auth surfaces look and behave inconsistently: login is a floating overlay, account creation and forgotten-password are plain pages, the forgot page leaks the stock plugin's English boilerplate, fields/buttons are mis-sized, and form feedback has no consistent identity. Bring all three onto **one shared floating presentation** with **one consistent, recognisable feedback component**, and fix the specific defects below — so a member sees a single coherent identity whether they log in, register, or recover a password.

## Boundaries — what this spec does NOT change

- **No `login`/`email` plugin PHP (`.php`) changes** — config, theme templates, CSS, and assets only (same constraint as the member-auth hardening work; if a desired effect genuinely needs a plugin PHP patch, stop and raise it). This prohibition is scoped to **plugin PHP / behaviour**; theme-level *shadowing* of a plugin's Twig partials and overriding plugin-owned page *content* are in-scope (this is how the forgotten-password boilerplate below gets removed without touching plugin code).
- **No auth behaviour changes** — verification gate, rate-limit/throttle, honeypot, CSRF, redirects, and the no-enumeration response all stay exactly as they are. This spec is presentation only.
- **No new routes or forms** — the existing surfaces are restyled, not replaced.

## Architectural requirements

- A **single shared floating-card presentation** for all three surfaces — a centred card floating over a dimmed page backdrop, with one identity (spacing, surface, accent, typography). Login already does this via the overlay; account creation and forgotten-password must adopt the same presentation. Factor the shared chrome into a reusable partial rather than duplicating it per template. The shared partial exposes a stable marker class **`.bv-auth-card`** — the chrome marker the tests assert on.
- A **single shared feedback component** for form messages, used by every auth form, with explicit **success** and **error** variants that are immediately distinguishable. There is no `.bv-message` CSS rule today — `partials/messages.html.twig` carries inline styles only — so this work **creates** a centralised `.bv-message` CSS component and routes *both* message sources through one identity: the login/email-plugin flashes (Grav's `messages` service via `partials/messages.html.twig`) **and** the forms-plugin registration messages, which currently render through a separate `.form-messages .alert` path in `forms/form.html.twig` (styled around `theme.css:673`). "Used by every auth form" requires unifying those two renderers — account creation must not keep its old `.alert` look.
- Keep the stock plugin's **functional form markup** intact where the plugin owns it — the input fields, the CSRF nonce, the submit control — and suppress/override only its *presentation* (the plugin's `built_in_css` stays false). This does **not** extend to prose the plugin injects into the page body: the forgotten-password English boilerplate (see below) is removable, and the sanctioned mechanism is a **theme-level shadow** of the stock `partials/forgot-form.html.twig` (a Twig override, not a PHP change) that drops its `{{ content|raw }}` block, and/or overriding the forgot page's content. Pick one and record it in the implementation notes; do not edit the login plugin's PHP.

## UI/UX requirements

### Login
- The card must be **wide enough to show its full text without horizontal scrolling / sliders** at normal desktop widths (the test pins a 1280×800 viewport and asserts `scrollWidth <= clientWidth` on the card element).
- The **left-side image must be present** (`theme://images/login-panel.svg` exists; ensure the login surface actually renders it — the page variant currently does not).

### Account creation
- Presented as a **floating card over the page, consistent with login** — same chrome/identity, not a bare full-width page.

### Forgotten password (and reset)
- Presented as a **floating card over the page, consistent with login**.
- The **reset step (`reset.html.twig`) presents as the same floating card** — it has the same plain-page shape today and must adopt the shared chrome (`.bv-auth-card`) too.
- **Remove the duplicated English boilerplate** — the stock plugin's "Recover your password / Enter your email to recover your password" block must not appear (the themed Danish content is the only copy shown). This prose is the **markdown body of the login plugin's `pages/forgot.md`**, injected by the stock `partials/forgot-form.html.twig` via `{{ content|raw }}`; remove it by shadowing that partial in the theme (or overriding the page content), per the Boundaries note. ("Email *" is the field's own label + required-marker — restyled via CSS, not removed.)
- The **email field and the CTA button must use the design-system sizing and font size** (`.bv-input` for the field; `.bv-btn--primary`/`.bv-btn--lg` for the CTA) — currently both are too small / wrong font. Because the field is rendered by the *stock* form partial, apply these via CSS selectors targeting the stock `#grav-login` markup rather than editing the plugin partial's field markup.

### Form feedback (all auth forms — general)
- All form messages (e.g. *"Hvis der findes en konto, er der sendt en vejledning til nulstilling af adgangskode på e-mail."*) render in a **box, centred on screen, floating over the form**, with a **clear, consistent identity**.
- **Success and error states are easily and consistently recognisable** (distinct colour/icon treatment, applied the same way on every surface). A validation error and a success notice must never be visually ambiguous.

## Interfaces to the system

- Templates: `themes/byvaerkstederne/templates/partials/login_overlay.html.twig`, `register.html.twig`, `forgot.html.twig`, `reset.html.twig`, `login.html.twig`, `partials/messages.html.twig` (+ a new shared auth-card partial if introduced).
- Styles: the theme CSS (`themes/byvaerkstederne/css/theme.css`).
- Assets: `themes/byvaerkstederne/images/login-panel.svg` (existing).
- Flash source: Grav's `messages` service (login-plugin + forms-plugin flashes) — rendered, not generated.

## Test requirements

Playwright coverage on the existing anonymous auth surface (reuse the WI-6 patterns, e.g. `tests/anonymous/password-reset.js`), success **and** failure paths:
- At a pinned **1280×800** viewport, the login card shows its full text with **no horizontal overflow** — asserted as `scrollWidth <= clientWidth` on the card element — and the left image (`login-panel.svg`) is rendered.
- Account-creation, forgotten-password, **and reset** surfaces present as the shared floating card (assert the chrome marker **`.bv-auth-card`** is present).
- The forgotten-password surface contains **no** "Recover your password" English text.
- Submitting forgotten-password for an unknown account renders the **success-variant** feedback box centred over the form (and creates no enumeration difference — behaviour unchanged); a deliberately invalid submission renders the **error-variant** box. The two variants are distinguishable by **stable classes — `.bv-message--success` / `.bv-message--error`** (the contract selector), and the test asserts the no-enumeration success response and a validation failure resolve to **different** variants. If the underlying Grav message *scopes* don't already differ for these two cases, the theme must map them to the distinct variant classes deterministically.

## Exit criteria

- All three surfaces (login, account creation, forgotten-password — **including its reset step**) share one floating-card identity; login shows full text without sliders and renders the left image; account creation, forgotten-password, and reset float consistently.
- The forgotten-password English boilerplate is gone; its email field + CTA match the design system.
- Every auth form's success/error feedback renders in the shared, centred, floating, clearly-distinguishable component.
- The above is covered by passing Playwright tests on both success and failure paths; no auth behaviour changed; no plugin PHP modified.
