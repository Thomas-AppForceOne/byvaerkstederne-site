# Navigation Placement: Footer-Only Links

## Purpose

This specification defines the correct placement for three site features that must not appear in the main navigation or anywhere else on the site — they must only be accessible as triggers in the footer.

---

## Affected Items

| Item | Type | Trigger | Auth required |
|---|---|---|---|
| Forslå Feature | Modal trigger | `bvFeatureSuggestion.open()` | Yes |
| Roadmap | Page link | `/roadmap` | Yes |
| Rapportér fejl | Modal trigger | `bvBugReport.open()` | Yes |

---

## Current Incorrect State

All three items are currently hardcoded in the main navigation template (`partials/navigation.html.twig`):

- **Forslå Feature** — desktop nav and mobile nav, navigates to `/foreslaa-feature`
- **Roadmap** — desktop nav and mobile nav, navigates to `/roadmap`
- **Rapportér fejl** — desktop nav and mobile nav, authenticated users only

This is incorrect. These items must be removed from all navigation surfaces.

---

## Required Behavior

### Main navigation

None of the three items may appear in:

- the desktop navigation bar
- the mobile navigation overlay
- any secondary or contextual navigation rendered by the navigation template

### Other site locations

None of the three items may appear as links, buttons, or references in:

- page body content (unless the page is the feature itself, e.g., the roadmap page may naturally reference these)
- page collection listings
- related page sections
- hero sections
- landing page modules
- breadcrumbs

### Footer

All three items must appear in the footer as links or triggers.

---

## Footer Placement

### Forslå Feature

- Label: `Forslå feature`
- Behavior: JavaScript trigger — opens the feature suggestion modal, does not navigate to `/foreslaa-feature`
- Trigger: calls `bvFeatureSuggestion.open()` on click; no `href` destination
- Visibility: **authenticated users only** — hidden when not logged in
- Rationale: mirrors the pattern used by Rapportér fejl; the form requires authentication and the page at `/foreslaa-feature` becomes an implementation detail, not a primary entry point

### Roadmap

- Label: `Roadmap`
- Behavior: standard anchor link
- Target: `/roadmap`
- Visibility: **authenticated users only** — hidden when not logged in
- Page access: the `/roadmap` route must return not-found (404) or redirect to login when accessed by an unauthenticated user — the page must not render its content publicly

### Rapportér fejl

- Label: `Rapportér fejl`
- Behavior: JavaScript trigger — calls `bvBugReport.open()` on click, does not navigate to a URL
- Trigger: no `href` destination; rendered as a button or `href="javascript:void(0)"`
- Visibility: **authenticated users only** — hidden when not logged in
- Rationale: the bug report overlay requires authentication; showing the trigger to unauthenticated users would result in a broken experience

---

## Forslå Feature Overlay

The existing form content from `foreslaa-feature.html.twig` must be extracted and placed in a modal overlay, following the same pattern as `bug_report_overlay.html.twig`.

### Required overlay behavior

- Overlay is rendered in the base template for authenticated users (same as bug report overlay)
- Opened by calling `bvFeatureSuggestion.open()` from any trigger on the page
- Closed by a close button inside the overlay or pressing Escape
- Contains the full form: title, description, community value, CSRF nonce, submission token
- On success: shows confirmation inside the overlay (same logic as current page confirmation)
- On unauthenticated state: the overlay is not rendered; no trigger is shown

### JavaScript module

A new `bvFeatureSuggestion` module must be created in `site.js`, following the same structure as `bvBugReport`:

```js
bvFeatureSuggestion.open()   // opens the overlay
bvFeatureSuggestion.close()  // closes the overlay
```

### Submission endpoint

No change — the overlay must POST to `/feature-suggestion/submit` with the same fields as the current page form.

### Page at `/foreslaa-feature`

The page may remain as a fallback route but is no longer the primary entry point. The nav link to it is removed regardless.

---

## Footer Column Placement

The three items should be grouped together in a dedicated footer column.

Suggested grouping:

```
Fællesskab                                              [authenticated only]
  Roadmap                  → /roadmap
  Forslå feature           → bvFeatureSuggestion.open()
  Rapportér fejl           → bvBugReport.open()
```

All three items are authentication-gated. The entire group may be hidden when the user is not logged in. The exact column name is left to the implementer, provided the placement and visibility rules above are met.

---

## Processing Rules

### Navigation template (`partials/navigation.html.twig`)

1. Remove the `<a href="/foreslaa-feature">` entry from desktop nav.
2. Remove the `<a href="/roadmap">` entry from desktop nav.
3. Remove the `Rapportér fejl` button/link entry from desktop nav.
4. Remove all three corresponding entries from the mobile nav overlay.
5. Do not add any replacement placeholder or empty element.

### Base template (`partials/base.html.twig`)

1. Include the new `feature_suggestion_overlay.html.twig` partial (authenticated guard inside the partial, same as bug report overlay).

### Footer template (`partials/footer.html.twig`)

1. Add a link to `/roadmap` — visible only when `grav.user.authenticated` is `true`.
2. Add a button/link that calls `bvFeatureSuggestion.open()` — visible only when `grav.user.authenticated` is `true`.
3. Add a button/link that calls `bvBugReport.open()` — visible only when `grav.user.authenticated` is `true`.

### New overlay partial (`partials/feature_suggestion_overlay.html.twig`)

1. Guard with `{% if grav.user.authenticated and grav.user.authorized %}`.
2. Port the form markup from `foreslaa-feature.html.twig`.
3. Wrap in an overlay panel structure matching `bug_report_overlay.html.twig`.
4. Move the inline `<script>` block from `foreslaa-feature.html.twig` into `site.js` as the `bvFeatureSuggestion` module.

### `site.js`

1. Create a `bvFeatureSuggestion` module exposing `open()` and `close()`.
2. Port the form submission logic from the inline script in `foreslaa-feature.html.twig`.
3. Use the same submission endpoint: `/feature-suggestion/submit`.

---

## Acceptance Criteria

### Navigation

- Forslå Feature does not appear in the desktop nav
- Forslå Feature does not appear in the mobile nav
- Roadmap does not appear in the desktop nav
- Roadmap does not appear in the mobile nav
- Rapportér fejl does not appear in the desktop nav (authenticated or not)
- Rapportér fejl does not appear in the mobile nav (authenticated or not)

### Footer

- Footer contains a link to `/roadmap` when user is authenticated
- Footer does not show the Roadmap link when user is not authenticated
- Footer contains a trigger for `bvFeatureSuggestion.open()` when user is authenticated
- Footer does not show the Forslå Feature trigger when user is not authenticated
- Footer contains a trigger for `bvBugReport.open()` when user is authenticated
- Footer does not show the Rapportér fejl trigger when user is not authenticated

### Feature suggestion overlay

- Clicking the footer trigger opens the feature suggestion overlay
- Overlay contains the full form (title, description, community value)
- Submitting a valid form POSTs to `/feature-suggestion/submit`
- Successful submission shows in-overlay confirmation
- Pressing Escape or the close button closes the overlay

### Roadmap page access

- Unauthenticated request to `/roadmap` returns 404 or redirects to login — page does not render
- Authenticated request to `/roadmap` renders normally

### General

- No other site surface exposes these three items as navigation affordances
- Removing them from the nav does not break page routing for authenticated users
