# Implementation roadmap

The order in which the specs in this folder should be tackled. Later specs assume earlier ones have shipped; implementing out of order will either duplicate work or leave gaps.

Folder policy (what belongs here, how specs become ADRs) lives in [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle).

---

## Order

### 1. Semantic version + build number display for apex and site — IMPLEMENTED

**Spec:** [archive/semantic_versioning_specification.md](archive/semantic_versioning_specification.md)

Decouple the version label from the deploy script and split it into two component-scoped files: `apex/VERSION` for the selector page and `config/www/VERSION` for the Grav site. Both read at request time, so the displayed version is a property of the deployed code rather than of the deploy step. Add a "Version <X> · build <N>" line to the Grav site footer (currently the version is only visible on the apex).

Augment the SemVer with an automatically maintained build number (`apex/BUILD`, `config/www/BUILD`, generated at deploy time as `git rev-list --count HEAD`). The build number is identical for every tier running the same commit — dev/test/staging/prod all show the same `build N` when they're on the same source — which is what gives the displayed pair its "stable through dev/test/staging/prod" property.

Both versions start at `0.1.0`. Independence between apex and site versions is intentional — they evolve at different paces.

**Exit criteria:** apex and site both display "Version <semver> · build <integer>" sourced from files in the repo; version bumps require no deploy-script changes; build number is regenerated automatically and matches across tiers running the same commit; missing/malformed file falls back to "ukendt" for that half without breaking the page.

### 2. Prod backup and restore tooling — IMPLEMENTED

**Spec:** [prod_backup_restore_specification.md](archive/prod_backup_restore_specification.md)

Foundation for the data-lifecycle work that follows. Build a single command that produces an encrypted, versioned snapshot of everything Grav considers state — member accounts, flex-objects, uploaded files, and their schema marker — and a matching restore command in two modes (to a scratch directory for inspection, or to a tier wholesale). Backups live off the prod server in object storage, protected at rest with `age`, retained on a daily/weekly/monthly schedule plus indefinitely-kept tagged snapshots used by later promotion steps as rollback insurance.

Independently useful even before any later step ships: gives us "undo what happened on Tuesday" capability for the first time.

**Exit criteria:** `./deploy/backup.sh prod` and `./deploy/restore.sh <tier-or-dir>` are working commands; backups carry a metadata file with code/data versions; retention enforces correctly; tagged backups are immune to retention sweeps.

### 3. Atomic deploy releases — IMPLEMENTED

**Spec:** [archive/atomic_deploy_releases_specification.md](archive/atomic_deploy_releases_specification.md)

Replace the in-place `rsync --delete` model in `deploy/deploy.sh` with an atomic, rollback-able release model. Each tier gets its own versioned release directories (`<tier>-releases/<timestamp>/`) holding immutable code, a sibling per-tier data directory (`<tier>data/v<N>/`) holding all mutable state, and a single symlink at the docroot (`<tier> → <tier>-releases/<current>`) that constitutes the live tier. Deploy is "rsync to a fresh release dir + symlink swap"; rollback is "symlink swap back". The April 2026 accounts wipe and the May 2026 dev re-wipe are structurally impossible under this layout — `<tier>data/` is not in the rsync's path tree at all.

Layout is per-tier-isolated (dev's data is independent of test's, etc.) and forward-compatible with versioned data dirs that step 4's data-versioning consumes for clean rollback across schema bumps. Phase 1 ships with a single `v0` data dir; Phase 2 (handled by step 4) extends the deploy to copy + migrate per-version dirs.

The apex `landing` deploy is unchanged — it has no mutable state and no rollback story to preserve.

**Exit criteria:** docroot is a symlink resolving to a release dir; `<tier>data/` is a sibling of every release dir and untouched by deploys; user state is bit-identical across deploys with no data version change; rollback to the previous release works via a single command; `release-meta.yaml` audit trail is present in every release; one-time migration script promotes existing tiers from the current in-place layout to the new one without data loss.

### 4. Data versioning and migration runner — IMPLEMENTED (remote-mode follow-up outstanding)

**Spec:** [archive/data_versioning_and_migrations_specification.md](archive/data_versioning_and_migrations_specification.md)

The runner, migrations, fixtures, test harness, CI workflow, and the deploy.sh local-mode integration are shipped. The SSH-driven remote-mode branch of `bv_remote_run_migration_step` (`deploy/lib/migrate-integration.sh`) is deliberately not yet implemented: when a real prod schema bump is requested, the helper refuses with a clear message and `deploy.sh` aborts before the atomic symlink swap. This preserves the spec's safety contract — schema-bump deploys against an SSH tier can only proceed via a manual backup-restore-migrate-push loop until the remote-mode SSH execution lands in a follow-up sprint.

Stamp the site's data with a SemVer schema version (independent of the code version), define a hand-written-PHP-script format for migrations (`migrations/<target_version>_<slug>.php`, idempotent, pure file transformation), and build a runner (`./bin/migrate <data-dir>`) that applies the right set of migrations to bring a snapshot from one schema version to another. CI runs each migration's fixture-based test on every PR that touches `migrations/`.

Plugs into the atomic-deploy layout from step 3: a deploy whose required schema version differs from the live tier's `<tier>data/current` triggers `cp -a <tier>data/v<old>/ <tier>data/v<new>/`, runs migrations against the new version dir, points the new release's symlinks at it, and updates the `current` marker. Rollback to a previous release uses the preserved `v<old>` dir, so cross-schema rollback works as long as retention hasn't pruned the old version.

Forward-only on the migration runner itself — rollback is by symlink swap into a preserved `v<old>` dir (or, if that's been pruned, by restore-from-backup). No live in-place migrations on production: the runner always operates on a fresh `v<new>` dir copied from `v<old>`.

**Exit criteria:** `data-version.yaml` exists on every tier; migration runner correctly applies the right scripts in order; idempotence is verified by CI; missing migrations halt with a clear error; deploy of a release with a bumped schema version produces a new `<tier>data/v<N>/` dir without modifying the previous one.

### 5. Promote to staging — Planned

**Spec:** [promote_to_staging_specification.md](promote_to_staging_specification.md)

A single command (`./deploy/promote-to-staging.sh`) that orchestrates the previous steps into a working refresh: take a fresh prod backup, restore it to a local scratch dir, run migrations forward to the code's data version, deploy code to staging via the atomic-deploy machinery, populate staging's `<staging>data/v<target>/` with the migrated snapshot, write a "blessing" marker on staging that records the (commit, version, build, data version, features.yaml hash) tuple. The marker is the only signal that step 6 (promote to prod) consumes.

Atomic-deploy handles the code-side mechanics; this spec adds the orchestration around it (backup-restore-migrate up front, blessing-marker write at the end) and replaces the per-subdirectory rsync into the live tier's `user/` paths with a write-then-symlink-into-place flow against the new `<staging>data/v<target>/` dir.

Adopts a strict "no preserved test entries on staging" contract: every promotion overwrites staging's data wholesale. The without-stripping-users decision means real member data lands on staging — flagged as a GDPR review point that must be resolved before this spec ships.

**Exit criteria:** the command produces a blessing on success and fails closed (no blessing) on any failure between reachability and data-push; staging visibly carries prod-shaped data afterwards; the test-entries contract is enforced; the previous staging release stays available for rollback per atomic-deploy.

### 6. Promote to prod — Planned

**Spec:** [promote_to_prod_specification.md](promote_to_prod_specification.md)

The final step. A single command (`./deploy/promote-to-prod.sh`) that promotes a staging-blessed (commit, data version, flag posture) tuple to production, gated behind verification that staging is genuinely blessed for the local commit + data version + flags. The command takes a tagged "pre-promotion" backup as rollback insurance, applies migrations to the snapshot, syncs staging's `features.yaml` over to prod's, deploys the new code via the atomic-deploy machinery, populates prod's `<prod>data/v<target>/` with the migrated snapshot, and prints a summary that constitutes the audit trail. A reviewable escape hatch (`--bypass-staging-gate --reason "..."`) exists for hot-fix scenarios where staging is itself broken.

Codifies the rule: *"never allow pushing a version to prod unless it has been deployed to staging with migrated prod data"*. The gate is the rule.

Rollback uses the atomic-deploy `rollback.sh prod` for the code+symlink layer and the backup-restore tooling for an alternate "restore tagged pre-promotion backup" path. The two are complementary: symlink rollback is the fast path (sub-second), backup restore is the safety net for situations the symlink swap can't recover (e.g. data corruption that landed during the bad release window and needs to be erased).

**Exit criteria:** the gate refuses any prod deploy whose staging-blessing tuple doesn't match exactly; tagged pre-promotion backups exist for every promotion; bypass usage is logged on prod; both rollback paths (symlink + backup-restore) work; the previous release stays preserved for symlink-rollback per atomic-deploy.

### 7. CI release protection, Part 1: PR validation & merge guards — IMPLEMENTED

**Spec:** [archive/ci_release_protection_part1_specification.md](archive/ci_release_protection_part1_specification.md)

Move the release invariants that today live only in the local `make` tooling "left" to the pull request. A no-secrets GitHub Actions workflow runs `make test-deploy` on every PR and enforces the release-branch, bumped-version, and free-tag rules on PRs into `main`, so the rules hold regardless of who merges or how (the `1.1.0` cleanup showed how drift accumulates when nothing runs at merge time). The back-merge condition is reported but never blocks, so a required check can't deadlock the repo. First of a three-part CI series — Part 2 auto-tags and auto-opens the back-merge on merge (needs a token); Part 3 runs the deploys from CI (needs secrets + runner network).

**Independent of steps 5–6.** Depends only on the release-safety tooling shipped in `1.1.0` (`deploy/lib/release-flow.sh`, `release-gate.sh`, `version-bump.sh`, `make test-deploy`), not on the promotion chain — so it can be tackled in parallel.

**Exit criteria:** `make test-deploy` runs as a required check on PRs; PRs into `main` from a non-`release/*`/`hotfix/*` head, with an unbumped or pre-release version, or with an already-existing tag, are refused with a specific message; the back-merge advisory reports the gap without ever failing; the introducing PR is not self-gated; the flaky `tests/deploy/migrate.sh` mtime assertion is hardened so the required `test-deploy` check is deterministic.

### 8. Member account creation & login hardening — Planned (independent track)

**Spec:** [member_auth_hardening_specification.md](member_auth_hardening_specification.md)

Close the seven findings from the June 2026 review of the self-service member registration and login flow. The stock `login` (v3.8.0) and `email` (v4.2.2) plugins are configured and themed, not patched — the work is configuration, theme templates, secrets-handling, and tests. Seven self-contained work items: a working themed password-reset flow with real SMTP transport (today reset is broken — no email transport, unstyled routes); email verification before access plus removal of instant auto-login; removing the committed `security.yaml` salt from git and rotating it; an explicit hardened session-cookie block (`Secure`/`HttpOnly`/`SameSite`); pinning `pwd_regex`/`username_regex` in the repo instead of inheriting Grav-core defaults; Playwright coverage of the custom auth surface on both success and failure paths; and registration UX/localisation polish (confirmed password, Danish validation messages, no hotlinked third-party image).

This is **not** part of the data-lifecycle/deploy chain (steps 2–6) and does not block or depend on it. Its only structural dependency — per-tier secret provisioning for SMTP creds and the salt — is satisfied by the already-shipped atomic-deploy per-tier state layout (step 3). It can be scheduled at any time. Work items WI-1 → WI-2 are ordered (email transport before the verification gate); the rest are independent and may land as separate PRs.

**Exit criteria:** password reset works end-to-end inside the themed site shell; new accounts are disabled until email-verified and are no longer auto-logged-in; no auth secret is tracked in git and the exposed salt is rotated on every tier that used it; the session cookie carries `Secure`/`HttpOnly`/`SameSite=Lax` on TLS tiers with login still working through the proxy; `pwd_regex`/`username_regex` are pinned and agree with the client-side checks; the registration/login/activation/reset surface has green success- and failure-path Playwright coverage that skips cleanly without credentials.

### 9. Event-card template unification — IMPLEMENTED (independent frontend track)

**Spec:** [archive/event_card_template_unification_specification.md](archive/event_card_template_unification_specification.md)

Unify every event-card rendering path (`event_list`, `atelier_sessions`, `calendar_featured`, `event_highlight`) onto a single canonical Twig partial (`partials/event_card.html.twig`) driven by `inList`/`featured` flags, replacing the bespoke per-template markup and CSS with one container-query-based component. Shipped across two sprints in **v1.1.0** (merge `a8d0b7d`): sprint 1 introduced the partial and migrated the list templates; sprint 2 migrated the two modular/featured templates and deleted the dead `.bv-featured-event*` / `.bv-event-highlight*` / `.bv-event-date*` classes, with Playwright mobile + desktop visual-parity coverage on both.

**Independent of the data-lifecycle chain (steps 2–6) and the CI/auth tracks.** A pure theme/template refactor; depends only on the `.bv-event-row` structure from PR #35. Listed here so the roadmap reflects everything that has shipped.

---

## Out-of-order risks

- Step 1 was independent of the data-lifecycle chain. (Implemented.)
- Skipping step 2 → steps 4–6 have nothing to back up, restore, or version. Step 2 is the foundation; without it the rest is paper.
- Skipping step 3 → steps 5–6 still work via the legacy in-place rsync, but every code deploy continues to risk the April 2026 / May 2026 wipe class of incident; data-lifecycle work that lands afterward inherits the same fragility on its data-push step. Step 3 is also a prerequisite for clean rollback across schema bumps; without it, step 4 can ship migrations but rollback after a breaking change requires backup-restore (slower, more downtime).
- Reordering 3 and 4 → step 4 (data-versioning) needs the per-version data-dir layout that step 3 introduces. Done in the other order, step 4 either ships in-place migrations on the live tier (the explicit non-goal of step 4's spec) or invents a parallel layout that step 3 then has to reconcile. Order matters.
- Skipping step 4 → step 5 can refresh staging only when no schema change is needed; the moment any data-shape edit lands without a migration, promotion silently corrupts staging's data.
- Reordering 5 before 6 → step 6's gate reads the blessing marker that step 5 produces; without 5 in place there is nothing to gate on, and step 6 collapses to "deploy code to prod" — which is what we have today.
- Reordering 6 before 5 → step 6 has no input. The gate would always refuse (no marker exists), which is at least fail-closed but means prod cannot be promoted at all.
