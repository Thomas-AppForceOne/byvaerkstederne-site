# Specification — Event RSVP & Rich Event Details

Status: Planned
Owner: thomas@appforceone.dk
Scope: Members sign up for (or mark interest in) events from the public site; everyone sees seat availability; organizers see who is coming; events carry a rich-text details body with images. Builds directly on the frontend event CRUD (PR #67) and ships behind the **existing, reserved `event_rsvp` feature flag** (on in dev/local, off elsewhere until ready).

**Language note (per CLAUDE.md):** all new developer-facing identifiers are English (`signups`, `signup_mode`, `details_html`, `admin.events.*` reuse); everything a visitor reads is Danish (Tilmeld / Interesseret / "x pladser tilbage" / flash messages).

---

## 0. Ground the CRUD PR already laid (do not re-do)

| Already in place (PR #67) | Consequence for this spec |
|---|---|
| `button_text` is a closed choice — `Tilmeld` or `Interesseret` — always rendered on the card, linking to `/begivenheder/<key>`; `button_url` is retired. | `button_text` **is** the signup mode: `Tilmeld` = binding signup counted against capacity; `Interesseret` = non-binding interest, never capacity-limited. No new field needed. |
| `capacity` is stored as `''` (unlimited, the default) or a bounded integer string. Legacy events may carry free text — treat any non-numeric capacity as unlimited. | Seat math is `(int)capacity - confirmed signups`. |
| The detail route `/begivenheder/<key>` exists with the §8.2 read contract (published ⇒ anyone; no existence leak), and cards/titles link to it. | The RSVP button and availability render on the detail page and cards without new routing. |
| The event-manager plugin owns the §8.1 mutation contract (flag → method → authn → CSRF → capability → ownership → mutate → audit → PRG) and the append-only `events-audit.jsonl`. | RSVP endpoints follow the same contract shape and audit channel. |
| The `organizers` group / `admin.events.*` namespace and the seeded `pw-test-org` Playwright account exist. | Attendee visibility is gated on ownership (owner or `admin.super`), reusing `EventAuthorizer`. |

---

## 1. In scope

1. **Sign up / withdraw** (`Tilmeld` events) and **mark/unmark interest** (`Interesseret` events) for logged-in, activated members — one signup per member per event, idempotent, reversible from the same button.
2. **Anonymous click ⇒ login offer**: the button opens the existing login overlay (with the register link) and returns to the event after login. No new auth surface.
3. **Public availability**: capacity-limited events show remaining seats ("3 pladser tilbage" / "Alle pladser er optaget"); unlimited events show only the count ("12 tilmeldte" / "12 interesserede"). Visible to everyone, including anonymous.
4. **Capacity enforcement**: a full `Tilmeld` event accepts no further signups (server-side check inside the mutation contract — the disabled button is UX only). No waitlist (out of scope).
5. **Organizer attendee list**: the owner (and super) sees who is signed up — username and full name — on the event's dashboard/detail management view. Not visible to other members.
6. **Rich details field**: a new `details` body on events, edited in a **full WYSIWYG editor** in the create/edit forms, with **image insertion**; rendered on the detail page.
7. Playwright coverage: success + forced-browsing negatives for every new endpoint, capacity race sanity, sanitizer round-trip, upload negatives.

## Out of scope

Waitlists, ticketing/payment, calendar export, email notifications/reminders, guest (+1) signups, self-service organizer onboarding.

---

## 2. Data model

**Signups live outside the event object** in a dedicated store, `user/data/flex-objects/event-signups.yaml`, keyed by event key:

```yaml
ev_abc123:
  pw-test-user: { ts: '2026-07-07T12:00:00Z', mode: tilmeld }
  anders:       { ts: '2026-07-07T12:05:00Z', mode: interesseret }
```

- Why not on the event object? Every event edit rewrites the whole object; concurrent signup-vs-edit must not clobber either. A separate file with the house atomic write (`flock` + full-file rewrite, same as roadmap votes) isolates the two write paths.
- `mode` is stamped from the event's `button_text` at signup time (lowercased identifier), so a later mode flip by the organizer does not reinterpret history.
- Live-tier data ⇒ off-git; the audit log records `signup` / `withdraw` actions with actor + event key.
- Counts are computed by reading this file — no denormalised counters to drift.

**Events** gain one field: `details` (server-managed name `details_html`, see §5) — sanitized HTML, empty by default. Blueprint-additive; no migration.

---

## 3. Endpoints & contract

Two mutating actions on the event-manager plugin (same interception point and contract order as §8.1 of the CRUD spec):

| Endpoint | Action |
|---|---|
| `POST /begivenheder/tilmeld` (`data[key]`) | Toggle the caller's signup/interest for the event. |

One endpoint, toggle semantics (mirrors the roadmap vote add/remove pattern): flag gate (`event_rsvp` **and** `event_management`) → POST → authn (401; the UX layer never lets an anonymous user reach this) → CSRF nonce → *no capability needed* (any activated member may sign up; `site.login` is the bar) → event must exist, be published, not archived, and its date not in the past (404/409) → capacity check for `tilmeld` mode (409 "Alle pladser er optaget" when full — checked inside the same `flock` as the write, so two racing signups cannot exceed capacity) → mutate → audit → respond (JSON for the AJAX button; PRG fallback with flash).

**Reads** (counts, "am I signed up?", attendee list) are injected server-side into the existing detail/dashboard templates — no new read endpoints. The attendee list renders only for owner/super (`EventAuthorizer::ownsOrSuper`).

---

## 4. UX

- **Cards + detail page**: under the meta column, the availability line (§1.3 wording). The card button stays a link to the detail page; the **live** signup button lives on the detail page (state-aware: "Tilmeld" / "Du er tilmeldt — klik for at framelde" / "Alle pladser er optaget", disabled when full or past).
- **Anonymous**: clicking the detail-page button opens the existing login overlay (`bv-login-overlay`) with a `redirect` back to the event; the overlay already links to `/opret-medlemskab`.
- **Organizer view**: the dashboard row and the detail page (for owner/super) show the attendee list with mode and timestamp, plus a count summary. Consider a CSV-ish copy affordance later — not in scope.

---

## 5. Rich details — full WYSIWYG (decision + plugin evaluation)

Decision requested by the owner: a **full WYSIWYG (HTML) editor**, not markdown.

**Plugin evaluation (do this first at implementation time):** the Grav ecosystem's editor plugins (e.g. `tinymce-editor`, `editor-buttons`, Quill-based experiments) target the **admin panel**, not frontend forms — there is no maintained frontend-form WYSIWYG plugin to "just install". Expect the outcome to be: **self-host a proven editor library** in the event form (theme-vendored, no CDN), with [TinyMCE (GPL self-hosted)](https://www.tiny.cloud) and [Quill](https://quilljs.com) as the candidates — TinyMCE preferred for real RTF feel (tables, images, paste-from-Word cleanup). Document the choice in the PR; if a suitable frontend plugin *has* appeared, prefer it.

**Non-negotiable security posture** (member-authored HTML is untrusted input):

1. The editor's output is stored as `details_html` **only after server-side sanitization** with an allowlist sanitizer (HTML Purifier via composer in the event-manager plugin — the established PHP standard). Allowlist: headings, p, br, strong/em/u, ul/ol/li, a (href http(s)/relative only, `rel="noopener"`), img (src restricted to the site's own upload path), blockquote, table basics. Everything else — scripts, styles, event handlers, iframes — is stripped. Sanitize on **write**; render with `|raw` only because the stored value is sanitizer-output.
2. **Images**: a dedicated upload endpoint on the event-manager plugin, gated by the full mutation contract (authn + `admin.events.create|update` + CSRF + flag). Validation reuses the bug-report plugin's magic-byte + extension + size checks verbatim; files land under `user/data/event-images/<event-key>/` with random names, `.htaccess` execution block, served via a plugin route (or direct path if the folder is web-reachable and execution-blocked — decide at implementation, mirroring bug-report's serving choice but public-read since event details are public).
3. Upload quota per event (e.g. 10 images / 5 MB each) to bound disk; hard-deleting an event removes its image folder.
4. The detail page renders `details_html` inside the themed article; the WYSIWYG is also fed the same sanitized value on edit (round-trip stable).

---

## 6. Feature flag & rollout

- Everything gates on `event_rsvp` (already in the FeatureFlag catalogue) **in addition to** `event_management`. Both on in dev/local; off in test/staging/prod until verified.
- Additive data only — no migration. Legacy events: non-numeric capacity ⇒ unlimited; missing `details` ⇒ section omitted.
- Note: `event_highlight.html.twig` already gates its CTA on `event_rsvp` — align it with the detail-page button when this lands.

---

## 7. Test plan (Playwright, reusing the pw-test-* seeds)

- Member signs up on a Tilmeld event → count +1 publicly, state-aware button flips, audit row; withdraw reverses it. Same for Interesseret (never capacity-blocked).
- Capacity: seed capacity=1, two members — second gets 409 and the public line shows "Alle pladser er optaget"; withdraw frees the seat.
- Unlimited event shows only the count, never "pladser tilbage".
- Anonymous: availability visible; button click opens the login overlay; direct POST ⇒ 401/redirect, nothing written.
- Attendee list: owner and super see it; another member/anonymous never does (no names leak in markup).
- Forced browsing: CSRF 403, unknown key 404, unpublished/archived/past event 409/404, flag-off ⇒ 404 on every new endpoint.
- Sanitizer: `<script>`/`onerror` payloads through the editor field are stripped server-side (stored value asserted); allowlisted formatting survives a save→edit→save round-trip.
- Uploads: non-image with image extension rejected (magic bytes), oversize rejected, anonymous/member-without-capability rejected; uploaded image renders on the detail page.
