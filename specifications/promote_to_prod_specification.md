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

## The branch gate

Before anything else, the promote command verifies the local
checkout is on a release or hot-fix branch. This is a direct
consequence of the project rule in
[CLAUDE.md](../CLAUDE.md#git-workflow--branching-and-prs):
**`develop` and `main` are sacred** — direct commits to either are
forbidden, including the flag-sync commit step 6 will produce.

Concretely, step 0 of the command is:

1. `BRANCH=$(git branch --show-current)`.
2. If `$BRANCH` matches `^(develop|main|master)$`, refuse with:
   "promote-to-prod must run from a release/* or hotfix/* branch
   (current: $BRANCH). Branch off develop with
   `git checkout -b release/v<X> develop` and re-run."
3. If `$BRANCH` does not match `^(release/.+|hotfix/.+)$`, print a
   warning but proceed (allows ad-hoc branch names during the
   spec's bedding-in period; can be tightened later).

This rule + the release/hotfix branch convention is the answer to
"how does the flag-sync commit not violate the branching rule".
Rationale and the alternatives that were rejected are recorded in
[ADR-003: Release-branch model for prod promotion](../decisions/ADR-003-release-branch-promotion.md).

---

## The blessing gate

Before any prod-altering action, the promote command checks:

1. Fetch `config/www/staging-blessed.yaml` from staging via
   SFTP. (No live HTTP read — bypassing Varnish caches. Note: the
   marker is at the Grav root, NOT inside `user/`, so data-push
   rsyncs cannot wipe it.)
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
6. **Prod-flag drift check.** Fetch
   `config/www/user/env/www.byvaerkstederne.dk/config/features.yaml`
   from prod via SFTP, compute its SHA-256, and compare it to the
   SHA-256 of the same file currently committed in the local repo.
   If they differ, refuse with: "prod features.yaml has drifted
   from git: prod=<sha-prod>, git=<sha-git>. Reconcile before
   continuing — either commit the drift to git, or accept that
   it'll be wiped by the upcoming flag sync. Re-run after
   reconciling."
   This catches hand-edits made on prod via SFTP (or via a previous
   bypass that took a shortcut). Without this check, the flag sync
   in step 6 of the main flow would silently overwrite the manual
   change.

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

- Requires a non-empty `--reason` of at least 50 and at most 500
  characters. The upper bound prevents a paste-the-whole-stack-trace
  accident; the lower bound forces the operator to articulate the
  rationale in prose.
- Appends an entry (reason + timestamp + operator from `whoami` +
  bypassed commit) to `config/www/prod-bypass-log.yaml` on prod
  (Grav root, **NOT inside `user/`**). Living outside `user/`
  guarantees the file survives the `rsync --delete` of state paths
  in step 8 of the main flow, regardless of how that path list
  evolves. The log is append-only — each entry is a new YAML doc
  separated by `---`, so step 8 can never truncate prior entries.
- Prints a banner before proceeding: "BYPASSING STAGING GATE —
  proceed (y/N)?"
- Is interactive; cannot be `--bypass-staging-gate --yes` scripted.

This is the "prod broke at 3am, staging is also broken, you need to
ship a fix now" path. It exists because reality demands it. Use is
expected to be rare; the audit log makes it visible.

The interactive `(y/N)` prompt is non-negotiable for v1: any future
"auto-rollback bot" or "auto-hotfix-promote" automation cannot use
this path and must instead extend the spec with a separate,
reviewable scriptable code-path. Forcing a human pause is the point.

---

## The command

```
./deploy/promote-to-prod.sh [--reason "..."]
./deploy/promote-to-prod.sh --bypass-staging-gate --reason "..."
```

`--reason` is optional on a normal promotion (no upper bound on
length other than the bypass cap; appended verbatim to the
audit summary so post-hoc reviewers can read why this promotion
happened today). It is **required** when `--bypass-staging-gate` is
set, with the 50–500-char constraint described above.

No `--from-backup` option here. The promotion is always against
prod's current data, with migrations applied. Promoting to a
historical backup is "restore to prod", a different operation
covered by the backup/restore spec.

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
    commits the change on the **current release/* or hotfix/* branch**
    (the branch gate has already verified we're on one) with a
    generated message ("chore: sync staging flags to prod for v<X>"),
    and refuses to continue if the working tree has other uncommitted
    changes (clean checkpoint). The committed change is part of this
    promotion's audit trail — a human can later see "for v0.2.0, the
    prod flags became X". Merging the release branch back to develop
    after deploy returns the commit to the integration line.
 7. Deploy code to prod via the existing ./deploy/deploy.sh prod
    path. (Which already gates behind DEPLOY_PROD_* credentials.)
    This includes the new prod features.yaml from step 6.
 8. Push the migrated snapshot's state paths into prod, same
    rsync-with-delete pattern as the staging promote.
 9. Clear prod caches (existing deploy.sh post-step).
10. Smoke-test prod against the same URL list as the staging spec
    (homepage, /login, /medlemmer, /begivenheder, /vaerksteder,
    plus a fetch of the prod blessing — there isn't one yet, so a
    fetch of `version.json` instead — to confirm the new build is
    live). On failure, print the failure prominently AND emit the
    exact rollback invocation the operator should run, verbatim:

    ```
    SMOKE TEST FAILED on https://www.byvaerkstederne.dk/<path>
    Expected <code-A>, got <code-B>.

    To roll back to the pre-promotion snapshot, run:
        ./deploy/rollback-prod.sh \
            --to-backup pre-promotion-v<X>-build<N> \
            --yes-i-mean-it
    ```

    No auto-rollback — the operator decides. Reducing panic at 3am
    is the point of emitting the command verbatim.
11. Print summary AND append it to `deploy/promotion-log.jsonl`
    (gitignored, kept on the operator's machine). The summary
    contains: pre-promotion backup ID, migrations applied, code
    version deployed, flag changes (diff staging vs prior prod),
    URL to the prod homepage, the operator's `--reason` (or empty),
    and the timestamp. Appending to a file rather than relying on
    terminal scrollback means the audit trail survives a closed
    window or a wedged tmux pane.
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

1. Branch off develop (`feature/fix-foo`), write the fix, open a
   PR, merge to develop.
2. `git checkout -b release/v0.2.1 develop` (or
   `hotfix/auth-403-fix develop`) — promote-to-prod requires a
   release/* or hotfix/* branch per the branch gate.
3. `./deploy/promote-to-staging.sh` — staging runs the fix, blesses.
4. `./deploy/promote-to-prod.sh` — branch gate passes, blessing
   gate passes, prod-flag drift check passes, promotion proceeds.
   The flag-sync commit lands on the release branch (allowed by
   project rules).
5. After deploy, open a PR from `release/v0.2.1` to `develop`
   (and from develop to main per the existing release flow) so
   the flag-sync commit returns to develop.

Total: ~5 minutes for a small fix, plus deploy time.

### Scenario B — staging is broken on something unrelated

1. Same `feature/fix-foo` branch + PR + merge to develop.
2. `git checkout -b hotfix/prod-down-fix develop`.
3. `./deploy/promote-to-staging.sh` — fails at smoke test or
   migration, doesn't bless.
4. `./deploy/promote-to-prod.sh` — branch gate passes, blessing
   gate refuses (no blessing for this commit).
5. Operator decides this is justified bypass territory:
   `./deploy/promote-to-prod.sh --bypass-staging-gate --reason "prod 500ing on /login since 02:13Z, root cause is the auth bug fixed in this commit; staging blocked on unrelated flaky migration test we'll fix next week"`
6. The bypass is logged on prod for retrospective review.
7. Same merge-back-to-develop step as Scenario A.

The escape hatch is explicit, audited, and survives review. It is
not a "do whatever you want" mode.

---

## Acceptance criteria

### Branch gate

- [ ] Running on `develop`, `main`, or `master` refuses with the
      release-branch message and exits non-zero.
- [ ] Running on `release/v0.2.0` proceeds past the branch check.
- [ ] Running on `hotfix/auth-403-fix` proceeds past the branch
      check.
- [ ] Running on `feature/foo` prints a warning but proceeds.

### Blessing gate enforcement

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

### Prod-flag drift detection

- [ ] If prod's live `features.yaml` differs from the git copy,
      the gate refuses with "prod features.yaml has drifted from
      git" and prints both SHAs.
- [ ] After the operator commits the drift to git (or accepts that
      it'll be wiped), re-running succeeds.

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
- [ ] `--bypass-staging-gate --reason "<501-char string>"` refuses
      with an "exceeds 500 characters" message.
- [ ] Successful bypass appends an entry to
      `config/www/prod-bypass-log.yaml` on prod (Grav root, NOT
      inside `user/`) containing timestamp, reason, operator (from
      `whoami`), commit being bypassed.
- [ ] After a subsequent normal promote, the bypass log entries
      are still present (the file lives outside any rsync'd state
      path, so it survives `rsync --delete`).

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
      named in the error message AND the exact
      `./deploy/rollback-prod.sh --to-backup <id> --yes-i-mean-it`
      command is printed verbatim.
- [ ] If smoke-test (step 10) fails, the same verbatim rollback
      command is printed.

### Audit

- [ ] Every promote-to-prod run produces four artefacts: the
      pre-promotion backup (tagged), the flag-sync commit (in
      git on the release/* or hotfix/* branch), a final summary
      printed to stdout, and an appended entry in
      `deploy/promotion-log.jsonl` on the operator's machine.
      Together these are the audit trail.
- [ ] `deploy/promotion-log.jsonl` is in `.gitignore` (it's
      operator-local and may carry sensitive context in
      `--reason`).
- [ ] If `--reason "..."` is passed on a normal (non-bypass)
      promotion, the reason text appears in the printed summary
      and in the appended journal entry.
- [ ] Bypassed runs additionally produce an entry in
      `config/www/prod-bypass-log.yaml` on prod.

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
