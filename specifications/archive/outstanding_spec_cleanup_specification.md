# Specification — Outstanding spec cleanup (consolidated leftovers)

Status: Planned
Owner: thomas@appforceone.dk
Scope: A single cleanup pass closing the small, verified divergences between the already‑shipped specifications and the implemented system (audit 2026‑06‑17). Touches feature‑flag config + one PHP interface method, two content corrections, an internal filter‑ID rename, three deploy‑test cases, and one env README. No new product surface.

---

## Goal

Bring the code into agreement with what its shipped specs called for, only where the gap is small and self‑contained. This is housekeeping, not new capability — each item is a verified spec↔code mismatch, scoped so the whole set lands as one PR. Forward‑work features, manual release gates, and immutable‑spec reconciliations are explicitly excluded (see Boundaries).

## Boundaries — what this spec deliberately does NOT cover

- **Forward‑work features** (→ roadmap, not cleanup): the remote‑mode (SSH) migration runner; CI release‑protection Parts 2 & 3; real‑tier automated coverage; and the orphan‑data‑dir pruner (`deploy/prune-orphan-data.sh`), which only has a job once schema‑bumped `v<N>` data dirs exist — i.e. it belongs with the remote‑mode work.
- **Operator / manual release gates** (→ a release checklist, not code): per‑tier salt‑rotation record (WI‑3 of member‑auth); live‑TLS `Set-Cookie` `Secure` confirmation through the real proxy (WI‑4); the staging GDPR ship‑gate (basic‑auth live + ADR‑002 sign‑off); one‑time live‑tier `data-version.yaml` stamping.
- **Archived‑spec text drift** (archived specs are immutable): e.g. the member‑auth spec lists `session.secure: true` while the impl deliberately relies on `secure_https` + `X-Forwarded-Proto`. Reconcile via an ADR, not here.

## Work items

Independent unless noted; each may land as its own commit, all on one PR.

### WI‑1 — Resolve the dead `workshop_detail_pages` feature flag
- **Problem.** The flag is defined in the enum and every per‑tier `features.yaml`, but the four `/vaerksteder/*` subpages it was meant to gate (`groent-byvaerksted`, `krea-cafe`, `makerspace`, `eventvaerkstedet`) carry no `feature:` field, so the flag hides nothing.
- **Resolution (high level).** A flag that gates nothing is the defect. Restore its purpose by gating those four pages with it (the original intent), **or** retire the flag from the enum and every `features.yaml`. Default: gate the pages.
- **Interface.** The feature‑flags enum + plugin resolution; the four pages' `modular.md` frontmatter (`feature:` key); `env/<host>/config/features.yaml`.
- **Acceptance.** Flag off on a tier ⇒ the four pages are unreachable (themed 404/redirect) and hidden from nav; flag on ⇒ reachable. OR the flag is gone from the enum and all `features.yaml` with no dangling reference. The chosen behaviour is pinned by a test on both the on and off path.

### WI‑2 — Add `isDisabled(): bool` to `FlagStoreInterface`
- **Problem.** The development‑flags spec lists `isDisabled(): bool` on the public store contract, but the interface declares only `isEnabled`/`isConfigured`/`getEnabledFlags`/`allFlags`/`debug`; `isDisabled` exists only in test mocks.
- **Resolution.** Add `isDisabled(string $flag): bool` to the interface and its concrete store as the exact inverse of `isEnabled` under the same resolution rules; expose via Twig if the siblings are.
- **Interface.** `config/www/user/plugins/feature-flags/src/FlagStoreInterface.php`, the concrete store, Twig function registration.
- **Acceptance.** `isDisabled` is on the interface and returns the exact inverse of `isEnabled` for enabled, disabled, and unconfigured flags, proven by a test.

### WI‑3 — Retire the Makerspace `_04.cta` module
- **Problem.** The opening‑day spec calls for a three‑section Makerspace page with `_04.cta` deleted; the module still exists.
- **Resolution.** Remove the `_04.cta` modular folder.
- **Interface.** `config/www/user/pages/03.vaerksteder/makerspace/`.
- **Acceptance.** Makerspace renders the three intended sections; no `_04.cta` content appears.

### WI‑4 — Remove fictive "Mads Nielsen" placeholder data under `config/`
- **Problem.** The opening‑day exit criterion forbids any "Mads Nielsen" reference under `config/`; it survives on the team, kontakt, team‑cards, and press‑contact content.
- **Resolution.** Replace with real content or remove the placeholder entries cleanly (no empty cards).
- **UI/UX.** Affects visible team/contact/press content — replacements must be real, valid Danish content.
- **Interface.** `teammedlemmer.yaml`, `04.kontakt/_02.form/contact_form.md`, `04.kontakt/_03.team/team_cards.md`, `08.presse/_04.contact/press_contact.md`.
- **Acceptance.** `grep -ri 'mads nielsen' config/` returns nothing; the affected pages render correctly.

### WI‑5 — Rebrand calendar filter IDs `groenne→groent`, `kreativ→krea`
- **Problem.** The opening‑day spec mandates this rename; the IDs remain `groenne`/`kreativ` (consistent, so filters work) — the rebrand was never executed.
- **Resolution.** Rename the two filter‑ID tokens consistently everywhere they appear — the filter UI **and** the event/task data — to the new names, preserving the visible labels and filter behaviour.
- **UI/UX.** Visible filter labels and which events each filter selects must be unchanged after the rename; only the internal IDs change.
- **Interface.** `partials/calendar_filters.html.twig`, `event_list.html.twig`, `event_highlight.html.twig`, `data/.../begivenheder.yaml`, `opgaver.yaml`.
- **Acceptance.** No `groenne`/`kreativ` ID tokens remain; the green and creative filters still select exactly the same items as before, pinned by a test.

### WI‑6 — Close the promote/rollback test‑coverage gaps
- **Problem.** Three spec‑named behaviours have no test (CLAUDE.md requires success + failure coverage); the suites currently stamp same‑version fixtures that short‑circuit the relevant branches:
  - promote‑to‑staging/prod **migration bump** — success (live data `0.1.0`, code requires `0.2.0` ⇒ migration applied, result at target) **and** failure (required migration missing ⇒ abort **before** any push to the tier).
  - staging `--from-backup <id>` **success** path (skips a fresh backup, uses the existing archive) — only the bad‑id failure is covered.
  - `rollback-prod --code-to <commit>` — uncovered (at least the local "skipping `--code-to`" branch).
- **Resolution.** Extend the existing fixture‑based local‑mode suites with these cases, following the established fixture pattern. No product‑code change is expected.
- **Test requirements.** Each case asserts both the success and the failure/abort outcome where applicable; the missing‑migration case must prove the abort happens **before** any tier push (removing that guard must make a test fail).
- **Interface.** `tests/deploy/promote-to-staging.sh`, `tests/deploy/promote-to-prod.sh`, the migration fixtures.
- **Acceptance.** `make test-deploy` green with the new cases.

### WI‑7 — Add the staging‑env README documenting the test‑entries contract
- **Problem.** The promote‑to‑staging spec requires a prominent README at `config/www/user/env/staging.hackersbychoice.dk/README.md` stating the "no preserved test entries on staging — staging carries real prod data, overwritten wholesale each promotion" contract; the file was never created.
- **Resolution.** Create the README with that contract, cross‑referencing ADR‑002.
- **Interface.** `config/www/user/env/staging.hackersbychoice.dk/README.md`.
- **Acceptance.** The file exists and states the contract + the ADR‑002 GDPR posture.

## Test requirements (whole spec)

Every behaviour‑changing item ships with a test that fails without the change (CLAUDE.md). WI‑6 is itself test work; WI‑1, WI‑2, and WI‑5 each get a pinning test on both the positive and negative path. WI‑3/WI‑4/WI‑7 are content/doc changes — assert by render/grep.

## Exit criteria (whole spec)

- WI‑1…WI‑7 met, each with its test; `make test-deploy` and the relevant Playwright suite green.
- No new product surface introduced.
- The excluded forward‑work and manual‑gate items are recorded (roadmap / release checklist) rather than silently dropped.
