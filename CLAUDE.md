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

**`main` and `develop` are both sacred.** Never commit, push, force-push, or merge directly to either branch — every change lands through a PR from a feature branch. If `git branch --show-current` prints `develop` or `main` before you stage a change, stop and create a feature branch first. This applies equally to chore/docs/hotfix edits; there are no exceptions.

`main` is additionally gated by a "protect branches" GitHub ruleset; pushes will be rejected. `develop` relies on this rule being honored.

**`develop` is the integration branch.** All work ships through `develop` first.

```
feature/*  →  develop  →  main
                           ↑
                  release PR only, after the work has been
                  deployed to /test (develop) and verified
```

Concrete rules for any agent or human session in this repo:

- A new feature branches off `develop`: `git checkout -b feature/<slug> develop`.
- **No direct commits to `develop` or `main`.** Always branch first. `git commit` while either branch is checked out is a bug, not a shortcut.
- A PR opened by an agent **must** target `develop` as its base. Pass `--base develop` to `gh pr create` explicitly — do not rely on the default base, which `gh` derives from `defaultBranchRef` and will pick `main`.
- `main` is updated only via a release PR from `develop`, opened by a human after the change has run on the `/test` environment. Agents do not open release PRs without an explicit instruction naming `main` as the target.
- Force-pushing or rewriting history on `main` or `develop` is forbidden. The only time it has happened was to undo a PR mistakenly merged into `main`; the recovery itself was a one-off, not a precedent.
- The `gan/<run-id>` branches produced by `/gan` are feature branches — they merge into `develop`, not `main`.

The full branching/deployment table lives in [README.md](README.md#branching-model). This section is the authoritative agent-facing rule; if the two disagree, this wins until reconciled.

---

## Testing discipline

Three rules, no exceptions:

- **Do not add `test.skip()` (or equivalent) unless the user has explicitly told you to.** Skips hide regressions and have repeatedly let real bugs through sprint passes. If a test cannot run, the correct response is to make it run — seed a fixture, fix the product, or surface the failure — not to silence it. If you genuinely believe a skip is warranted, stop and ask first.
- **Do not commit code that fails the tests.** Run the relevant suite before every commit that touches code or tests. A red suite on a feature branch is a work-in-progress snapshot, not a commit. If you need to checkpoint broken state, use `git stash` or a throwaway branch — do not push it.
- **New or updated code must be covered by tests that exercise both the success path and at least one failure path.** A handler that returns 200 on valid input and 403 on a tampered nonce needs a test for each. A function that parses input needs a test that feeds it garbage. "Happy path only" coverage is not coverage — the regressions we have shipped came from untested failure paths.

These rules apply to any code change, whether made directly, via `/gan`, or by a sub-agent. If you are reviewing a PR (human or agent) and any of the three is violated, block the merge.

---

## Testing in worktrees (Docker port management)

Each worktree can run its own Grav container on its own port so multiple
worktrees coexist without fighting over :8080. Ports are discovered
automatically, and the discovery chain survives Claude Desktop restarts.

### Start / stop a worktree

```bash
# From the worktree directory — port defaults to 8081
scripts/grav-up.sh . 9000

# Tear down
scripts/grav-down.sh .
```

`grav-up.sh` validates the port is free, starts a container named
`grav-<sha256_8>` where the hash is derived from the worktree's absolute
path (so the name is deterministic and unique per worktree), waits for
Grav to respond, writes `.gan/port-registry.json`, and exports
`GRAV_PORT`, `GRAV_CONTAINER`, `GRAV_ROOT` for the current shell.

### Running tests

`make test`, `make test-headed`, and `make test-auth` discover the port
automatically via `scripts/discover-grav-port.js`. The targets echo the
port they are using and fail loudly (exit 1) if no port can be found — no
silent defaulting, because Sprint-5 style bugs come from tests pointing at
the wrong instance.

### Discovery chain

Tests find the port in this order:

1. `GRAV_PORT` env var — set by `grav-up.sh` for the session.
2. `.gan/port-registry.json` — per-worktree, survives Claude Desktop
   restarts, updated by `grav-up.sh` / `grav-down.sh`.
3. `docker ps` — filter by the hashed container name, then by the legacy
   bare `grav` name (so `make start` on the main repo still works).
4. Fallback to `8080` **in `playwright.config.js` only** (with a warning).
   Makefile targets do not fall back — they fail loud.

### Claude Desktop restart

The env vars disappear but `.gan/port-registry.json` persists. Just rerun
`scripts/grav-up.sh .`; it sees the existing registry entry and either
re-exports the vars (if the container is still running) or restarts on
the same port.

### Common errors

- **"Port X is already in use"** — `grav-up.sh` uses `lsof`/`netstat`/`ss`
  and a `docker ps` scan. Pick a different port or stop the conflict.
- **"Cannot determine GRAV_PORT"** from a Make target — run
  `scripts/grav-up.sh . [port]`, or set `GRAV_PORT=<port>` manually.
- **"Grav not responding on port X"** — the registry is stale. Either
  `scripts/grav-down.sh . && scripts/grav-up.sh . <port>` to restart, or
  delete `.gan/port-registry.json` and start fresh.

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

### Confinement — GAN agents are sandboxed to the worktree

GAN sub-agents (generator and evaluator in particular) run under a `PreToolUse` hook that restricts their writes to `$WORKTREE_PATH` plus a narrow carve-out for harness metadata under `$REPO_ROOT/.gan/`. Everything else in the main repo is off-limits: `config/`, `tests/`, `specifications/`, `decisions/`, `scripts/`, `.claude/`, `CLAUDE.md`, `docker-compose.yml` — all read-only to them.

The hook lives at `.claude/hooks/gan-confine.sh` and activates when the orchestrator writes the marker file `.gan/confinement-active` (a single line containing the absolute path of the worktree). The orchestrator writes the marker when it creates the worktree and removes it on teardown. Sub-agents must never remove the marker themselves.

In addition to the filesystem confinement, a fixed list of bash patterns is always blocked under an active marker:
- `rsync --delete` anywhere (caused the April 2026 accounts wipe)
- `rm -r` with `..` traversal
- Any command referencing live-state dirs (`config/www/user/accounts/`, `config/www/user/data/`, `config/www/logs/`) without first `cd`-ing into the worktree
- Any command containing an absolute path inside the main repo but outside the worktree

If the hook rejects a command, the agent must *not* try to work around it. It must either reconsider the approach or surface the problem via the normal channel — an objection (generator) or `blockingConcerns` (evaluator).

Rules the agents are bound to independent of the hook are spelled out in `~/.claude/agents/gan-evaluator.md` and `~/.claude/agents/gan-generator.md` under "Confinement — non-negotiable". The hook and the prose are belt-and-braces; neither is sufficient alone.

### Live-server testing during a GAN run

The primary dev Grav container runs on `:8080` bound to `./config` (the main repo). **GAN agents must never test against it** — it reflects nothing the generator wrote. Instead, the evaluator spins up a separate container bound to the worktree:

```sh
scripts/grav-up.sh "$WORKTREE_PATH" 8081    # brings up a container scoped to this GAN run
tests/fixtures/grav-seeds/playwright/apply.sh <container-name>   # seeds test accounts
# ... probes against http://localhost:8081 ...
scripts/grav-down.sh "$WORKTREE_PATH"       # tears it down
```

Each GAN run gets a unique Compose project name derived from the worktree path, so multiple runs never collide. The primary `:8080` container keeps serving your actual dev workflow while GAN runs.

### Seed bundles

Tests that need live Grav state (accounts, flex data, pages) seed it via the bundles under `tests/fixtures/grav-seeds/`. Each bundle is idempotent and sources passwords from `~/.gan-secrets/workshop-site.env` rather than committing hashes. See `tests/fixtures/grav-seeds/README.md` for the full contract; `tests/fixtures/grav-seeds/playwright/` is the canonical example.

The principle: tests must not depend on pre-existing state. Every test suite either pre-fills what it needs, or documents the seed bundle it requires in its own setup. No more "works on Thomas's machine because his accounts happen to exist".

### Test credentials for the evaluator

Playwright's authenticated suite needs `TEST_PASSWORD` and `TEST_ADMIN_PASSWORD`. Without them, ~34 authenticated tests `test.skip()` at the describe level and the evaluator never exercises the real flows — Sprint 5's DOM-attribute bug got through a sprint pass for exactly this reason.

Credentials live **outside the repo** at `~/.gan-secrets/workshop-site.env`, mode `600`. Do not commit them, do not reference them in prompts (telemetry captures prompts verbatim now).

The orchestrator, when writing evaluator prompts that invoke `npx playwright test`, MUST instruct the evaluator to source that file first:

```bash
if [ -f ~/.gan-secrets/workshop-site.env ]; then
  set -a; . ~/.gan-secrets/workshop-site.env; set +a
fi
# Fail loudly rather than silently skipping if creds should be set but aren't.
if [ -f ~/.gan-secrets/workshop-site.env ] && [ -z "$TEST_PASSWORD" ]; then
  echo "FATAL: ~/.gan-secrets/workshop-site.env exists but TEST_PASSWORD is empty" >&2; exit 1
fi
npx playwright test
```

Rationale: the file exists on operator machines (populated once), absent on fresh clones. Presence-implies-must-work prevents silent skips masquerading as passes. If the file is missing entirely, skipping is acceptable — that's the spec's "anonymous-only" mode.

Contributors populate `~/.gan-secrets/workshop-site.env` manually; the passwords must match what the `tests/fixtures/grav-seeds/playwright/` bundle provisioned into the local Grav instance (usernames `pw-test-user` and `pw-test-admin`).
