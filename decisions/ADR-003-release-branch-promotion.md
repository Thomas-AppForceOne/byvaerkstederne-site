# ADR-003: Release-branch model for prod promotion

**Date:** 2026-04-30
**Status:** Accepted

---

## Context

The promote-to-prod spec
([`specifications/promote_to_prod_specification.md`](../specifications/promote_to_prod_specification.md))
includes a "flag sync" step: at promote time, the script copies
staging's `features.yaml` over prod's, commits the change locally,
and ships that commit as part of the prod deploy. Embedding the
flag-sync as a commit gives the promotion a self-contained audit
trail — `git log` on the prod features file shows exactly which
promotion changed which flag.

But the project's branching rule
([`CLAUDE.md`](../CLAUDE.md#git-workflow--branching-and-prs))
is unambiguous: **`develop` and `main` are sacred** — no direct
commits, ever, including chore-shaped automation commits. The
naive promote-to-prod implementation would therefore land its
flag-sync commit on whatever branch is checked out, which at
release time is most plausibly `develop`. That violates the rule.

The decision was how to reconcile the audit-trail value of the
flag-sync commit with the inviolable rule on `develop` and `main`.

## Decision

Promote-to-prod runs **only** from a `release/*` or `hotfix/*`
branch. The script's first action (step 0) is to verify the
current branch matches one of those patterns and refuse if it
doesn't. The flag-sync commit produced in step 6 lands on the
release/hotfix branch, which is a feature branch by the
project's rule and therefore allowed to receive direct commits.
After the prod deploy completes, the operator opens a normal PR
to merge the release branch back to `develop` (and, eventually, to
`main` per the existing release flow), returning the flag-sync
commit to the integration line through the standard review
channel.

The release/hotfix branch is created off `develop` immediately
before the promotion (`git checkout -b release/v0.2.1 develop`).
For a hot-fix scenario where staging is also broken, the branch
is `hotfix/<short-slug>`, branched off develop the same way.
The promote command warns but does not refuse on other feature
branch names — that allows ad-hoc workflows during the spec's
bedding-in period without weakening the develop/main protection.

## Alternatives considered

- **Branch + PR per promotion.** The script creates a temporary
  `flags-sync/v<X>` branch, commits the flag change, opens a PR
  via `gh`, and either waits for merge before continuing or merges
  via `gh pr merge --squash --auto` after CI passes. Rejected:
  every prod promotion would block on a PR review or CI cycle,
  which kills the "ship a hot-fix in 10 minutes" property the spec
  is reaching for. The release-branch model gets the same audit
  trail without the latency cost.
- **Don't commit the flag sync.** Rsync the flag file out without
  a git commit, accept that prod's `features.yaml` in git lags
  reality, add a CI lint that fails when prod's flag file diverges
  from staging's at promote time. Rejected: loses the audit-trail
  value the spec is reaching for, and replaces it with a CI lint
  whose failure mode is less informative than a git history entry.
- **Promote-to-prod as a CI job, not an operator script.** A
  dedicated CI runner with a service account that *is* allowed to
  commit to develop. Rejected: significantly larger surface
  (runner provisioning, secrets management, CI reliability becomes
  prod-deploy reliability), and it doesn't change the underlying
  question — we'd still need a place for the flag-sync commit to
  land, just on a different machine.

## Consequences

- The promote-to-prod spec carries a "branch gate" as step 0,
  with explicit acceptance criteria (`develop` / `main` /
  `master` refused, `release/*` / `hotfix/*` accepted, other
  feature branches warned).
- Every prod promotion produces a release/hotfix branch. The
  operator's post-deploy workflow includes opening a PR back to
  develop so the flag-sync commit isn't orphaned. If that PR is
  forgotten, the next promotion's prod-flag-drift check (also
  added by the review) will surface it: prod's live
  `features.yaml` will match what's in the abandoned branch but
  not what's in develop, forcing reconciliation.
- The branch convention extends to the existing release-to-main
  flow — a `release/v<X>` branch is the staging ground for the
  `develop → main` PR as well. This matches what mature teams do
  but had not been formalised in the project before.
- If a future automation needs to promote without operator
  intervention (an auto-rollback bot, a scheduled-deploy
  service), it must extend this spec rather than commit directly
  to develop. The branch gate is the seam where that
  conversation re-opens.
