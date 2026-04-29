# Specification — Prod backup and restore tooling

Status: Planned
Owner: thomas@appforceone.dk
Depends on: nothing
Scope: Produce, store, and restore complete snapshots of production
state. The foundation of the data-lifecycle series — every later spec
in the series consumes backups, none of them produces them.

---

## Motivation

There is no tooling today for backing up the production site. Our
deploy scripts handle code, but production *state* (member accounts,
flex-objects, uploads, edited page content) lives only on the prod
server. A disk failure, a botched manual edit, or a faulty migration
would take real members and real content with it.

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
This spec only writes it; it does not interpret or change it.

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
   `.env.deploy` alongside the existing tier credentials.
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
   `prod-2026-04-29T12-34Z-v0.1.0-b247.tar.gz.age` or similar.
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

## Encryption

Backups contain bcrypt-hashed passwords, member email addresses, and
bug-report screenshots that may include personal information. They
must be encrypted at rest.

Recommended: [`age`](https://age-encryption.org). Single binary, no
key infrastructure beyond a public key per recipient, integrates
cleanly with shell scripts. The recipients (people who can decrypt)
are listed in the backup script's config.

The decryption key lives in a password manager (or hardware key) on
the operator's machine, never in the repo.

Out of scope for this spec: HSM-backed key escrow, automated
rotation, multi-recipient policies. Add later if they're needed.

---

## Retention

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
- [ ] Encrypted with the recipient public keys configured at script
      level.
- [ ] Filename includes a UTC timestamp, source host, code version,
      and code build for human discoverability.

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
