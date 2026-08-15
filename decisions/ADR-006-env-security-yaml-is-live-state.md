# ADR-006: The per-host env `security.yaml` is live state the deploy must seed, not a file Grav can be trusted to create

**Date:** 2026-08-15
**Status:** Accepted

---

## Context

Grav resolves its environment from the request Host header, so production reads `user/env/www.byvaerkstederne.dk/config/`. That directory's `security.yaml` holds the salt every session, remember-me token and nonce on the tier is bound to. It is gitignored — a per-tier secret — so a release never carries one, and the §Symlink contract makes the release's copy a symlink into `<tier>data/<vdir>/`.

On 2026-08-14 the v1.2.0 deploy shipped the fix that renamed the env dir from the short tier name (`env/prod/`) to the host name. The wiring then replaced prod's real `env/www.byvaerkstederne.dk/config/security.yaml` — a leftover that had been quietly serving the tier — with a symlink into a data-dir path nobody had ever seeded. Grav's `Setup::check()` writes the salt when it is missing; writing through a dangling symlink threw before any page rendered, and production returned 500 on every request until the file was placed by hand.

Eight deploy steps stayed green. Step 7 (`bin/grav clearcache`) is the one that was supposed to catch this — the code comment said so — but the CLI has no HTTP Host, so it never resolves a per-host env at all and exits 0 on a tier that is already broken for every browser. The post-swap smoke probe caught it, after the swap, with no auto-rollback.

## Decision

The env `security.yaml` is treated as **live state the deploy is responsible for**, on the same footing as `user/accounts` and `user/data` — not as a file Grav will conjure on demand.

Concretely, `deploy.sh` now seeds it before wiring and verifies it after:

1. **Seed** (`bv_seed_security_salt`) — if the data dir has no salt for this host, take the previous release's real file when there is one (preserving the salt, so live sessions survive a layout change), otherwise generate `salt: <32 hex>`. An existing salt is never overwritten.
2. **Verify** (`bv_verify_release_state_symlinks`) — after wiring and **before the atomic swap**, every §Symlink-contract link must resolve. A dangling one aborts the deploy while the old release is still serving.

`email.yaml` stays outside the must-resolve set: it is operator-provisioned and its absence degrades mail without stopping boot (the ABSENT-FILE CONTRACT), so it keeps its non-fatal WARN.

The library's helpers now accept a **host-shaped** env dir name (`bv_validate_env_dir_name`) instead of demanding a tier name. That mismatch is why no test could have caught this: fixtures exercised `user/env/staging/` while the deploy wrote `user/env/staging.hackersbychoice.dk/`.

## Alternatives considered

- **Rely on Grav to regenerate the salt** — the status quo, and the assumption written into the old code comment. It only holds when the write can land; through a dangling symlink it is a fatal `RuntimeException`. Grav also cannot know the salt the tier was already using, so even a successful regeneration logs every member out.
- **Make the CLI cache-clear the gate** — it cannot be. `bin/grav clearcache` has no Host, so it never touches the per-host env; it passed on the broken release. Any check that depends on the CLI resolving an env is checking the wrong environment.
- **Auto-rollback when the smoke probe fails** — treats the symptom, and does so after real users have seen 500s. Worth having eventually, but it is not a substitute for refusing to swap a release that provably cannot boot. Left as separate work.
- **Commit the env `security.yaml` to git** — makes the deploy trivially correct and puts a per-tier secret in the repo, shared across every tier and every clone. Rejected outright.
- **Generate a fresh salt whenever one is missing** — simpler than the fallback chain, and it would have restored service on 2026-08-14 at the cost of invalidating every session and remember-me token on the tier. Preferring the previous release's file makes the common case (a layout change on a running tier) invisible to members.

## Consequences

- A deploy that would produce an unbootable release now fails **before** the swap, with the old release still live. The failure names the offending link.
- Any file added to the §Symlink contract must be classified: fatal-to-boot (seed it and add it to the verify set) or degrade-only (WARN, like `email.yaml`). "Grav will create it" is not a classification.
- Salt provenance is recorded in the deploy log — migrated, generated, or already present — so a later session-invalidation question has an audit trail.
- Fixture tests now model the host-named env dir the deploy actually writes. Fixture-only testing (ADR-004) still cannot exercise the remote path; the inline remote body in `deploy.sh` mirrors the library functions and the two must be changed together.
- **Known gap:** the rollback gate (`bv_check_previous_release_data_symlinks`) still checks only `accounts`, `data` and `logs`. Extending it to the env salt needs a tier→host map in `rollback.sh`, which this change does not build. Practically the exposure is small — the data-dir file now persists across releases — but a rollback to a release wired for a different env dir name is not gated.
