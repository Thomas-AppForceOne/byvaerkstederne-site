# Specification — Atomic deploy releases

Status: Planned
Owner: thomas@appforceone.dk
Depends on:
- Step 1 (Semantic version + build number) — IMPLEMENTED. The
  `version.json` and BUILD-file output from `deploy/deploy.sh` is
  reused unchanged; this spec only changes *where* on the remote
  those artefacts land.
- Nothing else. This spec is independent of the data-lifecycle
  chain (steps for backup, data-versioning, promote-to-staging,
  promote-to-prod) and ships before any of them.

Required by:
- [data_versioning_and_migrations_specification.md](data_versioning_and_migrations_specification.md)
  — uses the versioned data-dir layout introduced here.
- [promote_to_staging_specification.md](promote_to_staging_specification.md)
  — uses the atomic-deploy + rollback primitives instead of in-place
  rsync.
- [promote_to_prod_specification.md](promote_to_prod_specification.md)
  — same.

Replaces: the in-place rsync-with-`--delete` model in
`deploy/deploy.sh` for the grav tiers (dev/test/staging/prod).
The apex `landing` deploy is unchanged — it has no mutable state and
no rollback story to preserve.

Scope: replace the live-tier rsync-overwrite-in-place with an atomic,
rollback-able release model. Each tier has its own versioned release
directories holding immutable code, a sibling per-tier data
directory holding all mutable state, and a single symlink that
constitutes the live tier. Deploy is "rsync to a fresh release dir
plus a symlink swap"; rollback is "symlink swap back". User data
physically cannot be deleted by a misconfigured rsync because it
lives outside every directory the deploy script writes into.

---

## Motivation

The current `deploy/deploy.sh` runs `rsync -avz --delete` from a
locally-built staging dir over the live tier docroot. The
`--delete` flag is non-negotiable for code (stale plugin assets,
removed pages must actually disappear), but the live tree contains
four very different ownership models tangled together:

| Subtree | Owned by | Lifecycle |
|---|---|---|
| `system/`, `user/plugins/<grav-plugins>/`, `user/themes/`, `user/pages/`, `apex/`, `index.php`, top-level `vendor/` | Local repo + composer | Immutable per deploy |
| `user/config/`, `user/env/*/config/` (most files) | Local repo | Immutable per deploy |
| `user/accounts/`, `user/data/`, `user/env/*/config/security.yaml`, `user/config/security.yaml` | Server (real users edit them) | Mutable continuously |
| `cache/`, `logs/`, `tmp/`, `backup/` | Server (Grav generates them) | Regenerable / preserved |

`rsync --delete` says "make remote look like local." That is correct
for rows 1+2 and disastrous for rows 3+4. Every layer the current
script grows — explicit excludes, `--max-delete=25`, the pre-flight
dry-run grep — exists to retroactively communicate to rsync which
rows to skip. That list grows forever and a missed exclude is one
deploy from a wipe.

Two production incidents have already been caused by this model:

- **April 2026 — accounts wipe.** A deploy without `user/accounts/`
  excluded ran `rsync --delete`; every Grav user record on the live
  tier was destroyed. Recovered by manual user re-creation.
- **May 2026 — dev re-wipe.** The post-incident exclude list shrank
  back during a routine refactor, and a `make deploy-dev` deleted
  user `bobo` plus the entire flex-account index, scheduler queue,
  feed, and notifications. Same root cause.

Three adjacent fragility classes the current model also has, that
the post-May safeguards have only partly addressed:

1. **Drift / cruft.** The remote can carry files the local repo
   doesn't, from past mistakes (the `feature-flags/vendor/`
   incident). The next deploy's `--delete` either tries to remove
   them all (tripping `--max-delete`) or — worse, in some
   universe — succeeds, deleting state nobody documented.
2. **No atomicity.** A half-finished rsync leaves the live tier in
   a broken state for the duration of the transfer.
3. **No rollback.** Once the live tier is overwritten, the only undo
   is `git checkout && redeploy` against the old commit. Not viable
   when the failure happens during the rsync itself.

The pattern this spec adopts is the standard one for PHP-on-shared-
hosting: atomic releases, per-Capistrano / Deployer / Envoyer.
Adapted for Byværkstederne's per-tier-isolation invariant (no
sharing between dev / test / staging / prod) and forward-compatible
with the versioned data dirs the data-versioning spec needs.

---

## Non-goals

- **Database snapshotting.** Grav stores state as YAML files; there
  is no relational database to snapshot atomically. If we ever
  introduce one, this spec is amended.
- **Cross-tier data sharing.** Each tier remains fully independent;
  dev's data dir is unrelated to test's. The "shared" terminology
  some Capistrano-style descriptions use refers to *across releases
  of the same tier*, never across tiers.
- **Zero-downtime mid-request handovers.** PHP-FPM workers in flight
  during a symlink swap may finish on the old release; that's
  expected and fine. We do not buffer requests, drain workers, or
  guarantee that a single user's session reads a consistent release
  across consecutive requests for the duration of the swap.
- **Automatic data backup.** Backup is the
  [prod_backup_restore_specification.md](prod_backup_restore_specification.md)
  spec's responsibility; this spec doesn't take backups.
- **Migration mechanics.** Schema migrations are
  [data_versioning_and_migrations_specification.md](data_versioning_and_migrations_specification.md)'s
  responsibility; this spec defines only the *layout* in which
  versioned data dirs live, and the deploy script's role in pointing
  a new release at the appropriate version dir.
- **Apex/landing redesign.** `apex/index.php` is a single flat PHP
  file with no mutable state. The atomic-release machinery is
  overkill there; the apex deploy continues to use the existing
  rsync model. (Excludes for sibling-tier folders still apply.)
- **CI/CD plumbing.** Promotion through tiers stays a manually-
  invoked command flow. This spec does not introduce a build system.

---

## Layout

Per-tier on the remote, after this spec ships:

```
<docroot-parent>/
  <tier>data/                                     # mutable state, per-tier
    v0/                                           # data at schema version 0 (initial)
      user/accounts/
      user/data/
      user/config/security.yaml
      user/env/<env>/config/security.yaml
    current → v0                                  # marker: which data version is "live"
                                                  # (a symlink in a stable location for ops visibility)
  <tier>-releases/                                # versioned code, per-tier
    20260520T140000-abc1234/                      # one release dir per deploy
      system/, user/plugins/, user/themes/, user/pages/, apex/, index.php, vendor/, …
      VERSION, BUILD, version.json                # produced by deploy.sh as today
      release-meta.yaml                           # who/when/from-what (see §Audit)
      user/accounts          → ../../<tier>data/v0/user/accounts/
      user/data              → ../../<tier>data/v0/user/data/
      user/config/security.yaml         → ../../../<tier>data/v0/user/config/security.yaml
      user/env/<env>/config/security.yaml → ../../../../../<tier>data/v0/user/env/<env>/config/security.yaml
      logs                   → ../../<tier>data/logs/    # see §Logs
    20260519T180000-def5678/                      # previous release
      … (same shape)
  <tier> → <tier>-releases/20260520T140000-abc1234   # the docroot — symlink to the current release
```

Key invariants this layout enforces:

1. **Data physically lives outside every release directory.** The
   release directory is `<tier>-releases/<timestamp>/`. The data
   directory is `<tier>data/`. They are siblings, not nested. A
   recursive operation rooted at any release dir cannot reach
   `<tier>data/`.
2. **The docroot is one symlink.** The single source of truth for
   "which release is live" is the `<tier>` symlink. No other state
   determines liveness. Reading the link's target tells you the
   release.
3. **Each release's symlinks bake in the data version.** The
   symlinks inside `<tier>-releases/<X>/user/...` point at a
   specific `<tier>data/v<N>/...`, decided at deploy time and
   never edited again for that release. A rollback to that release
   gets the data version it expected; a rollback never spans an
   unintended schema bump.
4. **Releases are immutable after the swap.** Nothing outside this
   spec writes into a release dir after it goes live. Cache files
   and logs that have to be writable live in the data dir (see
   §Caches and logs below).
5. **Per-tier isolation.** `<tier>data/` and `<tier>-releases/`
   exist once per tier. Dev's are unrelated to test's, staging's,
   prod's.

### Caches and logs

Grav writes to `cache/`, `logs/`, and `tmp/` at runtime. Two options
for where these live:

- **Inside the release dir (regenerable).** Each release gets its
  own empty `cache/`. After swap, Grav repopulates. Pro: completely
  isolated per release, never carries stale compiled twig from a
  previous release. Con: cache rebuild lag on the first request
  after a swap.
- **In `<tier>data/` (shared across releases).** Symlinked from
  inside the release dir. Pro: warm cache survives a release swap.
  Con: stale entries from a previous release can get served by the
  new release; needs a `bin/grav cache --all` after every swap
  anyway.

This spec **uses option A for `cache/` and `tmp/`** (regenerable,
isolation outweighs warmth) and **option B for `logs/`** (operators
expect log continuity across releases). `bin/grav cache --all` runs
on the new release before the swap, fail-loud, as today.

### One.com docroot constraint

The `<tier>` directory in the layout above is currently a real
directory on one.com (e.g. `/customers/4/e/5/hackersbychoice.dk/httpd.www/dev/`),
because that's where one.com maps the `dev.hackersbychoice.dk`
subdomain. Whether one.com lets the docroot itself be a symlink
needs to be verified at implementation start.

Two implementation paths, depending on the answer:

- **A (preferred): docroot is the symlink.** `<tier>` itself is a
  symlink to `<tier>-releases/<current>`. `ln -sfn` swaps it
  atomically. Apache resolves it transparently. This is the layout
  described above.
- **B (fallback): docroot is a thin shim.** `<tier>` stays a real
  directory containing only a bootstrap `index.php` and `.htaccess`
  that delegate to the current release. The shim's contents are
  written once and never updated; "swap" becomes "update a
  CURRENT-RELEASE marker file the shim reads at request time".
  Adds one indirection but works under any docroot policy.

The spec's acceptance criteria are written assuming path A. If
implementer determines A is impossible, they switch to B and amend
this section.

---

## Symlink contract

A release directory is "wired up" — i.e., ready to be made live —
when every entry in this table exists in the release dir and points
at the right place. The deploy script creates these symlinks during
step 3 of the deploy sequence (§Deploy command).

| Symlink path (relative to release dir root)            | Target (relative to symlink) |
|---|---|
| `user/accounts`                                        | `../../<tier>data/<dataver>/user/accounts/` |
| `user/data`                                            | `../../<tier>data/<dataver>/user/data/` |
| `user/config/security.yaml`                            | `../../../<tier>data/<dataver>/user/config/security.yaml` |
| `user/env/<env>/config/security.yaml`                  | `../../../../../<tier>data/<dataver>/user/env/<env>/config/security.yaml` |
| `logs`                                                 | `../../<tier>data/logs/` |

Where `<dataver>` is `v0` until the data-versioning spec ships and
introduces real schema versions; after that, it's whatever data
version the release's bundled `data-version.yaml` declares (see
§Versioned data dirs below).

### Why per-file symlinks for `security.yaml`

The two `security.yaml` files (root-env and per-env) are *files*
inside otherwise-deploy-controlled directories (`user/config/`,
`user/env/<env>/config/`). The rest of those directories ships with
the deploy and is overwritten on each release. Only the
`security.yaml` files within them are server-owned (Grav generates
salts on first request). Symlinking the *file* lets the surrounding
config still update normally.

### What is NOT symlinked

- `cache/`, `tmp/` — kept inside the release dir (regenerable).
- Anything under `system/`, `user/plugins/`, `user/themes/`,
  `user/pages/` — these are deploy-controlled and live entirely
  inside the release dir.

### Symlink creation is part of the deploy script

The deploy script never assumes symlinks already exist in a fresh
release dir; it creates them every time, idempotently. If a target
in `<tier>data/<dataver>/` is missing, the script creates an empty
directory or — for the two `security.yaml` files — leaves the
symlink dangling, which Grav handles by regenerating on first
request.

---

## Versioned data dirs

`<tier>data/` is laid out as `<tier>data/v<N>/...` where `v<N>` is
the schema version (introduced and managed by the
[data-versioning spec](data_versioning_and_migrations_specification.md)).
This spec ships the layout but does not yet ship the version-bump
mechanics. Two phases:

### Phase 1 — atomic deploys ship (this spec)

There is exactly one data-version dir, `<tier>data/v0/`. All
releases' symlinks point at it. No copy, no migration, no
version-pick logic in the deploy script.

`<tier>data/current → v0` exists from day one as a marker — ops can
read its target to see "the live tier reads from v0".

The deploy script learns to:

- Create `<tier>data/v0/...` on first deploy if missing (one-time
  bootstrap).
- Wire each new release's data symlinks to `<tier>data/v0/...`.

### Phase 2 — data-versioning ships (separate spec)

The data-versioning spec adds:

- `data-version.yaml` in each release's deploy bundle, declaring
  the schema version the code expects.
- Migration scripts, runner, and CI-fixture tests.

It also extends this spec's deploy script with:

- Read the deploy bundle's required schema version `vM`.
- If `<tier>data/vM/` doesn't exist: `cp -a <tier>data/<current>/ <tier>data/vM/`,
  run migrations against `<tier>data/vM/`, update `<tier>data/current → vM`.
- Wire the new release's data symlinks to `<tier>data/vM/...`.
- Old releases keep pointing at their original `v<earlier>/`, so
  rollback to them still works *as long as the corresponding `v<earlier>/`
  hasn't been pruned* (see §Retention).

The seam between this spec and data-versioning is `<tier>data/`'s
on-disk layout. This spec defines it; data-versioning consumes and
extends it.

### Rollback strategy this layout enables

This is the "Strategy 2 — versioned data dirs" option from the
spec author's prior analysis. Rollback after a breaking schema
change works because:

- The previous release's symlinks point at `<tier>data/v<old>/`,
  which still physically exists on disk (until pruned).
- A symlink swap brings the previous release back, with its data
  intact.

Trade-off being inherited explicitly: writes made *during* the
release that's being rolled away from land in `<tier>data/v<new>/`
and are forfeit on rollback. For the workshop site this is
acceptable — content edits during a bad release window can be
re-done. If a future feature adds writes that cannot be lost
(payments, time-stamped audit records), that spec must address
the gap, not this one.

---

## Deploy command

`./deploy/deploy.sh <env>` for grav tiers becomes:

1. **Build the deploy package** in `$STAGING_DIR` exactly as today —
   Grav core extraction, repo overlay, BUILD/VERSION/version.json
   generation. Includes the SemVer feature shipped in step 1.
2. **Pre-flight checks (network).** Verify ssh works, the parent of
   `<tier>-releases/` is writable, the existing `<tier>` symlink
   resolves to a real release dir (or doesn't exist yet for first-
   time deploy), and `<tier>data/v0/` exists (create on first run).
3. **Compute release id.** `<UTC-timestamp>-<git-sha-short>`. This
   becomes the new release dir name. Must be unique on the remote
   (deploy aborts if a dir of the same name already exists, with a
   clear diagnostic naming the offender).
4. **rsync to the new release dir.** Target: `<tier>-releases/<release-id>/`.
   No `--delete` — the target dir is fresh and empty. No live-state
   excludes either (those state subtrees aren't in the staging dir
   anyway). Existing excludes for `cache/`, `logs/`, `tmp/`,
   `backup/`, `.DS_Store` still apply (we don't want to ship local
   dev cache state). Optional `--max-delete=0` belt-and-braces (no
   delete should ever happen against a fresh dir; assert it).
5. **Wire up symlinks.** For each symlink in §Symlink contract,
   `ln -sfn` it inside the new release dir. Idempotent. Phase 1:
   targets are `<tier>data/v0/...`. Phase 2: targets are
   `<tier>data/v<M>/...` with `<M>` decided by data-versioning.
6. **Write the release manifest.** `<tier>-releases/<release-id>/release-meta.yaml`
   captures who deployed, when, from what commit, what the previous
   release was, what data version it points at, what the prior data
   version was. See §Audit for the schema.
7. **Cache clear in the new release.** `php bin/grav cache --all`
   inside `<tier>-releases/<release-id>/`, fail-loud (no `|| true`,
   no stderr suppression) per the May 2026 fix that's already
   landed. Failure here aborts the deploy *before* the swap, so
   the previous release stays live.
8. **Atomic swap.** `ln -sfn <tier>-releases/<release-id> <tier>`
   on the remote. This is the moment the new release goes live.
9. **Update the `current` marker.** `ln -sfn v<M> <tier>data/current`
   if the data version changed (Phase 2 only).
10. **Run a post-swap smoke probe.** Curl `<tier-url>/` and check
    for HTTP 200 + presence of the expected `Version <X> · build <N>`
    string. If the probe fails, *do not* auto-rollback (operator
    decision); print a clear "rollback command:" hint and exit
    non-zero.
11. **Done.** Print summary: release id, previous release id (the
    rollback target), data version pointed at, smoke-probe result.

Step 4 (the rsync) is the *only* network-bulky step and now never
touches live state — physically can't, because the rsync target
is a fresh release dir, not the live tree.

### Existing exclude rules

The `--max-delete=25`, the pre-flight dry-run grep, the
`user/accounts/***` etc. live-state excludes — all of these become
unnecessary under this model and the spec implementer is expected
to remove them at the same time as ripping out the in-place
rsync. Their replacement is "the live state literally isn't in the
rsync target directory, by construction." Keeping the safeguards
around in case of regression is acceptable as belt-and-braces, but
no longer load-bearing.

---

## Rollback command

`./deploy/rollback.sh <env>` (new file).

1. Read the previous-release id from
   `<tier>-releases/<current>/release-meta.yaml` (the `previous_release`
   field). Reject the rollback if the previous release is missing
   from `<tier>-releases/` (it was pruned past retention).
2. Confirm the previous release's data symlinks resolve. If the
   `v<earlier>` data dir was pruned (Phase 2), reject the rollback
   with a clear diagnostic naming what's missing.
3. `ln -sfn <tier>-releases/<previous-id> <tier>` — atomic swap
   back.
4. Run the post-swap smoke probe (same as deploy).
5. Append a rollback row to `<tier>-releases/<current-after-rollback>/release-meta.yaml`'s
   audit log (or write a sibling `rollback-log.yaml` — implementer's
   choice as long as it's discoverable).
6. Print summary: rolled back from <X> to <Y>, data version <Z>,
   smoke result.

Rollback is **manual-only** — there is no automatic rollback on
deploy failure. The deploy command's smoke-probe failure is loud
enough that an operator notices and runs the rollback command
themselves, knowing what's happening. Auto-rollback after a
mysterious failure has historically caused more confusion than it
solves.

A multi-step rollback ("two releases back") is out of scope. To go
further back than one release, run the rollback command, verify, then
run it again. Each step is its own decision.

### Rollback across schema versions (Phase 2)

Once the data-versioning spec ships, rollback that crosses a
schema bump uses `<tier>data/v<old>/`, which is preserved on
disk by the deploy that bumped to `v<new>`. Writes during the
v<new> window are forfeit (see §Versioned data dirs trade-off).

The rollback command does **not** roll the data-version backwards
in `<tier>data/current` — that's a one-way marker maintained for
ops visibility, not a binding constraint. The live tier's actual
data version is whatever the active release's symlinks point at.

---

## Retention

`<tier>-releases/` and `<tier>data/v<N>/` accumulate forever
without cleanup. A simple retention policy:

- **`<tier>-releases/`**: keep the last N (default 5) releases.
  Anything older is `rm -rf`ed by the deploy script after a
  successful new deploy. The two newest releases (current + immediate
  previous) are *never* eligible for cleanup, even if N=1.
- **`<tier>data/v<N>/`**: keep any version that *some retained
  release* points at. Anything no live release references can be
  pruned. Pruning is opt-in (`./deploy/prune-orphan-data.sh`),
  not part of every deploy, because it's destructive and worth a
  human checking the list.

---

## Audit

Every release dir gets `release-meta.yaml` at its root, written by
the deploy script during step 6 of the deploy sequence:

```yaml
release_id: 20260520T140000-abc1234
deployed_at: 2026-05-20T14:00:31Z
deployed_by: thomas@appforceone.dk           # from `git config user.email` on the deploy host
deployed_from:
  host: laptop-thomas-2024.local
  cwd: /Users/taa/AppForceOne/projects/workshop-site
  branch: develop
  sha: abc1234567890…
  sha_short: abc1234
  is_dirty: false                             # `git status --porcelain` was empty
code_version: "0.2.0"                         # apex/VERSION or config/www/VERSION as applicable
build: "247"                                  # git rev-list --count HEAD
data_version: "v0"                            # which <tier>data/v<N>/ this release symlinks at
previous_release: 20260519T180000-def5678     # the rollback target
previous_data_version: "v0"
swapped_at: 2026-05-20T14:00:34Z              # atomic-swap timestamp
swap_duration_ms: 23
smoke_probe:
  url: https://dev.hackersbychoice.dk/
  status: 200
  expected_version_substring: "Version 0.2.0 · build 247"
  matched: true
```

This file is the audit trail. `grep -r release_id <tier>-releases/`
gives you the full history; `cat <tier>/release-meta.yaml` tells
you what's currently live.

---

## One-time migration from the in-place layout

When this spec is first implemented, every existing tier
(dev/test/staging) is in the in-place layout. The migration script
(`./deploy/migrate-to-atomic-layout.sh <env>`) does the following on
the live tier, idempotently:

1. **Sanity check.** Refuse to proceed if the layout is already
   atomic (i.e., the docroot is already a symlink, or
   `<tier>-releases/` already exists with content).
2. **Take a backup snapshot** of the live tier (the existing
   `deploy/backup.sh`, even in its pre-spec state, suffices —
   we just need a recoverable copy).
3. **Create `<tier>data/v0/`** as a sibling of the docroot. Move
   the live state subtrees into it:
   - `user/accounts/`
   - `user/data/`
   - `user/config/security.yaml`
   - `user/env/<env>/config/security.yaml`
4. **Create `<tier>-releases/migrate-bootstrap-<timestamp>/`** as
   a sibling. Move the rest of the live tree into it (everything
   that was not state — code, themes, etc.). This becomes the
   first "release" in the new layout.
5. **Wire symlinks** from inside the bootstrap release dir to
   `<tier>data/v0/...` per §Symlink contract.
6. **Replace the original `<tier>` directory with a symlink** to
   the bootstrap release dir.
7. **Smoke-probe** the live URL.

Step 6 is the only window during which the live tier is briefly
offline (the time between deleting the old directory and creating
the symlink — single-digit seconds in practice).

The migration script is run once per tier, by hand, with the
operator watching. There is no rollback for the migration itself;
if it fails partway, recovery is "restore from the backup taken in
step 2" and try again.

After the migration runs, the next normal deploy ships into
`<tier>-releases/<new-timestamp>/` and the previous "release" (the
bootstrap) becomes the rollback target.

---

## Acceptance criteria

A reviewer or test must be able to confirm each of the following.

### Layout

- [ ] After a fresh atomic deploy, the docroot
      `<docroot-parent>/<tier>` resolves (via `readlink`) to a path
      under `<docroot-parent>/<tier>-releases/`.
- [ ] `<docroot-parent>/<tier>data/v0/` exists and contains the
      subtrees listed in §Layout, populated with that tier's
      actual user data.
- [ ] No release directory under `<tier>-releases/` contains real
      contents at the symlinked paths from §Symlink contract — they
      must be symlinks (`test -L`), not directories (`test -d -L`
      returns true; `test -d -h` would too — pick the right test
      for the implementer's shell).
- [ ] `<docroot-parent>/<tier>data/current` is a symlink whose
      target is the data-version dir the live release reads from.

### Per-tier isolation

- [ ] `<docroot-parent>/<tier1>data/` and
      `<docroot-parent>/<tier2>data/` are entirely independent —
      no symlinks in one cross into the other.
- [ ] An rsync against tier1's release dir or its data dir, run
      under any flags, has no path-resolution route into tier2's
      data.

### Deploy

- [ ] A fresh `./deploy/deploy.sh <env>` against an already-atomic
      layout produces a new dir under `<tier>-releases/`, leaves
      the previous one untouched, and atomically swaps the docroot
      symlink.
- [ ] During the rsync portion of the deploy, the `<tier>data/`
      tree is read-only from the deploy script's perspective —
      verified by checking that `<tier>data/`'s mtime does not
      change during step 4.
- [ ] If `php bin/grav cache --all` fails on the new release, the
      deploy aborts before the swap; the docroot symlink still
      points at the previous release.
- [ ] If the post-swap smoke probe fails, the deploy exits non-
      zero but leaves the new release live (operator decision
      whether to rollback).

### Rollback

- [ ] After a successful deploy, `./deploy/rollback.sh <env>`
      atomically swaps the docroot back to the previous release.
- [ ] Rollback is rejected with a clear diagnostic if the previous
      release directory has been pruned.
- [ ] After Phase 2 ships, rollback across a schema bump uses the
      preserved `v<old>` data dir; the rolled-back release reads
      its expected schema version.

### State preservation

- [ ] The April 2026 / May 2026 failure mode is structurally
      impossible: the rsync target is `<tier>-releases/<new>/`, a
      fresh empty dir; `<tier>data/` is not in the rsync's path
      tree at all.
- [ ] User accounts, flex objects, scheduler queue, and the two
      `security.yaml` files are bit-for-bit identical before and
      after a deploy that does not change the data version.

### Auditability

- [ ] Every release dir contains a `release-meta.yaml` matching
      the schema in §Audit.
- [ ] The current live release's `release-meta.yaml` is reachable
      at `<tier>/release-meta.yaml` (via the docroot symlink).
- [ ] After a rollback, the audit trail records who initiated the
      rollback and when.

### Migration from current layout

- [ ] `./deploy/migrate-to-atomic-layout.sh dev` against a current-
      layout dev tier produces an atomic layout, with all live
      data preserved and the smoke probe green.
- [ ] Re-running the migration script against an already-atomic
      tier exits non-zero with a clear "already migrated" message;
      it does not corrupt the layout.

### Tests

The repo's existing Playwright + shell-probe pattern (Sprint 3 of
SemVer) is the model. Acceptance:

- [ ] Shell-level probe (`tests/deploy/atomic-layout.sh`): builds
      a fake tier dir locally, runs through deploy + rollback +
      a Phase-2-stub schema-bump, asserts every invariant in this
      section. No remote ssh — entirely local rsync + ln + bash.
- [ ] Live HTTP smoke (extends the existing deploy script's step
      10): the deploy and rollback commands both run an end-to-end
      assertion against the live tier URL on success.

---

## Out-of-scope future work

These are noted so a future spec author has a record of what was
considered and deferred.

- **Blue-green deploys with health gating.** A more elaborate
  swap pattern that probes the new release before any user traffic
  hits it. Atomicity from a swap is enough for now.
- **Multi-region replication.** Not relevant on one.com shared
  hosting; mentioned only because it's a common follow-up.
- **Configuration drift detection.** A daemon that periodically
  diffs the live tier against its release dir and reports drift.
  Useful but not load-bearing.
- **Scheduled rollbacks.** "Rollback automatically if the smoke
  probe fails N times in M minutes." Worth considering once the
  manual workflow is well-trodden.
- **Pruning policy that survives long retention.** The current
  spec keeps N releases by count; a smarter policy would keep
  "every release for the last week, plus weekly snapshots beyond
  that." Out of scope until disk usage becomes a real constraint.
