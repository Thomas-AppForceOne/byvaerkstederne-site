# Agent Instructions — Byværkstederne

Instructions for Claude agents, GAN workers, and any AI tooling operating in this repository.

---

## Project overview

Byværkstederne is a Grav CMS site (PHP 8 + Twig templates + vanilla JS) running in Docker locally at `http://localhost:8080`. The Grav root is `config/www/`. PHP plugins live in `config/www/user/plugins/`, templates in `config/www/user/themes/byvaerkstederne/templates/`.

---

## Repository structure

| Folder | Contents |
|---|---|
| `config/` | Grav CMS — all site code, templates, plugins, pages, data |
| `specifications/` | Pre-implementation specs for planned/in-progress features |
| `decisions/` | Architecture Decision Records — permanent record of why things work the way they do |
| `deploy/` | Deployment scripts and staging config |
| `.gan/` | GAN harness runtime state — gitignored, do not commit |

---

## Specifications and decisions lifecycle

### Where to look

- Need to understand **what to build**? Read `specifications/`. Each file there is an active, unimplemented feature.
- Need to understand **why something works the way it does**? Read `decisions/`. Each ADR is short — the full folder is cheap to scan.

### The lifecycle

```
Write spec (specifications/)
    ↓
Implement (via /gan or direct development)
    ↓
Move spec to specifications/archive/ — preserves the original prompt
    ↓
Open PR; reviewer may request an ADR before merge if the
implementation encodes decisions worth recording permanently
    ↓
On merge: if an ADR was written, the spec in archive/ stays as its
historical counterpart; if no ADR, archive/ remains the only record
```

### PR-time obligations (orchestrator responsibility, not sub-agents)

**This applies when preparing a branch for PR, after implementation is verified complete.** GAN sub-agents (planner, proposer, reviewer, generator, evaluator) must not modify `specifications/`, `decisions/`, or `ROADMAP.md` during sprint work — those changes belong to the orchestrating session at PR time.

When a `/gan` run (or direct work) has fully implemented one or more specs, the orchestrating session MUST, as part of post-completion handoff:

1. `git mv specifications/<spec>.md specifications/archive/<spec>.md` for each implemented spec.
2. Update `specifications/ROADMAP.md` to mark the step IMPLEMENTED and repoint the link to `archive/<spec>.md`.
3. Commit as a dedicated chore commit on the run branch, e.g. `chore: archive implemented spec and mark roadmap step done`.
4. Open the PR with `gh pr create --base develop` (see Git workflow below — never rely on `gh`'s default base).
5. In the PR body, call out that the ADR is pending reviewer decision. The reviewer decides during PR review whether an ADR is required before merge; if yes, it lands as an additional commit on the same branch via `decisions/ADR-template.md` plus a row in `decisions/README.md`. ADRs are optional when the implementation is a straightforward realisation of the spec with no surprising decisions.

### GAN orchestrator automation

When `/gan` completes with `status: complete` and `--target` points at this repo, the orchestrating session MUST perform steps 1-4 above automatically as part of Step 3.2 of the skill, before presenting the run to the human. Do not stop at "branch ready for review" — push and open the PR. The human reviews the PR, not the branch.

On `status: failed`, do none of the above — leave the branch for debugging and let the user decide.

---

## Git workflow — branching and PRs

**`main` is release-only and protected.** Never push, force-push, or open a PR directly to `main`. The branch is gated by a "protect branches" GitHub ruleset; pushes will be rejected.

**`develop` is the integration branch.** All work ships through `develop` first.

```
feature/*  →  develop  →  main
                           ↑
                  release PR only, after the work has been
                  deployed to /test (develop) and verified
```

Concrete rules for any agent or human session in this repo:

- A new feature branches off `develop`: `git checkout -b feature/<slug> develop`.
- A PR opened by an agent **must** target `develop` as its base. Pass `--base develop` to `gh pr create` explicitly — do not rely on the default base, which `gh` derives from `defaultBranchRef` and will pick `main`.
- `main` is updated only via a release PR from `develop`, opened by a human after the change has run on the `/test` environment. Agents do not open release PRs without an explicit instruction naming `main` as the target.
- Force-pushing or rewriting history on `main` or `develop` is forbidden. The only time it has happened was to undo a PR mistakenly merged into `main`; the recovery itself was a one-off, not a precedent.
- The `gan/<run-id>` branches produced by `/gan` are feature branches — they merge into `develop`, not `main`.

The full branching/deployment table lives in [README.md](README.md#branching-model). This section is the authoritative agent-facing rule; if the two disagree, this wins until reconciled.

---

## Known gotchas

### Grav CLI cache command

The correct command is:

```bash
bin/grav clearcache
```

Not `bin/grav clear-cache` (with hyphen) — that command does not exist and will prompt a "did you mean?" error.

### Vote nonce — do not reintroduce replay blacklist

The roadmap vote handler (`config/www/user/plugins/roadmap/roadmap.php`) previously maintained a session-based nonce blacklist (`bv_used_vote_nonces`) as an extra replay protection layer. It was removed because it caused 403 errors when users voted on multiple items in quick succession. Grav's `Utils::verifyNonce()` is the sole CSRF gate for votes. Do not reintroduce single-use per-request nonce enforcement — see `decisions/ADR-001-navigation-footer-placement.md` for full context.

### Community affordances are footer-only and auth-gated

Forslå Feature, Roadmap, and Rapportér fejl must not appear in the main navigation or anywhere else outside the footer. They are hidden from unauthenticated users entirely. See `decisions/ADR-001-navigation-footer-placement.md`.

---

## GAN harness

GAN state lives in `.gan/` (gitignored). Schemas are in `~/.claude/skills/gan/schemas/`. Use `bin/grav clearcache` in evaluator prompts, not `clear-cache`.

When running `/gan`, the orchestrator (main Claude session) is the sole writer of `.gan/progress.json`. Sub-agents communicate via stdout only.
