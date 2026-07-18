# Implementation Plan — Event RSVP & Rich Event Details

Companion to [event_rsvp_specification.md](event_rsvp_specification.md). Working document for the
`feature/event-rsvp` branch; delete or archive alongside the spec when the feature ships.

**Branch:** `feature/event-rsvp` off `develop`. All work lands in the existing `event-manager`
plugin + theme; gated on `event_rsvp` **and** `event_management` (both already in the
`FeatureFlag` enum — `event_rsvp` at `FeatureFlag.php:41`).

Seven phases, each independently committable with a green suite. Phases 1–3 are the RSVP core;
4 is the modal UX; 5–6 are rich details; 7 is the test sweep and flag alignment.

---

## Phase 1 — Signup store (`SignupRepository`)

New class `src/SignupRepository.php` in the event-manager plugin, owning
`user/data/flex-objects/event-signups.yaml` (map: event key → username → `{ts, mode}`).

- **Atomic write pattern:** use the bug-report plugin's strong pattern
  (`saveRoadmapItemAtomic()`, `bug-report.php:419-477`): `fopen('c+')` → `flock(LOCK_EX)` →
  read+parse → mutation callback → `ftruncate`/`rewind`/`fwrite` → unlock in `finally`. The spec
  says "same as roadmap votes," but roadmap's `saveYaml()` only uses
  `file_put_contents(..., LOCK_EX)` — that is *not* a read-modify-write under one lock, and the
  capacity check must happen inside the same lock as the write (spec §3). The bug-report variant
  is the one that actually delivers that; the mutation callback receives the parsed map and
  returns the new map *or a typed rejection* (event full), so two racing signups can't exceed
  capacity.
- API: `toggle(eventKey, username, mode, ?capacity): result` (signed_up | withdrawn | full),
  `countFor(eventKey, mode)`, `isSignedUp(eventKey, username)`, `attendeesFor(eventKey)`
  (username + ts + mode), `deleteFor(eventKey)` (used by hard delete).
- `mode` stamped at signup time from the event's `button_text`, lowercased
  (`tilmeld`/`interesseret`), per spec §2.
- Full-name resolution for the attendee list: look up each username via Grav's accounts
  (`$grav['accounts']`) at render time — not stored in the signup file.
- PHPUnit tests for the toggle/capacity logic (event-manager already has the feature-flags
  composer-dev precedent); the capacity race additionally gets a Playwright sanity test in
  Phase 7.

## Phase 2 — Toggle endpoint `POST /begivenheder/tilmeld`

Extend the existing mutation contract in `event-manager.php` rather than mirroring it:

- Add `'tilmeld' => 'rsvp'` to `mutationActionForPath()` (`event-manager.php:360-372`), with two
  deviations handled in `onPageInitialized()` (`:302-357`):
  - **Flag gate:** `rsvp` requires `event_rsvp` **and** `event_management`; either off →
    existing `sendFlagDisabled404()`.
  - **Capability step skipped** for `rsvp` — any authenticated+authorized member qualifies
    (`site.login` is the bar). Authn 401 and CSRF 403 checks stay exactly as-is.
- **CSRF:** dedicated nonce action `'event-rsvp'`, read from `$_POST['rsvp_nonce']`, verified
  with `Utils::verifyNonce()`, and a fresh `new_nonce` minted into every success response — the
  roadmap-vote rotation pattern (`roadmap.php:288`, `:377`), which the AJAX button needs (the
  shared `'form'` nonce is fine for full-page forms but the button flips state without
  navigation).
- `handleRsvp()` order after the shared gates: `data[key]` matches `KEY_PATTERN` and event
  exists → 404 (same no-leak posture as the detail route); published && !archived → 404;
  `event_date` in the past (Europe/Copenhagen) → 409; then `SignupRepository::toggle()` with
  capacity passed only for `tilmeld` mode (non-numeric/empty capacity ⇒ unlimited, per spec §0);
  `full` result → 409 with Danish message "Alle pladser er optaget".
- **Audit:** `AuditLog::append('signup'|'withdraw', $key, $username, ['mode' => …])` — same
  JSONL channel.
- **Response:** content-negotiated like `validateOr400()` (`:520`): JSON
  `{success, action: 'signed_up'|'withdrawn', count, remaining, new_nonce}` for AJAX;
  PRG-with-flash back to the referring page for no-JS.

## Phase 3 — Server-side reads + card button + availability line

No new read endpoints (spec §3). Register two Twig functions in the plugin's existing
`onTwigInitialized`:

- `event_signup_info(key)` → `{count, remaining, is_full, user_signed_up, mode}` (remaining only
  for numeric-capacity tilmeld events). Available to any template; data is public.
- `event_attendees(key)` → attendee list **or null**, with the `EventAuthorizer::ownsOrSuper()`
  check enforced inside the PHP function — a template can't leak names by accident.

Template changes:

- `partials/event_card.html.twig` — the single card chokepoint (all surfaces route through it).
  When `event_rsvp` is on and the event carries a key: render the CTA as a
  `<button class="bv-btn …" data-rsvp-key data-rsvp-mode data-rsvp-state>` instead of the
  current `<a>` (`:81-84`). States: "Tilmeld" / "Du er tilmeldt — klik for at framelde" /
  "Alle pladser er optaget" (disabled) / disabled when past. Interesseret events:
  "Interesseret" / marked state, never capacity-disabled. Availability line under the meta
  column: capacity-limited → "3 pladser tilbage" / "Alle pladser er optaget"; unlimited →
  "12 tilmeldte" / "12 interesserede". Flag off → today's link behaviour, untouched.
- `modular/event_list.html.twig` and `event_detail.html.twig` (`_cta = null` at `:20` — the
  comment at `:18-19` already reserves this slot) pass key/mode/signup-info into the card.
- Nonce: one hidden `nonce_field('event-rsvp', 'rsvp_nonce')` container per page (authenticated
  only), mirroring `#bv-rm-vote-nonces` (`roadmap.html.twig:170`).

JS (in `site.js`, following the roadmap vote handler): delegate clicks on `[data-rsvp-key]`;
anonymous → `bvOpenOverlay('bv-login-overlay')` (the overlay form POSTs to the current URL, so
the login plugin's referrer redirect brings the user back to the event — no new redirect
plumbing needed); authenticated → `fetch('/begivenheder/tilmeld', FormData)`, optimistic
button/count flip with rollback on error, nonce rotation from `new_nonce`, update **all** cards
with the same key (calendar + modal can show the same event twice).

**Dashboard attendee list:** `event_dashboard.html.twig` gains a per-row expandable attendee
section (username, full name, mode, timestamp, count summary) via `event_attendees()`.

## Phase 4 — Card modal expansion

- Every card click that isn't the button or a link expands the card modally: dimmed backdrop,
  Esc/backdrop/luk close, focus trap + `aria-modal` + focus restore — copy the
  feature-suggestion overlay pattern (`site.js:406-503`), the fullest existing implementation.
- Expanded content: description (always visible in both states, per spec §4), full
  `details_html` body, all meta, availability line, live signup button. The details body is
  delivered server-side as a hidden `<template data-event-details>` inside each card (keeps
  "reads injected into existing templates" true; images inside get `loading="lazy"`).
- `history.pushState` to `/begivenheder/<key>` on open, `popstate`/close restores; a direct load
  of that URL still renders the full server page (existing detail route, untouched) — the
  no-JS/SEO fallback.
- The detail page itself shows the same content inline (no modal needed there).

## Phase 5 — Rich details field + sanitizer

- **Plugin evaluation first (spec §5 mandates it):** check the Grav ecosystem for a maintained
  frontend-form WYSIWYG plugin; expected outcome per spec is none → **vendor TinyMCE (GPL
  self-hosted)** into the theme (`theme://js/vendor/tinymce/`), no CDN. Document the choice +
  evaluation outcome in the PR body.
- **Blueprint + form:** additive `details` textarea in `begivenheder.yaml` and the create/edit
  form frontmatter; TinyMCE enhances it progressively (plain textarea without JS still posts
  HTML-ish text — the sanitizer makes that safe). Edit form default feeds the stored value back
  in (round-trip stable, spec §5.4).
- **Sanitize on write:** HTML Purifier via composer in the event-manager plugin, **vendor/
  committed** (established convention — every plugin with deps commits its vendor/, and no
  CI/deploy step runs composer for plugins). New `src/DetailsSanitizer.php` wrapping Purifier
  with the spec's allowlist: headings, p, br, strong/em/u, ul/ol/li, a (`http(s)`/relative href
  only, forced `rel="noopener"`), img (src restricted to the event-image serving path),
  blockquote, table basics. Plus a raw-size cap (e.g. 200 KB) before purification.
  `EventValidator` sanitizes `data[details]` → stores as `details_html` (server-managed name);
  the raw field is never persisted.
- **Rendering:** `event_detail.html.twig` + the card modal template render `details_html|raw` —
  safe only because the stored value is sanitizer output, and a code comment says exactly that.
- PHPUnit tests for the sanitizer (script/onerror/iframe stripped; allowlist survives;
  idempotent on its own output).

## Phase 6 — Image upload + serving

- **Endpoint `POST /begivenheder/upload`** — added to `mutationActionForPath()` with the
  **full** contract: flags → POST → authn → CSRF (`'form'` nonce is fine here; the editor can
  read it from the surrounding form) → capability `admin.events.create` or
  `admin.events.update` → validate → store → JSON `{location}` (TinyMCE's upload-handler shape).
- **Validation reuses bug-report verbatim** (spec §5.2): magic-byte sniffing (`detectMimeType`,
  `bug-report.php:598-632`), extension allowlist, 5 MB cap. Extract into a shared helper inside
  event-manager (copy, don't cross-import plugins).
- **Storage:** `user/data/event-images/<event-key>/<32-hex>.<ext>`, `.htaccess` exec-block +
  deny-all + empty `index.html` on dir create (bug-report `:575-584`). **Quota:** max 10 images
  per event, enforced by counting the folder inside the handler.
- **Create-form problem — the event key doesn't exist yet at upload time.** Solution:
  pre-generate the `ev_` key server-side as a hidden field on the create form (via
  `FormDataProvider`), and have `handleCreate()` adopt the posted key when it's well-formed and
  unused (the repository already pins keys via `setStorageKey()`). Upload authorization rule: if
  the key resolves to an existing event → `ownsOrSuper` required; if it doesn't exist → allowed
  for capability-holders only (bounded by quota; orphaned folders from abandoned create forms
  are organizer-only, quota-capped residue — acceptable, noted in PR).
- **Serving:** plugin route `GET /begivenheder/billede/<key>/<file>` streaming with
  magic-byte-derived Content-Type, `X-Content-Type-Options: nosniff`, public cache headers —
  bug-report's `handleImageServe()` (`:682-730`) minus the admin gate, since event details are
  public. Strict filename regex, no path traversal possible.
- **Hard delete** (`handleDelete()` hard branch) additionally calls
  `SignupRepository::deleteFor()` + recursive removal of the event's image folder.

## Phase 7 — Flag alignment, tests, docs

- **`modular/event_highlight.html.twig` alignment (spec §6):** it still gates its CTA on
  `event_rsvp && button_url` (`:61-63`) — rewire to the same live signup button as the other
  cards; drop the `button_url` dependency.
- **Playwright** (new suites; fixtures extended in `tests/helpers/fixtures.js` with a
  capacity=1 event + a helper that seeds/clears `event-signups.yaml`; teardown cleans the
  signups file and image folders):
  - `tests/authenticated/events-rsvp.js` — signup from the card button → public count +1,
    button flips without navigation, audit row; withdraw reverses; Interesseret never
    capacity-blocked; capacity=1 with two members → second gets 409 and public line reads
    "Alle pladser er optaget"; withdraw frees the seat.
  - `tests/anonymous/events-rsvp-public.js` — availability visible anonymously; unlimited
    events show count only, never "pladser tilbage"; button click opens `#bv-login-overlay`;
    direct POST → 401, nothing written; attendee names absent from anonymous/other-member
    markup; forced browsing: CSRF 403, unknown key 404, unpublished/archived/past 409/404,
    flag-off → 404 on every new endpoint (tilmeld, upload, billede).
  - Card-modal suite — click-to-expand, Esc/backdrop close, URL pushState, direct
    `/begivenheder/<key>` load renders the same content.
  - `tests/authenticated/events-details.js` — `<script>`/`onerror` payloads stripped in the
    stored YAML (asserted via docker exec, like events-crud does today); allowlisted formatting
    survives save→edit→save; upload negatives (fake extension, oversize, anonymous,
    member-without-capability) and a positive that renders on the detail page.
- **PR-time:** spec is archived only on explicit "ready to merge"; PR body documents the
  WYSIWYG plugin evaluation outcome and flags the ADR question (sanitize-on-write + separate
  signup store are ADR-worthy decisions).

---

## Open decisions (default position stated; veto before Phase 1/5 respectively)

1. **TinyMCE over Quill** — spec expresses the preference; real cost is vendored size
   (TinyMCE + HTML Purifier add a few MB of committed vendor code → deploy footprint).
2. **Bug-report's flock pattern, not roadmap's `file_put_contents(LOCK_EX)`** for the signup
   store — the capacity-check-inside-the-lock requirement is only met by read-modify-write
   under one lock.
3. **Details delivered as a hidden `<template>` per card** for the modal, rather than a fetch —
   honors "no new read endpoints"; cost is calendar-page weight when many events carry
   image-heavy details.
4. **Pre-generated event key on the create form** to make image upload work before first save.
