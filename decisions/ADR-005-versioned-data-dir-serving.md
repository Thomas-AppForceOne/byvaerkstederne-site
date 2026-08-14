# ADR-005: Versioned-data-dir SERVING — releases bind to the data-version dir `current` targets at deploy time

**Date:** 2026-06-14
**Status:** Accepted

---

## Context

The atomic-release machinery wired every release's `user/` data symlinks
(accounts, data, the two `security.yaml` files) to a hardcoded
`<tier>data/v0/...`, in both `bv_wire_release_symlinks` and `deploy.sh`'s
inline Step-5 copy. The data-versioning layer already created versioned
dirs (`v_0_2_0` etc.) and a `<tier>data/current` pointer, but nothing
ever served them: a release always read from `v0` regardless of where
`current` pointed. `promote-to-staging.sh` therefore could not serve a
migrated, versioned snapshot — it had to overwrite `v0` in place
(risk-mitigated interim behaviour), so versioned dirs were dead weight
and a versioned promote was impossible.

## Decision

A release binds to the data-version dir that `<tier>data/current` points
at **at deploy time**. `current` is the live pointer; a release's
symlinks are wired to `<tier>data/<vdir>/...` where `<vdir> =
basename(readlink current)` (falling back to `v0`). Those symlinks are
written once, at deploy, and stay pinned to that dir for the life of the
release.

`promote-to-staging.sh` activates a versioned snapshot by building a
**complete** `v_<target>` data dir and repointing `current` at it
**before** the code deploy:

1. `CURRENT_VDIR = basename(readlink current)` (`v0` fallback).
2. `VDIR = bv_version_to_dirname(TARGET_VERSION)` (`0.2.0` → `v_0_2_0`).
3. Build `<VDIR>` so it carries the per-tier secrets/config/env, then
   overlay the migrated `accounts/data/pages/uploads` via per-subdir
   `rsync --delete`. Three cases by how `<VDIR>` relates to the live dir:
   - **`CURRENT_VDIR == VDIR`** (a re-promote at the same `data_version`
     — the steady-state code-only release): the target IS the live dir,
     so it is refreshed **in place**. It is never `rm`'d (doing so would
     delete the live data dir and, with no source left to copy from,
     destroy `user/config`'s secrets); the overlay touches only the four
     state subdirs, so the secrets are preserved untouched.
   - **`CURRENT_VDIR != VDIR`, `<CURRENT_VDIR>` exists**: `cp -a
     <CURRENT_VDIR> <VDIR>` to inherit the secrets, then overlay. Any
     pre-existing `<VDIR>` here is a stale build (not what `current`
     points at), so it is `rm`'d first.
   - **Fresh tier** (no `<CURRENT_VDIR>`): `mkdir` the `<VDIR>/user`
     skeleton, then overlay.
4. `ln -sfn <VDIR> current`.
5. `deploy.sh staging --skip-data-migration` — wires the new release to
   `<VDIR>`.

Rollback is safe because each release keeps its own symlinks pinned to
the dir it deployed with. A later promote only ever `rm`s a `<VDIR>`
that `current` does NOT point at (a stale build); the dir `current`
points at is refreshed in place, never deleted. Data rollback is
therefore automatic on the docroot swap; `rollback.sh` additionally
repoints `current` for bookkeeping, resolving the rolled-back release's
vdir from its `user/accounts` symlink target (authoritative) or, failing
that, its `release-meta.yaml` `data_version`. If neither resolves to a
safe single-component dir name, it warns and skips rather than guess.

`<vdir>` is validated as a single, non-empty, traversal-free path
component before it is concatenated into any `ln`, `cp`, `rm`, or `rsync`
target. The `logs` symlink stays **unversioned** (`<tier>data/logs`).

This supersedes the interim "refresh `v0` in place" behaviour in
`promote-to-staging.sh`.

## Alternatives considered

- **Keep `v0`-in-place (the interim behaviour)** — rejected. It makes
  versioned data dirs and the `current` pointer inert, so a promote
  cannot serve a versioned, migrated snapshot and rollback across a
  schema bump has no distinct data dir to fall back to. It was only ever
  a stopgap to avoid touching the April-2026 wipe-class code path.
- **Resolve `current` at request time (Grav reads `current` on each
  request)** — rejected. It would couple every release to whatever
  `current` happens to be now, breaking rollback isolation: rolling the
  docroot back would not roll the data back, because the live release and
  the rolled-back release would share one mutable pointer. Binding at
  deploy time keeps each release's data view immutable.
- **Symlink the release's `user/accounts` etc. directly at
  `current`** — rejected for the same isolation reason, and because a
  dangling/edited `current` would then dangle every release at once.

## Consequences

- For every existing tier whose `current → v0`, behaviour is
  byte-identical: `VDIR` resolves to `v0` and the wiring/mv/meta are
  unchanged. The model only diverges once `current` moves (post-promote).
- `bv_wire_release_symlinks` gains an optional 4th `vdir` arg (default
  `v0`); 3-arg callers are unchanged. `deploy.sh` resolves `VDIR` inside
  its remote bodies (the pointer lives on the remote) and records the
  bound dir as `release-meta.yaml` `data_version`.
- Promote's destructive operations (`rm -rf` of a stale `<VDIR>` that
  `current` does NOT point at, per-subdir `rsync --delete` overlay) are
  string-rooted under `DATA_ROOT` with `VDIR` validated non-empty,
  quoted, and never run against an empty variable — the wipe-class
  invariants from the atomic-release library are preserved. The dir
  `current` points at is never `rm`'d.
- The per-tier secrets in `<vdir>/user/config` and
  `<vdir>/user/env/<env>/config` are preserved across every promote: by
  the `cp -a` when building a new dir, and by the in-place refresh when
  the target is already current. The overlay touches only the four state
  subdirs, never `user/config`.
- Versioned data dirs accumulate; retention/pruning of old
  `<tier>data/v_*` dirs remains out of scope (still deferred, as noted in
  `bv_prune_old_releases`).
