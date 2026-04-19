# Specification — End-to-end test coverage for Roadmap, Rapportér fejl, and Forslå Feature

Status: Planned
Owner: thomas@appforceone.dk
Scope: Playwright tests under `tests/` that cover the three community-affordance features end-to-end.

---

## Goal

Expand the existing Playwright suite so the Roadmap page (`/roadmap`), the Bug-report overlay (`#bv-bug-report-overlay`), and the Feature-suggestion page + overlay (`/foreslaa-feature`, `#bv-feature-suggestion-overlay`) are each covered by anonymous and authenticated tests that exercise the full user flow — form submission, AJAX endpoints, success and error paths — not just visibility.

Today's suite covers nav/footer placement and a single roadmap vote add/remove. That is not enough to catch regressions in the PHP handlers or the overlay JS.

---

## Non-goals

- Unit tests for PHP classes. Keep this end-to-end only.
- Load/performance testing.
- Admin-only endpoints (`/admin/roadmap/release-votes`, `/admin/bug-report-promote`, `/feature-suggestion/approve|decline`) beyond a single happy-path smoke each — full admin coverage is out of scope for this sprint.
- Email-delivery verification (the `email` plugin is mocked at the SMTP layer in local dev).

---

## Layout

Follow the established test structure: entry point spec files are thin requirers, actual test cases live in focused files under `anonymous/` and `authenticated/`. Each new concern gets its own file.

```
tests/
  anonymous.spec.js               (existing entry point — add requires for new anonymous files)
  authenticated.spec.js           (existing entry point — add requires for new authenticated files)
  helpers/
    auth.js                       (exists — login() and hasCredentials)
    cleanup.js                    (new — best-effort teardown of items created by tests)
  anonymous/
    smoke.js                      (exists)
    navigation.js                 (exists)
    footer.js                     (exists)
    access-control.js             (exists)
    bug-report.js                 (new)
    feature-suggestion.js         (new)
  authenticated/
    navigation.js                 (exists)
    footer.js                     (exists)
    roadmap.js                    (exists — extend with full vote flow coverage)
    bug-report.js                 (new)
    feature-suggestion.js         (new)
```

Admin-credential tests live inside the relevant authenticated file inside their own `test.describe` block, skipped unless admin creds are set.

---

## Test environment

- Base URL: `http://127.0.0.1:8080` (configured in `playwright.config.js`).
- User credentials: `TEST_USERNAME` / `TEST_PASSWORD` env vars. Tests skip when unset.
- Admin credentials: `TEST_ADMIN_USERNAME` / `TEST_ADMIN_PASSWORD` for admin smoke tests only. Skip when unset.
- Every test that creates persistent data (roadmap vote, bug report, feature suggestion) must clean up after itself in an `afterEach` where possible. Where cleanup is not possible (e.g. submitted bug report) the test must use a clearly prefixed payload (`[TEST] …`) so the data is identifiable and can be pruned manually.
- Tests must not rely on the state of existing roadmap items. Each test that needs a voteable item picks `.bv-rm-vote-btn[data-action="add"]:first` and tolerates the case where the budget is already full (skip with a clear message).

---

## Coverage requirements

### 1. Roadmap

Extend `tests/authenticated/roadmap.js`. Anonymous redirect is already covered in `tests/anonymous/access-control.js`.

**Authenticated — page rendering**

- `/roadmap` returns 200, renders at least one item container (`.bv-rm-item` or equivalent), and exposes the budget widget.
- Items with locked statuses (`under_implementation`, `klar_til_test`, `loest`) render without an add-vote button or with it disabled.

**Authenticated — vote flow**

- Add vote: click `.bv-rm-vote-btn[data-action="add"]`, assert the remove button appears, assert the displayed vote count increments by one, assert no `pageerror`.
- Remove vote: from the post-add state, click remove, assert add button reappears and count decrements.
- Nonce re-issue: capture the hidden `vote_nonce` before the click, assert the DOM value changed after the successful response (the handler issues a fresh nonce).
- Budget enforcement: vote on items until the category budget (3) is hit, then assert the next add attempt surfaces the user-facing error toast and does not increment the count. Clean up all votes added by the test.
- Locked item: attempt to POST `/roadmap/vote` with an `item_id` of a locked status using `page.request.post(...)` — expect a 4xx JSON error.
- AJAX error surface: with network intercepted to return 500, clicking add shows an error toast and leaves the button in its original state.

**Admin smoke** (skipped unless admin creds set)

- Admin can POST `/admin/roadmap/release-votes` for a single item and get `success: true`.

---

### 2. Rapportér fejl

Anonymous tests in `tests/anonymous/bug-report.js`, authenticated in `tests/authenticated/bug-report.js`.

**Anonymous**

- Footer button absent (already covered in `tests/anonymous/footer.js` — do not duplicate).
- `POST /bug-report/submit` without auth returns 401/redirect (use `page.request.post`).

**Authenticated — overlay**

- Footer trigger opens `#bv-bug-report-overlay` (already covered in `tests/authenticated/footer.js` — do not duplicate).
- Overlay closes on its close control and on Escape.
- `page_url` and `browser_os` hidden fields are auto-populated before submit.

**Authenticated — submission**

- Happy path: fill `description`, `expected`, add two `steps[]` rows, submit without image, assert `#bv-bug-report-message` shows success and contains a link to the created roadmap item (href matches `/roadmap#…`). Follow the link and assert the roadmap page renders the new item with display_id prefix `#B`.
- Validation: submit with empty `description` — assert inline error, no network call (or 400 from server if JS guard is absent).
- Image upload: attach a valid 1×1 PNG fixture, submit, assert success. Attach a non-image file and assert server-side magic-byte validation rejects it with a visible error.
- Size cap: attach a >5 MB file and assert rejection.
- Double-submit: click submit twice rapidly; assert only one roadmap item is created (verify by counting matches of the generated display_id on `/roadmap`). This exercises the `submission_token` guard.
- Nonce tampering: override `bug_report_nonce` to a garbage value and submit; expect 403.

**Admin smoke** (skipped unless admin creds set)

- Legacy `/admin/bug-report-promote` returns 409 `already_auto_published` when called against a report that was auto-promoted.

---

### 3. Forslå Feature

Anonymous tests in `tests/anonymous/feature-suggestion.js`, authenticated in `tests/authenticated/feature-suggestion.js`.

**Anonymous**

- `GET /foreslaa-feature` returns <400 (already covered in `tests/anonymous/access-control.js` — do not duplicate).
- Anonymous users see a login prompt and no form fields (`fs_title` input is absent).
- `POST /feature-suggestion/submit` without auth returns 401/redirect.

**Authenticated — page and overlay**

- `/foreslaa-feature` renders the form with `fs_title`, `fs_description`, `fs_community_value` fields and a hidden `fs_nonce`.
- Footer trigger opens `#bv-feature-suggestion-overlay` (already covered in `tests/authenticated/footer.js` — do not duplicate).
- Overlay form has the same three required fields and its own nonce.

**Authenticated — submission (from both page form and overlay)**

- Happy path: submit with non-empty values, assert `#bv-fs-overlay-confirmation` (or page equivalent) shows success, response contains `roadmap_id` and `display_id` starting with `#F`. Navigate to `roadmap_url` and confirm the item appears with status `rapporteret` and type `feature`.
- Whitespace-only values: submit with `fs_title` set to `"   "` — expect 400 validation error.
- Double-submit: exercise the shared submission-token guard.
- Nonce tampering: garbage `fs_nonce` → 403.
- HTML escaping: submit `fs_title` containing `<script>alert(1)</script>`; visit the generated roadmap item and assert the script tag does not execute (`pageerror` remains empty) and the text is rendered escaped.

**Admin smoke** (skipped unless admin creds set)

- `/feature-suggestion/approve` is idempotent: calling against an auto-published suggestion returns 200 with `already_approved: true`.

---

## Shared helpers

**`tests/helpers/auth.js`** (exists, CommonJS)

```js
const { login, hasCredentials } = require('../helpers/auth');
// Add loginAsAdmin() and hasAdminCredentials for admin smoke tests
```

**`tests/helpers/cleanup.js`** (new, CommonJS)

- `removeVote(page, itemId)` — POSTs a remove to `/roadmap/vote` for the given item using the current nonce.
- `testMarker(prefix = 'TEST')` — returns `[TEST] <timestamp> <uuid>` so created items are identifiable.

---

## Acceptance criteria

1. `npx playwright test` (without credentials) passes all anonymous tests and skips authenticated ones with a clear reason.
2. With user creds set, the full user-facing matrix above passes against a fresh local Docker site.
3. With admin creds set, the admin smoke tests pass.
4. No test leaves a vote, bug report, or feature suggestion behind except `[TEST]`-prefixed items that cannot be cleaned via public endpoints.
5. Each test file is <500 lines and uses `test.describe` blocks mirroring the headings above.
6. `playwright.config.js` retains its current shape; no new projects or browsers are added.

---

## Out of scope / deferred

- Mobile viewport coverage — add in a follow-up sprint once desktop is green.
- Visual-regression snapshots.
- CI wiring (GitHub Actions).

---

## References

- Existing tests: `tests/anonymous/`, `tests/authenticated/`, `tests/helpers/auth.js`
- Playwright config: `playwright.config.js`
- Handlers: `config/www/user/plugins/roadmap/roadmap.php`, `config/www/user/plugins/bug-report/bug-report.php`, `config/www/user/plugins/feature-suggestion/feature-suggestion.php`
- Templates: `config/www/user/themes/byvaerkstederne/templates/roadmap.html.twig`, `config/www/user/themes/byvaerkstederne/templates/foreslaa-feature.html.twig`
- Related ADR: `decisions/ADR-001-navigation-footer-placement.md`
