# Specification — Promote to staging (data + code refresh)

Status: Planned
Owner: thomas@appforceone.dk
Depends on:
- [prod_backup_restore_specification.md](prod_backup_restore_specification.md)
- [atomic_deploy_releases_specification.md](atomic_deploy_releases_specification.md)
- [data_versioning_and_migrations_specification.md](data_versioning_and_migrations_specification.md)
Scope: A single command that refreshes staging with the current code
*and* a migration-applied snapshot of prod data, so staging genuinely
mirrors what prod is about to become. The third step of the
data-lifecycle series.

> **Interface with atomic-deploy and the migration runner.** This spec
> uses atomic-deploy's machinery for the code-side mechanics — release
> dirs, symlink swap, rollback. Migrations are run **locally** on the
> restored scratch snapshot with the shipped runner `deploy/migrate.sh`
> (there is no `bin/migrate`), so promotion pushes an *already-migrated*
> snapshot rather than migrating on the tier — it therefore does **not**
> depend on the still-unshipped remote-mode migration path in
> `deploy/lib/migrate-integration.sh`. The data-push step does **not**
> rsync into a release's live `user/` paths; it populates a fresh
> `<staging>data/v<target>/` directory from the migrated scratch and
> repoints `<staging>data/current` at it — the same
> `<tier>data/v<N>/user/...` layout `push-data.sh` already writes to.
> Because promote owns the data dir *and* the migration, it runs
> `deploy.sh` with `--skip-data-migration` (a flag this spec adds, see
> [Prerequisite](#implementation-prerequisite)) so deploy.sh's own
> in-deploy schema-bump step — which would otherwise invoke the
> unshipped remote runner and abort — stays out of the way. The
> blessing marker lives at the deployed release's Grav root
> (`config/www/staging-blessed.yaml`), outside `user/` and outside the
> `<staging>data/` tree, so no data push can wipe it.

## Implementation prerequisite

`deploy/deploy.sh` today runs an in-deploy schema-bump step (its
"Step 7.5", `bv_remote_run_migration_step` in
`deploy/lib/migrate-integration.sh`): when the live tier's data version
differs from the deployed bundle's, it tries to migrate the tier's data
dir in place — over SSH for remote tiers, which is the deliberately
**unshipped** remote-mode path that refuses and aborts the deploy.

A promotion always presents that mismatch at deploy time (staging's
live data is still the old version until step 7 pushes the new one), so
this spec adds a **`--skip-data-migration` flag** to `deploy.sh` that
suppresses Step 7.5. Promote then owns the migration (run locally,
step 5) and the versioned data-dir population + `current` repoint
(step 7). This is the single piece of new `deploy.sh` behaviour the
spec requires; everything else reuses existing commands.

---

## Motivation

Today, "deploy to staging" means deploy code. Staging's data is
whatever it happened to have last time someone touched it — fictional
test entries, a few admin accounts, no member accounts at all. That
makes staging a useless rehearsal venue for anything that depends on
realistic content shape: how does the events page render with 300
events? How does the member directory paginate at 200 entries? What
breaks when a real bug-report screenshot is 4MB?

We want staging to look like prod — not for marketing screenshots,
but so the rehearsal actually rehearses something real.

The pieces are now in place: backups exist, migrations are runnable.
This spec orchestrates them into a one-shot promote-to-staging
command.

---

## Non-goals

- **Anonymising data.** Staging gets prod data with members intact —
  including email addresses and bcrypt-hashed passwords. The
  team has decided this is acceptable given staging's restricted
  access — see [ADR-002](../decisions/ADR-002-prod-data-on-staging.md)
  for the rationale and the conditions that decision depends on.
  A future spec may add anonymisation; this one doesn't.
- **Preserving staging's existing test entries.** A promote-to-staging
  always replaces staging's data wholesale. If you need to keep test
  data across promotions, you keep it in a separate scratch space, or
  put it back manually after the promotion.
- **Promoting a specific historical commit.** This command always
  works against develop's tip (or whatever branch you've checked out).
  It's not a "promote backup-from-2026-04-15 to staging" tool — for
  that, use the backup spec's restore-to-tier directly.
- **Cross-account credential management.** The operator is assumed to
  have credentials for both prod (backup source) and staging
  (restore destination). Storing them is the existing
  `.env.deploy` mechanism's problem.

---

## The command

```
./deploy/promote-to-staging.sh [--from-backup <id>]
```

Without arguments: takes a fresh backup of prod, runs migrations
against it, deploys current code to staging, pushes the migrated
backup as staging's data.

With `--from-backup <id>`: skips the fresh-backup step and uses the
specified existing archive. Useful for "restore staging to last
night's prod state" without re-running the backup.

The command is non-interactive (scriptable). It prints progress
per step and exits non-zero on any failure.

**Where it runs.** This spec assumes the operator's laptop as the
primary execution host: the laptop holds the SFTP credentials for
both prod and staging (in `.env.deploy`), and the operator runs the
command interactively after merging a change to develop. We are
**not** wiring this to cron in any environment in v1, because:

- Cron on the laptop only fires when the laptop is on, which makes
  scheduled refreshes unreliable.
- Cron on a third box (a small ops VM) would require duplicating
  the prod + staging credentials onto a long-running host, which
  expands the credential blast radius.
- Auto-promotion is listed as out-of-scope future work below; until
  the team has hand-promoted enough to trust the loop, leaving the
  decision to a human is the right default.

A future spec can add a cron-host story (e.g., a dedicated ops VM
with its own credentials and a tightened blessing gate) once usage
patterns justify it.

---

## Steps in order

```
1. Verify staging is reachable. Verify prod is reachable.
2. If --from-backup is not given:
     a. Take a fresh prod backup using ./deploy/backup.sh prod.
     b. Note the resulting backup ID.
3. Restore the backup into a scratch directory (./deploy/staging-stage/),
   using the restore-to-directory mode of the backup spec.
4. Read the data_version from the scratch directory's metadata.
   Read the target data_version from the current code's
   config/www/user/data-version.yaml.
5. If they differ, run
   `deploy/migrate.sh ./deploy/staging-stage/ --to <target>`
   (the shipped migration runner — note `./bin/migrate` does not
   exist) to migrate the snapshot forward to the code's data version.
   If migration fails, abort — staging is untouched; the failed
   scratch dir is left for inspection.
6. Run `./deploy/deploy.sh staging --skip-data-migration` — the
   existing code-only deploy, with deploy.sh's in-deploy schema-bump
   step suppressed (see [Implementation prerequisite](#implementation-prerequisite)).
   Promote owns the migration (step 5) and the data-dir population
   (step 7), so deploy.sh must not also try to migrate the remote
   tier — which it can't, since the remote-mode runner is unshipped.
7. Populate staging's versioned data dir from the migrated snapshot
   and make it live:
     - Create a fresh `<staging>data/v<target>/` on the tier (with
       `<target>` the data version migrated to in step 5), then
       rsync -a --delete the scratch dir's `user/accounts/` into
       `<staging>data/v<target>/user/accounts/`, and likewise for
       `user/data/`, `user/pages/`, `user/uploads/`, and
       `user/data-version.yaml`. This is the same
       `<tier>data/v<N>/user/...` layout `push-data.sh` already writes
       to — promotion never rsyncs into a release's live `user/` paths.
     - Repoint `<staging>data/current` → `v<target>` only after the
       dir is fully populated. The new release's internal symlinks
       resolve through `current`, so activating the refreshed data is
       a symlink repoint, not an in-place overwrite.
     - **Forbidden:** the rsync MUST be per-subdirectory against the
       versioned data dir. The script enforces this by listing the
       state paths as a fixed array; widening that array (e.g. to a
       `user/`-level or release-dir-level sync) requires editing the
       script in a reviewable PR. This keeps the blessing marker
       (step 9, at the release Grav root, outside `<staging>data/`)
       structurally unreachable by the data push.
8. Clear staging's caches (existing deploy.sh post-step).
9. Write a "blessing" marker on staging:
     config/www/staging-blessed.yaml  (Grav root, NOT inside user/)
   containing:
     blessed_at, code_commit, code_version, code_build,
     data_version, features_yaml_sha256, source_backup_id.
   The marker lives **outside `user/`** specifically so the data-push
   rsyncs in step 7 can never wipe it, regardless of how the path
   list evolves. This file is what the promote-to-prod spec uses to
   gate prod deploys. Its production is a contract this spec must
   honour.
10. Smoke test against staging. The script `curl`s the URLs below
    and asserts the expected status code per URL:

    | URL (relative to https://staging.hackersbychoice.dk)         | Expected |
    |---------------------------------------------------------------|----------|
    | `/`                                                           | 200      |
    | `/login`                                                      | 200      |
    | `/medlemmer` (member-only landing)                            | 302 → /login |
    | `/begivenheder` (events list)                                 | 200      |
    | `/vaerksteder` (workshops list)                               | 200      |
    | `/staging-blessed.yaml`                                       | 200 — and `code_commit` matches |

    On any failure the script prints the failing URL + actual code,
    leaves the blessing in place (so later runs can inspect),
    exits non-zero, and does NOT auto-rollback. The operator decides
    next step.
11. Print summary: backup ID consumed, migrations applied, code
    version deployed, blessing details.
```

The "scratch directory" is local to the operator's machine. It
contains real prod data temporarily. The script removes it on
successful completion (and leaves it on failure for debugging).

---

## The "no preserved test entries on staging" contract

Any data that exists on staging before a promote-to-staging is gone
afterwards. This is non-negotiable, because:

- Selectively keeping some staging entries while replacing others is
  a merge problem, not a refresh problem.
- If staging's test entries survived, super users testing on staging
  would see a mix of real and fictional content, hard to reason
  about.
- The whole point is that staging looks like prod did at backup time.
  Test entries violate that.

If a super user's test setup is valuable, it goes into a documented
"manual staging fixture" workflow, not a side-effect of staging's
state.

This contract is mentioned prominently in
`config/www/user/env/staging.hackersbychoice.dk/README.md` so anyone
exercising staging knows the rules.

---

## GDPR note

The without-stripping-users decision means real personal data lives
on staging. Staging is hosted on the same one.com account as test
and dev, and is accessible by anyone who knows its URL (no auth
gate at the edge).

The decision to ship prod data unanonymised — together with the
conditions that make it acceptable (basic-auth at the edge, privacy
policy disclosure, retention contract) — is recorded in
[ADR-002: Prod data on staging](../decisions/ADR-002-prod-data-on-staging.md).
**This spec must not ship unless the conditions in that ADR are
met:** basic-auth gating live on staging, privacy-policy text
updated, and the operator has read and signed off on the ADR.

---

## The blessing marker

When the promotion succeeds, staging gets a file:

```
config/www/staging-blessed.yaml
```

(At Grav root, **outside `user/`**, so data-push rsyncs cannot wipe it.)

```yaml
blessed_at: 2026-04-29T13:45Z
code_commit: "abc1234"
code_version: "0.2.0"
code_build: "312"
data_version: "0.2.0"
features_yaml_sha256: "..."          # of staging's features.yaml
source_backup_id: "prod-2026-04-29T12-34Z-v0.1.0-b247.tar.gz.age"
```

`source_backup_id` records the backup the migrated snapshot was
derived from. The audit trail is then self-contained — given the
blessing, you can reconstruct what staging was set up from without
crossreferencing logs.

This file is the *only* signal the promote-to-prod spec uses to
decide whether prod is allowed to deploy. Producing it correctly is
this spec's primary downstream obligation.

The file is written **only** if every step above succeeded. A
half-finished promotion does not write the blessing — and if a
previous blessing exists, it must be removed at step 1 of the
next promotion attempt so a stale blessing can't survive a failed
re-promotion.

---

## Failure handling

| Step | What happens on failure |
|---|---|
| 1 (reachability) | Abort. Nothing changed. |
| 2 (fresh backup) | Abort. Nothing changed on staging or prod. |
| 3 (restore to scratch) | Abort. Scratch dir partially populated; safe to delete by hand. |
| 4 (read versions) | Abort. Scratch dir intact. |
| 5 (migration) | Abort. Scratch dir tainted but inspectable; staging untouched. |
| 6 (deploy code) | Abort. Staging may have new code with old data — explicitly logged; operator must redeploy or revert. |
| 7 (push/activate data) | Abort. The new `<staging>data/v<target>/` may be partially populated, but `current` is repointed only after a complete sync, so a mid-sync failure leaves the prior data version live. Operator re-runs promote-to-staging to converge. |
| 8 (clear cache) | Print warning, continue. Cache will refill naturally. |
| 9 (write blessing) | Abort. No blessing written → prod cannot promote. |
| 10 (smoke test) | Print warning, continue. Operator inspects. Blessing IS written; team decides whether to consume it. |

The pattern: anything before "deploy code" leaves staging in its
prior state. Anything after may leave staging partially updated, in
which case the operator re-runs to converge.

---

## Acceptance criteria

### Happy path

- [ ] `./deploy/promote-to-staging.sh` from a clean state takes a
      backup, runs migrations as needed, deploys code, pushes data,
      writes blessing, exits 0.
- [ ] After running, staging's live data (via `<staging>data/current
      → v<target>`) contains the same `user/accounts/` list as prod's
      at backup time.
- [ ] After running, `<staging>data/v<target>/user/data-version.yaml`
      matches the target data version from the code, and
      `<staging>data/current` points at `v<target>`.
- [ ] After running, `config/www/staging-blessed.yaml` (at Grav
      root, NOT inside `user/`) exists with all seven fields
      populated: `blessed_at`, `code_commit`, `code_version`,
      `code_build`, `data_version`, `features_yaml_sha256`,
      `source_backup_id`.
- [ ] Visiting `https://staging.hackersbychoice.dk` returns 200 on
      home, member-protected pages render correctly when logged in
      with a real member's credentials (manual smoke).

### Test entries contract

- [ ] Staging contains a fictional event before promotion. After
      promotion, the fictional event is gone and only prod-sourced
      events remain.

### --from-backup

- [ ] `./deploy/promote-to-staging.sh --from-backup
      prod-2026-04-29T12-34Z-v0.1.0-b247.tar.gz.age` skips step 2
      (no new backup taken) and uses the specified archive.
- [ ] Running with a non-existent backup ID fails at step 3 with a
      clear error.

### Migration

- [ ] Promoting when prod is at data_version 0.1.0 and code
      requires 0.2.0 applies the 0.2.0 migration; the resulting
      staging has data_version 0.2.0.
- [ ] Migration is run locally via `deploy/migrate.sh` on the scratch
      dir; the step-6 code deploy passes `--skip-data-migration` and
      `deploy.sh` does not attempt its in-deploy (remote-mode)
      migration during a promotion.
- [ ] Promoting when no migration is needed (data and code already
      agree) skips the migration step (no-op message printed).
- [ ] Promoting when a required migration is missing aborts with
      "no migration to <version> found".

### Blessing marker

- [ ] On success, the marker is written with the current commit's
      SHA, version, build, data version, and the SHA-256 of
      staging's deployed `features.yaml`.
- [ ] On any failure between steps 1–7, no blessing is written. If
      a previous blessing existed at `config/www/staging-blessed.yaml`,
      it is removed at step 1 of the next promotion attempt so a
      stale blessing can't survive a failed re-promotion.
- [ ] Reading the marker via SFTP from another machine returns
      identical content (consumed by promote-to-prod).

### Cleanup

- [ ] On success, the local scratch directory is removed.
- [ ] On failure, the local scratch directory is left in place
      with a path printed in the error.
- [ ] `./deploy/staging-stage/` is in `.gitignore` (and excluded
      from Time Machine per the backup spec's hygiene checklist).

---

## Out-of-scope future work

- **Anonymisation pass before push.** Possibly required before this
  spec ships; covered by its own spec if so.
- **Differential pushes** (only sync changed files instead of full
  rsync --delete). Optimisation; current sizes don't justify.
- **Auto-promotion on schedule.** A nightly cron that calls
  promote-to-staging without operator intervention. Build only when
  promotion has been hand-done enough times to trust the
  automation.
- **A "diff what would happen" dry-run mode.** Useful eventually;
  not required for v1.
