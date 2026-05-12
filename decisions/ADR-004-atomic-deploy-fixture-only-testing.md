# ADR-004: Atomic-deploy testing — shell-level fixtures only, with documented gaps on the remote-side path

**Date:** 2026-05-10
**Status:** Accepted

---

## Context

The atomic-deploy releases work (ROADMAP step 3, [archived spec](../specifications/archive/atomic_deploy_releases_specification.md)) shipped under `/gan` automation. The GAN harness runs subagents inside a confinement hook that explicitly excludes `~/.gan-secrets/` and any path outside the per-run worktree, so the agents had no SSH credentials to a real remote and no way to exercise `deploy.sh`, `rollback.sh`, or `migrate-to-atomic-layout.sh` against the actual `dev`/`test`/`staging`/`prod` tiers during sprint runs.

The choice was: ship with no automated tests, OR ship with shell-level probes against `mktemp` fixtures that exercise the local primitives end-to-end without ssh. The second was picked. PR #17's 374 fixture-mode assertions cover the deploy/rollback/migrate behaviour structurally, including the load-bearing safety property (`<tier>data/` mtime invariance, bit-identity preservation, idempotence guards). The PR-#17 review (recorded in this run's transcript) flagged the implication: the SSH plumbing is not exercised by any test in the PR, and a regression in remote-side argument quoting would land silently. Findings 1 and 2 of the review are direct consequences of this gap.

## Decision

Atomic-deploy testing is **shell-level local-fixture probes only**. Real-remote runs are not part of the automated test suite and never reach the GAN harness. The properties under test are structural (path validation before shell use, no rsync/cp/rm of live state, single-`ln -sfn` swap, audit-trail completeness, refusal paths under bad input); the behavioural assertions run inside a `mktemp` parent-dir that mimics `<parent>/<tier>`, `<parent>/<tier>-releases/`, `<parent>/<tier>data/`. Every primitive that touches the remote is a thin wrapper around `bv_remote_run` (the post-PR-#17-review SSH dispatcher); the wrapper is exercised in fixtures via local-mode short-circuits (`BV_*_LOCAL_PARENT` env vars).

Consequence: regressions in `bv_remote_run` itself, or in any code that flows through the SSH path without a local-mode short-circuit, can land without breaking any test. The mitigations are:

- The static lint at `tests/deploy/lint-remote-ssh.sh` (added by the post-PR-#17 follow-up commits) refuses any new `remote_ssh "<...>"` string-built call site, any double-quoted `bv_remote_run` body, and any duplicate definition of the helper. This catches the most common form of the remote-side argument-quoting regression class.
- Code review of changes to `bv_remote_run`, `deploy.sh`'s `remote_*` paths, `rollback.sh`'s remote-mode branches, and `migrate-to-atomic-layout.sh`'s real-remote scaffolding (which is currently disabled by an explicit `exit 1` — see §Real-remote migration) is the second line of defence.
- Operator-supervised first runs against the dev tier are the third. Every new tier of automation must first be exercised by a human against `dev` before being trusted on `test`/`staging`/`prod`.

## Real-remote migration

`deploy/migrate-to-atomic-layout.sh` ships with real-remote mode disabled — the script refuses to run unless `BV_MIGRATE_LOCAL_PARENT` is set. The reasoning is the same as for the rest of this ADR: the GAN harness can't exercise the real-remote path, so shipping the SSH plumbing untested would be worse than shipping a script that's explicitly local-only.

The operator workaround for migrating a real tier today:

1. `rsync -a` the live tier's contents down to a local fixture parent directory.
2. Run `BV_MIGRATE_LOCAL_PARENT=<that-dir> ./deploy/migrate-to-atomic-layout.sh <env>`.
3. `rsync -a` the resulting atomic-layout tree back up to the remote, taking care to preserve symlinks (`-l`, included in `-a`) and the relative-target shape of the `<tier>` symlink.
4. The pre-flight `deploy.sh <env>` will then refuse to deploy unless the docroot is a symlink — confirming the migration landed correctly.

This is a documented procedure, not a hidden gap. A future ADR-NNN may supersede this if/when the SSH plumbing for real-remote migration ships.

## Alternatives considered

- **Skip automated tests entirely.** Rejected: the local-fixture probes catch a class of regressions (off-by-one in symlink targets, broken release-id validation, `--max-delete=0` removal, retention pruner overreach) that would otherwise land blind. 374 assertions is real signal even if the SSH layer is unmeasured.
- **Provide a vault for `~/.gan-secrets/` so the GAN harness can exercise real remotes.** Rejected for now: the framework's confinement hook deliberately excludes `~/.gan-secrets/` to prevent agents from leaking credentials via prompt or filesystem trace. Plumbing a vault that's accessible to agents but invisible to logging is a larger framework change (would need T1 run-trace integration and a per-tier throwaway tier on the actual hosting). Worth revisiting after T1 and U-series UX work lands.
- **Ship the real-remote migration plumbing without a fixture for it.** Rejected: shipping untested code that touches live PII (the migration moves `accounts/`, `user/data/`, the two `security.yaml` files) is a worse failure mode than shipping a script that's explicitly local-only.

## Consequences

- **Positive:** the safety properties of the atomic-deploy work (the April/May 2026 wipe class becoming structurally impossible) are testable and tested. PR review of any change to deploy/rollback/migrate has a precise structural bar to clear.
- **Constraint:** any future change to `bv_remote_run` or to remote-mode code paths must be paired with either (a) an extension to `tests/deploy/lint-remote-ssh.sh`, (b) a manual test plan run against dev, or (c) an ADR explaining why the change is safe to land without the above.
- **Constraint:** the migration script is operator-only by design. Removing the `tier=prod` refusal in `make migrate-atomic`, or adding any Make target that lets the prod migration run without operator interaction, is a regression of this decision and must be rejected at PR review.
- **Constraint:** any spec that ships real-remote testing infrastructure (vault, throwaway tier, etc.) supersedes this ADR's "fixture-only" stance and should be recorded as ADR-NNN with a `Status: Superseded by ADR-NNN` link added here.
