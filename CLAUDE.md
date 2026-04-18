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
Write ADR (decisions/) capturing key decisions and rationale
    ↓
Delete the spec — the ADR is the permanent record
```

### ADR obligation — merge-time only

**This applies only when preparing a branch for PR or merge, after all implementation work is verified complete.**

Before opening a PR, check whether any spec in `specifications/` is now fully implemented by the work on this branch. If so:

1. Create an ADR in `decisions/` using `decisions/ADR-template.md`
2. Delete the spec file from `specifications/`
3. Add a row to the index table in `decisions/README.md`
4. Include these changes in the PR branch

**This does not apply to GAN sub-agents** (planner, proposer, reviewer, generator, evaluator) operating within a sprint. Those agents must not modify `specifications/` or `decisions/` during sprint work. ADR creation is the responsibility of the orchestrating session at PR time.

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
