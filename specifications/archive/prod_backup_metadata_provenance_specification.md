# Specification — Backup metadata provenance + first-write banner

Status: Planned
Owner: thomas@appforceone.dk
Depends on: archive/prod_backup_restore_specification.md (implemented;
the bugs fixed below were introduced by that implementation, found in
post-merge review of PR #15)
Scope: Three surgical fixes to the prod-backup-restore tooling — one
spec violation (metadata fields read from the operator's laptop
instead of the live tier), one missed acceptance criterion (the
first-write reminder banner), and one testing gap (the live
restore-to-tier code path has zero exercise). Nothing else in the
backup/restore tooling changes.

---

## Background

PR #15 implemented `archive/prod_backup_restore_specification.md` via
GAN run `20260507T183206-3497`. The contract scored 15/15 (mean 8.93)
and the bats suite passes 25/25, but a post-merge review found three
gaps the contract did not ask about:

1. **Metadata fields are sourced from the operator's local repo, not
   the live tier.** `code_version`, `code_build`, and `data_version`
   are read from `$REPO_ROOT/config/www/VERSION`, `BUILD`, and
   `user/data-version.yaml` respectively, rather than from the source
   tier over SSH. The original spec mandates the latter for
   `data_version` ("reads the live tier's
   `config/www/user/data-version.yaml` over SFTP") and the same
   provenance is implied for the other two — the field meanings are
   "what the source tier was running", not "what the operator's
   laptop happened to have checked out". Downstream consumers (the
   migration runner, promote-to-staging, promote-to-prod) will trust
   this metadata; feeding them laptop-local state silently makes
   "wrong migration applied because metadata lied" a real failure
   mode.

2. **The first-write reminder banner is missing entirely.** The
   original spec's "Operator-laptop privacy hygiene" subsection says:
   "the script prints a reminder banner the first time it writes
   into one of these paths on a given laptop." Neither `backup.sh`
   nor `restore.sh` does this. The README block listing the
   `tmutil addexclusion` commands is present, the `.metadata_never_index`
   marker writing is present, but the active nudge to run the
   exclusion commands is not.

3. **The live restore-to-tier code path is untested.** The bats
   suite tests the prod safety-gate refusal (without
   `--yes-i-mean-it`) but does not exercise the path the gate
   protects: download → decrypt → unpack → `rsync --delete` into a
   tier path → `bin/grav clearcache`. That code lives behind
   `RESTORE_TO_TIER_ENABLED=1` and runs only on a real operator
   invocation. Given the project's regression history (April 2026
   accounts wipe was exactly this kind of destructive operation
   going wrong), "is the disaster-recovery path syntactically and
   logically correct?" should not be answered for the first time
   during an actual disaster.

---

## What changes

### Live-tier metadata

`deploy/backup.sh` fetches metadata fields from the source tier as
part of the existing source-pull step:

| Field          | Source on the live tier                                    |
|----------------|------------------------------------------------------------|
| `code_version` | `config/www/VERSION` — first line, trimmed                  |
| `code_build`   | `config/www/BUILD` — first line, trimmed                    |
| `data_version` | `config/www/user/data-version.yaml` — `version:` field value |

In SSH mode, the script reads each file with one of:
- `ssh ${user}@${host} -p ${port} cat <quoted-remote-path>` (small files, ≤1KiB), OR
- bundling the three reads into one `ssh ... 'cat A; echo ---; cat B; echo ---; cat C'` to save round-trips — implementer's choice.

In `BACKUP_FIXTURE_DIR` mode, the script reads from
`$BACKUP_FIXTURE_DIR/config/www/VERSION` etc. — the same paths
relative to the fixture root. Tests construct fixtures with these
files explicitly.

**Fallback rules — fail loud, not quiet.** If a file is missing on
the live tier:

- `code_version` missing → `die "source tier missing config/www/VERSION"` (exit code 3, the "archive build" code). This is unrecoverable; the backup metadata would be useless without it.
- `code_build` missing → same: hard fail.
- `data_version` missing → `warn "source tier has no data-version.yaml — defaulting to 0.0.0"` (stderr) and write `data_version: "0.0.0"` to meta. The data-versioning spec hasn't shipped yet, so the file legitimately won't exist on first runs; defaulting is the only sensible behaviour. **The fallback is `"0.0.0"`, not `code_version` and not whatever happened to be in the operator's local repo.** Silently inheriting laptop state is the bug we're fixing.

The local-repo files (`$REPO_ROOT/config/www/VERSION` etc.) are no
longer consulted by `backup.sh` for any purpose. The
`BACKUP_FAKE_CODE_VERSION` / `BACKUP_FAKE_CODE_BUILD` /
`BACKUP_FAKE_DATA_VERSION` env-var overrides are kept for tests but
must come from the test fixture's metadata, not from a chunked
override path that obscures the real fetch.

### First-write reminder banner

Both `backup.sh` and `restore.sh` print a one-time reminder banner to
stderr when they first write into one of the three privacy-sensitive
paths on a given machine:

- `./backups/` (backup script with `--keep-local`, or any failed-upload fallback)
- `./deploy/staging-stage/` (restore-to-tier scratch staging)
- `./deploy/prod-stage/` (restore-to-tier scratch staging)

The banner names these three paths and lists the `tmutil addexclusion`
commands operators must run. It also reminds the operator not to keep
the checkout inside a Dropbox/iCloud/Google-Drive synced root.

"First time on a given machine" is tracked by a sentinel file at
`${XDG_CONFIG_HOME:-$HOME/.config}/byvaerksted/backup-banner-shown`.
Once the sentinel exists, the banner is suppressed. Operators who
want to re-see it can `rm` the sentinel.

The banner goes to stderr only — stdout remains the parseable
upload-URL/path channel for cron friendliness.

### Restore-to-tier integration test

A new bats scenario exercises the live restore-to-tier code path
end-to-end against a worktree-scoped scratch tier directory. To make
this possible without an SSH daemon, `restore.sh` grows a "local
tier" mode that activates only when:

- `RESTORE_TO_TIER_ENABLED=1` is set (the existing safety gate), AND
- `RESTORE_LOCAL_TIER_DIR` is set to an absolute path the operator
  trusts.

In this mode `restore.sh` performs the wipe-and-replace against
`$RESTORE_LOCAL_TIER_DIR/<allow-listed-path>/` instead of via
`rsync -e ssh`, and runs `bin/grav clearcache` from
`$RESTORE_LOCAL_TIER_DIR` if `bin/grav` exists (otherwise logs
"clearcache skipped — no Grav binary"). This is purely additive — the
SSH path is unchanged for real operator runs.

The test scenario:

1. Builds a fixture tree under the bats temp dir resembling a tier:
   `user/accounts/`, `user/data/`, `user/pages/`, `user/uploads/`,
   plus `config/www/VERSION` / `BUILD` / `user/data-version.yaml`.
2. Runs `backup.sh dev` with `BACKUP_FIXTURE_DIR=$fixture_a` and
   `BACKUP_LOCAL_STORE_DIR=$store` to produce an archive.
3. Builds a second tree (`$tier_b`) from the same fixture, then
   mutates it: deletes one file, modifies one, adds one untracked.
4. Runs `restore.sh dev --from latest --yes-i-mean-it` with
   `RESTORE_TO_TIER_ENABLED=1` and `RESTORE_LOCAL_TIER_DIR=$tier_b`.
5. Asserts:
   - The deleted file is back.
   - The modified file matches the fixture byte-for-byte.
   - The added untracked file is gone (the `--delete` semantic).
   - `./logs/restore-dev-*.log` exists and contains
     `restore op begin` + `restore complete` lines.
   - The first-write banner sentinel was created (covers issue 2 too).

The test runs under `make test-backup-restore` and is part of the
default suite — it must pass on a fresh checkout with no extra
operator setup beyond `bats-core` and `age`.

---

## Acceptance criteria

### Metadata provenance

- [ ] `backup-meta.yaml` `code_version` equals the source tier's
      `config/www/VERSION` (first line, trimmed). Verifiable by
      running `backup.sh` against a fixture whose
      `config/www/VERSION` differs from the orchestrating repo's,
      and asserting the metadata field matches the fixture's value
      exactly.
- [ ] Same provenance for `code_build`
      (`<source>/config/www/BUILD`).
- [ ] Same provenance for `data_version`, sourced from the
      `version:` field of `<source>/config/www/user/data-version.yaml`.
- [ ] When the source tier has no `data-version.yaml`, the script
      logs a stderr warning naming the missing file and writes
      `data_version: "0.0.0"`. It does NOT fall back to
      `code_version`, the operator's local repo, or any other
      surrogate.
- [ ] When the source tier has no `config/www/VERSION` or `BUILD`,
      the script exits non-zero with a specific error message
      naming the missing file.
- [ ] `backup.sh` no longer reads `$REPO_ROOT/config/www/VERSION`,
      `$REPO_ROOT/config/www/BUILD`, or
      `$REPO_ROOT/config/www/user/data-version.yaml`. (Verifiable by
      grep — the only consumers of those paths in the codebase
      should be unrelated to backup tooling.)

### First-write banner

- [ ] When the sentinel
      `${XDG_CONFIG_HOME:-$HOME/.config}/byvaerksted/backup-banner-shown`
      does not exist, the first run of `backup.sh --keep-local`
      prints a banner to stderr listing the three `tmutil addexclusion`
      commands and the cloud-sync warning. The sentinel is created
      after the banner is shown.
- [ ] Same banner-and-sentinel behaviour on the first
      `restore.sh --to <dir>` invocation.
- [ ] On the second invocation with the sentinel present, the banner
      is not printed.
- [ ] Banner output goes to stderr only; stdout still carries the
      parseable URL/path output. (Verifiable by piping stdout to a
      file and inspecting that the banner is not in it.)
- [ ] A bats test exercises both the first-time-shown and
      sentinel-suppressed branches, using a `XDG_CONFIG_HOME` set to
      a bats temp dir so the developer's real `~/.config` is never
      touched.

### Restore-to-tier coverage

- [ ] `restore.sh` honours `RESTORE_LOCAL_TIER_DIR=<abs-path>` (only
      when also `RESTORE_TO_TIER_ENABLED=1`) and performs the
      wipe-and-replace + cache-clear against that path instead of
      via SSH.
- [ ] A new bats test exercises the full local-tier restore flow:
      backup against fixture A, mutate fixture B, restore over
      fixture B, assert byte-identity with fixture A on every
      allow-listed path, assert the deleted file is back, assert the
      added file is gone, assert the restore log was written.
- [ ] The test runs under `make test-backup-restore` and passes on a
      fresh checkout.

### No regressions

- [ ] All 25 existing bats scenarios in
      `tests/deploy/backup-restore.bats` still pass.
- [ ] `tests/deploy/excludes-preserve-live-state.sh` (10 assertions)
      still passes.
- [ ] No pre-existing test is newly skipped, removed, or `.skip`'d.
- [ ] `make test` (the project's full-suite invocation) passes after
      the changes.

---

## Out of scope

Three other gaps were identified in the post-merge review and are
deliberately deferred:

- **Tag-retention defence in depth.** Treat the sidecar
  `<archive>.tag` as the authoritative tag marker; checking embedded
  `backup-meta.yaml` requires the operator's private key, which the
  retention sweep does not have. A future spec can add an
  unencrypted parallel manifest if the sidecar approach proves
  brittle in practice.
- **Source-host sanity check on tier restore.** Worth doing, but
  belongs in the promote-to-staging / promote-to-prod specs that
  define cross-tier semantics.
- **ADR for `RESTORE_TO_TIER_ENABLED`.** Reviewer call on PR #15;
  not implementation work.

---

## GAN sandbox compatibility

Same constraints as the original spec. The new restore-to-tier
integration test is scoped to a worktree-local destination
(`RESTORE_LOCAL_TIER_DIR` set to a bats temp dir under
`$BATS_TEST_TMPDIR`), which is inside `WORKTREE_PATH` and therefore
not blocked by the confinement hook. The SSH path (real operator
runs) is unchanged and remains untestable inside GAN, which is fine —
that path is operator-only by the original spec's design.
