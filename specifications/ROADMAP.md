# Implementation roadmap

The order in which the specs in this folder should be tackled. Later specs assume earlier ones have shipped; implementing out of order will either duplicate work or leave gaps.

Folder policy (what belongs here, how specs become ADRs) lives in [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle).

---

## Order

### 1. Feature-flag infrastructure — IMPLEMENTED

**Spec (archived):** [archive/development_flags_specification.md](archive/development_flags_specification.md)

Shipped on branch `gan/20260419T154559Z-f8eb`. `FeatureFlag` enum, `FlagStore`, Twig helpers (`feature_enabled`, `enabled_features`, `feature_visible`), page-level `feature:` frontmatter gating, and centralized collection filter are all in place under `config/www/user/plugins/feature-flags/`. Flags default to false; no visible site changes.

**Exit criteria:** met. PHPUnit suite: 122 tests / 397 assertions. Live HTTP verified. ADR to be written at PR-merge time per CLAUDE.md.

### 2. End-to-end test coverage for Roadmap, Rapportér fejl, Forslå Feature — IMPLEMENTED

**Spec (archived):** [archive/roadmap_bug_feature_tests_specification.md](archive/roadmap_bug_feature_tests_specification.md)

Shipped on branch `gan/20260419T200123Z-5ee1`. Playwright suite covers anonymous rejection paths and authenticated flows for Roadmap voting, Rapportér fejl (bug report overlay + submission), and Forslå Feature. Includes globalSetup/globalTeardown-driven account provisioning/cleanup, feature-flag touchpoint assertion, and acceptance-criteria matrix under [tests/ACCEPTANCE.md](../tests/ACCEPTANCE.md).

**Exit criteria:** met. Anonymous suite 23 passed / 34 skipped / 0 failed; authenticated tests skip cleanly with env-var-named reasons when creds are absent.

### 3. Feature-flag rollout to unfinished features and pages — IMPLEMENTED

**Spec (archived):** [archive/feature_flag_rollout_specification.md](archive/feature_flag_rollout_specification.md)

Shipped on branch `gan/20260422T182055Z-5cb6`. 17-flag rollout catalogue declared in the `FeatureFlag` enum; `test.hackersbychoice.dk` and `staging.hackersbychoice.dk` env profiles under `config/www/user/env/`; page-level frontmatter gates across home sub-sections, workshop detail pages, roadmap, community affordances, membership-signup, press/minutes/calendar/contact/statutes; Twig partial gates on navigation, footer, base overlays, and the roadmap card grid; `|feature_visible` on the workgroups card grid; PHP handler gates on the roadmap/feature-suggestion/bug-report plugins returning a non-leaking `404 Not Found` before any nonce/auth/input parsing when their flag is off. Playwright coverage across both profiles: 117 anonymous tests passing.

**Exit criteria:** met. Anonymous suite 117/117 passed under both profiles; PHPUnit feature-flags suite 139 tests / 1113 assertions; pre-existing Sprint-1+2 regression baseline intact. ADR to be written at PR-merge time per CLAUDE.md.

### 4. Semantic version + build number display for apex and site — PLANNED

**Spec:** [semantic_versioning_specification.md](semantic_versioning_specification.md)

Decouple the version label from the deploy script and split it into two component-scoped files: `apex/VERSION` for the selector page and `config/www/VERSION` for the Grav site. Both read at request time, so the displayed version is a property of the deployed code rather than of the deploy step. Add a "Version <X> · build <N>" line to the Grav site footer (currently the version is only visible on the apex).

Augment the SemVer with an automatically maintained build number (`apex/BUILD`, `config/www/BUILD`, generated at deploy time as `git rev-list --count HEAD`). The build number is identical for every tier running the same commit — dev/test/staging/prod all show the same `build N` when they're on the same source — which is what gives the displayed pair its "stable through dev/test/staging/prod" property.

Both versions start at `0.1.0`. Independence between apex and site versions is intentional — they evolve at different paces.

**Exit criteria:** apex and site both display "Version <semver> · build <integer>" sourced from files in the repo; version bumps require no deploy-script changes; build number is regenerated automatically and matches across tiers running the same commit; missing/malformed file falls back to "ukendt" for that half without breaking the page.

### 5. Prod backup and restore tooling — PLANNED

**Spec:** [prod_backup_restore_specification.md](prod_backup_restore_specification.md)

Foundation for the data-lifecycle work that follows. Build a single command that produces an encrypted, versioned snapshot of everything Grav considers state — member accounts, flex-objects, uploaded files, and their schema marker — and a matching restore command in two modes (to a scratch directory for inspection, or to a tier wholesale). Backups live off the prod server in object storage, protected at rest with `age`, retained on a daily/weekly/monthly schedule plus indefinitely-kept tagged snapshots used by later promotion steps as rollback insurance.

Independently useful even before any later step ships: gives us "undo what happened on Tuesday" capability for the first time.

**Exit criteria:** `./deploy/backup.sh prod` and `./deploy/restore.sh <tier-or-dir>` are working commands; backups carry a metadata file with code/data versions; retention enforces correctly; tagged backups are immune to retention sweeps.

### 6. Data versioning and migration runner — PLANNED

**Spec:** [data_versioning_and_migrations_specification.md](data_versioning_and_migrations_specification.md)

Stamp the site's data with a SemVer schema version (independent of the code version), define a hand-written-PHP-script format for migrations (`migrations/<target_version>_<slug>.php`, idempotent, pure file transformation), and build a runner (`./bin/migrate <data-dir>`) that applies the right set of migrations to bring a snapshot from one schema version to another. CI runs each migration's fixture-based test on every PR that touches `migrations/`.

Forward-only by design — rollback is by restore-from-backup, not by reversing a migration. No live in-place migrations on production: the runner always operates on a snapshot, which is then pushed to the target by the promotion specs.

**Exit criteria:** `data-version.yaml` exists on every tier; migration runner correctly applies the right scripts in order; idempotence is verified by CI; missing migrations halt with a clear error.

### 7. Promote to staging — PLANNED

**Spec:** [promote_to_staging_specification.md](promote_to_staging_specification.md)

A single command (`./deploy/promote-to-staging.sh`) that orchestrates the previous two steps into a working refresh: take a fresh prod backup, restore it to a local scratch dir, run migrations forward to the code's data version, deploy code to staging, push the migrated data into staging, write a "blessing" marker on staging that records the (commit, version, build, data version, features.yaml hash) tuple. The marker is the only signal that step 8 (promote to prod) consumes.

Adopts a strict "no preserved test entries on staging" contract: every promotion overwrites staging's data wholesale. The without-stripping-users decision means real member data lands on staging — flagged as a GDPR review point that must be resolved before this spec ships.

**Exit criteria:** the command produces a blessing on success and fails closed (no blessing) on any failure between reachability and data-push; staging visibly carries prod-shaped data afterwards; the test-entries contract is enforced.

### 8. Promote to prod — PLANNED

**Spec:** [promote_to_prod_specification.md](promote_to_prod_specification.md)

The final step. A single command (`./deploy/promote-to-prod.sh`) that promotes a staging-blessed (commit, data version, flag posture) tuple to production, gated behind verification that staging is genuinely blessed for the local commit + data version + flags. The command takes a tagged "pre-promotion" backup as rollback insurance, applies migrations to the snapshot, syncs staging's `features.yaml` over to prod's, deploys the new code, pushes the migrated data, and prints a summary that constitutes the audit trail. A reviewable escape hatch (`--bypass-staging-gate --reason "..."`) exists for hot-fix scenarios where staging is itself broken.

Codifies the rule: *"never allow pushing a version to prod unless it has been deployed to staging with migrated prod data"*. The gate is the rule.

A sibling command (`./deploy/rollback-prod.sh --to-backup <id>`) handles undo by restoring a tagged backup, with its own pre-rollback backup taken first.

**Exit criteria:** the gate refuses any prod deploy whose staging-blessing tuple doesn't match exactly; tagged pre-promotion backups exist for every promotion; bypass usage is logged on prod; rollback works via the dedicated command.

---

## Out-of-order risks

- Skipping step 1 → everything else is blocked; there is nothing to gate against.
- Skipping step 2 → step 3 ships without a regression net on the three most behaviourally complex surfaces, and any bug introduced by the flag wiring will be found in production.
- Rolling up steps 1 and 3 into one sprint → large, hard-to-review change; harder to isolate a rollback if the gating mechanism itself is buggy.
- Step 4 is independent of 1–3 and can be implemented at any time. It does touch `apex/index.php`, `deploy/deploy.sh`, and the Grav site footer template — small surface area, but worth a fresh GAN run rather than tacking onto an unrelated branch.
- Skipping step 5 → steps 6–8 have nothing to back up, restore, or version. Step 5 is the foundation; without it the rest is paper.
- Skipping step 6 → step 7 can refresh staging only when no schema change is needed; the moment any data-shape edit lands without a migration, promotion silently corrupts staging's data.
- Reordering 7 before 8 → step 8's gate reads the blessing marker that step 7 produces; without 7 in place there is nothing to gate on, and step 8 collapses to "deploy code to prod" — which is what we have today.
- Reordering 8 before 7 → step 8 has no input. The gate would always refuse (no marker exists), which is at least fail-closed but means prod cannot be promoted at all.
