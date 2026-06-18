# Specification — Member account creation & login hardening

Status: Planned
Owner: thomas@appforceone.dk
Scope: Configuration, theme templates, tests, `.gitignore`, a `deploy.sh` extension that wires per-tier `email.yaml` into the atomic-release symlink contract, and the test Docker (Mailpit) stack — for the self-service member registration and login flow. The stock Grav `login` plugin (v3.8.0) and `email` plugin (v4.2.2) are configured and themed — neither plugin's PHP is modified. The one-time `migrate-to-atomic-layout.sh` is a completed migration and is explicitly out of scope (see WI-1).

---

## Goal

Close the seven findings from the June 2026 review of the member account-creation and login system. Each finding becomes a self-contained work item (WI) with its own acceptance criteria; together they bring the auth flow to a state where:

- a member who forgets their password can recover it (today they cannot);
- an account cannot be created against an email address the registrant does not control, and a brand-new account cannot reach member-only content until the email is verified;
- no authentication secret is committed to the repository;
- the session cookie carries the protections expected of a TLS site behind a reverse proxy;
- the password and username policies are written down in this repo rather than inherited implicitly from whatever Grav core ships;
- the custom registration/login surface has Playwright coverage on both the success and at least one failure path, per [CLAUDE.md](../CLAUDE.md#testing-discipline);
- the registration form's error handling and copy match the rest of the Danish-language site.

The auth engine itself is the unmodified upstream `login` plugin (confirmed: committed wholesale in the initial commit, no local patches). This spec changes **configuration, theme templates, tests, `.gitignore`, the ongoing `deploy.sh` state-file wiring (to provision per-tier `email.yaml`), and the test Docker (Mailpit) stack** only — no plugin PHP, and the completed one-time `migrate-to-atomic-layout.sh` is not touched.

---

## Non-goals

- **No changes to the `login` or `email` plugin PHP.** Everything here is config, Twig, secrets-handling, and tests. If a desired behaviour genuinely requires patching a stock plugin, stop and raise it — do not fork the plugin inside this spec.
- **No human/admin approval workflow.** This spec verifies *email ownership* before access; it does not add a "an officer must approve each new member" gate. Coupling verified-email to approved-membership is a larger product change and is explicitly deferred. (Called out as an open question in WI-2.)
- **No 2FA.** Two-factor stays disabled; revisit separately.
- **No git-history rewrite as a hard requirement.** WI-3 rotates the exposed salt and stops tracking the file going forward; scrubbing the salt out of historical commits with `git filter-repo` is noted as optional follow-up, not a gate.
- **No new member-only pages.** This spec hardens the gate; it does not add content behind it. (Today the gate protects `/roadmap` and the footer community affordances only.)

---

## Background — what exists today

| Area | Current state | Reference |
|---|---|---|
| Registration page | `/opret-medlemskab`, themed, uses Grav's form renderer (CSRF nonce auto-injected), server-gated by the `membership_signup` feature flag (404 when off). | `pages/09.opret-medlemskab/register.md`, `themes/byvaerkstederne/templates/register.html.twig` |
| Login | Themed overlay with `nonce_field('login-form', …)`; rate-limited (5/10 min + IP). | `templates/partials/login_overlay.html.twig` |
| Registration config | Self-service open registration; `set_user_disabled: false`, `send_activation_email: false`, `login_after_registration: true`. New users get `access.site.login: true`, `level: Newbie`. | `config/plugins/login.yaml:12-31` |
| Password policy | Enforced server-side in `Login::register()` → `validateField()` against `system.pwd_regex`, but that regex is **not** set in this repo — it falls back to Grav core defaults. | `plugins/login/classes/Login.php:270,379-390`; `config/system.yaml` (no `pwd_regex`) |
| Forgot/reset/activate | Plugin dynamic routes only — **no themed templates**, and `built_in_css: false`, so they render unstyled. No `email.yaml` exists, so reset mail has no transport. | `config/plugins/login.yaml:2`; absence of `config/plugins/email.yaml` |
| Salt | `config/www/user/config/security.yaml` (root) is **tracked in git** with a real salt. Per-tier `user/env/*/config/security.yaml` are correctly gitignored and provisioned as per-tier state by `deploy.sh`. | `.gitignore:110-114`, `deploy/deploy.sh:826-831` |
| Session cookie | No `session:` block in `system.yaml` → Grav defaults (`secure: false`, `samesite: Lax`). Site runs behind a TLS-terminating proxy (`reverse_proxy_setup: true`). | `config/system.yaml` |
| Tests | No coverage of the custom registration/login surface. | `tests/` |

---

## Prerequisites — per-tier mail provisioning (operational, before WI-1/WI-2 ship to a tier)

WI-1 and WI-2 only become *usable* on a tier once that tier can actually deliver mail; flipping the verification gate (WI-2) on a tier that cannot deliver locks new members out (they register, never receive the activation link, cannot log in). These provisioning steps are independent of the code, carry external lead time (mailbox creation, SMTP enablement, DNS propagation), and should be started before — or in parallel with — implementation. They are **not** code changes and do not belong in a sprint commit; they are recorded here so the gate flip is sequenced behind confirmed delivery.

**From identity (decided):** transactional mail uses a dedicated `noreply@` address per tier — never the site contact `kontakt@byvaerkstederne.dk`. The From domain deliberately matches each tier's sending infrastructure so SPF/DKIM/DMARC align cleanly:

| Tier(s) | Sending host | From address | Delivery posture |
|---|---|---|---|
| dev, test, CI | one.com (hackersbychoice.dk) | `noreply@hackersbychoice.dk` | **Sink** — Mailpit (API-queryable; see WI-6). No real outbound mail; no mailbox strictly required, but the From is fixed for when the path is exercised locally. |
| staging | one.com (hackersbychoice.dk) | `noreply@hackersbychoice.dk` | **Full sandbox — never delivers to real inboxes (decided).** Staging carries real prod member data (ADR-002), so it must not be able to email a real member from a test environment. Capture all mail; use a Mailtrap *sandbox* (real one.com SMTP send path, captured instead of delivered) if you want staging to rehearse the SMTP/DKIM path without real delivery. |
| prod | chosting.dk (byvaerkstederne.dk) | `noreply@byvaerkstederne.dk` | **Real SMTP — the only tier that delivers to real members.** It is therefore the first place real-world deliverability is exercised; validate it at cutover via Prerequisites step 4. |

**Provisioning checklist per sending domain:**

1. Create the `noreply@` mailbox / SMTP sending account: `noreply@hackersbychoice.dk` on one.com, `noreply@byvaerkstederne.dk` on chosting. Confirm SMTP is enabled (chosting SSH required a support ticket — SMTP may similarly need enabling; verify early).
2. Set deliverability DNS on each sending domain: SPF listing the host's SMTP, DKIM signing, and a DMARC record. Without these, activation/reset mail spam-folders and WI-2 makes the tier unusable. DNS has propagation lead time — do this first.
3. Place credentials in the tier's gitignored `user/env/<host>/config/email.yaml` (host/port/user/password/encryption); never in the repo-tracked `email.yaml`.
4. **Confirm real delivery on the tier** (send a test activation/reset to a real inbox and verify it lands, not in spam) *before* enabling WI-2's verification gate on that tier.

**Quick pre-check worth doing now:** the bug-report plugin already mails `kontakt@byvaerkstederne.dk` (`site.yaml:5`, `bug-report` blueprints). Whether that mail currently arrives tells you what prod's transport really is today — if it silently fails, that confirms the reset path is dead for the same reason and clarifies how much SMTP work prod actually needs.

---

## Work items

Work items are ordered by dependency. WI-3, WI-4, WI-5, WI-7 are independent and small; WI-1 must land before WI-2 (verification needs working email); WI-6 covers all of them. Each WI may ship as its own PR — they share this spec but do not have to land together. Per-tier mail delivery (see Prerequisites) is an operational precondition for WI-2's gate flip, not a code dependency.

---

### WI-1 — Working password reset and email transport (review finding #1, High)

**Problem.** The login overlay links to `/forgot_password` (`login_overlay.html.twig:44`), but (a) there is no `email.yaml`, so the `email` plugin has no SMTP transport and reset mail is best-effort PHP `mail()` — unreliable or disabled on one.com / chosting shared hosting; and (b) the forgot/reset routes have no themed template and `built_in_css: false`, so they render unstyled. Net: a member who forgets their password cannot recover it, and there is no admin self-serve UI in this repo.

**Change.**

1. Add `config/www/user/config/plugins/email.yaml` enabling SMTP, with **no credentials in the file**. Host/port/user/password/encryption come from each tier's gitignored per-environment config (`user/env/<host>/config/email.yaml`), following the exact pattern already used for `security.yaml`. The repo-tracked `email.yaml` carries only non-secret defaults (`mailer.engine: smtp`, `charset`, and the non-prod `from`/`from_name`) and a documented note that the transport block is provisioned per tier and out of band. The **From identity is per-tier** (see Prerequisites): the repo default `from` is `noreply@hackersbychoice.dk` (used by dev/test/staging); prod's `user/env/www.byvaerkstederne.dk/config/email.yaml` overrides `from` to `noreply@byvaerkstederne.dk`. The site contact address `kontakt@byvaerkstederne.dk` (`site.yaml:5`) is **not** used as the transactional From — keep transactional mail on its own `noreply@` identity per tier.
2. Add the per-environment `email.yaml` path to `.gitignore` (`config/www/user/env/*/config/email.yaml`) and extend **`deploy.sh`** to treat it as per-tier state exactly as it does `security.yaml`: add `email.yaml` to the first-deploy bootstrap move-into-`<tier>data` block (`deploy.sh:826-831`) and to the symlink-wiring list (`:843-850`), which today names each state file individually and therefore silently ignores any file not on the list. Because `deploy.sh` only symlinks the state files it knows by name, an operator- or hand-placed `email.yaml` is otherwise never linked into a release, so this automation — not manual placement — is the supported path. Already-migrated tiers receive `email.yaml` through this ongoing `deploy.sh` path on their next deploy.

   **`migrate-to-atomic-layout.sh` is explicitly NOT touched.** It is a completed one-time migration that refuses to run on an already-atomic tier (header §Sanity check; ADR-004 §Real-remote migration), and it predates `email.yaml`, so it has nothing to provision — every tier is already atomic, and a new per-tier file arrives via `deploy.sh`, never via the migration.

   **ADR-004 constraint (in scope, must be honoured).** The two blocks above run inside `bv_remote_run`, so per [ADR-004](../decisions/ADR-004-atomic-deploy-fixture-only-testing.md) §Consequences this is "a change to remote-mode code paths" and must be paired with one of: (a) an extension to `tests/deploy/lint-remote-ssh.sh`, (b) an operator-supervised dev-tier run, or (c) a superseding ADR. The fixture-level deploy-path test in the acceptance criteria is local-mode coverage and does **not** by itself discharge this obligation — the PR must also satisfy (a), (b), or (c).

   **Absent-file failure category — `email.yaml` is NOT in `security.yaml`'s "may-dangle" class.** The shipped symlink contract splits per-tier state into *must-resolve* (accounts/data/logs — fatal if the symlink dangles) and *may-dangle* (`security.yaml`, which Grav regenerates with a fresh salt if absent). `email.yaml` is neither: Grav does not regenerate SMTP credentials, so an absent `email.yaml` does not fail loud and does not self-heal — it silently degrades to PHP `mail()`, the exact WI-1 defect, on the very fresh-tier / post-recovery path atomic-deploy exists to make safe. Wiring it "everywhere `security.yaml` is named" is therefore wrong: `email.yaml` is its own third category — **operator-provisioned, must-be-present-to-function but not fatal-to-boot.** The deploy/preflight must emit a non-fatal **WARN** when a tier's `email.yaml` is missing (so the silent degrade becomes visible), and the documented contract is "transactional mail degrades to non-sending until the tier's `email.yaml` is provisioned."

   **Promotion invariant — `email.yaml` is tier-pinned and MUST NEVER be synced across tiers.** It shares `user/env/<host>/config/` with `features.yaml`, which the promotion specs deliberately copy between tiers; `email.yaml` (like `security.yaml`) must not. The promotion specs' sync allow-lists must never widen to `env/<host>/config/*.yaml` — only `features.yaml` in that directory is promotable. (Cross-reference: [promote_to_staging](promote_to_staging_specification.md), [promote_to_prod](promote_to_prod_specification.md). This spec does not edit them; it records the invariant they must continue to honour so a future allow-list widening cannot carry SMTP credentials across tiers.)
3. Provide themed Twig templates in `themes/byvaerkstederne/templates/` for the **three** login-plugin routes that render a page and currently fall back to unstyled plugin defaults: `login.html.twig`, `forgot.html.twig`, `reset.html.twig`. Each extends `partials/base.html.twig` so it renders inside the site shell (header + footer), consistent with the existing custom `register.html.twig`. `built_in_css` stays `false`. **There is no activation *page* to theme:** the `route_activate` (`/activate_user`) handler processes the token, adds a flash message, and redirects to `/` — its only user-visible surface is the flash on `/`, which WI-2 covers. (The plugin ships an *email* template at `templates/emails/login/activate.html.twig`; that is the activation mail body, not a page.)
4. For local dev and CI, reset/activation mail is captured by an **API-queryable, non-delivering sink — Mailpit** — so the flow is testable without sending real mail *and* a test can read the captured message to extract the token (see WI-6 for the mechanism). A pure log/debug engine is **not** sufficient for WI-6's token-usability tests because scraping a log for the link is brittle; Mailpit's REST API is the contract the tests depend on. The test Grav's SMTP points at Mailpit (`mailpit:1025`, no auth); the repo-tracked `email.yaml`'s SMTP block is overridden by the test environment's config. Document the sink in `tests/fixtures/grav-seeds/README.md` or the test setup.

**Acceptance criteria.**

- `GET /forgot_password` returns 200 and renders inside the themed site shell (asserts the site header/footer markers are present), not the unstyled plugin fallback.
- `GET /login` returns 200 and renders inside the themed site shell (same header/footer-marker assertion), not the unstyled plugin fallback. (`/reset_password` is covered below; activation has no page — see WI-2 for its flash criterion.)
- Submitting a valid registered email at `/forgot_password` results in a reset message being generated: in the test environment the captured message contains a `/reset_password` link bearing a token for that user (assert against the sink, not real delivery).
- Following that link renders a themed `/reset_password` form (200, inside the site shell); submitting a new compliant password lets the user authenticate with the new password and rejects the old one.
- `config/www/user/config/plugins/email.yaml` contains no host, username, or password literal (grep-assertable); the per-environment path is gitignored.
- **Deploy preservation:** two consecutive deploys to a tier preserve that tier's `user/env/<host>/config/email.yaml` — it lives in `<tier>data`, is symlinked into each release, and is not overwritten or removed by the release rsync (asserted by the same deploy-path test that already covers `security.yaml`, extended to `email.yaml`).
- **ADR-004 compliance:** the PR carrying the `deploy.sh` change satisfies one of ADR-004's three options — `tests/deploy/lint-remote-ssh.sh` extended to assert the `email.yaml` symlink line, an operator-supervised dev-tier run recorded in the PR/deploy log, or a linked superseding ADR. (The fixture deploy-path test does not satisfy this on its own.)
- **Absent-file is surfaced, not silent (failure path):** on a tier whose `email.yaml` is missing, the deploy/preflight emits a non-fatal WARN and the tier still boots (no HTTP 500); transactional mail is non-sending until the file is provisioned. Asserted against a fixture with the file removed — a missing `email.yaml` must never produce a green deploy with no warning.
- **Promotion no-sync invariant:** a check confirms neither `promote_to_staging` nor `promote_to_prod` sync logic includes `email.yaml` (or a broadened `env/<host>/config/*.yaml` glob) in its allow-list — only `features.yaml` in that directory is promotable (grep-assertable against the two promotion scripts).
- The generated message's From is `noreply@hackersbychoice.dk` on dev/test/staging and `noreply@byvaerkstederne.dk` on prod (assert in the test environment's sink; `kontakt@` never appears as the transactional From).
- Failure path: submitting an email that matches no account does **not** reveal whether the account exists (same response/redirect as the success case) and generates no message in the sink.

---

### WI-2 — No instant unverified access (review finding #2, High) — depends on WI-1

**Problem.** `login.yaml:27-31` sets `set_user_disabled: false`, `send_activation_email: false`, `login_after_registration: true`. Anyone can register with any email address (no proof of ownership), is granted `access.site.login: true`, and is logged in immediately. The member roster therefore has no integrity and the form is an open spam/abuse vector.

**Change.** In `config/www/user/config/plugins/login.yaml`, under `user_registration.options`:

- `set_user_disabled: true`
- `send_activation_email: true`
- `login_after_registration: false` (the handler skips auto-login for a disabled account anyway — `login.php:947` — so this makes intent explicit)
- Set the post-activation behaviour so the activation link enables the account and shows the Danish activation-confirmed flash on `/` (the plugin's `route_activate` handler enables the account, adds a flash message, and redirects to `/` — there is no themed activation page; the flash surface is themed via `/` rendering, see WI-1 step 3).

The registration success copy changes from "welcome" to a Danish "check your inbox to activate" notice; ensure the redirect target (`/`) renders flash messages so the notice is visible.

**Per-tier rollout rule.** The gate (`set_user_disabled: true` + `send_activation_email: true`) must not be enabled on a tier until that tier has confirmed mail delivery (Prerequisites step 4). The config change can land in the repo for all tiers at once *only* if every target tier already delivers; otherwise stage the flip per tier behind the per-environment config so a tier without working mail keeps the current behaviour until its mailbox + DNS are verified.

**Acceptance criteria.**

- After a successful registration POST, the new account YAML is written with `state: disabled` and an activation message is generated in the test sink containing an `/activate_user` link with a token for that user.
- **Registration copy/flash:** the rendered `/` redirect-target response after a registration POST contains the Danish activation-pending flash (assert a substring such as `aktiver` / `tjek din indbakke`) and **no longer** contains the previous "welcome" copy. (This pins the WI-2 Change's copy swap and that the flash actually renders on `/`.)
- A freshly registered (un-activated) account **cannot** log in: a login attempt with correct credentials is rejected with a clear Danish message, and the account cannot reach a member-only page (e.g. `/roadmap` still redirects to login).
- Following the activation link flips the account to `state: enabled` and redirects to `/`, whose rendered response shows the Danish activation-confirmed flash; the user can then log in and reach `/roadmap`.
- Registration no longer logs the user in implicitly (no authenticated session immediately after the registration POST).
- Failure path: an `/activate_user` request with a tampered or expired token does not enable the account (account stays `disabled`).

**Open question for the owner (does not block the WI):** should verified-email also require an officer to approve the membership before `access.site.login` is granted? If yes, that is a separate spec; this WI delivers email verification only.

---

### WI-3 — Remove the committed salt and rotate it (review finding #3, High)

**Problem.** `config/www/user/config/security.yaml` (the repo root config, not the per-tier env copy) is tracked in git and contains a real salt (`salt: Wbd0yZKOPckagC`). This salt feeds Grav nonce generation and remember-me token signing. The per-tier `user/env/*/config/security.yaml` files are already gitignored (`.gitignore:110-114`) and provisioned as per-tier state, so the defect is specifically the tracked **root** copy: it pins a publicly known salt into the repo, into local dev, and into the initial release window before `deploy.sh` moves it into tier state.

**Change.**

1. Add `config/www/user/config/security.yaml` to `.gitignore` (same class of secret as the env copies already listed there) and `git rm --cached` it so it stops being tracked while remaining on local disk.
2. Confirm a fresh checkout still works: Grav regenerates a `security.yaml` with a fresh salt on first request when the file is absent (this is the documented behaviour the `.gitignore` comment already relies on for the env copies). Document the one-line bootstrap in `README.md`/setup notes if any step is needed beyond "Grav generates it".
3. Rotate the exposed salt on every tier that actually used it. Verify per tier whether the live `user/env/<host>/config/security.yaml` salt equals the committed value; where it does, replace it with a freshly generated salt. Rotating invalidates existing remember-me cookies and any in-flight nonces — acceptable; document it.

**Acceptance criteria.**

- `git ls-files config/www/user/config/security.yaml` returns nothing (file untracked).
- `git check-ignore config/www/user/config/security.yaml` reports it ignored.
- A clean checkout + local `make start` produces a working site whose `security.yaml` is auto-generated and whose salt is **not** `Wbd0yZKOPckagC`.
- A short note in the spec's PR (or an ADR, at reviewer discretion) records which tiers were rotated and confirms the old salt is no longer the live salt anywhere.
- Out of scope but noted in the PR: whether to scrub the salt from git history with `git filter-repo` (optional follow-up).

---

### WI-4 — Harden the session cookie (review finding #4, Medium)

**Problem.** `system.yaml` defines no `session:` block, so the session cookie inherits Grav defaults (`secure: false`, `samesite: Lax`). The site terminates TLS at a reverse proxy (`reverse_proxy_setup: true`), so the cookie is issued without the `Secure` flag.

**Change.** Add an explicit `session:` block to `config/www/user/config/system.yaml`:

- `secure: true`
- `httponly: true`
- `samesite: 'Lax'` (Lax, not Strict — activation and reset links arrive as top-level navigations from email; Lax permits the cookie on those while still blocking cross-site POST)

Because TLS is terminated upstream, verify Grav sees the request as HTTPS (via `reverse_proxy_setup` + `X-Forwarded-Proto`; see the documented one.com Varnish behaviour) so a `Secure` cookie is actually set and not dropped, leaving users unable to log in.

**Acceptance criteria.**

- Against the worktree Grav container, a request with `X-Forwarded-Proto: https` injected (the same signal the prod reverse proxy sets — see CLAUDE.md's one.com Varnish note) yields a session `Set-Cookie` whose value, asserted as **three independent substrings**, contains `Secure`, `HttpOnly`, and `SameSite=Lax`. (Three separate assertions, not one bundled check.)
- A login round-trip over that same `X-Forwarded-Proto: https` request completes (form submit → 302 → authenticated `GET /roadmap` returns 200), proving the `Secure` cookie was accepted and not dropped.
- The `session:` block is present and explicit in `system.yaml` (the three keys above).

**Manual release gate** (explicit, tracked — not an inline "or"):

- [ ] On the first deploy to a real TLS tier, capture the live `Set-Cookie` response header and confirm `Secure` is present and a login completes through the proxy; record the tier and date in the PR/deploy log. This is the one step the localhost `X-Forwarded-Proto` substitute only approximates (it proves Grav *emits* `Secure` when told HTTPS, not that the real proxy doesn't strip it); it is **not** gated by CI and is a named release-checklist item.

---

### WI-5 — Pin the password and username policy in this repo (review finding #5, Medium)

**Problem.** `system.pwd_regex` and `system.username_regex` are not set anywhere under `config/www/user/config`, and Grav core is not vendored in the repo. The actual password-strength rule and the 3–16-char username rule are therefore whatever the installed Grav core defaults to — a core upgrade or a differently-configured tier could silently weaken them. The client-side JS in `register.html.twig:60-80` encodes a specific policy that has no pinned server-side counterpart in the repo.

**Change.** Add to `config/www/user/config/system.yaml`, matching the existing client-side rules exactly:

- `username_regex: '^[a-z0-9_-]{3,16}$'`
- `pwd_regex: '(?=.*[A-Z])(?=.*[0-9])(?=.*[a-z]).{8,}'` (≥8 chars, at least one upper, one lower, one digit)

**Acceptance criteria.**

- Both keys are present in the repo's `system.yaml`.
- **Username policy — string equality across the three single-string artifacts:** `system.username_regex` equals the `validate.pattern` on the username field in `register.md` equals the username regex literal in `register.html.twig`, and all three equal `^[a-z0-9_-]{3,16}$`. (These are all single strings, so direct equality is well-defined.)
- **Password policy — shared accept/reject truth-table fixture:** because the client-side password check is an imperative `.length` + `/[a-z]/` + `/[A-Z]/` + `/[0-9]/` chain (not a single regex), it has no canonical string form to compare for equality against `pwd_regex`. Instead a fixture lists fixed cases — accept: `Abcdefg1`; reject: `abcdefg1` (no uppercase), `ABCDEFG1` (no lowercase), `Abcdefgh` (no digit), `Abcdef1` (too short) — and a test feeds each case to **both** the JS chain and `pwd_regex`; both must produce the fixture's verdict for every row. Divergence (e.g. a `pwd_regex` that drops the lowercase rule) fails the test.
- Failure path: a direct registration POST (bypassing the client JS) with a 6-character password is rejected server-side; with a compliant password (`Abcdefg1`) it succeeds.

---

### WI-6 — Test coverage for the custom auth surface (review finding #6, Medium)

**Problem.** None of the custom registration/login surface is covered by tests, violating the CLAUDE.md rule that new/changed behaviour have both success- and failure-path coverage. This is the gap class that let the Sprint-5 auth regression through.

**Change.** Add Playwright coverage following the established layout (thin entry-point requirers; cases under `anonymous/` and `authenticated/`; self-managed test accounts; source `~/.gan-secrets/workshop-site.env` per CLAUDE.md; skip-with-reason when creds absent). New files:

- `tests/anonymous/registration.js`
- `tests/anonymous/password-reset.js`
- `tests/helpers/mail.js` (new — Mailpit query/clear helper, below)
- extend `tests/authenticated/` as needed for the activation→login transition.

**Test-environment additions (the mechanism that makes "emails are sent and codes are usable" assertable).** Email-bearing flows are verified end-to-end against an **API-queryable mail sink (Mailpit)** — the test reads the captured message over Mailpit's REST API, extracts the activation/reset link, and *drives that link* to prove the token works. Nothing is mocked at the Grav layer; the real `login` + `email` plugin path runs.

```
Playwright ──drives──▶ Grav (test container) ──SMTP :1025──▶ Mailpit ◀──REST API── Playwright
```

1. Add a `mailpit` service to the test Docker stack (its own compose profile so it only runs under test, not the dev `:8080` workflow). It exposes SMTP on `1025` and the API/UI on `8025`, both on the shared Docker network so the Grav container reaches it as `mailpit:1025`.
2. The test environment's `email.yaml` overrides the SMTP block to `server: mailpit, port: 1025`, no auth. This is the per-environment override path from WI-1; the repo-tracked defaults are not used under test.
3. `playwright.config.js` / the test setup exports `MAILPIT_URL` (e.g. `http://127.0.0.1:8025`) so specs can query it. The Mailpit endpoints the helper depends on: `GET /api/v1/search?query=to:<addr>`, `GET /api/v1/message/{ID}` (returns `From`, `To`, `Subject`, `Text`, `HTML`), and `DELETE /api/v1/messages` (clear between tests).
4. `tests/helpers/mail.js` provides `clearMail()`, `waitForMail(to, timeout)` (poll-with-timeout, returns the full message), and `extractLink(msg, pattern)` (regex the `Text`/`HTML` body for the route URL). Tests clear the inbox before the action, then `waitForMail` the recipient.

Coverage (each item is success **and** at least one failure path):

1. **Registration success:** valid POST creates a `state: disabled` account and shows the Danish activation notice. **Failure:** duplicate username (`login.php:826`) and duplicate email (`login.php:841`) are each rejected with the user-facing message; weak password rejected server-side (WI-5); invalid username pattern rejected.
2. **CSRF:** the rendered registration and login forms contain a nonce field; a POST with a missing/garbage nonce is rejected.
3. **Feature gate:** with `membership_signup` disabled, `GET /opret-medlemskab` returns the themed 404 and a registration POST does not create an account.
4. **Login:** correct credentials on an **activated** account log in and can reach `/roadmap`; a disabled (un-activated) account is refused (WI-2); wrong password is refused; repeated wrong-password attempts hit the rate limiter (assert the rate-limit response after the configured threshold).
5. **Activation (email sent + code usable):** after registration, `waitForMail` finds exactly one message to the registrant, asserts `From` matches the tier identity (WI-1), and `extractLink` pulls the `/activate_user` URL from the body. **Negative-before-positive:** logging in with the new credentials is refused while the account is `disabled`; then visiting the extracted link flips the account to `enabled` and the same login now succeeds. **Failure:** a token mutated by one character does not enable the account.
6. **Password reset (email sent + code usable):** clear inbox → submit `/forgot_password` for a known account → `waitForMail` → `extractLink` the `/reset_password` URL → the themed form sets a new password → the new password authenticates and the old one is rejected. **Failure:** a non-existent email produces **no** captured message and an identical response (no user enumeration).

Per-test cleanup removes any account/state the test created (signup tests create arbitrary usernames outside the two-account allowlist in `tests/helpers/accounts.js`, so teardown deletes those YAMLs directly — or the suite runs against the disposable per-run container); tests never touch account files other than the ones they create or declare. Recipients are unique per run (e.g. `pwsignup<n>@example.invalid`) so repeated runs don't collide with the duplicate-email guard.

**Coverage boundary (state explicitly so green CI is not misread).** These tests prove **transport + token usability** — that mail is generated, correctly addressed/From'd, and that the activation/reset code drives the real state change. They do **not** prove real-world **deliverability** (SPF/DKIM/DMARC, spam-foldering on a real provider), because Mailpit accepts everything. Deliverability per tier stays the manual check in Prerequisites step 4 (a real-inbox send + mail-tester.com score). A green WI-6 run must never be read as "prod mail lands."

**Optional — post-deploy smoke against a real non-prod tier.** A tier pointed at a [Mailtrap](https://mailtrap.io) *sandbox* (instead of Mailpit) can be smoke-tested after deploy by querying Mailtrap's API the same way `tests/helpers/mail.js` queries Mailpit. This exercises the live one.com SMTP path without emailing real people. Out of scope for the core WI but noted as the bridge between CI (Mailpit) and the manual deliverability check.

**Acceptance criteria.**

- New specs run green locally and in CI with creds present, and skip with a clear reason when `~/.gan-secrets/workshop-site.env` is absent (no silent pass).
- The `mailpit` service starts under the test profile only; `MAILPIT_URL` is exported to the suite; `tests/helpers/mail.js` exposes `clearMail`/`waitForMail`/`extractLink`.
- Each of the six areas above has at least one passing assertion on the success path and one on a failure path.
- **Email-sent assertion:** the activation and reset tests fail if no message reaches the sink for the recipient, or if the `From` does not match the tier identity from WI-1.
- **Code-usable assertion:** the activation and reset tests complete the flow using the token *extracted from the captured email* (not a token read out of band), and the corresponding tampered-token / wrong-recipient failure path is asserted.
- Removing any one of the WI-2/WI-4/WI-5 config changes makes a corresponding test fail (the tests actually pin the behaviour, not just smoke it).

---

### WI-7 — Registration UX & localisation polish (review finding #7, Low)

**Problem.** The registration form has a single password field (a typo locks the user out — compounded, before WI-1, by broken reset). Server-side validation throws untranslated English (`"Password does not pass the minimum requirements"`, `Login.php:387`) on a Danish site. The login overlay hotlinks an image from `googleusercontent.com` (`login_overlay.html.twig:11`) — fragile and it leaks visitor IPs to Google.

**Change.**

1. Add a password-confirmation field. Convert the registration form to `password1`/`password2` and set `validate_password1_and_password2: true` in `login.yaml`; the handler already enforces the match (`login.php:858-871`). Update `user_registration.fields` and the page's `register_user` `fields` list accordingly. Keep the client-side strength check and add a client-side match check.
2. Localise server-side rejection. Add a `validate.pattern` + Danish `validate.message` to the password field in `register.md` so the **forms plugin** rejects a non-compliant password with a Danish message *before* `Login::register()` throws its English `RuntimeException`. (This keeps the stock plugin unpatched, per the non-goals.)
3. Replace the hotlinked `googleusercontent.com` image in `login_overlay.html.twig` with a locally hosted asset under the theme's image directory.

**Acceptance criteria.**

- Registration form renders two password fields; mismatched passwords are rejected (client-side message, and server-side via `validate_password1_and_password2`) and no account is created.
- A non-compliant password submitted to the registration form surfaces a Danish message (not the English `RuntimeException` string) to the user.
- `login_overlay.html.twig` references a local asset; no request to `googleusercontent.com` is made when the overlay renders (assert no external image request in a Playwright run).

---

## Sequencing

```
WI-3  WI-4  WI-5  WI-7   (independent, small — any order, can land first)
WI-1  ──▶  WI-2          (reset/email transport before email-verification gate)
WI-6                     (covers all of the above; written alongside each WI)
```

WI-1's per-tier secret provisioning leans on the atomic-deploy per-tier state layout, which is already shipped (ROADMAP step 3). No other roadmap step blocks this spec, and this spec blocks none of them — it is an independent hardening track.

## Exit criteria (whole spec)

- A member who forgets their password can complete a themed reset flow end-to-end; reset/forgot/activate/login routes all render inside the site shell.
- A new registration creates a disabled account, sends a verification email, and grants no member access until the email is verified; instant auto-login is gone.
- No authentication secret (`security.yaml` salt, SMTP credentials) is tracked in git; the previously-exposed salt is rotated on every tier that used it.
- The session cookie carries `Secure`, `HttpOnly`, `SameSite=Lax` — asserted as three substrings against an `X-Forwarded-Proto: https` request to the worktree container, with a login round-trip proving the cookie is accepted — and the live-TLS confirmation is a named manual release gate (WI-4), not an inline waiver.
- `username_regex` is pinned and string-equal across `system.yaml` / `register.md` / `register.html.twig`; `pwd_regex` is pinned and proven equivalent to the client-side JS chain by the shared accept/reject truth-table fixture (WI-5).
- The custom registration/login/activation/reset surface has Playwright coverage on both success and failure paths, green in CI with creds and skipping cleanly without them. The activation and reset tests assert the email is captured by the Mailpit sink and complete each flow using the token extracted from that email — proving the codes are usable end-to-end (transport + token usability; real-provider deliverability remains the manual per-tier check).
- Registration uses a confirmed password, shows Danish validation messages, and serves no third-party-hotlinked assets.
