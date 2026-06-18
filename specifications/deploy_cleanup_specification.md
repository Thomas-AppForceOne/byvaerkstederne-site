# Specification — Deploy cleanup (ship only the files the running site needs)

Status: Planned
Owner: thomas@appforceone.dk
Scope: Reduce every tier's deployed footprint to the files the running website actually needs. Determine the necessary set, encode it in the deploy file-selection, and prove the result by wiping the dev tier and redeploying.

---

## Goal

Tiers currently carry a large amount of content the running site never uses. The deploy first assembles a staging tree (Grav core extracted from the release zip, plus `config/www/user/` copied in by a near-unfiltered rsync that excludes only `.DS_Store`), and the atomic-release rsync that follows excludes only `cache/`, `tmp/`, `backup/`, `logs/`, and `.DS_Store` — so everything else under `config/www/user/` ships verbatim to every tier: each dependency's **dev tooling and test suites** (e.g. a plugin's vendored phpunit / php-code-coverage), **build sources and source maps** (webpack configs, scss, `*.min.*` map files), **VCS and package metadata** (`composer.lock`/`composer.json`, any nested `.git`), **docs** (CHANGELOG/README), **unused locale files**, and any **disabled plugins**. (The illustrative `debugbar`/`.phan/` categories named in earlier drafts are not present in this repo — the determination governs whatever is actually on disk.) Cut the deploy down to what Grav needs to serve the site, applied uniformly to every tier.

## Boundaries — what this spec does NOT change

- **No change to what the site does** — pages, themes, the *enabled* plugins' runtime behaviour, per-tier config, and all live state stay exactly as they are. This is a footprint reduction, not a feature change.
- **No change to the atomic-deploy model** — release dirs, the symlink swap, rollback, and the live-state isolation contract are untouched. Only the *file-selection* feeding the release rsync changes.
- **Runtime dependencies stay.** Grav core's `vendor/` and each enabled plugin's *runtime* vendored deps (e.g. login's `twofactorauth`, email's `symfony/mailer`) are required and must continue to ship. Only the **dev/test/build/doc** portions of dependencies are candidates for exclusion.
- **Not a repo cleanup.** Whether committed dev-dependencies (e.g. a plugin's vendored phpunit) should also be pruned from git is out of scope here — this spec governs what is *deployed*, not what is *tracked*. If the determination finds tracked files that serve no runtime or tooling purpose anywhere, **flag** them; do not delete them under this spec. Note that some of the largest exclusion targets are **present on disk but untracked** — e.g. `config/www/user/plugins/feature-flags/vendor/phpunit/` (~6 MB, gitignored) — so the determination must run against the **on-disk `config/www` tree that rsync actually sees**, not `git ls-files`. Deploy-excluding an untracked-but-present file is in scope; pruning a *tracked* file from git is not.
- **Live state is never in the rsync source** and remains so.

## Architectural requirements

- **Determination first.** Produce an authoritative, documented determination of the minimal file set the running site requires, derived from how Grav loads at runtime: Grav core runtime (`system/`, top-level `vendor/`, `index.php`, the bootstrap files, `bin/grav` for the cache CLI the deploy invokes), the active theme, the **enabled** plugins' runtime code + runtime vendor deps, `pages/`, and per-tier config (`user/config/` + `user/env/<host>/`). Everything off that necessity path is an exclusion candidate. The determination is the artifact that *justifies* each exclusion — record it (a `deploy/` doc or the implementation notes) so the resulting selection is a set of explained rules, not an opaque pile of patterns. Note the staging tree the rsync sees is **Grav core (extracted from the release zip at deploy time, not repo-tracked) plus `config/www/user/` (from the repo)** — so exclusion patterns match against Grav-core files too (a blanket `--exclude=composer.json` or `--exclude=*/Tests/` would also strip Grav core's own metadata/tests). Reason about both halves of the tree.
- **One selection, all tiers — applied at the point bloat enters.** There are **three** file-moving rsync surfaces, and the reduction must land at the right one rather than being smeared across "two lists":
  1. **Staging assembly** — `deploy/deploy.sh`, the `config/www/user/` → staging rsync (`deploy.sh:411`), currently `--exclude='.DS_Store'` only. **This is where the dependency dev/test/build/doc bloat enters the bundle**, so this is where the reduced selection must be applied (or the staging tree pruned immediately after assembly). Fix it here once and every downstream rsync inherits the minimal tree, making "one selection, all tiers" literally true with a single edit.
  2. **Atomic release** — `deploy/lib/atomic-release.sh`, `bv_atomic_release_excludes`, staging → fresh release dir, `--max-delete=0`. Keep its anchored runtime-junk excludes (`cache/`, `tmp/`, `backup/`, `logs/`, `.DS_Store`) as a belt-and-braces guard; it cannot strip what the staging step already pruned, and it must never be the *only* place an exclusion lives.
  3. **Apex/landing in-place upload** — `deploy/deploy.sh`, `-az --delete --max-delete=25` (`deploy.sh:554`). This ships only `apex/` (the selector page; no Grav dependency tree), and its own exclude list exists to protect sibling-tier/live-state dirs on an in-place `--delete`, **not** to reduce a dependency footprint. It needs no footprint change; do not retrofit dependency excludes here.

  Whatever lands in surfaces 1–2 applies uniformly to dev/test/staging/prod with no per-tier divergence.
- **Fail-safe selection.** Prefer a mechanism that cannot silently drop something Grav needs — expanding the anchored deny-list over a hand-maintained allow-list — unless the implementer can demonstrate an allow-list is both safer and complete. Anchor patterns to avoid over-broad matches on runtime paths — the known traps in this tree are nested `cache/` (e.g. `vendor/doctrine/.../cache/`, already documented in `atomic-release.sh`), `Resources/` (Symfony polyfills ship runtime `Resources/`), and `symfony/mailer/Test/` (a runtime helper namespace, not a test suite). These are the concrete cases the failure-path guard (below) must reject. Whichever mechanism is chosen, the dev wipe-and-redeploy below is the proof of completeness.
- **Guard against regression.** Cover the new selection with the deploy test tooling (`tests/deploy/`, `make test-deploy`) so a later edit can neither quietly re-bloat the deploy nor exclude a needed path. The fit-for-purpose host is `tests/deploy/excludes-preserve-live-state.sh` — it already extracts and asserts against the rsync exclude arrays and runs fixture rsyncs. `tests/deploy/lint-remote-ssh.sh` is a static SSH-quoting lint and is **not** where exclude/required-path assertions belong.

## Interfaces to the system

- `deploy/lib/atomic-release.sh` — `bv_atomic_release_excludes` (release-dir runtime-junk excludes, `--max-delete=0`) and `bv_rsync_to_release_dir`.
- `deploy/deploy.sh` — the **staging-assembly rsync** (`config/www/user/` → staging, currently `--exclude='.DS_Store'` only — the primary surface for this work) and the apex/landing in-place upload (`-az --delete --max-delete=25`, with its own sibling-tier/live-state exclude list).
- `make deploy` / `make deploy tier=landing` entry points (there is no separate `deploy-landing` target).
- `tests/deploy/*` — regression suite; `tests/deploy/excludes-preserve-live-state.sh` is the exclude/required-path guard for this work; `tests/deploy/lint-remote-ssh.sh` is a static SSH-quoting lint (not the host for exclude assertions).
- Live state under `<tier>data/` — read-only to this work; must stay out of the rsync tree (existing contract).

## Test requirements

- **Static / regression:** `make test-deploy` (via `tests/deploy/excludes-preserve-live-state.sh` or a sibling guard) asserts the reduced exclude set is present **and** that no needed path (`system/`, top-level `vendor/`, `index.php`, enabled plugins, active theme, `pages/`, `user/config/`, `user/env/<host>/`) is excluded. Cover both the success path and at least one failure path — e.g. an exclude rule that *would* drop a required directory, or a runtime `cache/` / `Resources/` / `symfony/mailer/Test/` path (the traps named above), is rejected by the guard.
- **Acceptance via clean redeploy on dev:** wipe the dev tier's deployed **code** (its release dirs + docroot) so no pre-existing file can mask a missing one, then run a normal deploy to dev with the reduced selection and verify the dev site is **fully functional** — every page renders, CSS/JS/assets load, and login/registration/password-reset work — proving nothing the running site needs was excluded. Live-state (`devdata`) handling follows the existing atomic-deploy contract; this test concerns the *code* footprint. Deploys to dev are operator-run (interactive SSH), so the operator executes this step as part of implementation. Per [ADR-004](../decisions/ADR-004-atomic-deploy-fixture-only-testing.md), the **static fixture guards above** are what satisfy the testing-discipline contract (success + failure paths); the operator-run dev wipe-and-redeploy is corroborating evidence of completeness, not the automated gate.
- **Footprint evidence:** record before/after file count and size per tier (at least dev) so the reduction is demonstrably real.

## Exit criteria

- A documented determination of the site's necessary files exists and justifies every exclusion.
- The shared deploy file-selection ships only those files; the same selection applies to all tiers and the apex/landing flow.
- `make test-deploy` + the exclude/required-path guard cover the new selection on success and failure paths and are green.
- The dev tier has been wiped and redeployed with the reduced selection, and the dev site is verified fully functional afterwards; before/after footprint numbers are recorded.
- No change to site behaviour, the atomic-deploy model, or live-state isolation.