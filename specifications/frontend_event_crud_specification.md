# Specification — Frontend Event CRUD

Status: Planned
Owner: thomas@appforceone.dk
Scope: Let approved non-admin members ("arrangører") create, read, update and delete events from the public site through a themed UI, instead of the Grav admin panel. Server-side enforcement is the real boundary. Complete CRUD is the release gate — no partial ship.

**Language note (per CLAUDE.md — Language conventions):** every *new* developer-facing identifier in this spec is English — the `organizers` group, the `event-manager` plugin and its classes, `admin.events.*`, the `event_management` flag, the `events-audit.jsonl` log, blueprint field names. Danish appears only where visitors read it: URL slugs (`/begivenheder/...`), form labels ("Synlig"), flash messages, status chips, and the group's `readableName`. In prose, "arrangør" is the Danish UI label for the organizer role; its code-side name is `organizers`. One grandfathered exception: the Flex directory key `begivenheder` predates the rule and must be extended, not replaced (§0). New pages with Danish slugs set `template:` explicitly in frontmatter to an English template name.

---

## 0. System facts & constraints (authoritative)

These are the current state of the system, established by inspection, and the ground truth this spec is built on. Each carries a binding implication for the implementation.

| System fact | Binding implication |
|---|---|
| Events are an **existing** Flex Directory `begivenheder` — blueprint `user/blueprints/flex-objects/begivenheder.yaml`, data `user/data/flex-objects/begivenheder.yaml`, registered in `user/config/plugins/flex-objects.yaml`; **16 live events** (`event001`–`event016`, verified 2026-06-18 — re-confirm the count at implementation time, since live-tier data drifts off-git). | Extend the existing `begivenheder` directory. Do **not** create a new directory. All field and permission work is additive to `begivenheder`. |
| There is **no** `user/config/groups.yaml`. The only account (`bob`) carries an inline `access:` tree granting `admin.super`. | Create `user/config/groups.yaml` with an `organizers` group; accounts join it via a `groups:` list (§5). |
| The site's own plugins (roadmap, bug-report, feature-suggestion) mutate Flex data by writing the data YAML directly (atomic `flock`), not via the Flex API. The `flex-cache-bust` plugin invalidates render cache on `onFlexAfterSave`/`onFlexAfterDelete` — but in this codebase those events are only demonstrably fired by the admin `AdminController`; whether a *frontend* Flex save emits them in 1.3.8 is unverified. | Mutate via the **Flex API** (§7–§8) for blueprint validation and the supported write path; **additionally bust the render cache explicitly** after every mutation (§8) rather than relying on `onFlexAfterSave/Delete` firing frontend-side. A raw-YAML write that bypasses both validation and cache-busting is not permitted. |
| On a deployed tier the events data lives in the **non-versioned `<tier>data/` dir** (live state, preserved across deploys, not a git repo). Git history covers only the repo's seed copy, never live tier mutations. | Git history is **not** a live-audit mechanism. Explicit actor stamping + an append-only audit log is **required** (§10). |
| The admin plugin has **no `user/config/plugins/admin.yaml` override** (the bundled plugin default is `enabled: true`, so confirm the panel's actual on/off state at implementation time). Either way, only `bob` (super) can reach it — admin access is gated on `admin.login`. | Events are edited today only by a super, directly in the data YAML / via git. This feature is frontend-only; arrangører never receive admin-panel access, because the `organizers` group grants `admin.events.*` but **not** `admin.login`. |
| The `published` field **defaults to `1`** in the blueprint, which runs `validation: loose`. | The create form exposes the `published` (Synlig) toggle to the arrangør and the handler honours the submitted value (default visible), **coercing it to a strict boolean server-side** (loose validation won't). There is **no forced moderation state** — an arrangør's own event publishes immediately unless they save it as a draft. |
| The site is **Danish-only** (`default_lang: da` in `user/config/site.yaml`, no `languages.supported`). The `group` enum currently reads `alle/makerspace/kreativ/groenne/kulturhus`; a filter/enum rename (`groenne→groent`, `kreativ→krea`) is tracked separately (PR #57 renames calendar *filter IDs*, not necessarily the blueprint enum). | All labels Danish; no i18n branching. Forms read `group`/`button_style` options **from the blueprint** (single source of truth), never hardcoded — so the final names don't matter to this spec. |
| Versions in place: Grav 1.7.52 (core ships from the deploy release zip / Docker image, not the repo checkout), Form 8.2.1, Flex Objects 1.3.8 (enabled), Login 3.8.0 (enabled); frontend login enabled (`/login`, register `/opret-medlemskab`, email-activation on, no auto-login). | All version constraints (§14) are already satisfied; no plugin or core upgrade is needed. |

---

## 1. Overview & scope

### In scope
- Extend the `begivenheder` blueprint with ownership/audit fields and a soft-delete marker.
- A public events **list** and **detail** view (anonymous sees published only). Detail is net-new (today events render only as cards).
- A gated, feature-flagged frontend **management surface**: "Mine begivenheder" dashboard + create / edit / delete forms, themed in house style.
- A new custom plugin that provides the create/update/delete handlers with a single, centralised **authorization contract** (authn + capability + per-object ownership + server-side validation), mutating via the Flex API.
- A `groups.yaml` with an `organizers` group, owner-stamping on create, an in-app audit trail, and Playwright coverage including forced-browsing negative tests.

### Out of scope
- Event RSVP/signup flows, ticketing, capacity enforcement, calendar export, recurring events.
- Any change to the public **rendering** of event cards beyond what the new fields require (the canonical `partials/event_card.html.twig` stays the single render chokepoint).
- Re-enabling or using the Grav admin panel for arrangører (frontend-only, by design).
- Self-service "become an arrangør" onboarding (manual/invite to start — §11).
- Any pending group/filter rename — tracked separately (PR #57 renames calendar *filter IDs*, not necessarily the blueprint `group` enum). This spec reads the blueprint as the single source of truth and is unaffected by the final names.

### Release gate
Create, Read, Update **and** Delete must all work from the frontend, with owner-stamping and per-object authorization, before the feature ships. Milestones (§12) are a build order, not a scope-reduction lever.

Note the **build** divides cleanly into two phases even though the **release** is atomic: M1 (model + public read) is independently developable, testable, and mergeable ahead of the gated mutation surface (M2–M4: the new `event-manager` plugin + authz contract + audit). This spec is deliberately large; if it proves too big to land as one unit, split it along that M1 │ M2–M4 seam — the §0 facts, §3 permission matrix, and §8.1 contract are the shared context the mutation half carries. The atomic *release* gate is a product decision, unaffected by how the work is sequenced or split.

---

## 2. Data model / blueprint

Extend `user/blueprints/flex-objects/begivenheder.yaml`. Existing fields (`published`, `title`, `description`, `group`, `badge`, `event_date`, `event_time`, `location`, `capacity`, `price`, `button_text`, `button_url`, `button_style`, `featured`, `featured_tag`) are unchanged. Add the following **server-managed** fields — all `readonly` in any form, never client-settable, stamped only by handlers:

| Field | Type | Meaning |
|---|---|---|
| `owner` | text | Username of the creator. Basis of per-object authz. Stamped once on create; preserved verbatim on every update. |
| `created_by` | text | Username at create (== `owner` initially). |
| `created_at` | text | ISO-8601 UTC timestamp at create (`gmdate('Y-m-d\TH:i:s\Z')`). |
| `updated_by` | text | Username of the last mutator. |
| `updated_at` | text | ISO-8601 UTC timestamp of the last mutation. |
| `archived` | toggle (default 0) | Soft-delete marker. An archived event is hidden from all public views; it stays visible to its **owner** (and super) in the management dashboard, where the owner can restore it. |

Notes:
- **Missing `owner` ⇒ super-only-editable.** The 16 pre-existing events (`event001`–`event016`) have no `owner`; the authorization contract treats a null/empty `owner` as editable only by `admin.super`. This makes the new fields purely additive — **no data migration is required** (optional backfill in §13).
- The object **key** (storage id, e.g. `event001`) is the identity used by update/delete. New events get a collision-resistant key (e.g. `ev_` + random hex, mirroring the `br_`/`rm_` convention) — never a client-supplied key. Legacy `event0NN` keys and new `ev_<hex>` keys coexist in the same SimpleStorage map with no collision risk (the prefixes differ).
- Storage stays `SimpleStorage` (single YAML file). Concurrency: mutations must be serialised (the Flex API's save path, or an explicit `flock` if a raw fallback is ever used) so two simultaneous writes can't clobber the file.

---

## 3. Roles & per-action permission matrix

| Capability | Anonymous | Member (`site.login`, no events perms) | Arrangør (`organizers` group) | Super (`admin.super`) |
|---|---|---|---|---|
| Read **published** events (list + detail) | ✅ | ✅ | ✅ | ✅ |
| Read **own unpublished/archived** | — | — | ✅ (own only) | ✅ (all) |
| Create event (publish or save as draft) | — | — | ✅ (own, self-published) | ✅ |
| Update **own** event | — | — | ✅ | ✅ |
| Publish / unpublish **own** event | — | — | ✅ | ✅ |
| Delete = **soft archive** own (reversible) | — | — | ✅ | ✅ |
| Update / publish / delete **another's** event | — | — | ❌ (403) | ✅ (rare escalation) |
| **Hard delete** (permanent removal) | — | — | ❌ | ✅ (rare) |

- An arrangør is **fully self-service for their own events**: create, edit, publish/unpublish, and remove (soft archive) with **no admin involvement** in the normal flow.
- **Super passes every `admin.events.*` check** automatically (Grav `admin.super` overrides `authorize()`), so it needs no group membership. Super is a **rare escalation path only** — acting on events an arrangør does not own, and permanently hard-deleting — never a step in the routine publish flow.
- A logged-in member with no events permission is, for events, exactly equivalent to anonymous.

---

## 4. Permission namespace (single source of truth)

One namespace, **`admin.events.{create,read,update,delete}`**, is the single source of truth, checked identically by the Flex directory ACL (defense-in-depth / future admin use) and by the frontend handlers (the authoritative boundary).

- `admin.events.create` — create new events.
- `admin.events.read` — view own unpublished/archived events in the management UI. (Public reading of *published* events is **not** permission-gated.)
- `admin.events.update` — update an event the user owns, **including setting its `published` flag** (publish/unpublish your own event).
- `admin.events.delete` — soft-archive an event the user owns.

**Elevated actions gated on `admin.super` (rare escalation, not part of the normal flow):** acting on events the user does **not** own, and permanently hard-deleting an object.

Rationale for reuse over a fresh `site.events.*`: it matches the existing `admin.contacts.list` / `admin.flex-objects` convention, and a scoped `admin.events.*` grant does **not** confer admin-panel access (that needs `admin.login`) — so least privilege holds. The `admin.events.*` strings must be **declared** (e.g. an `events` block in a plugin `permissions.yaml`, mirroring `user/plugins/admin/permissions.yaml`) so they appear as real, checkable permissions.

*Open alternative (see §16):* mint `admin.events.manage_all` if a non-super "moderator" role is ever wanted for cross-owner fixes. The default keeps cross-owner actions on `admin.super` to keep the namespace lean. (Publishing is **not** a separate permission — it is part of `admin.events.update` on one's own event.)

---

## 5. Auth & onboarding flow

- Frontend login is already live; arrangører are **ordinary, email-activated members**. A super grants the role by adding `organizers` to the account's `groups:` list (manual/invite to start). On next login the group's `access:` tree confers `admin.events.*`. No admin-panel access is granted.
- `user/config/groups.yaml` (new):
  ```yaml
  organizers:
    readableName: 'Arrangør'
    description: 'Can create and edit own events from the public site.'
    access:
      site:
        login: true
      admin:
        events:
          create: true
          read: true
          update: true
          delete: true
  ```
- No change to registration, activation, the password rules, the throttle, or the honeypot. This spec consumes the existing auth surface; it does not alter it (see §9 of this spec, which cross-references the auth UI/UX spec for the shared form-feedback component).

---

## 6. Frontend pages & routes

Danish slugs, numbered page folders, house gating (`access:` frontmatter + feature flag). The feature flag (new `FeatureFlag` enum case, e.g. `event_management`) gates the **entire management surface and every handler**; it follows the existing tier posture (on in dev/local, off in staging/test until ready).

| Route | Audience | Purpose |
|---|---|---|
| `/vaerkstedskalenderen` (existing) | public | Public list — reuses `event_list.html.twig` → `event_card.html.twig`, already filtered to `published`. Confirm it also excludes `archived`. |
| `/begivenheder/<key>` | public (published); owner/super may preview unpublished | **Event detail** (net-new). Anonymous request for an unpublished/archived/unknown event ⇒ 404 (no existence leak). |
| `/begivenheder/mine` | gated (`site.login` + events perm) | "Mine begivenheder" dashboard: the user's events (incl. own unpublished/archived) with edit/delete affordances; super sees all. |
| `/begivenheder/opret` | gated | Create form. |
| `/begivenheder/rediger/<key>` | gated, owner/super | Edit form, prefilled. |
| `/begivenheder/slet/<key>` | gated, owner/super | Delete confirmation. |

- In-page buttons/links are shown via `grav.user.authorize('admin.events.create')` etc. — **UX only**; never the boundary.
- **Navigation placement (ADR-001):** the management entry point ("Mine begivenheder" / create) is a members-only affordance and follows [ADR-001](../decisions/ADR-001-navigation-footer-placement.md) — surfaced in the **footer, auth-gated, hidden from anonymous**, not in the main navigation. Public event *reading* (the list at `/vaerkstedskalenderen` and the detail view) is not a community affordance and is navigated normally.
- Detail rendering and the `<key>` routes are resolved by the plugin (intercepting in `onPluginsInitialized`/`onPageInitialized`, mirroring how the roadmap plugin drives its page), loading the object server-side and enforcing read visibility before rendering.

---

## 7. Per-operation form definitions

All three mutations use the **Form plugin** (page-frontmatter forms, like `09.opret-medlemskab/register.md`), rendered through the stock `forms/form.html.twig` with `.bv-*` CSS overrides — giving CSRF nonce injection, server-side validation hooks, and house styling for free. Each form declares a custom process action that the plugin handles in `onFormProcessed`.

- **Create** (`process: [ { event_create: … } ]`): fields = `title`, `description`, `group` (select; options sourced from the blueprint), `event_date`, `event_time`, `location`, `capacity`, `price`, `badge`, `button_text`, `button_url`, `button_style` (select), `featured`/`featured_tag` (optional), a `published` (Synlig) toggle defaulting to visible, + a honeypot. **No** `owner` or audit fields in the form — those are server-stamped. On success → PRG redirect to `/begivenheder/mine` with a success flash.
- **Update** (`event_update`): same visible fields, **prefilled** from the loaded object, plus a hidden `key`. The `published` (Synlig) toggle is editable by the owner (and super), so an arrangør publishes/unpublishes their own event directly. `owner`/audit fields never appear.
- **Delete** (`event_delete`): a minimal confirmation form — hidden `key` + a destructive confirm button. Arrangør ⇒ soft archive; super ⇒ choice of soft archive or hard delete.

The `key` in update/delete is a routing/correlation value only; the handler re-resolves the object server-side and authorizes against the **stored** object — never trusting any client-submitted ownership or state.

---

## 8. Custom-plugin design + the authorization contract

**Plugin:** `event-manager` (kebab-case, house convention). `namespace Grav\Plugin; class EventManagerPlugin extends Plugin`. Layout: `event-manager.php`, `blueprints.yaml`, `event-manager.yaml`, `permissions.yaml` (declares `admin.events.*`), `src/` (PSR-4 `Grav\Plugin\EventManager\` via the `spl_autoload_register` pattern used by `feature-flags`/`site-version`), with at least: `EventAuthorizer` (the contract), `EventValidator` (server-side validation), `EventRepository` (Flex read/write + audit).

**Subscribed events:** `onPluginsInitialized` (route interception for detail + management rendering, and the feature-flag gate), `onFormProcessed` (the `event_create`/`event_update`/`event_delete` actions), `onTwigInitialized`/`onTwigSiteVariables` (expose any view helpers). Mutations go through the **Flex API** — `$grav['flex_objects']->getDirectory('begivenheder')` → `createObject($data,$key)->save()` / `getObject($key)->update($data)->save()` / `->delete()` — primarily for **blueprint validation** and to stay on the supported write path. Cache-busting must **not** depend on `onFlexAfterSave`/`onFlexAfterDelete` firing from a frontend save: in this codebase those events are only demonstrably fired by the admin `AdminController`, and whether a frontend Flex save emits them in 1.3.8 is unverified. Therefore the handler **explicitly and unconditionally busts the render cache after every successful mutation** (mirroring what `flex-cache-bust` does on `onFlexAfterSave/Delete`), so public-list freshness never hinges on event emission. If the implementer confirms the events do fire frontend-side, the explicit bust is harmless redundancy. (The implementer also verifies the exact 1.3.8 method signatures.)

### 8.1 Handler authorization contract (the single source of truth)

Every mutating handler (`event_create`, `event_update`, `event_delete`) runs these checks **in this order, server-side, before any write**. The same `EventAuthorizer` is the only place this policy lives.

1. **Feature-flag gate** — if `event_management` is disabled, return a generic 404 (gate before any I/O or payload parsing; house pattern).
2. **Method** — must be POST.
3. **Authentication** — `$user = $grav['user']; if (!$user || !$user->authenticated || !$user->authorized) ⇒ reject` (401 / redirect to `/login`).
4. **CSRF** — Form-plugin nonce verified (`Utils::verifyNonce`/the form's built-in check); missing/invalid ⇒ 403. Grav 1.7 form XSS detection stays enabled.
5. **Capability** — `$user->authorize('admin.events.<action>')` for the operation; fail ⇒ 403. (`admin.super` passes automatically.)
6. **Input validation** — `EventValidator` re-validates **every** field server-side, independent of HTML5/client checks: `title` required, ≤80, no `<`/`>` (house `^[^<>]{1,80}$` pattern); `group` ∈ blueprint enum; `event_date` matches `^\d{4}-\d{2}-\d{2}$` and is a real calendar date; `button_style` ∈ blueprint enum; `button_url` passes an **allowlist** — accept only a site-relative path matching `^/` (and **not** `//`), or an absolute `http(s)://` URL; reject everything else (`javascript:`, `data:`, `vbscript:`, protocol-relative `//host`, …) — an allowlist, not a denylist, so it cannot rot as new schemes appear; `published` is coerced to a **strict boolean** server-side (the blueprint runs `validation: loose`, so don't rely on it — treat only a genuinely-absent field as "default visible"); bounded lengths on free-text fields. Fail ⇒ 400 with field-level Danish messages.
7. **Per-object authorization** (update/delete only) — load the object by `key`; not found ⇒ 404. Compute ownership against the **stored** object: `owner === $user->username || $user->authorize('admin.super')`; otherwise 403. A null/empty stored `owner` ⇒ super-only.
8. **Mutate** via the Flex API:
   - *create*: stamp `owner = created_by = $user->username`, `created_at`/`updated_at = now`, set `published` to the **validated submitted value** (default visible) — the arrangør self-publishes; no forced moderation state. Assign a fresh server key.
   - *update*: apply validated fields **including `published`** (the owner controls their own event's visibility); **preserve `owner`/`created_*` from the stored object** (ignore any client value); set `updated_by`/`updated_at`.
   - *delete*: arrangør ⇒ `archived:true` + `published:false` (retain object, reversible by the owner); super ⇒ hard `->delete()` or soft, per the form.
9. **Audit** — append `{ts, actor, action, key, before?/after?}` to the audit log (§10).
10. **Respond** — PRG redirect with a flash (success/error) for form posts; never echo back client-controlled identity.

**Invariants stated for tests:** `owner` is never client-settable and is preserved across updates; an arrangør can act **only** on events they own; the object id is always re-resolved server-side; a direct POST / forced browse that skips the UI hits exactly these checks and is rejected. These are the negative-test targets (§12).

### 8.2 Read-path authorization contract (detail + dashboard)

Read routes (`/begivenheder/<key>`, `/begivenheder/mine`) get the same gate-before-auth rigor as the mutation contract. In order, before rendering:

1. **Feature-flag gate** — disabled ⇒ generic 404 (as §8.1.1).
2. **Load** the object by `key`.
3. **Read-visibility** — `published` ⇒ anyone; unpublished/archived ⇒ owner or `admin.super` only (null/empty stored `owner` ⇒ super-only, consistent with the write rule).
4. **No existence leak** — *any* denial (unknown key, or unpublished/archived without rights) ⇒ **404, never 403-with-detail** (§10).

The dashboard lists only objects the viewer may read (own incl. unpublished/archived; super sees all). Reads are GET; no CSRF. Forced-browsing an unowned unpublished/archived `<key>` returning 404 (not 403) is a negative-test target (§12).

---

## 9. Theme / template integration

- **Forms:** reuse the `register.html.twig` pattern — a themed card wrapper around stock `forms/form.html.twig`, styled by `.bv-*` overrides in `theme.css`. Field labels, help, and validation messages in Danish. Cross-reference [`auth_surface_uiux_specification.md`](auth_surface_uiux_specification.md): create/edit/delete must use the **same shared, centred, floating success/error feedback component** specified there, so flash identity is consistent across the auth and event surfaces.
- **Detail view:** a new `event_detail` template; may compose the canonical `partials/event_card.html.twig` for the header summary plus a fuller body. No new event-card variants — the card partial stays the single render chokepoint.
- **Dashboard:** "Mine begivenheder" lists events with status chips (kladde/afventer/publiceret/arkiveret) and `.bv-btn` edit/delete actions.
- All buttons use `.bv-btn` variants; square corners, 4px accent borders, container-query layout — the established house style.

---

## 10. Security requirements (non-negotiable)

- Authn + authz re-checked **inside every handler** per §8.1; frontend gating (`access:` frontmatter, `authorize()`-hidden buttons) is UX only.
- Per-object ownership enforced for update **and** delete, against the stored object.
- All input validated server-side (§8.1.6); never trust client/HTML5 validation.
- CSRF nonce on every mutating form (Form plugin); Grav 1.7 form XSS detection enabled.
- Least privilege: the `organizers` group carries **only** `site.login` + `admin.events.*` — no `admin.super`, `admin.login`, `admin.pages`, `admin.users`.
- **Audit (required, not a fallback):** because live tier event data is off-git, every mutation stamps `created_by`/`updated_by`/timestamps on the object **and** appends an immutable record `{ts, actor, action, key}` to a genuinely **append-only** log. Use a line-oriented append — `fopen($path, 'a')` + `flock(LOCK_EX)`, one JSON object per line, e.g. `user/data/flex-objects/events-audit.jsonl` — **not** the site's house full-file load-mutate-`file_put_contents(LOCK_EX)` YAML pattern: that pattern is serialised but rewrites the whole file on every write, so it is not append-only or immutable. A dedicated monolog channel is an acceptable alternative. This is the authoritative actor trail.
- No existence leak: unauthorized reads of unpublished/archived/unknown events return 404, not 403-with-detail.

---

## 11. Onboarding / "approved"

Manual/invite to start: a super assigns the `organizers` group to an existing, activated member (via account edit or the existing `deploy/` user tooling). Self-register-then-approve is explicitly future work. No new account-creation path is introduced.

---

## 12. Milestones & per-milestone test plan

Each milestone is independently testable and ships behind the `event_management` flag. Playwright, reusing the anonymous + authenticated harness and seed bundles; the authenticated suite needs a **seeded `organizers` member** plus the existing `pw-test-user`/`pw-test-admin`. Every milestone from M2 covers success **and** failure paths.

**Seeding an arrangør is a new bundle step, not a one-liner.** The existing `tests/fixtures/grav-seeds/playwright/apply.sh` provisions accounts via `bin/plugin login newuser -P <preset>`, which sets a single permission preset and has **no `--groups` flag**. The bundle must therefore: (a) seed `user/config/groups.yaml` (the `organizers` group, §5) into the test container; (b) create the member account; (c) patch that account's YAML to add `groups: [organizers]`; and the run must confirm `groups.yaml` is actually present in the test tier so the group's `access:` tree resolves on login. Without this, the entire own-vs-other-owner authz suite (the core of M3/M4) cannot run — and per CLAUDE.md a silently-unrunnable authz suite is the Sprint-5 failure mode, so the harness must **fail loud** if the arrangør seed is missing rather than skip.

- **M1 — Model + Read.** Add the §2 fields; build the public detail route and confirm list/detail show published-only and exclude `archived`.
  - Tests: anon sees published list + detail; unpublished/archived/unknown detail ⇒ 404; all legacy events still render (16 at time of writing — assert against the actual count, not a hardcoded 7).
- **M2 — Create.** Gated create page + form; `event_create` handler with the full §8.1 contract, owner stamp, self-chosen `published` state.
  - Tests (success): arrangør creates a **published** event → object persisted with `owner`, `published:true`, audit row, and it appears in the public list immediately; creating with Synlig = Nej → saved as a draft the owner sees in their dashboard while the public list excludes it.
  - Tests (failure/negative): anon GET of `/begivenheder/opret` ⇒ redirect to `/login`; **direct POST** to the create action as anon ⇒ 401/403; logged-in member without events perm ⇒ 403; missing/invalid CSRF ⇒ 403; invalid input (bad date, `<>` in title, out-of-enum group, `javascript:` url) ⇒ 400 with field errors and no object written.
- **M3 — Update.** Load-by-key, prefilled form, per-object authz, save.
  - Tests (success): arrangør edits **own** → fields change, `owner` unchanged, `updated_by/at` set, audit row; super edits any.
  - Tests (negative): arrangør direct-POST `event_update` with **another owner's key** ⇒ 403, object untouched; client-submitted `owner` ignored (owner preserved across the update); unknown key ⇒ 404.
- **M4 — Delete.** Confirmation step; soft archive (arrangør/own) vs hard delete (super).
  - Tests (success): arrangør soft-archives own → object retained, `archived:true`, gone from public list + detail 404, audit row; super hard-deletes → object removed.
  - Tests (negative): arrangør delete of another's event ⇒ 403; delete without confirm/CSRF ⇒ rejected; forced-browse direct POST ⇒ rejected.

**Cross-cutting (M2→):** a forced-browsing suite asserting every mutating endpoint enforces authn+authz+CSRF regardless of UI; audit entries written on every successful mutation **and the audit log is append-only** (a second mutation adds a line without altering prior lines); an `organizers` account is denied admin-panel access (`/admin` ⇒ not authorized, confirming `admin.events.*` does not confer `admin.login`); flash feedback renders via the shared component.

---

## 13. Release acceptance criteria

- All four operations work from the frontend; arrangører full-CRUD **within their permitted scope**; anonymous users see published events only and cannot mutate anything.
- Direct-POST / forced-browsing attempts that bypass UI gating are rejected by handler-level authz — **negative tests present and green**.
- Tests green across M1–M4; the §10 security checklist satisfied; the rollout/migration below documented and executed.

---

## 14. Dependencies & version constraints

- **Required & present:** Grav ≥1.7.25 (1.7.52), Form ≥5.1.0 (8.2.1), Flex Objects (1.3.8, enabled), Login (3.8.0, enabled).
- **Relied upon:** `feature-flags` (gating; add the new enum case) and **`flex-cache-bust`** (must stay enabled — public-list freshness after a Flex mutation depends on its `onFlexAfterSave/Delete` cache busting).
- **Not required:** the admin plugin stays disabled — the feature is frontend-only.

---

## 15. Rollout / migration plan

1. **Current state:** events edited only by a super, directly in the events YAML / via git (admin panel disabled). No ownership fields.
2. **Ship code** (blueprint fields, `groups.yaml`, `event-manager` plugin, templates) with `event_management` **off** on staging/test, **on** in dev/local. The new fields are additive/optional — **no data migration required**; legacy events with no `owner` are treated as super-only-editable.
3. **Optional backfill:** assign `owner` on the existing legacy events (16 at time of writing) — to a super or a named arrangør — if specific ownership is wanted. Because live data sits in `<tier>data/` (off-git), any backfill runs against each tier's live data (manual edit or the data-versioning runner) — not a repo commit.
4. **Grant the role:** create the first `organizers` account(s) by group assignment; verify they get `admin.events.*` and **not** admin-panel access.
5. **Flip the flag per tier** once a tier's manual + automated checks pass (dev → test → staging → prod), matching the existing feature-flag promotion posture.

---

## 16. Open decisions (resolved with recommendations)

| Decision | Recommendation (adopted) | Alternative |
|---|---|---|
| Publishing | **Self-service**: arrangører publish/unpublish their **own** events directly (part of `admin.events.update`); no admin approval in the normal flow. | Gated moderation (super approves) — rejected; arrangører must be self-sufficient. |
| Edit/Delete scope | **Own-only** for arrangører via `owner`; super = all (rare escalation, for fixing others' events). | Any-arrangør-edits-any (drop ownership) — rejected; weakens least privilege. |
| Delete semantics | **Soft archive** = the arrangør's self-service, reversible delete (retain, unpublish, hide); **hard delete** (permanent) super-only and rare. | Hard delete for all — rejected; no undo. |
| Onboarding | **Invite/manual** group assignment by super. | Self-register-then-approve (future). |
| Admin access for arrangører | **None** — frontend-only, `site.login` + `admin.events.*`, no `admin.login`. | — (confirmed). |
| Permission namespace | **Reuse `admin.events.{create,read,update,delete}`** (publishing own = part of `update`); cross-owner actions + hard-delete = `admin.super`. | `site.events.*`; or mint `admin.events.manage_all` for a non-super moderator role. |
| Mutation mechanism | **Flex API** (blueprint validation + supported write path) **plus an explicit post-mutation cache bust** — don't rely on `onFlexAfterSave/Delete` firing frontend-side (unverified in 1.3.8; §8). | Direct-YAML house pattern — rejected: bypasses validation, and would still need its own cache bust. |
| Event detail routing | Plugin-resolved `/begivenheder/<key>` with server-side read authz. | A Flex-registered object route — verify 1.3.8 support during implementation. |
