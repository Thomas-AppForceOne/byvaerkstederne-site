# Specification — Data versioning and migration runner

Status: Planned
Owner: thomas@appforceone.dk
Depends on:
- [prod_backup_restore_specification.md](prod_backup_restore_specification.md)
- [atomic_deploy_releases_specification.md](atomic_deploy_releases_specification.md)
  — the per-version data-dir layout (`<tier>data/v<N>/`) introduced
  there is what this spec extends with `cp -a` + migrate semantics.
  Without atomic-deploy in place this spec would have to either
  invent a parallel layout or run in-place migrations on live data
  (the latter is an explicit non-goal here).
Scope: Stamp the site's data with a schema version, define a format
for migration scripts, and build a runner that brings a snapshot
forward from one schema version to another. The second step of the
data-lifecycle series.

> **Interface with atomic-deploy.** A deploy whose required schema
> version differs from the live tier's `<tier>data/current` triggers
> `cp -a <tier>data/v<old>/ <tier>data/v<new>/`, runs migrations
> against the new version dir, points the new release's symlinks at
> it, and updates `<tier>data/current → v<new>`. The previous
> release's symlinks still target `v<old>`, which is preserved on
> disk — that's how rollback across a schema bump stays a single
> symlink swap. See atomic-deploy §Versioned data dirs for the
> full handoff.

---

## Motivation

Once we can produce backups, the next question is: what do we do
when the *shape* of the data changes? A flex-object gets a new
required field. A page frontmatter gate is renamed. A user account
field is split into two.

Without a migration story, two things happen:

- Old backups become unrestorable against new code, because the new
  code expects fields that weren't in the backup.
- Promoting a backup from prod to staging fails or silently
  corrupts data when the staging code has moved on from prod's
  schema.

We need a small, well-defined mechanism for forward-migrating data
between schema versions. Not a heavyweight ORM-style framework; a
folder of PHP scripts and a runner that knows which to apply.

---

## Non-goals

- **Backwards / down migrations.** Migrations here are forward-only.
  Rollback is by restoring an earlier backup, not by reversing a
  migration. (See the promote-to-prod spec for rollback handling.)
- **Generated migrations.** No `make:migration` codegen. Each
  migration is a hand-written PHP script with a clear name.
- **Schema migrations as code refactors.** A migration that changes
  field names also requires the corresponding code change in the
  same release. The migration runner doesn't try to keep old code
  working alongside new data.
- **Live in-place migrations on production.** The runner is always
  applied to a backup snapshot, never directly against a live tier's
  filesystem. The promote-to-* specs use the runner against a
  snapshot, then push the migrated snapshot to the target.

---

## The `data_version` marker

Each backup carries a `data_version` SemVer string in its
`backup-meta.yaml` (defined in the backup spec). This is the
canonical "what schema is this data in" answer.

The marker is **not** the same thing as the code version. They
share the same SemVer scheme but advance for different reasons:

- Code version (`apex/VERSION`, `config/www/VERSION`) bumps for any
  release decision worth labelling.
- Data version bumps **only** when a migration is added.

So a release can ship `code 0.3.0 / data 0.1.0` if it didn't change
any data shapes. The migration runner uses only the data version to
decide what to apply.

A live deployed tier also stores its current data_version, in a
small file at a known location:

```
config/www/user/data-version.yaml
```

```yaml
data_version: "0.1.0"
```

This file is part of the deploy bundle. The site code reads it at
boot for diagnostics; the migration runner reads it (or the value
from a backup) to know where to start.

The git-tracked file in `config/www/user/data-version.yaml`
represents **the schema version the current code expects** — it is
shipped as part of every deploy. On a live tier, the same path is
overwritten by the data-push step of a promotion to reflect the
**actual schema version of the data sitting on disk**. After a
successful promotion the two should agree; between promotions, the
file in git can be ahead (a code change adds a migration before any
tier has been promoted to it). The promote specs treat the git copy
as "target" and the live-tier copy as "current".

A starter file `config/www/user/data-version.yaml.example` is
committed to give a fresh clone or a freshly reset tier a template
to copy.

---

## Migration script format

Migrations live in a top-level repo folder:

```
migrations/
  README.md
  0.2.0_add_event_capacity_field.php
  0.3.0_split_member_into_member_and_volunteer.php
  0.4.0_drop_legacy_oenskeliste_collection.php
  ...
```

Naming: `<target_version>_<short_slug>.php`. The target version is
the `data_version` the script produces. Slug is human-readable and
helps in `git log`.

Each script exposes a single function:

```php
<?php
/**
 * @param string $dataDir Absolute path to a directory containing
 *                        the data tree (`accounts/`, `data/`,
 *                        `pages/`, `uploads/`, `data-version.yaml`).
 *                        The function mutates this directory in
 *                        place.
 *
 * @return void           Throws on failure. Idempotent on success
 *                        (re-running against already-migrated data
 *                        is a no-op).
 */
return function (string $dataDir): void {
    // Read $dataDir, mutate files in place, write data-version.yaml
    // to the new version at the end.
};
```

Conventions:

- The script may read and write any file under `$dataDir`.
- It may NOT read or write outside `$dataDir`. No HTTP, no database,
  no admin API. Pure file transformation.
- It must finish by writing the new `data_version` value into
  `$dataDir/config/www/user/data-version.yaml`.
- It must be idempotent: running it twice in a row produces the
  same result as running it once.
- It must be self-contained: no `require_once` of project code from
  outside the migration runner. The runner provides its own
  `composer.json` at `migrations/composer.json` (Symfony YAML is the
  expected dependency); the runner `require`s that autoload before
  invoking each migration's closure, and migrations can call the
  loaded libraries directly. `$dataDir` is a pure data tree
  (`accounts/`, `data/`, `pages/`, `uploads/`, `data-version.yaml`)
  and contains no `vendor/` of its own — migrations must not reach
  into a Grav install for libraries.

---

## The migration runner

A single CLI:

```
./deploy/migrate.sh <data-dir> [--to <version>]
```

Behaviour:

1. Read `data-version.yaml` from `<data-dir>`. Call this `from`.
2. If `--to` is given, target = that. Otherwise target = the
   `data_version` declared by the code in the deploy bundle (also
   in a known location: `config/www/user/data-version.yaml` shipped
   from git).
3. List all migration scripts whose target version is strictly
   greater than `from` and less than or equal to `target`. Sort by
   target version ascending.
4. For each migration in order:
   - Print "applying <name>".
   - `require` the file, call its returned closure with `<data-dir>`.
   - On success, verify the migration wrote the expected
     `data_version` value. Refuse to continue if it didn't.
5. Print summary: from-version, to-version, list of migrations
   applied.

The runner exits non-zero on any failure with a clear error.

The runner is invoked by the promote-to-staging and promote-to-prod
commands; it can also be run by hand against a restored backup for
inspection.

---

## Bootstrap

Production's existing data has no `data_version` marker today.
Before the migration runner can be useful, prod must be stamped.

A one-time bootstrap step:

1. Decide the initial data version. `0.1.0` is the natural choice
   (matches the initial code version).
2. SSH to prod, write `config/www/user/data-version.yaml` with that
   value.
3. Take a fresh backup. The backup script (per the
   [backup spec](prod_backup_restore_specification.md)) reads
   `config/www/user/data-version.yaml` from the live tier over SFTP
   and writes its value into the archive's `backup-meta.yaml` —
   that's the connection that lets a future restore know which
   schema version the snapshot came from.

This is documented in the spec's "Implementation notes" section
when this work starts; it does not need a migration script (it's
not a transformation).

Staging, test, and dev tiers do the same one-time stamp on whatever
data they currently hold (likely also `0.1.0`).

### Pre-spec backups

Backups produced by the previous `deploy/backup.sh` (before this
spec ships) carry no `data_version` field in their metadata — most
of them carry no metadata file at all. The runner treats a missing
field as **`data_version: "0.1.0"` by convention** so historical
backups remain restorable. If that assumption is wrong for a given
backup, the operator stamps the unpacked snapshot manually
(`echo 'data_version: "X.Y.Z"' > <scratch>/config/www/user/data-version.yaml`)
before re-running the runner. The runner prints a warning each time
it hits the convention path so the operator knows it kicked in.

---

## Failure modes

### Missing migration

If the runner encounters a target version with no script — e.g.,
data is at `0.2.0`, target is `0.4.0`, but only `0.3.0_*.php` exists
— it must:

- Refuse to apply anything.
- Print: "no migration to 0.4.0 found; cannot proceed from 0.3.0".
- Exit non-zero.

This protects against silent gaps in the migration sequence.

### Migration throws mid-way

The migration script may have partially mutated `<data-dir>` before
throwing. The runner does NOT attempt cleanup — `<data-dir>` is
considered tainted and must not be used.

The orchestrating commands (promote-to-staging, promote-to-prod)
arrange for `<data-dir>` to be a copy of the backup, not the
original, so a thrown migration just abandons that copy. The
original archive on disk is untouched.

### Idempotence violation

A migration that produces different output on a second run is a
bug. Caught by the test suite (see "Testing" below).

---

## Testing

Each migration must come with a test fixture. Layout:

```
migrations/tests/
  0.2.0_add_event_capacity_field/
    before/                # representative data shaped at 0.1.0
      data/begivenheder.yaml
      data-version.yaml    # contains "0.1.0"
    after/                 # what the migration must produce
      data/begivenheder.yaml
      data-version.yaml    # contains "0.2.0"
```

A single `migrations/run-tests.sh` iterates test directories:

- **Per-migration test.** Copy `before/` to a tmp dir, run the
  migration, diff the result against `after/`. Equal → pass.
- **Idempotence test.** Run the migration a second time in the tmp
  dir. Diff again. Equal → idempotence pass.
- **Compose-chain test.** Starting from the lowest-version
  `before/` fixture, apply migrations in declared order through to
  the highest target version. Diff the result against the highest
  fixture's `after/`. This catches bugs where each migration is
  individually correct but their composition isn't (an early
  migration writes a field a later one assumes is absent, a
  reordering bug, etc.). The compose-chain test runs alongside the
  per-migration tests; both must pass.

The runner sorts migrations by **SemVer comparison**, not by
filename. `0.10.0_X.php` correctly applies after `0.2.0_X.php`
even though it lex-sorts before it.

### CI integration

A GitHub Actions workflow at `.github/workflows/migrations.yml`
runs `migrations/run-tests.sh` on every PR whose file changes
touch `migrations/**`, `config/www/user/data-version.yaml`, or
`config/www/user/data-version.yaml.example`. The workflow uses
the matrix-PHP versions Grav itself supports.

If repo CI infrastructure isn't yet in place when this spec lands,
implementer can ship the test runner first and add the workflow as
a follow-up commit on the same branch — but the spec's acceptance
is not met until the workflow is wired and green.

---

## Acceptance criteria

### Marker handling

- [ ] `config/www/user/data-version.yaml` exists in the deploy
      bundle, contains `data_version: "0.1.0"`.
- [ ] After bootstrap, every live tier has the same file with the
      same value.
- [ ] Backups capture the file (already covered by the backup spec).

### Runner

- [ ] `./deploy/migrate.sh <data-dir>` reads the from-version, computes
      the to-version from the deployed code, applies the right set
      of migrations, and writes the new version into the data dir.
- [ ] Running with no migrations needed (already at target) is a
      no-op; exits 0; prints "already at <version>, nothing to do".
- [ ] Running with a missing migration script in the chain refuses
      with a clear error.

### Idempotence

- [ ] Each migration's CI test passes both the "produces correct
      output" and "is idempotent on re-run" checks.

### Migration discipline

- [ ] No two migration files target the same version (CI check).
- [ ] The runner sorts migrations by SemVer comparison, not by
      filename — verified by a test that puts `0.10.0` and `0.2.0`
      migrations in the chain and asserts the runner applies them
      in numeric order.
- [ ] The compose-chain test passes: starting from the earliest
      fixture's `before/`, applying every migration in order
      produces the latest fixture's `after/`.

### Failure modes

- [ ] A migration that throws halts the runner; the runner exits
      non-zero; partially-mutated data dir is left as-is for
      debugging (callers know not to consume it).

---

## Out-of-scope future work

- **Backwards migrations.** Restore-from-backup is the rollback
  path. If we ever need targeted rollbacks of single fields, we
  amend.
- **Schema definition language.** No "describe the shape of an
  event in a YAML schema and have migrations generated". Hand-written
  migrations are fine for our scale.
- **Database migrations.** No database to migrate. Reconsider when
  one shows up.
- **Tooling for "preview a migration's diff".** Would be useful;
  build only when the migration cadence justifies it.
