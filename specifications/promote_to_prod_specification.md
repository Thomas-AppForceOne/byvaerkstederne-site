# Specification — Promote to prod (gated, rollback-insured)

Status: Planned
Owner: thomas@appforceone.dk
Depends on:
- [prod_backup_restore_specification.md](prod_backup_restore_specification.md)
- [data_versioning_and_migrations_specification.md](data_versioning_and_migrations_specification.md)
- [promote_to_staging_specification.md](promote_to_staging_specification.md)
Scope: A single command that promotes the staging-blessed combination
of code + data shape + flags to production, with a hard gate
ensuring nothing reaches prod that hasn't first been blessed on
staging. The fourth and final step of the data-lifecycle series.

---

## Motivation

The earlier specs in this series establish:

- We can produce and restore prod backups (spec 5).
- We can stamp data with a schema version and run migrations (spec 6).
- We can promote a backup-derived state to staging, with code +
  flags + data all aligned, recording a "blessing" marker on success
  (spec 7).

What's still missing: the actual promote-to-prod step. Today,
deploying to prod is `./deploy/deploy.sh prod` — code only, no
backup, no migration awareness, no gate. With the earlier specs in
place we can do better.

The constraint Thomas stated explicitly:

> never allow pushing a version to prod unless it has been deployed
> to staging with migrated prod data

This spec defines that gate and the orchestrated promotion that
satisfies it.

---

## Non-goals

- **Continuous deployment.** Promotions are deliberate manual acts.
  No automatic prod deploys triggered by merging to main / tagging
  a release / a CI pipeline.
- **Multi-region or blue/green prod.** One prod, one tier.
- **Online migrations.** Migrations are applied to a snapshot, the
  snapshot is then pushed to prod (during a brief window where
  prod is briefly unavailable for writes). No live database
  migration.
- **Migration rollback.** Rollback is by restore-from-backup, not by
  reversing a migration. (Per spec 6.)
- **Approvals workflow.** No "two humans must click approve" UI.
  The discipline lives in the staging-blessing gate; whoever has
  the prod credentials can run the promote command.

---

## The blessing gate

Before any prod-altering action, the promote command checks:

1. Fetch `config/www/user/staging-blessed.yaml` from staging via
   SFTP. (No live HTTP read — bypassing Varnish caches.)
2. Verify the file is present and parseable. If not — refuse.
3. Verify the `code_commit` field matches the commit currently
   checked out locally. If not — refuse with a message naming both
   commits ("staging is blessed for abc1234, you're trying to
   promote def5678").
4. Verify the `data_version` field matches the target data version
   from the local repo (`config/www/user/data-version.yaml`). If
   not — refuse.
5. Verify the `features_yaml_sha256` field matches the SHA-256 of
   the local `config/www/user/env/staging.hackersbychoice.dk/config/features.yaml`.
   If not — refuse.

Only if all checks pass does the command proceed. The error
messages must be specific enough that the operator knows exactly
which check failed.

The gate is enforced by the script. Bypassing it requires editing
the script itself, which is a reviewable change.

### The escape hatch

```
./deploy/promote-to-prod.sh --bypass-staging-gate \
    --reason "rolling forward a hot-fix; staging is broken on a
              flaky test that this fix addresses"
```

The escape hatch:

- Requires a non-empty `--reason` of at least 50 characters.
- Writes the reason + timestamp + operator (from `whoami`) to a
  log file `config/www/user/prod-bypass-log.yaml` on prod **after**
  the promotion completes successfully.
- Prints a banner before proceeding: "BYPASSING STAGING GATE —
  proceed (y/N)?"
- Is interactive; cannot be `--bypass-staging-gate --yes` scripted.

This is the "prod broke at 3am, staging is also broken, you need to
ship a fix now" path. It exists because reality demands it. Use is
expected to be rare; the audit log makes it visible.

---

## The command

```
./deploy/promote-to-prod.sh
./deploy/promote-to-prod.sh --bypass-staging-gate --reason "..."
```

No `--from-backup` option here. The promotion is always against
prod's current data, with migrations applied. Promoting to a
historical backup is "restore to prod", a different operation
covered by spec 5.

---

## Steps in order

```
 1. Check the blessing gate (see above). Refuse if any check fails
    and --bypass-staging-gate is not set.
 2. Take a fresh "before-promotion" backup of prod, tagged
    `pre-promotion-v<X>-build<N>`. This is the rollback insurance.
    The tag prevents retention sweeps from deleting it.
 3. Restore the just-taken backup into a local scratch directory
    (./deploy/prod-stage/).
 4. Read the data_version from the scratch metadata.
 5. Read the target data_version from the local code's
    data-version.yaml. If they differ, run ./bin/migrate
    ./deploy/prod-stage/ to bring the snapshot forward.
 6. Sync the staging features.yaml to prod. The script copies
    config/www/user/env/staging.hackersbychoice.dk/config/features.yaml
    over config/www/user/env/www.byvaerkstederne.dk/config/features.yaml,
    commits the change with a generated message ("chore: sync
    staging flags to prod for v<X>"), and refuses to continue if the
    working tree has other uncommitted changes (clean checkpoint).
    The committed change is part of this promotion's audit trail —
    a human can later see "for v0.2.0, the prod flags became X".
 7. Deploy code to prod via the existing ./deploy/deploy.sh prod
    path. (Which already gates behind DEPLOY_PROD_* credentials.)
    This includes the new prod features.yaml from step 6.
 8. Push the migrated snapshot's state paths into prod, same
    rsync-with-delete pattern as the staging promote.
 9. Clear prod caches (existing deploy.sh post-step).
10. Smoke-test (curl key URLs, expect 200). On failure, print the
    failure prominently — the rollback backup from step 2 is the
    operator's path forward.
11. Print summary: pre-promotion backup ID, migrations applied,
    code version deployed, flag changes (diff staging vs prior
    prod), URL to the prod homepage.
```

The "scratch directory" is the same idea as in the staging spec:
a local working area that holds real prod data temporarily.
Removed on success, kept for inspection on failure.

---

## Rollback

A separate command:

```
./deploy/rollback-prod.sh --to-backup <id> [--code-to <commit>]
```

Behaviour:

1. Refuse without `--yes-i-mean-it`.
2. Take a fresh "pre-rollback" backup, tagged with the timestamp.
   (Yes, even rollbacks get a backup-before. If the rollback itself
   is wrong, you have a snapshot of the broken state to study.)
3. If `--code-to` is given, deploy that commit to prod first;
   otherwise leave the current code in place.
4. Restore the specified backup to prod via the existing restore
   spec's "restore to tier" mode.
5. Smoke-test.

The "before-promotion" backups produced by step 2 of the promote
command are the natural input here.

---

## The flag-file copy mechanic

Step 6 of the promote command. There are two design choices to
walk through:

### Option A — copy at promote time (this spec's choice)

When promote-to-prod runs, it copies the staging flag file over the
prod flag file as part of the run. The copy is committed locally
(triggering a code change), and that commit is what the prod deploy
ships. Audit trail: a single `chore: sync staging flags to prod` per
promotion in git history.

Pro: simple, atomic with the promotion, hard to forget.
Con: the prod features.yaml in main only gets updated at promotion
time. Between promotions, the file lags staging.

### Option B — auto-PR when staging flips

When someone flips a flag on staging and merges, an automation
opens a follow-up PR that flips the same flag on prod. The PR sits
open until the next prod promotion merges it.

Pro: the lag is visible; reviewers can comment on prod changes
ahead of promotion.
Con: more moving parts, requires the automation, can pile up if
staging flips multiple flags before promotion.

This spec adopts **Option A** — simpler, fewer moving parts. The
audit trail lives in `git log -- config/www/user/env/www.byvaerkstederne.dk/config/features.yaml`,
which is searchable and adequate for this scale.

If the team later wants more visibility, Option B becomes a
separate spec.

---

## Hot-fix scenario walkthrough

Real-world test of the design: prod has a critical bug that
slipped through. We need to ship a fix in 10 minutes. Two
sub-scenarios:

### Scenario A — staging is healthy

1. Branch off develop, write the fix, open a PR, merge to develop.
2. `./deploy/promote-to-staging.sh` — staging runs the fix, blesses.
3. `./deploy/promote-to-prod.sh` — gate passes, promotion proceeds.

Total: ~5 minutes for a small fix, plus deploy time.

### Scenario B — staging is broken on something unrelated

1. Same branch + PR + merge.
2. `./deploy/promote-to-staging.sh` — fails at smoke test or
   migration, doesn't bless.
3. `./deploy/promote-to-prod.sh` — refuses (no blessing for this
   commit).
4. Operator decides this is justified bypass territory:
   `./deploy/promote-to-prod.sh --bypass-staging-gate --reason "..."`
5. The bypass is logged on prod for retrospective review.

The escape hatch is explicit, audited, and survives review. It is
not a "do whatever you want" mode.

---

## Acceptance criteria

### Gate enforcement

- [ ] `./deploy/promote-to-prod.sh` against a commit not
      blessed on staging refuses with "staging is blessed for
      <X>, you're trying to promote <Y>; promote staging first".
- [ ] Same command against a commit where staging's flag-hash
      differs from local refuses with "features.yaml SHA mismatch:
      staging has <X>, local has <Y>".
- [ ] Same command against a commit where data_version differs
      refuses with "data version mismatch: staging blessed for
      <X>, local code requires <Y>".
- [ ] All three messages name the specific mismatch and exit
      non-zero.

### Pre-promotion backup

- [ ] On any successful promote, a backup tagged
      `pre-promotion-v<X>-build<N>` exists in backup storage.
- [ ] The tagged backup is excluded from retention sweeps.

### Migration

- [ ] Promoting when prod is at data_version 0.1.0 and code
      requires 0.2.0 applies the 0.2.0 migration to the snapshot
      before push.
- [ ] If a required migration is missing, the promotion aborts
      before pushing anything to prod.

### Flag sync

- [ ] After promotion, `config/www/user/env/www.byvaerkstederne.dk/config/features.yaml`
      on disk and in git is byte-identical (modulo header comment
      lines) to the staging file at promotion time.
- [ ] The git history shows a `chore: sync staging flags to prod`
      commit dated to the promotion.

### Bypass

- [ ] `--bypass-staging-gate` without `--reason` refuses.
- [ ] `--bypass-staging-gate --reason "x"` (under 50 chars)
      refuses.
- [ ] Successful bypass appends an entry to
      `config/www/user/prod-bypass-log.yaml` on prod containing
      timestamp, reason, operator (from `whoami`), commit being
      bypassed.

### Rollback

- [ ] `./deploy/rollback-prod.sh --to-backup <id>
      --yes-i-mean-it` restores the named backup to prod.
- [ ] A pre-rollback backup is taken and tagged before the
      rollback applies.
- [ ] Without `--yes-i-mean-it`, refuses.

### Failure handling

- [ ] If migration fails (step 5), prod is untouched, scratch dir
      remains for inspection, no rollback needed.
- [ ] If push to prod fails mid-rsync (step 8), prod may be in an
      inconsistent state; the rollback backup from step 2 is
      named in the error message so the operator can recover.

### Audit

- [ ] Every promote-to-prod run produces three artefacts: the
      pre-promotion backup (tagged), the flag-sync commit (in
      git), and a final summary printed to stdout. Together these
      are the audit trail.
- [ ] Bypassed runs additionally produce an entry in
      `prod-bypass-log.yaml`.

---

## Out-of-scope future work

- **Multi-stage promotion** (promote to canary, then 5%, then full).
  We're a small site; canary doesn't earn its complexity yet.
- **Approval workflow / two-person rule.** Currently the rule is
  "whoever has prod credentials can promote". If team size grows,
  add an approval step.
- **Auto-rollback on smoke-test failure.** Today: smoke test fails,
  print message, leave for human. Auto-rollback adds complexity
  and a risk of flapping. Defer until manual rollback proves
  insufficient.
- **A "promote to prod" web UI.** Convenient eventually, but the
  CLI is the source of truth and stays that way for v1.
- **Synchronising prod data BACK to staging after a hot-fix.**
  Could be useful: if prod has gotten out of sync because of a
  bypass, the next promote-to-staging refreshes everything anyway.
  No special handling needed.
