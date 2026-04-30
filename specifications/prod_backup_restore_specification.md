# Specification — Prod backup and restore tooling

Status: Planned
Owner: thomas@appforceone.dk
Depends on: nothing
Scope: Produce, store, and restore complete snapshots of production
state. The foundation of the data-lifecycle series — every later spec
in the series consumes backups, none of them produces them.

---

## Relationship to the existing `deploy/backup.sh`

The repo already ships a `deploy/backup.sh` that does a partial job:
it rsyncs `accounts/`, `data/`, `pages/`, `config/`, and the theme
images, keeps the last 30 backups under `./backups/` on the operator
laptop, and is unencrypted. This spec **replaces** that script —
fold the additional state paths in (`user/uploads/` is the notable
omission), add encryption, add metadata, and move retention off the
operator's laptop into managed storage. The existing local-retention
behaviour is governed by this spec's "Local copies on the operator's
laptop" subsection below.

Implementer should treat the work as "rewrite `deploy/backup.sh`
in place against this spec", not "write a new script alongside the
old one". One backup tool, one entry point.

---

## Motivation

There is no production-grade tooling today for backing up the site.
The existing `deploy/backup.sh` handles code-shaped state (page
markdown, theme config) but misses uploads, ships unencrypted, and
keeps everything on the operator's laptop. A disk failure, a botched
manual edit, or a faulty migration would take real members and real
content with it.

The data-lifecycle series of specs (this one + the migration runner
+ promote-to-staging + promote-to-prod) all assume that "fetch a
backup" is a thing you can do. Building that primitive is step one.
Without it, we can't refresh staging with prod-shaped data, can't run
migrations against a known starting point, and can't take a
rollback-insurance snapshot before promoting changes to prod.

Even on its own — without any of the later specs — backups are worth
having. Daily snapshots of prod, retained for a few weeks, mean
"undo this thing that happened on Tuesday" is a real option.

---

## Non-goals

- **Restoring to a different schema version.** This spec produces
  and consumes backups at whatever schema version is current. The
  schema version + migration runner is a separate spec.
- **Cross-tier orchestration.** Promoting a backup from prod to
  staging, with migration applied, is a separate spec. This one only
  builds backup/restore as primitives.
- **Anonymising personal data.** Member email addresses and
  bcrypt-hashed passwords go into backups as-is. Whether that data
  travels to staging is a decision the promote-to-staging spec
  makes; this spec doesn't filter.
- **Per-record backups.** Backups are whole-site snapshots. There is
  no "back up just member 47" or "back up just bug reports". If you
  need a partial restore, restore everything to a scratch location
  and copy out by hand.
- **Database backups.** Grav stores data in YAML files on disk; there
  is no relational database. If we ever introduce one, this spec is
  amended.

---

## What's in a backup

Conceptually, a backup is a tar archive of everything Grav considers
state. Concretely:

| Path                    | Why                                              |
|-------------------------|--------------------------------------------------|
| `user/accounts/`        | Member accounts (bcrypt-hashed passwords + metadata) |
| `user/data/`            | Flex-objects: events, bug reports, roadmap items, team members, etc. |
| `user/pages/`           | Page content — most is in git, but admin-UI edits land here too |
| `user/uploads/`         | Uploaded files (member avatars, bug-report screenshots) |
| Any other directory under `user/` that holds runtime-mutable state | Caught by an allow-list, not a deny-list |

What is **not** in a backup:

- `cache/` — regenerated on demand
- `logs/` — historical, not recoverable state
- `system/` — Grav core, comes from the deploy
- `vendor/` — composer-managed, comes from the deploy
- Anything under `tmp/` or named `*.tmp`

The list of included paths lives as a config in the backup script
(`deploy/backup-paths.txt` or similar) so it's reviewable in PRs.

Each backup also contains a small **metadata file** at the archive
root:

```yaml
# backup-meta.yaml
backup_taken_at: 2026-04-29T12:34Z
source_host: www.byvaerkstederne.dk
code_version: "0.1.0"            # from VERSION at backup time
code_build: "247"                # from BUILD at backup time
data_version: "0.1.0"            # current schema version of the data
producer: "deploy/backup.sh"
producer_version: "0.1.0"        # this script's own version
```

`data_version` is the field the migration-runner spec will consume.
This spec only writes it; it does not interpret or change it. The
script reads the live tier's `config/www/user/data-version.yaml`
over SFTP to populate this — see the data-versioning spec for the
field's source-of-truth contract.

`producer_version` is a constant declared near the top of
`deploy/backup.sh` (e.g. `BACKUP_SCRIPT_VERSION="0.1.0"`); bump it
in the same commit as a behaviour change to the script.

A JSON Schema for this metadata file lives at
`deploy/schemas/backup-meta.schema.yaml` (committed alongside the
script) so future consumers — the migration runner, the promote
scripts — can validate against it instead of parsing fields by hand.

---

## Where backups live

Backups must live somewhere reachable from at least:

- The operator's laptop (so a human can inspect and download).
- The staging account (so a future promote-to-staging command can
  pull without prod credentials).

They must NOT live on the prod server itself. A backup that dies with
the box defeats its purpose.

Three viable storage options, ordered by recommendation:

1. **A small VPS or object-storage bucket controlled by the project.**
   Most flexible, smallest blast radius if compromised, costs a few
   euros a month. AWS S3, Backblaze B2, or any S3-compatible service.
   The backup script `aws s3 cp`s or equivalent. Credentials in
   `.env.deploy` alongside the existing tier credentials. The new
   variables (`BACKUP_S3_BUCKET`, `BACKUP_S3_ENDPOINT`,
   `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY` — name
   choice up to the implementer, but pinned at acceptance time) must
   land in `.env.deploy.example` so a fresh clone has a template to
   fill in.
2. **One.com's hosting backup feature**, if our plan includes
   programmatic access. Nice that it's already paid for; less nice
   that it's tied to one vendor and may not have a CLI.
3. **The staging account's filesystem.** Cheapest, but a compromise
   — staging is also a one.com account, so you've concentrated risk.

The choice is left to whoever implements this spec. Defaulting to
option 1 unless someone makes a case for the others.

---

## Producing a backup

A single command, runnable from a developer laptop or from a cron job
on a third box:

```
./deploy/backup.sh prod        # → uploads to backup storage, prints URL/path
./deploy/backup.sh prod --keep-local  # → also leaves a copy in ./backups/
```

What it does:

1. SSH to the prod host using `DEPLOY_PROD_*` credentials.
2. Tar the included paths into a temp file on the prod box.
3. Stream the tar back to the operator (or to backup storage
   directly, depending on size).
4. Generate the metadata file from the live VERSION/BUILD/data_version
   markers and embed it in the archive.
5. Encrypt the archive (see "Encryption" below).
6. Upload to storage with a deterministic filename:
   `prod-2026-04-29T12-34Z-v0.1.0-b247.tar.gz.age`.

   Filename encoding: ISO-8601 UTC timestamp with `:` replaced by `-`
   (filesystems and S3 prefixes dislike colons). Format is
   `<tier>-<YYYY-MM-DD>T<HH-MM>Z-v<semver>-b<build>.tar.gz.age`. The
   colon-to-hyphen swap applies only to the time portion; the date
   keeps its literal `-` separators. Implementer must use this exact
   form so the promote specs can derive backup IDs without parsing
   ambiguity.
7. Print the storage URL and a short summary.

The script must work non-interactively (cron-friendly) and exit
non-zero on any failure with a specific error message.

---

## Restoring a backup

Two scopes for "restore". Both available; both clearly named.

### Restore to a directory (inspection)

```
./deploy/restore.sh --to ./scratch/2026-04-29-prod-backup
```

Just unpacks the archive into a local directory. Doesn't touch any
live site. Useful for:

- Inspecting "what was member X's email on 2026-04-29".
- Running the migration runner against a backup before deciding to
  ship it forward.
- Hand-extracting a single record for a partial restore.

### Restore to a tier (operational)

```
./deploy/restore.sh prod --from <backup-id>     # disaster recovery
./deploy/restore.sh staging --from <backup-id>  # used by promote-to-staging
```

Wipes the target's `user/data/`, `user/accounts/`, `user/uploads/`
(and the other state paths), then unpacks the backup into them.
Clears caches afterwards.

Restoring to prod is the disaster-recovery path. It must:

- Refuse without a `--yes-i-mean-it` flag.
- Take a fresh "before-restore" backup of prod first, so a botched
  restore is itself recoverable.
- Log the restore operation somewhere visible.

Restoring to staging is the same machinery without the safety
prompts — it's used in routine workflows (the promote-to-staging
spec) and the contract is that staging's prior state is always
expendable.

---

## Operator-laptop privacy hygiene

Restore-to-scratch unpacks bcrypt password hashes, member email
addresses, and any uploaded files (including bug-report screenshots)
into a local directory. macOS Time Machine, Spotlight indexing, and
cloud-backup tools (Dropbox, iCloud Desktop, Google Drive) can
silently capture that data. To prevent that:

1. **Time Machine excludes.** Operators must run, once per machine
   after first checkout:

   ```sh
   tmutil addexclusion ./backups
   tmutil addexclusion ./deploy/staging-stage
   tmutil addexclusion ./deploy/prod-stage
   ```

2. **Cloud-sync excludes.** `./backups/`, `./deploy/staging-stage/`,
   and `./deploy/prod-stage/` must not live inside a Dropbox /
   iCloud Drive / Google Drive synced root. Operators are
   responsible for their machine layout.
3. **`.gitignore` lines** for the three paths land in `.gitignore`
   as part of this spec's acceptance — no scratch-data leak via a
   stray `git add .`.
4. **Spotlight.** A `.metadata_never_index` file in each scratch
   path tells macOS to skip indexing — created by `restore.sh` when
   it creates the scratch directory.

The README's "First-time setup" section gains a "Backup operator
hygiene" subsection that calls out these steps; the script prints a
reminder banner the first time it writes into one of these paths on
a given laptop.

---

## GAN sandbox compatibility

GAN sub-agents run under the confinement hook documented in
[CLAUDE.md](../CLAUDE.md#confinement--gan-agents-are-sandboxed-to-the-worktree),
which blocks `rsync --delete` workflows and writes outside the
worktree. The implications for this spec:

- A GAN agent **cannot** exercise `restore.sh prod` or
  `restore.sh staging` — both invoke `rsync --delete` against live
  tier paths and would be rejected by the hook (correctly).
- A GAN agent **can** exercise `backup.sh` against a fixture host,
  and `restore.sh --to <scratch>` against a scratch directory inside
  the worktree.
- Acceptance criteria that need an end-to-end restore-to-tier loop
  are operator-run, not GAN-run. Spec authors should phrase those
  criteria so a non-destructive stand-in (restore-to-scratch + diff
  against the backup) gives the GAN evaluator a way to score the
  feature.

---

## Encryption

Backups contain bcrypt-hashed passwords, member email addresses, and
bug-report screenshots that may include personal information. They
must be encrypted at rest.

Recommended: [`age`](https://age-encryption.org). Single binary, no
key infrastructure beyond a public key per recipient, integrates
cleanly with shell scripts.

The recipients (public keys of people who can decrypt) live in
`deploy/age-recipients.txt` — one age public key per line, comments
allowed with `#`, committed to the repo. The backup script reads it
via `age -R deploy/age-recipients.txt …`. Recipient rotation is a
reviewable PR that adds or removes a line; the file's small size
makes diffs obvious.

The decryption key lives in a password manager (or hardware key) on
the operator's machine, never in the repo.

Out of scope for this spec: HSM-backed key escrow, automated
rotation, multi-recipient policies. Add later if they're needed.

---

## Retention

### In managed storage (S3 / B2 / equivalent)

A simple retention rule, enforced by the backup script after each
upload:

- All daily backups for the past 14 days.
- One weekly backup (Sunday) for the past 12 weeks.
- One monthly backup (1st of month) for the past 12 months.
- All "tagged" backups indefinitely. A tag is created by passing
  `--tag <label>` to the backup command (e.g.
  `--tag pre-promotion-v0.2.0`).

Tagged backups are how the promote-to-prod spec captures
"rollback-insurance" snapshots that should never auto-expire.

Retention enforcement is a step at the end of the upload phase. It
queries the storage for existing backups and deletes anything that
falls outside the rules above (and is not tagged).

### Local copies on the operator's laptop

When `--keep-local` is passed (or step 5 below failed to upload), a
copy lands in `./backups/` on the operator's machine. The local
retention rule is the simplest one that prevents disk fill: keep
the most recent 14 local archives, drop older ones with each
new run. This supersedes the previous `deploy/backup.sh`'s
"keep last 30" rule — local copies are now a debugging convenience,
not a primary retention layer (managed storage owns that).

`./backups/` must be in `.gitignore` (it already is) and excluded
from Time Machine — see "Operator-laptop privacy hygiene" below.

---

## Acceptance criteria

### Backup production

- [ ] `./deploy/backup.sh prod` produces an encrypted tar archive
      in the configured backup storage.
- [ ] The archive contains the paths listed in the "What's in a
      backup" table and nothing more.
- [ ] The archive root contains a `backup-meta.yaml` with
      backup_taken_at / source_host / code_version / code_build /
      data_version / producer fields populated.
- [ ] Encrypted via `age -R deploy/age-recipients.txt`; the
      recipients file exists, is committed, and contains at least
      one valid age public key.
- [ ] Filename includes a UTC timestamp, source host, code version,
      and code build for human discoverability, in the form
      `<tier>-<YYYY-MM-DD>T<HH-MM>Z-v<semver>-b<build>.tar.gz.age`.
- [ ] `deploy/schemas/backup-meta.schema.yaml` exists and validates
      a sample `backup-meta.yaml` produced by the script.

### Restore — to directory

- [ ] `./deploy/restore.sh --to ./scratch/X` unpacks the latest backup
      into `./scratch/X` without touching any live tier.
- [ ] `./deploy/restore.sh --to ./scratch/X --from <id>` restores a
      specific archive by ID/timestamp.

### Restore — to tier

- [ ] `./deploy/restore.sh staging --from <id>` wipes staging's state
      paths and replaces them with the archive contents. Clears
      caches afterwards.
- [ ] `./deploy/restore.sh prod --from <id>` does the same for prod
      but only with `--yes-i-mean-it`. Without it, it refuses with a
      clear message.
- [ ] A prod restore takes a "before-restore" backup tagged
      `pre-restore-<timestamp>` before applying.

### Retention

- [ ] After 30 days of daily backups, there are at most 14 daily +
      4 weekly archives in storage (plus any tagged ones).
- [ ] A backup with `--tag pre-promotion-v0.2.0` is never deleted by
      retention sweeps.

### Configuration plumbing

- [ ] `.env.deploy.example` contains entries for the new managed-
      storage credentials (bucket name, endpoint, key id, secret).
- [ ] `.gitignore` excludes `./backups/`, `./deploy/staging-stage/`,
      and `./deploy/prod-stage/`.
- [ ] `restore.sh` writes `.metadata_never_index` into any scratch
      directory it creates.
- [ ] The README's "First-time setup" section names the
      `tmutil addexclusion` commands the operator must run.

### Failure modes

- [ ] If prod is unreachable, backup fails with a specific error
      ("ssh to <host>:<port> failed") and exits non-zero.
- [ ] If backup storage is unreachable, the local archive is kept on
      the operator's box (not deleted) and the failure is reported
      with the archive's local path.
- [ ] An interrupted backup leaves no half-uploaded artifacts in
      storage (atomic rename pattern).

---

## Out-of-scope future work

- **Per-record restore as a first-class command.** Today: restore
  to scratch directory and copy by hand. Sufficient for current
  scale.
- **Backup browsing UI.** A web page listing available backups with
  download buttons. Useful eventually; over-engineered for now.
- **Continuous WAL-style streaming.** Daily snapshots are the
  granularity. We're not running a database.
- **Backup of code artifacts** (deploy bundles, git tags). Code is
  in git and reproducible; only state needs backing up.
