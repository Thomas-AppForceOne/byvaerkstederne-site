# Specification — Data versioning and migration runner

Status: Planned
Owner: thomas@appforceone.dk
Depends on: [prod_backup_restore_specification.md](prod_backup_restore_specification.md)
Scope: Stamp the site's data with a schema version, define a format
for migration scripts, and build a runner that brings a snapshot
forward from one schema version to another. The second step of the
data-lifecycle series.

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
- It must be self-contained: no `require_once` of project code. If
  it needs a YAML parser, it `require`s composer's autoload from
  inside `$dataDir/vendor/` or pulls one in from a known migration
  helper folder.

---

## The migration runner

A single CLI:

```
./bin/migrate <data-dir> [--to <version>]
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
3. Take a fresh backup. The metadata will pick up the new value.

This is documented in the spec's "Implementation notes" section
when this work starts; it does not need a migration script (it's
not a transformation).

Staging, test, and dev tiers do the same one-time stamp on whatever
data they currently hold (likely also `0.1.0`).

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

A single `migrations/run-tests.sh` (or a PHPUnit suite) iterates
test directories:

- For each test: copy `before/` to a tmp dir, run the migration,
  diff the result against `after/`. Equal → pass.
- Run the migration a second time in the tmp dir. Diff again. Equal
  → idempotence pass.

The CI runs this suite on every PR that touches `migrations/`.

---

## Acceptance criteria

### Marker handling

- [ ] `config/www/user/data-version.yaml` exists in the deploy
      bundle, contains `data_version: "0.1.0"`.
- [ ] After bootstrap, every live tier has the same file with the
      same value.
- [ ] Backups capture the file (already covered by the backup spec).

### Runner

- [ ] `./bin/migrate <data-dir>` reads the from-version, computes
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
- [ ] Migration filenames sort lexicographically in the same order
      as their target versions (CI check, for human-readability).

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
