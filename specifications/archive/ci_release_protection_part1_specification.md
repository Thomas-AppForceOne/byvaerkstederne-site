# Specification — CI release protection, Part 1: PR validation & merge guards

Status: Planned
Owner: thomas@appforceone.dk
Depends on:
- The release-safety tooling shipped in `1.1.0` — `deploy/lib/release-flow.sh`
  (`bv_count_commits_ahead`), `deploy/lib/release-gate.sh` (`bv_promotion_gate`),
  `deploy/lib/version-bump.sh` (`bv_bump_semver`), and `make test-deploy`.
- A SemVer **comparison** primitive for `release-pr-guard` rule 4. The repo's
  only comparator today, `semver_compare`, lives *inside* `deploy/migrate.sh`
  and is not separately sourceable; `bv_bump_semver` bumps but cannot compare.
  Part 1 therefore extracts a sourceable `bv_semver_compare` (prints `-1|0|1`)
  into `deploy/lib/` (e.g. `version-bump.sh`), with unit coverage for
  lower/equal/higher, callable only on clean `X.Y.Z` values.
- GitHub Actions (already in use — see `.github/workflows/migrations.yml`).

Scope: Two no-secrets GitHub Actions workflows that (a) run the deploy
test suite on every pull request and (b) enforce the release-branch,
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
> (2) the PR that *introduces* these workflows is not gated by them,
> because for `pull_request` events GitHub reads the workflow files from
> the **base** branch, which won't carry them until this spec merges. See
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

Two workflow files under `.github/workflows/`, both on a standard Linux
runner. No job uses `secrets`, a deploy credential, or Docker.

| Job | File | Runs on | Purpose | Can be required? |
|---|---|---|---|---|
| `test-deploy` | `ci-test-deploy.yml` | `pull_request` (any base) + `push` to `develop`/`main` | Runs `make test-deploy` | **Yes** |
| `release-pr-guard` | `ci-release-guards.yml` | `pull_request` scoped to **base = `main`** | Enforces the release invariants | **Yes — on `main` only** |
| `backmerge-advisory` | `ci-release-guards.yml` | `pull_request` scoped to base = `main` | Reports the `main`↔`develop` gap | **No — always informational** |

The two-file split is deliberate. The `main`-only guards must be
**absent** — not merely *skipped* — on a `feature → develop` PR, so they
live in their own file scoped at the **trigger**: `on: pull_request:
branches: [main]`, which filters on the PR's *base* branch and so does
not run the workflow at all for a `develop`-based PR. A single file with
a job-level `if: github.base_ref == 'main'` would instead surface a
*skipped* check named `release-pr-guard` on every `develop` PR — clutter
that also muddies required-check configuration (a skipped required check
reads as neutral, but it still appears in the list). `test-deploy` runs
on PRs of any base, so it sits in its own always-on file.

### `test-deploy`

- `actions/checkout` (default depth is sufficient — `make test-deploy`
  is hermetic; every probe initialises its own throwaway git fixtures
  and touches no network, no Docker, no credentials).
- Runs `make test-deploy`. The job fails iff any probe fails.
- This is the same suite that gates local commits; running it in CI
  makes "the deploy tooling is green" a property of the PR.

### `release-pr-guard`

Runs only on PRs whose base branch is `main` (enforced at the trigger —
see the two-file split above). Reads the PR head's branch name and
`VERSION` files, compares against the base (`main`), and asserts the
following, reporting every *applicable* failure (not just the first)
before exiting non-zero:

1. **Head is a release branch.** `github.head_ref` matches
   `release/*` or `hotfix/*`. Anything else (a feature branch, a bare
   `develop`, `main` itself) fails with a message naming the rule.
2. **Component resolves from the branch.** The head matches one of two
   component globs — matched as **shell globs**, so the `[0-9]` pins the
   character right after `v` (rejecting e.g. `release/version-foo`)
   while `*` absorbs the dotted SemVer remainder: `release/v[0-9]*` /
   `hotfix/v[0-9]*` → the Grav site (`config/www/VERSION`, tag namespace
   `v*`); `release/landing-v[0-9]*` / `hotfix/landing-v[0-9]*` → the
   landing page (`apex/VERSION`, tag namespace `landing-v*`). A
   `release/*`/`hotfix/*` head that matches neither glob fails with a
   "cannot resolve component" message. The globs are a coarse gate; the
   strict SemVer shape is rule 3. (Implement the match in the job's
   shell — `case`/`[[ == ]]` — not as a regex; under regex semantics
   `[0-9]*` means "zero or more digits" and the pattern means something
   else entirely.)
3. **Version is a clean release SemVer.** The resolved `VERSION` file on
   the PR head matches `^[0-9]+\.[0-9]+\.[0-9]+$` — i.e. it carries **no
   pre-release suffix**. A `-dev`/`-rc.N` version is a development
   value and must be finalised before it reaches `main`.
4. **Version is bumped.** The PR head's `VERSION` is strictly greater
   (SemVer-ordered) than the base `main`'s current `VERSION` for the
   same component. This rule **presupposes rule 3**: it is evaluated
   only when the head `VERSION` is a clean release SemVer, so the
   comparator never sees a `-dev`/`-rc.N` value (it handles only the
   `X.Y.Z` numeric core and would error on a suffix). If rule 3 failed
   for the component, rule 4 is reported as "not evaluated — version is
   not a clean release SemVer" rather than run on bad input.
5. **Tag is free.** No tag (annotated or lightweight) named
   `<prefix><VERSION>` already exists on the remote — so a version that
   has already shipped cannot be re-released.

**Checkout requirements.** Unlike `test-deploy`, this job is *not*
hermetic: rule 4 needs the base `main`'s `VERSION` and rule 5 needs the
remote tag list. The default `actions/checkout` for a `pull_request`
event is a shallow checkout of the merge ref **with no tags**, which
provides neither. Check out with `fetch-depth: 0` (or fetch explicitly:
`git fetch origin main` and `git fetch --tags`).

`hotfix/*` is accepted as a convention. No command creates hotfix
branches today — a maintainer cuts one by hand off `main` — but the
guard only ever *validates* the head a PR presents, so Part 1 needs no
hotfix-creation tooling.

### `backmerge-advisory`

- Computes `bv_count_commits_ahead <repo> origin/develop origin/main`
  (commits on `main` not yet in `develop` — the pending back-merge
  count) using the shipped helper. Note the helper takes the repo path
  as its first argument (`bv_count_commits_ahead <repo> <base> <tip>`),
  so pass the checkout dir (e.g. `"$GITHUB_WORKSPACE"` or `.`); this
  also means the job must `git fetch` `origin/develop` and `origin/main`
  first, as they are not present in the default `pull_request` checkout.
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
  GitHub evaluates the workflow files from the **base** branch. Until
  this spec merges to `develop` (and later `main`), neither carries the
  workflows, so the PR that adds them runs no new checks. After it
  merges, subsequent PRs are evaluated against the merged result. There
  is no bootstrap cycle.

---

## Determinism precondition (before any check is marked "required")

A required check must be deterministic; a flaky required check is a
deadlock vector. `tests/deploy/migrate.sh` asserts the ordering of
`release-meta.yaml`'s mtime against the docroot symlink's mtime
(`META_MTIME <= DOCROOT_MTIME`). The assertion has been observed to fail
intermittently — but the cause is **not** the obvious "1-second
granularity". The check is already inclusive (`<=`), and because the
meta file is written before the swap, `floor(meta) <= floor(docroot)`
holds across any second boundary; granularity alone cannot make it fail.
The likely real mechanism is that an atomic symlink swap stamps the
symlink's mtime at **creation** (the `ln -s`), which can precede the
meta write, so `DOCROOT_MTIME` lands *before* `META_MTIME` — an ordering
inversion that only surfaces when the two cross a whole-second boundary.

**Part 1 includes hardening this assertion, but the implementer must
first reproduce the flake and capture the actual failing values**
(`meta=… docroot=…`); the correct fix depends on the true cause, and a
blind "add a tolerance" would either be a no-op (the check is already
`<=`) or silently weaken a real invariant. Acceptable fixes once the
cause is confirmed: compare against the recorded swap timestamp rather
than the symlink's inode mtime, have the writer touch `release-meta.yaml`
after the swap, or stat the swap event itself. The bar is the acceptance
criterion below — `make test-deploy` green 20× in a row — and that bar
is met by a fix grounded in the captured evidence, not by guesswork.

---

## Rollout (staged, so nothing is surprised by a new gate)

1. **Land non-required.** Merge both workflows. All three jobs run on
   new PRs and report status, but none is a *required* status check, so
   no merge is blocked.
2. **Observe green.** Confirm `test-deploy` and `release-pr-guard` pass
   on real PRs across the active branches.
3. **Flip to required.** A maintainer marks `test-deploy` and
   `release-pr-guard` as required status checks on `main`, and
   `test-deploy` (only) on `develop`. **Do not mark `release-pr-guard`
   required on `develop`:** its workflow is trigger-scoped to
   `branches: [main]`, so it never runs on a `develop`-based PR, and
   GitHub leaves a required-but-never-reported check pending forever —
   freezing every `develop` PR. That is the same deadlock class the rest
   of this spec guards against, surfacing in the branch-protection
   config rather than in a workflow.
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
- [ ] `tests/deploy/migrate.sh`'s mtime-ordering assertion is
      deterministic regardless of where the meta write and the symlink
      swap fall relative to a wall-clock second boundary: running
      `make test-deploy` 20 times in a row is green every time. The fix
      is justified by captured failing values, not guesswork (see
      [Determinism precondition](#determinism-precondition-before-any-check-is-marked-required)).

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
- [ ] A `hotfix/v1.2.4 → main` PR resolves the Grav component
      (`config/www/VERSION`, `v*` tag namespace) exactly as a
      `release/v*` head does.
- [ ] A `release/version-foo → main` PR (a `release/*` head that matches
      neither component glob) fails with a "cannot resolve component"
      message.
- [ ] The rule-4 bump check uses a sourceable `deploy/lib` SemVer
      comparator with unit tests for lower, equal, and higher inputs,
      and is never invoked on a pre-release value (rule 4 is reported
      "not evaluated" when rule 3 fails for that component).
- [ ] The job fetches the base ref and tags rather than relying on the
      default shallow merge-ref checkout — it catches an already-used
      tag that the default tag-less checkout would miss.
- [ ] The guard reports *all* applicable violations of a multiply-broken
      PR in one run, then exits non-zero.
- [ ] The guard does not run on PRs whose base is `develop`: a
      `feature → develop` PR shows **no `release-pr-guard` check at all**
      — not even a skipped one — because the guards workflow is
      trigger-scoped to base `main`.

### `backmerge-advisory` job

- [ ] When `main` is ahead of `develop`, the job reports the pending
      back-merge count in its summary and **still concludes success**
      (it is never a failing check).
- [ ] When `main` is not ahead of `develop`, the job reports `0` and
      concludes success.
- [ ] The job is not configured as a required status check.

### Deadlock safety & rollout

- [ ] The PR that introduces `ci-test-deploy.yml` / `ci-release-guards.yml`
      is itself not evaluated by `release-pr-guard` or `test-deploy` (the
      base branch — `develop` — does not yet carry the workflows).
- [ ] With the workflows merged but no check marked required, a PR can
      still be merged even if a job reports failure (jobs are advisory
      until a maintainer flips them).
- [ ] `release-pr-guard` is not marked a required check on `develop` (it
      never runs there; a required-but-unreported check would freeze
      every `develop` PR).
- [ ] Documentation in a workflow file or the repo records the exact
      branch protection / ruleset settings a maintainer must apply for step 3
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
