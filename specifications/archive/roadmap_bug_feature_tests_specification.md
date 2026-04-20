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
- The suite owns its test accounts. The developer does not create them by hand and does not supply usernames.

### Self-managed test accounts

Usernames are constants owned by the suite:

- `playwright-test-user` — standard authenticated user
- `playwright-test-admin` — admin user, used only by the admin smoke tests

Passwords are supplied via env vars and are the only secrets the developer provides:

- `TEST_PASSWORD` — required to run the authenticated tests; suite skips them with a clear reason when unset
- `TEST_ADMIN_PASSWORD` — required to run the admin smoke tests; those skip when unset

Lifecycle, implemented as Playwright `globalSetup` / `globalTeardown`:

1. **Setup** (once before the suite): for each required account, check whether `config/www/user/accounts/<username>.yaml` exists. If not, create it via:
   ```
   docker exec grav bin/plugin login new-user \
     -u playwright-test-user -e playwright-test-user@example.invalid \
     -p "$TEST_PASSWORD" -n 'Playwright Test User' \
     -t default -s enabled
   ```
   The admin variant adds `-a admin.super` and uses `playwright-test-admin`. The check-then-create makes setup idempotent: a second run, or a leftover file from a crashed previous run, does not error.
2. **Teardown** (once after the suite): `rm -f config/www/user/accounts/playwright-test-user.yaml` and the admin counterpart. Use `-f` so a missing file (e.g. setup failed before creating it) is not an error.
3. **Per-test cleanup**: each test that creates domain artefacts (roadmap vote, bug report, feature suggestion) must remove them in `afterEach`. Where removal is not possible via a public endpoint (a submitted bug report), the test prefixes content with `[TEST]` so it is identifiable for later manual pruning. There is no `[TEST]` user — the user is removed by teardown.

### Robustness rules

- The `globalSetup` script must tolerate Docker not running by failing fast with an actionable error, not by silently skipping authenticated tests.
- A crash mid-suite may leave the account YAML on disk. This is harmless because setup is idempotent — the next run reuses the existing account.
- `make reset-users` already purges everything except the developer's admin. It will also wipe these test accounts, which is fine — the next test run recreates them.
- Tests must not rely on the state of existing roadmap items. Each test that needs a voteable item picks `.bv-rm-vote-btn[data-action="add"]:first` and tolerates the case where the budget is already full (skip with a clear message).
- Tests must never read or write any account file other than the two declared above.

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

**`tests/helpers/accounts.js`** (new, CommonJS)

- `TEST_USER` / `TEST_ADMIN` — frozen objects holding the canonical username, email, and full name for each account.
- `ensureAccount(account, password)` — runs the idempotent `docker exec … bin/plugin login new-user` command described above. Used by `globalSetup`.
- `removeAccount(account)` — `rm -f` on the account YAML. Used by `globalTeardown`.
- `hasUserPassword` / `hasAdminPassword` — booleans the test files use to skip when the corresponding password is not set.

**`tests/helpers/auth.js`** (exists, CommonJS — extend, do not break existing imports)

```js
const { login, loginAsAdmin } = require('../helpers/auth');
// login() and loginAsAdmin() use TEST_USER / TEST_ADMIN from accounts.js plus the env-var passwords.
// Old hasCredentials export is replaced by hasUserPassword / hasAdminPassword from accounts.js.
```

**`tests/helpers/cleanup.js`** (new, CommonJS)

- `removeVote(page, itemId)` — POSTs a remove to `/roadmap/vote` for the given item using the current nonce.
- `testMarker(prefix = 'TEST')` — returns `[TEST] <timestamp> <uuid>` so created items are identifiable.

**`tests/global-setup.js`** and **`tests/global-teardown.js`** (new) — wired into `playwright.config.js` via `globalSetup` / `globalTeardown`. They call `ensureAccount` / `removeAccount` for the user account always, and the admin account only when `TEST_ADMIN_PASSWORD` is set.

---

## Acceptance criteria

1. `npx playwright test` with no env vars set passes all anonymous tests and skips authenticated ones with a clear reason.
2. With `TEST_PASSWORD` set, `globalSetup` creates `playwright-test-user` if absent, the full user-facing matrix passes, and `globalTeardown` removes the account YAML so `config/www/user/accounts/` looks identical to before the run.
3. With `TEST_ADMIN_PASSWORD` also set, `playwright-test-admin` is created/torn down the same way and the admin smoke tests pass.
4. Re-running the suite immediately after a previous successful run, and re-running it after a previous crashed run that left the account YAML on disk, both succeed without manual intervention.
5. No test leaves a vote, bug report, feature suggestion, or account behind except `[TEST]`-prefixed domain items that cannot be cleaned via public endpoints.
6. The developer is never required to create a Grav account by hand to run the suite. The README testing section names only the two password env vars.
6a. `git check-ignore config/www/user/accounts/playwright-test-user.yaml` and the admin counterpart both report the file as ignored. The existing wildcard rule at `.gitignore` line 44 (`config/www/user/accounts/*`) covers this; the spec only requires that the rule remain in place, not that a new entry be added.
7. Each test file is <500 lines and uses `test.describe` blocks mirroring the headings above.
8. `playwright.config.js` gains `globalSetup` and `globalTeardown` entries; no new projects or browsers are added.

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
