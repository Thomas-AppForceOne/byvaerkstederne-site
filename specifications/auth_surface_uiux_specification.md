# Specification — Auth surface UI/UX (login, account creation, forgotten password)

Status: Planned
Owner: thomas@appforceone.dk
Scope: Presentation/UX of the three self-service auth surfaces — login, account creation, and forgotten-password (and its reset step) — plus a single consistent form-feedback component. Theme templates, CSS, and assets only. No auth behaviour changes.

---

## Goal

The three auth surfaces look and behave inconsistently: login is a floating overlay, account creation and forgotten-password are plain pages, the forgot page leaks the stock plugin's English boilerplate, fields/buttons are mis-sized, and form feedback has no consistent identity. Bring all three onto **one shared floating presentation** with **one consistent, recognisable feedback component**, and fix the specific defects below — so a member sees a single coherent identity whether they log in, register, or recover a password.

## Boundaries — what this spec does NOT change

- **No `login`/`email` plugin PHP changes** — config, theme templates, CSS, and assets only (same constraint as the member-auth hardening work; if a desired effect genuinely needs a plugin patch, stop and raise it).
- **No auth behaviour changes** — verification gate, rate-limit/throttle, honeypot, CSRF, redirects, and the no-enumeration response all stay exactly as they are. This spec is presentation only.
- **No new routes or forms** — the existing surfaces are restyled, not replaced.

## Architectural requirements

- A **single shared floating-card presentation** for all three surfaces — a centred card floating over a dimmed page backdrop, with one identity (spacing, surface, accent, typography). Login already does this via the overlay; account creation and forgotten-password must adopt the same presentation. Factor the shared chrome into a reusable partial rather than duplicating it per template.
- A **single shared feedback component** for form messages (flash + inline validation), used by every auth form, with explicit **success** and **error** variants that are immediately distinguishable. Centralise it (e.g. extend `partials/messages.html.twig`) so all surfaces render identically.
- Keep the stock plugin's own form markup intact where the plugin owns it; suppress/override only its presentation (the plugin's `built_in_css` stays false).

## UI/UX requirements

### Login
- The card must be **wide enough to show its full text without horizontal scrolling / sliders** at normal desktop widths.
- The **left-side image must be present** (`theme://images/login-panel.svg` exists; ensure the login surface actually renders it — the page variant currently does not).

### Account creation
- Presented as a **floating card over the page, consistent with login** — same chrome/identity, not a bare full-width page.

### Forgotten password (and reset)
- Presented as a **floating card over the page, consistent with login**.
- **Remove the duplicated English boilerplate** — the stock plugin's "Recover your password / Enter your email to recover your password / Email *" block must not appear (the themed Danish content is the only copy shown).
- The **email field and the CTA button must use the design-system sizing and font size** — currently both are too small / wrong font.

### Form feedback (all auth forms — general)
- All form messages (e.g. *"Hvis der findes en konto, er der sendt en vejledning til nulstilling af adgangskode på e-mail."*) render in a **box, centred on screen, floating over the form**, with a **clear, consistent identity**.
- **Success and error states are easily and consistently recognisable** (distinct colour/icon treatment, applied the same way on every surface). A validation error and a success notice must never be visually ambiguous.

## Interfaces to the system

- Templates: `themes/byvaerkstederne/templates/partials/login_overlay.html.twig`, `register.html.twig`, `forgot.html.twig`, `reset.html.twig`, `login.html.twig`, `partials/messages.html.twig` (+ a new shared auth-card partial if introduced).
- Styles: the theme CSS (`themes/byvaerkstederne/css/theme.css`).
- Assets: `themes/byvaerkstederne/images/login-panel.svg` (existing).
- Flash source: Grav's `messages` service (login-plugin + forms-plugin flashes) — rendered, not generated.

## Test requirements

Playwright coverage on the existing anonymous auth surface (reuse the WI-6 patterns), success **and** failure paths:
- Login card shows its full text with **no horizontal overflow** and the left image is rendered.
- Account-creation and forgotten-password surfaces present as the shared floating card (assert the shared chrome marker is present).
- The forgotten-password surface contains **no** "Recover your password" English text.
- Submitting forgotten-password for an unknown account renders the **success-variant** feedback box centred over the form (and creates no enumeration difference — behaviour unchanged); a deliberately invalid submission renders the **error-variant** box. The two variants are distinguishable by a stable selector/class.

## Exit criteria

- All three surfaces share one floating-card identity; login shows full text without sliders and renders the left image; account creation and forgotten-password float consistently.
- The forgotten-password English boilerplate is gone; its email field + CTA match the design system.
- Every auth form's success/error feedback renders in the shared, centred, floating, clearly-distinguishable component.
- The above is covered by passing Playwright tests on both success and failure paths; no auth behaviour changed; no plugin PHP modified.
