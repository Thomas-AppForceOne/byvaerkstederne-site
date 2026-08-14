# Specification — Account menu & self-service (user extension)

Status: Planned
Owner: thomas@appforceone.dk
Scope: The logged-in user label in the header becomes a dropdown menu giving access to a new account page (`/konto`) where a member can change email (verified), change password, edit display name, see current roles, request access rights (arrangør), and delete their account (soft delete with a 30-day regret window followed by automatic GDPR-compliant hard delete + anonymization). Ships behind a new `account_self_service` feature flag.

**Language note (per CLAUDE.md):** all new developer-facing identifiers are English (`account-manager` plugin, `account.html.twig`, `deletion_requested_at`, `pending_email`); everything a visitor reads is Danish ("Min konto", "Skift e-mail", "Skift adgangskode", "Ret navn", "Rettigheder", "Slet konto"). The page slug `/konto` is Danish per convention; its template is bound explicitly via `template: account` in the page frontmatter so no Danish name propagates into the theme.

---

## 1. Goal

Today the authenticated header shows the member's name as a dead `<span class="bv-nav__user">` (navigation.html.twig:36-39) next to a separate "Log ud" link. Members have no self-service at all: they cannot change their email or password while logged in, cannot fix their display name, cannot see or request roles, and cannot leave. Give the name chip a purpose — a dropdown context menu — and give members a single account page where every user-centric operation lives.

## 2. In scope

1. **Header dropdown**: the user chip becomes an interactive control opening a context menu (desktop nav and the mobile menu overlay) with entries deep-linking to the `/konto` sections. The existing separate "Log ud" header link is **unchanged** — logout does not move into the menu.
2. **Account page `/konto`**: authenticated-only, presented with the existing `.bv-auth-card` floating-card identity, one section per operation. Anonymous requests to `/konto` redirect to login (reusing `redirect_to_login` behaviour), never leak content.
3. **Change email — verify-new-address-first**: the account keeps the old email until a single-use, expiring confirmation link sent to the *new* address is clicked. A notification goes to the old address. The verified-email invariant from the registration gate is never broken.
4. **Change password**: current password + new password (entered twice), while logged in. Distinct from the anonymous forgot-password flow, which is untouched.
5. **Edit display name**: change `fullname` (what the header chip and event author lines render).
6. **Show current roles**: read-only list of what the member is — baseline "Medlem" plus group `readableName`s (e.g. "Arrangør") — giving the access request context.
7. **Request access rights**: member picks a requestable role (only *arrangør* for now) with an optional motivation; the site emails the admins; the member sees a pending state on `/konto`. **Granting stays manual** — a super adds the group via the admin panel exactly as today; no new admin UI.
8. **Delete account — soft delete, 30-day regret window, automatic hard delete**:
   - Request (password re-entry + explicit confirmation) marks the account `deletion_requested_at`, terminates the session **and invalidates remember-me tokens**, and emails the member the hard-delete date and the reinstatement rule.
   - **Signing in again before the deadline reinstates the account** (marker cleared, confirmation flash + email). That is the whole regret mechanism — there is no limbo state where a logged-in member is "half deleted".
   - A scheduled job hard-deletes accounts whose window has lapsed and **anonymizes** their footprint (§7). Content the member authored **stays** — events keep running, suggestions/reports stay on the roadmap — but no personal identifier survives.
9. Playwright coverage: success + failure paths for every operation (§10).

## Out of scope

Username change (the account file is keyed by it), avatar/profile pictures, self-service organizer *granting* (request-only), admin-side approval queue UI, deleting authored content on account deletion, email/newsletter preferences, two-factor auth, moving "Log ud" into the dropdown, data-export (GDPR portability) — each may become its own spec later.

## 3. Boundaries

- **No `login`/`email` plugin PHP changes** (same constraint as the auth-surface and member-auth-hardening work). Reinstatement-on-login and session handling hook the login plugin's *events* (e.g. `onUserLoginAuthenticated`) from the new plugin; if a desired effect genuinely needs a login-plugin PHP patch, stop and raise it.
- **No auth behaviour changes** to registration, activation, forgot-password, throttling, or the no-enumeration responses. This spec adds surfaces; it does not alter existing ones.
- **Footer-only rule untouched** (ADR-001): the dropdown carries account operations only — no community affordances migrate into it.
- Live-tier state (`user/accounts/`, `user/data/`) is never committed; seed bundles provide test state.

## 4. Architecture

### 4.1 New plugin: `account-manager`

A new plugin `config/www/user/plugins/account-manager/` owns every server-side behaviour in this spec (mirrors the `event-manager` precedent). It registers:

- The mutation endpoints (§4.3) on the `/konto` route.
- The email-change confirmation route (token link target).
- Login-event subscriber: clears `deletion_requested_at` on successful authentication (reinstatement) and emits the reinstatement flash + email.
- A **Grav scheduler job** (daily, idempotent) that executes lapsed hard deletes + anonymization (§7). The scheduler is cron-driven on all tiers (prod cron granularity is 15 min — ample).
- An append-only audit log `user/data/account-manager/account-audit.jsonl` recording every mutation (action, actor, timestamp — no secrets, no password material).

### 4.2 Data model — everything on the account YAML

All three transient states live as fields on the member's own account file (`user/accounts/<username>.yaml`), so they travel with the account and die with it:

```yaml
pending_email:            # set while an email change awaits confirmation
  address: new@example.dk
  token_hash: <sha256>    # token is random ≥128-bit; only its hash is stored
  expires_at: '2026-07-08T06:00:00Z'
deletion_requested_at: '2026-07-07T06:00:00Z'   # set → hard delete at +30 days
access_request:           # at most one open request
  role: organizers
  motivation: '…'
  requested_at: '2026-07-07T06:00:00Z'
```

- Pending/granted state for the access request is **derived**, not duplicated: member in the group ⇒ granted (clear `access_request` on next load); `access_request` present ⇒ pending; else none.
- Account-file writes use the house atomic-write pattern.

### 4.3 Endpoint contract

Every mutating action follows the event-manager contract order, extended with a re-auth step for the sensitive ones:

**flag → method (POST) → authn → CSRF nonce → re-auth (current password, where marked) → validate → mutate → audit → PRG (redirect back to `/konto` with a flash).**

| Action | Re-auth | Notes |
|---|---|---|
| `request-email-change` | yes | stores `pending_email`, sends token to new address, notifies old address |
| `confirm-email-change` | — (token is the credential) | GET route with token; single-use, expiring, hash-compared |
| `change-password` | yes | |
| `change-fullname` | no | sanitized, length-bounded |
| `request-access` | no | one open request; cooldown before re-request after clearing |
| `request-deletion` | yes | plus explicit confirmation input; kills session + remember-me |

Failed CSRF/authn/forced-browsing responses match the site's existing pattern (403 / redirect, no content leak). Remember the house gotcha: Grav nonces bind to the User-Agent.

## 5. UI/UX requirements

### Header dropdown
- The user chip becomes a `<button>` (or equivalently accessible control) with `aria-haspopup="menu"` / `aria-expanded`; opens on click, closes on Escape, click-outside, and focus-out; items are keyboard-navigable. No hover-only behaviour.
- Menu entries (Danish): "Min konto", "Skift e-mail", "Skift adgangskode", "Ret navn", "Rettigheder", "Slet konto" — each a deep link to the corresponding `/konto` section anchor. Exact final wording may be tuned at implementation; identifiers stay English.
- Rendered only when `grav.user.authenticated and grav.user.authorized` **and** the flag is on; with the flag off the chip renders exactly as today (dead span).
- The mobile menu overlay gets the same entries under the user name; the desktop pattern must not break the hamburger flow.

### /konto page
- Danish slug, `template: account` set explicitly in frontmatter → `account.html.twig` (English).
- Shares the `.bv-auth-card` floating-card identity and design-system controls (`.bv-input`, `.bv-btn--primary`).
- All feedback renders through the shared `.bv-message` component with its `--success`/`--error` variants — no new feedback style.
- The delete section states the consequences in Danish: the 30-day window, the exact hard-delete date after requesting, and that signing in again cancels the deletion. After requesting, `/konto` is unreachable (the member is logged out); the *reinstatement* flash after a subsequent login carries the "din konto er genaktiveret" message.
- Pending states are visible: an unconfirmed email change shows the target address and a resend/cancel affordance; an open access request shows "afventer godkendelse".

## 6. Email-change security semantics

- Token: random ≥128-bit, stored only as a hash, expires (24 h), single-use, invalidated by any newer request.
- **No enumeration**: if the requested address already belongs to another account, the UI response is identical to the success case ("hvis adressen kan bruges…"); the existing owner of that address gets an informational email instead of the confirmation link.
- Old address is notified on request **and** on completion (hijack visibility).
- Throttle: per-account and per-IP limits on `request-email-change` (reuse the registration-throttle pattern; do not modify that plugin).

## 7. Deletion lifecycle & anonymization inventory

Hard delete runs when `now ≥ deletion_requested_at + 30 days`. The job removes `user/accounts/<username>.yaml` and then anonymizes every store that references the account, replacing the username with a **per-account random tombstone** (`deleted-<random>`, generated at delete time, never persisted in any mapping) so counts and one-per-user invariants survive while re-identification is impossible:

| Store | Field(s) | Treatment |
|---|---|---|
| `user/accounts/<username>.yaml` | whole file (email, fullname, hash, groups) | delete |
| Events flex (`begivenheder.yaml`) | `owner`, `created_by`, `updated_by` | tombstone; orphaned events remain manageable by `admin.super` |
| Events audit (`events-audit.jsonl`) | actor fields | one-time sanctioned rewrite to tombstone (structure preserved) |
| Roadmap items | `votes[username]`, `vote_history[username]` | re-key to tombstone (vote counts unchanged) |
| Feature suggestions | `username`, `source_username` | tombstone |
| Bug reports | `username`, `submitter_username` | tombstone |
| Event signups (if the RSVP spec has landed) | signup key | **remove** (frees the seat — the member no longer exists) |
| `account-audit.jsonl` (own log) | actor | tombstone |

- The job is idempotent and logs each hard delete (tombstone id only) to the account audit log.
- No email is sent at hard delete (the address is being erased; the member consented at request time and was told the date).
- **Deterministic completeness check** (also the test oracle): after the job runs, a case-insensitive search for the deleted username, email, and fullname across `user/accounts/`, `user/data/`, and the flex stores returns zero hits.
- If the RSVP/attendee spec lands first, its stores join the inventory; the inventory table is the single place to extend.

## 8. Access-request notification

- Requesting emails the admin recipients (resolved from per-tier email config, not hardcoded) with username, role, and motivation; the member sees the pending state.
- Granting is unchanged: a super edits the account's `groups:` in the admin panel. No plugin writes groups.
- Rejection has no formal flow in this iteration: an admin simply doesn't grant; the member may clear and re-request after the cooldown.

## 9. Feature flag

- New flag `account_self_service` gates the dropdown, the `/konto` page, and **every endpoint server-side** (contract step 1 — UI hiding is not the gate).
- Added to the base profile and dev-tier profile as `"true"`, and to the test/staging (and future prod) profiles as `"false"`, following the strict quoted-string rule.
- Flag off ⇒ byte-for-byte today's behaviour: dead chip, no route, endpoints 404/refuse.

## 10. Test requirements

Playwright, seeded via the existing bundle mechanism, sourcing credentials per the CLAUDE.md contract. **Tests must not delete or mutate the shared seeded accounts** (`pw-test-user`, `pw-test-org`, `pw-test-admin`); destructive flows use disposable accounts created by the test's own seed step.

Success **and** failure paths per operation:
- Dropdown: opens/closes (click, Escape, outside), entries land on the right `/konto` section; absent when logged out; chip is a dead span with the flag off.
- `/konto`: anonymous access redirects to login without leaking content; renders `.bv-auth-card`.
- Email change: happy path round-trip (request → old-address notification asserted at the mail layer → confirm via token → email swapped); expired token rejected; token reuse rejected; wrong re-auth password rejected; occupied target address produces the identical neutral UI response.
- Password change: happy path (old password stops working, new works); wrong current password rejected; mismatch rejected.
- Fullname: change reflected in the header chip; over-length/markup input sanitized or rejected.
- Access request: pending state appears; admin email produced (mail layer assertion); duplicate open request refused; state derives to "granted" once the group is present.
- Deletion: request logs the member out and invalidates remember-me; login within the window reinstates (marker gone, flash shown); forced-browsing and CSRF negatives on the endpoint.
- Hard delete: with a backdated `deletion_requested_at`, invoking the scheduler job removes the account and passes the §7 zero-hits search against fixture data planted in every inventoried store; a second run is a no-op.

## 11. Exit criteria

- The logged-in chip opens an accessible dropdown (desktop + mobile) deep-linking to a `/konto` page carrying all six operations in the shared card identity; "Log ud" is untouched.
- Email change never breaks the verified-email invariant and produces no enumeration signal; password and name changes work with correct failure behaviour.
- Roles are visible; an access request notifies admins and shows pending/granted state; granting remains a manual super action.
- Deletion follows request → logout + token invalidation → 30-day window → sign-in reinstates → scheduled hard delete + full anonymization passing the zero-hits check, with authored content preserved under tombstones.
- Everything is server-side gated by `account_self_service` (off on all deployed tiers except dev), covered by passing Playwright success/failure tests, with no login/email plugin PHP modified.
