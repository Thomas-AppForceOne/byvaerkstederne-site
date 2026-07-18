# Specification — Flex data out of git (live-state lifecycle)

Status: Proposed
Owner: thomas@appforceone.dk
Scope: Stop tracking `config/www/user/data/flex-objects/` in git; provide a seed bundle for local development and tests; harden `push-data.sh` against overwriting live user state.

---

## 1. Problem

The flex-objects YAML files are tracked in git, but they have become **runtime user state**, not code or editorial content:

- `begivenheder.yaml` — since the frontend event CRUD + RSVP features, events are created/edited by organizers on the tier, and signups attach to them. The committed copy is stale by design.
- `roadmap-items.yaml` — carries per-user votes mutated at runtime.
- `bug-reports.yaml`, `feature-suggestions.yaml`, `submission-tokens.yaml` — user-generated content and tokens; `push-data.sh` already refuses to push them for exactly this reason.
- `events-audit.jsonl` — append-only runtime audit log (~240 KB and growing).
- `teammedlemmer.yaml`, `opgaver.yaml`, `oenskeliste.yaml` — not yet used in production (confirmed by operator, 2026-07-18); demo/dev content only.

The stated policy already agrees: "Live-tier state (`user/accounts/`, `user/data/`) is never committed; seed bundles provide test state" (account_self_service spec §3). Deploys already exclude the data tree; tiers own their data in `<tier>data/v0/`; `backup.sh` is the recovery path.

**Concrete foot-gun:** once testers create events/signups on a tier, a `push-data.sh` run overwrites their work with the stale committed copy.

## 2. In scope

1. **Untrack** every file under `config/www/user/data/flex-objects/` (`git rm --cached`; history is preserved) and gitignore the directory.
2. **Seed bundle** `tests/fixtures/grav-seeds/sample-content/` containing the current sample dataset (10 events incl. `details_html` on five, roadmap items, team/opgaver/ønskeliste), following the grav-seeds bundle contract (idempotent `apply.sh`, README, no secrets).
3. **Local bootstrap**: `make setup` (or a documented `make seed-content`) applies the bundle so a fresh clone still gets a populated local site; the empty-state after a bare clone must render without errors.
4. **Test suites** that assume flex data exist locally declare/apply the bundle in their own setup, per the "tests must not depend on pre-existing state" rule.
5. **`push-data.sh` hardening**: with no committed canonical source the script's premise changes — require an explicit `--files=` (no implicit `begivenheder.yaml` default) and extend the warning text: pushing events overwrites organizer-created events and RSVP signups on the tier.

## 3. Out of scope

- Account seeding (exists: `grav-seeds/playwright/`).
- The data-versioning/migration machinery (`<tier>data/v<N>`, migrate.sh) — unchanged.
- `reset-data.sh` and the tier-reset family — already operate on tier-side data.
- Removing files from git *history* (`git filter-repo`) — not required; nothing secret is involved.
- Prod — the unused datasets are absent/ignored there regardless.

## 4. Boundaries

- No plugin/PHP changes; this is repo-lifecycle + tooling only.
- The seed bundle is the **only** sanctioned source of sample content; ad-hoc `push-data` of local files to a tier with live users requires the sharpened confirmation.
- Local Docker keeps binding `./config`, so the gitignored files continue to work as the local instance's live data — they are simply no longer version-controlled.

## 5. Test requirements

- Bundle `apply.sh` is idempotent (second run is a no-op) — success + failure path (refuses when the target Grav root is missing).
- A bare clone (no seed) renders calendar/roadmap/team pages as empty states without errors.
- `push-data.sh` without `--files=` exits non-zero with the new usage text.

## 6. Migration steps (implementation order)

1. Create the seed bundle from the current committed content.
2. Wire bootstrap + test setups to the bundle; verify suites green.
3. `git rm --cached` + `.gitignore`; adjust `push-data.sh`.
4. README/CLAUDE.md note: where sample content now lives.
