# Migrations — script-author contract

This folder holds the forward-only data-shape migrations the
Byværkstederne site applies via `deploy/migrate.sh`. Each script
takes a snapshot of the data tree from one schema version to the
next.

The spec is authoritative — see
`specifications/data_versioning_and_migrations_specification.md`
(or `specifications/archive/...` once it ships). This README is the
quick-reference for someone adding a new migration; if it disagrees
with the spec, the spec wins.

---

## Naming

```
migrations/<target_version>_<short_slug>.php
```

* `<target_version>` — the SemVer string the migration produces, e.g.
  `0.2.0`. The runner uses this to sort and to verify the migration
  wrote the new `data_version` value.
* `<short_slug>` — human-readable, lowercase, underscore-separated.

Examples:

```
0.2.0_add_event_capacity_field.php
0.3.0_split_member_into_member_and_volunteer.php
0.10.0_drop_legacy_oenskeliste_collection.php
```

No two files may declare the same `<target_version>`. The test
harness (`migrations/run-tests.sh`) fails the build if two ever do.

---

## Closure signature

Each migration file `return`s a single closure with the exact
signature below. The runner `require`s the file, captures the
returned closure, and invokes it with the data-dir path.

```php
<?php
/**
 * @param string $dataDir Absolute path to a directory containing
 *                        the data tree (`accounts/`, `data/`,
 *                        `pages/`, `uploads/`,
 *                        `config/www/user/data-version.yaml`). The
 *                        closure mutates this directory in place.
 *
 * @return void           Throws on failure. Idempotent on success.
 */
return function (string $dataDir): void {
    // 1. Read from $dataDir, transform as needed, write back.
    // 2. Finish by writing the new data_version into
    //    $dataDir/config/www/user/data-version.yaml.
};
```

Rules — these are enforced by the runner, by the test harness, or
both:

1. **Mutate only `$dataDir`.** The closure may read and write any
   path under `$dataDir`. It must not touch anything outside.
   No HTTP, no database, no admin-API call, no SSH. Pure file
   transformation.
2. **Self-contained dependencies.** The runner's `composer.json`
   (in this folder) provides Symfony YAML; the runner `require`s
   its autoload before invoking the closure. Migrations may use
   any library declared in `migrations/composer.json`. Migrations
   must NOT `require_once` anything from the Grav install — the
   `$dataDir` is a pure data tree and contains no `vendor/` of
   its own.
3. **Finish by writing `data-version.yaml`.** The closure must
   write `$dataDir/config/www/user/data-version.yaml` with the
   new `data_version` value matching the file's
   `<target_version>` prefix. The runner verifies this after the
   closure returns and refuses to continue if the file is missing
   or holds a different value.
4. **Idempotent.** Running the closure a second time against an
   already-migrated `$dataDir` must produce a byte-identical
   result to running it once. Express the migration as "ensure the
   shape is X" rather than "apply transformation X" wherever that
   distinction matters.

---

## Test fixtures

Every migration ships with a paired fixture under
`migrations/tests/<migration-name>/`:

```
migrations/tests/<target_version>_<slug>/
  before/        # representative data shaped at the from-version
    config/www/user/data-version.yaml   # contains "<from_version>"
    <…the bits the migration cares about…>
  after/         # what the migration must produce
    config/www/user/data-version.yaml   # contains "<target_version>"
    <…the post-migration shape…>
```

`migrations/run-tests.sh` walks each fixture and exercises three
checks per migration:

1. **Per-migration test.** Copy `before/` to a tmp dir, run the
   migration once, diff the result against `after/`. Equal → pass.
2. **Idempotence test.** Run the migration AGAIN in the same tmp
   dir, diff against `after/` once more. Equal → pass.
3. **Compose-chain test.** Starting from the lowest-version
   fixture's `before/`, apply every migration in SemVer order
   through to the highest target. Diff the result against the
   highest fixture's `after/`. Equal → pass. Catches composition
   bugs where each migration is individually correct but their
   composition isn't.

A peer check inside the harness scans the folder for duplicate
target versions and fails fast if any are found.

---

## Pre-spec backup convention

Backups produced before this spec shipped carry no `data_version`
field (most have no metadata file at all). The runner treats those
inputs as `data_version: "0.1.0"` by convention, and prints a
warning each time it does so. Concretely, if
`<data-dir>/config/www/user/data-version.yaml` is missing or is
present without a parseable `data_version` field, the from-version
is taken to be `0.1.0`. If that assumption is wrong for a given
backup, stamp the unpacked snapshot manually before invoking the
runner:

```sh
mkdir -p <scratch>/config/www/user
echo 'data_version: "X.Y.Z"' > <scratch>/config/www/user/data-version.yaml
deploy/migrate.sh <scratch> --to <target>
```

---

## Demo migration `0.2.0_demo_data_version_metadata.php`

The folder ships one demo migration after the baseline. It
demonstrates a real (small) transformation: it appends a
`migrated_at` field to `data-version.yaml`. The value is derived
from `$dataDir/.migrated-at-seed` if that file exists (so test
fixtures stay deterministic) and from the current UTC instant
otherwise. The migration is idempotent because it only writes
the field if it isn't already present, and the test fixture pins
the seed file so the diff against `after/` is stable across runs.
