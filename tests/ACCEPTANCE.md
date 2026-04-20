# Acceptance-Criteria Coverage Matrix

Maps each of the 8 source-spec acceptance criteria
(from `specifications/roadmap_bug_feature_tests_specification.md`) to the
specific test file(s) or helper(s) that cover it. Every row references a real
path in the repository.

| # | Acceptance criterion | Covered by |
|---|----------------------|------------|
| 1 | `npx playwright test` with no env vars passes all anonymous tests and skips authenticated with a clear reason naming the missing `TEST_PASSWORD`. | `tests/anonymous/*.js` (all anonymous specs run unconditionally); `tests/authenticated/roadmap.js`, `tests/authenticated/bug-report.js`, `tests/authenticated/feature-suggestion.js`, `tests/authenticated/navigation.js`, `tests/authenticated/footer.js` (top-level `test.skip(!hasUserPassword, 'TEST_PASSWORD not set — …')`); `tests/helpers/auth.js` (`hasUserPassword` flag). |
| 2 | With `TEST_PASSWORD` set, `globalSetup` creates `pw-test-user` if absent, the full user-facing matrix passes, and `globalTeardown` removes the YAML so `config/www/user/accounts/` matches pre-run state. | `tests/global-setup.js`, `tests/global-teardown.js`, `tests/helpers/accounts.js` (`ensureAccount` / `removeAccount`); wired via `playwright.config.js` `globalSetup` / `globalTeardown`. |
| 3 | With `TEST_ADMIN_PASSWORD` also set, `pw-test-admin` is created/torn down the same way and admin smoke passes. | `tests/global-setup.js`, `tests/global-teardown.js` (admin branch keyed on `hasAdminPassword`); admin-smoke blocks in `tests/authenticated/roadmap.js`, `tests/authenticated/bug-report.js`, `tests/authenticated/feature-suggestion.js`. |
| 4 | Re-running after a successful or crashed previous run (leftover YAML) both succeed without manual intervention. | Idempotent `ensureAccount` in `tests/helpers/accounts.js` (check-then-create via `docker exec grav bin/plugin login new-user`); procedure documented in the "Re-run robustness" subsection of `README.md`. |
| 5 | No test leaves a vote, bug report, feature suggestion, or account behind except `[TEST]`-prefixed domain items that cannot be cleaned via public endpoints. | `tests/helpers/cleanup.js` (`removeVote`, `testMarker`); `afterEach` cleanup in `tests/authenticated/roadmap.js`; `tests/global-teardown.js` (account cleanup). |
| 6 | Developer never required to create a Grav account by hand; README names only the two password env vars. | `README.md` "Testing" section (env-vars table + "you do not create Grav accounts by hand" subsection). |
| 6a | `git check-ignore` reports both account YAMLs as ignored via the existing `.gitignore:44` wildcard — no new entry added. | `tests/anonymous/gitignore.js` (shells out `git check-ignore` for both account paths and asserts each is reported ignored); pre-existing `config/www/user/accounts/*` rule in `.gitignore`. |
| 7 | Each test file < 500 lines with `test.describe` blocks mirroring spec headings. | All files under `tests/anonymous/` and `tests/authenticated/` are below 500 lines; describe-block headings mirror the source-spec sections (Page rendering, Vote flow, Overlay, Submission, Admin smoke, etc.). |
| 8 | `playwright.config.js` gains `globalSetup` / `globalTeardown`; no new projects or browsers. | `playwright.config.js` (`globalSetup: require.resolve('./tests/global-setup.js')`, `globalTeardown: require.resolve('./tests/global-teardown.js')`, single `chromium` project unchanged). |
