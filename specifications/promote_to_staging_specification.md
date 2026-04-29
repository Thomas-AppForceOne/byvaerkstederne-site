# Specification — Promote to staging (data + code refresh)

Status: Planned
Owner: thomas@appforceone.dk
Depends on:
- [prod_backup_restore_specification.md](prod_backup_restore_specification.md)
- [data_versioning_and_migrations_specification.md](data_versioning_and_migrations_specification.md)
Scope: A single command that refreshes staging with the current code
*and* a migration-applied snapshot of prod data, so staging genuinely
mirrors what prod is about to become. The third step of the
data-lifecycle series.

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
  access. (See "GDPR note" below.) A future spec may add
  anonymisation; this one doesn't.
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

The command is non-interactive (cron-friendly, scriptable). It
prints progress per step and exits non-zero on any failure.

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
5. If they differ, run ./bin/migrate ./deploy/staging-stage/
   to migrate the snapshot forward. If migration fails, abort —
   staging is untouched; the failed scratch dir is left for
   inspection.
6. Run ./deploy/deploy.sh staging — the existing code-only deploy.
7. Push the migrated snapshot's state paths into staging:
     - rsync -a --delete the scratch dir's user/accounts/ into
       staging's user/accounts/, similarly for user/data/, user/pages/,
       user/uploads/, and the data-version.yaml.
8. Clear staging's caches (existing deploy.sh post-step).
9. Write a "blessing" marker on staging:
     config/www/user/staging-blessed.yaml
   containing:
     blessed_at, code_commit, code_version, code_build,
     data_version, features_yaml_sha256.
   This file is what the promote-to-prod spec uses to gate prod
   deploys. Its production is a contract this spec must honour.
10. Smoke test (curl key URLs, expect 200/expected status). On
    failure, print the failure but don't auto-rollback — leave the
    operator to inspect.
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

Before this spec ships, the team must:

- Confirm that staging access is restricted enough for our
  data-protection commitments. If not, anonymisation becomes a
  hard prerequisite and a separate spec.
- Document in our privacy policy (or its internal counterpart) that
  member data is replicated to staging for testing purposes.
- Decide retention: when staging is promoted-to next time, the old
  data is overwritten. Backups containing prod data are retained
  per the backup spec's policy. The data on staging itself is
  retained until the next promotion.

This is a decision flagged here, not solved here. If the answer is
"we need anonymisation", a separate spec is added before this one
ships.

---

## The blessing marker

When the promotion succeeds, staging gets a file:

```
config/www/user/staging-blessed.yaml
```

```yaml
blessed_at: 2026-04-29T13:45Z
code_commit: "abc1234"
code_version: "0.2.0"
code_build: "312"
data_version: "0.2.0"
features_yaml_sha256: "..."   # of staging's features.yaml
```

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
| 7 (push data) | Abort. Staging may have partial new data — operator must re-run promote-to-staging once the underlying issue is fixed. |
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
- [ ] After running, staging's `user/accounts/` contains the same
      account list as prod's at backup time.
- [ ] After running, staging's `data-version.yaml` matches the
      target data version from the code.
- [ ] After running, `config/www/user/staging-blessed.yaml` exists
      with all six fields populated.
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
- [ ] Promoting when no migration is needed (data and code already
      agree) skips the migration step (no-op message printed).
- [ ] Promoting when a required migration is missing aborts with
      "no migration to <version> found".

### Blessing marker

- [ ] On success, the marker is written with the current commit's
      SHA, version, build, data version, and the SHA-256 of
      staging's deployed `features.yaml`.
- [ ] On any failure between steps 1–7, no blessing is written. If
      a previous blessing existed, it is removed at step 1.
- [ ] Reading the marker via SFTP from another machine returns
      identical content (consumed by promote-to-prod).

### Cleanup

- [ ] On success, the local scratch directory is removed.
- [ ] On failure, the local scratch directory is left in place
      with a path printed in the error.

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
