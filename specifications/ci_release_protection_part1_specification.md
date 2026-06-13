# Specification — CI release protection, Part 1: PR validation & merge guards

Status: Planned
Owner: thomas@appforceone.dk
Depends on:
- The release-safety tooling shipped in `1.1.0` — `deploy/lib/release-flow.sh`
  (`bv_count_commits_ahead`), `deploy/lib/release-gate.sh` (`bv_promotion_gate`),
  `deploy/lib/version-bump.sh` (`bv_bump_semver`), and `make test-deploy`.
- GitHub Actions (already in use — see `.github/workflows/migrations.yml`).

Scope: A no-secrets GitHub Actions workflow that (a) runs the deploy
test suite on every pull request and (b) enforces the release-branch,
version, and tag invariants on PRs **into `main`** — moving the cheap
checks that today live only in the local `make` tooling "left" to the
PR, so they hold regardless of who merges or how. This is the first of
a three-part CI series; everything that needs a secret (tagging on
merge, and deploys) is deliberately deferred to Parts 2 and 3.

> **Deadlock safety is a first-class requirement.** A required check
> that the current tree cannot satisfy freezes *every* PR. Two rules
> make this safe: (1) the back-merge check is **advisory only** — it
> reports, it never fails — because a pending `main → develop`
> back-merge is a real condition that must not block unrelated work;
> (2) the PR that *introduces* this workflow is not gated by it, because
> for `pull_request` events GitHub reads the workflow from the **base**
> branch, which won't carry it until this spec merges. See
> [Deadlock safety](#deadlock-safety).

---

## Motivation

Every release invariant we enforce today — "prod/staging ship from a
clean `main`", "a release carries a bumped version and an annotated
tag", "don't start a release while a back-merge is pending" — lives in
the local `make` tooling (`bv_promotion_gate`, `release-start`,
`tag-release`). That tooling protects the operator's machine. It does
**nothing** for a change merged through the GitHub UI: a maintainer can
open a PR straight from a feature branch into `main`, with an unbumped
version and no release branch, and merge it with two clicks. The local
gates never run.

The `1.1.0` cleanup (June 2026) is the cautionary tale: `develop` had
silently fallen 30 commits behind `main`, the `VERSION` file disagreed
with the tags, a stray lightweight tag floated in history, and a
mistaken `main`-as-PR-head merge even deleted `main`. None of that was
caught at merge time because nothing runs at merge time.

Part 1 closes the cheapest, highest-value gap: run the hermetic test
suite and the release invariants **on the PR**, as required status
checks, so the rules hold for every merge path. It ships nothing that
needs a credential, so it carries no deploy-blast-radius risk and can
land immediately.

---

## Non-goals

- **No deploys, no secrets.** Part 1 never connects to a host, never
  reads `.env.deploy`, never touches the live tiers. Deploys from CI
  are Part 3 (and require the secrets-migration + runner-network work).
- **No auto-tagging or auto-back-merge.** Creating the `v<VERSION>` tag
  on merge to `main`, and opening the `main → develop` back-merge PR,
  are Part 2 (they need a write-scoped token). Part 1 only *checks*.
- **Not a replacement for the local gates.** `bv_promotion_gate` and
  the `release-start` guards still run on the operator's machine. CI is
  defense in depth — both run; neither is removed.
- **Does not gate `dev`/`test` deploys.** Those are ungated by design
  (any branch); Part 1 changes nothing about them.
- **Does not configure the `main` ruleset.** Marking checks "required"
  and restricting who may merge into `main` is a GitHub repository
  setting, performed by a maintainer; this spec documents the required
  setting but cannot apply it from a workflow.

---

## The workflow

A single workflow file, `.github/workflows/ci-release-guards.yml`, on a
standard Linux runner, with three jobs. No job uses `secrets`, a
deploy credential, or Docker.

| Job | Runs on | Purpose | Can be required? |
|---|---|---|---|
| `test-deploy` | `pull_request` (any base) + `push` to `develop`/`main` | Runs `make test-deploy` | **Yes** |
| `release-pr-guard` | `pull_request` with **base = `main`** | Enforces the release invariants | **Yes** |
| `backmerge-advisory` | `pull_request` with base = `main` | Reports the `main`↔`develop` gap | **No — always informational** |

### `test-deploy`

- `actions/checkout` (default depth is sufficient — `make test-deploy`
  is hermetic; every probe initialises its own throwaway git fixtures
  and touches no network, no Docker, no credentials).
- Runs `make test-deploy`. The job fails iff any probe fails.
- This is the same suite that gates local commits; running it in CI
  makes "the deploy tooling is green" a property of the PR.

### `release-pr-guard`

Runs only when the PR's base branch is `main`. Reads the PR's head
branch name and the PR head's `VERSION` files, compares against the
base (`main`), and asserts **all** of the following, reporting every
failure (not just the first) before exiting non-zero:

1. **Head is a release branch.** `github.head_ref` matches
   `release/*` or `hotfix/*`. Anything else (a feature branch, a bare
   `develop`, `main` itself) fails with a message naming the rule.
2. **Component resolves from the branch.** `release/v*` /
   `hotfix/v*` → the Grav site (`config/www/VERSION`, tag namespace
   `v*`); `release/landing-v*` / `hotfix/landing-v*` → the landing page
   (`apex/VERSION`, tag namespace `landing-v*`).
3. **Version is a clean release SemVer.** The resolved `VERSION` file on
   the PR head matches `^[0-9]+\.[0-9]+\.[0-9]+$` — i.e. it carries **no
   pre-release suffix**. A `-dev`/`-rc.N` version is a development
   value and must be finalised before it reaches `main`.
4. **Version is bumped.** The PR head's `VERSION` is strictly greater
   (SemVer-ordered) than the base `main`'s current `VERSION` for the
   same component.
5. **Tag is free.** No tag (annotated or lightweight) named
   `<prefix><VERSION>` already exists on the remote — so a version that
   has already shipped cannot be re-released.

### `backmerge-advisory`

- Computes `bv_count_commits_ahead origin/develop origin/main` (commits
  on `main` not yet in `develop` — the pending back-merge count) using
  the shipped helper.
- Posts the result to the job summary. **Always exits 0.** It surfaces
  the condition `release-start` refuses on locally, without ever
  blocking a PR — see [Deadlock safety](#deadlock-safety).

---

## Deadlock safety

A required check that the repository's current state cannot satisfy is
a deadlock: it fails on every PR, including the PR that would fix the
condition. Part 1 is designed so this cannot happen.

- **The back-merge check never blocks.** When `main` is ahead of
  `develop` (a routine, transient post-release state), making that a
  required check would fail every open PR — including the back-merge PR
  itself. So `backmerge-advisory` is informational forever; the *hard*
  back-merge enforcement stays in `release-start` (cutting a release),
  where blocking is correct and local.
- **The release-PR guard is satisfiable from any clean state.** Its
  invariants (release-branch head, bumped clean SemVer, free tag) can
  always be met by cutting a `release/*` branch with `make
  release-start` and choosing a version above `main`'s current and any
  existing tag. It only runs on PRs into `main`, so no feature→develop
  PR is affected.
- **The introducing PR is not self-gated.** For `pull_request` events
  GitHub evaluates the workflow file from the **base** branch. Until
  this spec merges to `develop` (and later `main`), neither carries the
  workflow, so the PR that adds it runs no new checks. After it merges,
  subsequent PRs are evaluated against the merged result. There is no
  bootstrap cycle.

---

## Determinism precondition (before any check is marked "required")

A required check must be deterministic; a flaky required check is a
deadlock vector. `tests/deploy/migrate.sh` currently contains a
timing-sensitive assertion that compares `release-meta.yaml`'s mtime to
the docroot symlink's mtime at 1-second granularity, and fails
intermittently when the two land in different seconds. **Part 1
includes hardening that assertion** (compare with a tolerance, or order
the writes deterministically) so `make test-deploy` is reproducibly
green before the `test-deploy` job is promoted to a required check.

---

## Rollout (staged, so nothing is surprised by a new gate)

1. **Land non-required.** Merge the workflow. All three jobs run on new
   PRs and report status, but none is a *required* status check, so no
   merge is blocked.
2. **Observe green.** Confirm `test-deploy` and `release-pr-guard` pass
   on real PRs across the active branches.
3. **Flip to required.** A maintainer marks `test-deploy` and
   `release-pr-guard` as required status checks in the `main` (and, for
   `test-deploy`, `develop`) branch protection / ruleset.
4. **`backmerge-advisory` stays non-required permanently.**

The required-status configuration in step 3, and the complementary
ruleset that restricts `main` merges to PRs whose head is
`release/*`/`hotfix/*`, are GitHub settings a maintainer applies — this
spec specifies them but a workflow cannot enforce them on itself.

---

## Acceptance criteria

### `test-deploy` job

- [ ] On a PR that leaves the deploy tooling green, the `test-deploy`
      job runs `make test-deploy` and the job concludes success.
- [ ] On a PR that breaks a deploy probe, the `test-deploy` job
      concludes failure and names the failing probe in its log.
- [ ] The job uses no `secrets`, no Docker, and no network beyond the
      `actions/checkout` of the repo (greppable: the job's steps
      reference neither `secrets.` nor a deploy host).
- [ ] `tests/deploy/migrate.sh`'s mtime-ordering assertion no longer
      depends on 1-second wall-clock granularity: running
      `make test-deploy` 20 times in a row is green every time.

### `release-pr-guard` job

- [ ] A PR `feature/x → main` (non-release head) fails the guard with a
      message stating that `main` accepts only `release/*`/`hotfix/*`.
- [ ] A PR `release/v1.3.0 → main` whose `config/www/VERSION` is
      `1.3.0` (bumped above `main`, clean SemVer, no `v1.3.0` tag yet)
      passes the guard.
- [ ] A PR whose head `config/www/VERSION` is `1.3.0-dev` fails with a
      "pre-release version must be finalised" message.
- [ ] A PR whose head `VERSION` equals or is lower than `main`'s
      current `VERSION` fails with a "version not bumped" message.
- [ ] A PR proposing a `VERSION` whose tag `v<VERSION>` already exists
      (annotated or lightweight) fails with a "tag already exists"
      message.
- [ ] A `release/landing-v0.3.0 → main` PR is evaluated against
      `apex/VERSION` and the `landing-v*` tag namespace (not the Grav
      site's).
- [ ] The guard reports *all* violations of a multiply-broken PR in one
      run, then exits non-zero.
- [ ] The guard does not run on PRs whose base is `develop` (a
      `feature → develop` PR shows no `release-pr-guard` check).

### `backmerge-advisory` job

- [ ] When `main` is ahead of `develop`, the job reports the pending
      back-merge count in its summary and **still concludes success**
      (it is never a failing check).
- [ ] When `main` is not ahead of `develop`, the job reports `0` and
      concludes success.
- [ ] The job is not configured as a required status check.

### Deadlock safety & rollout

- [ ] The PR that introduces `ci-release-guards.yml` is itself not
      evaluated by `release-pr-guard` or `test-deploy` (the base branch
      — `develop` — does not yet carry the workflow).
- [ ] With the workflow merged but no check marked required, a PR can
      still be merged even if a job reports failure (jobs are advisory
      until a maintainer flips them).
- [ ] Documentation in the workflow or repo records the exact branch
      protection / ruleset settings a maintainer must apply for step 3
      of the rollout (required checks + `release/*`/`hotfix/*`-only
      merges into `main`).

---

## Out-of-scope future work

- **Part 2 — automation on merge to `main`.** Auto-create the annotated
  `v<VERSION>` tag and auto-open the `main → develop` back-merge PR on
  merge. Needs a write-scoped token; deferred so Part 1 stays
  secret-free.
- **Part 3 — CI deploys.** Run `make deploy tier=staging`/`prod` from
  CI, gated by a `production` Environment with required reviewers.
  Needs the `.env.deploy`/SSH/age secrets migrated into Environment
  secrets and runner network reachability to the hosts.
- **Hardening the `main` ruleset itself.** The `1.1.0` incident showed
  `main` was deletable and accepted direct pushes. Tightening the
  ruleset is a GitHub-settings task tracked separately from this
  workflow.
