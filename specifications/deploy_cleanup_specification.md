# Specification — Deploy cleanup (ship only the files the running site needs)

Status: Planned
Owner: thomas@appforceone.dk
Scope: Reduce every tier's deployed footprint to the files the running website actually needs. Determine the necessary set, encode it in the deploy file-selection, and prove the result by wiping the dev tier and redeploying.

---

## Goal

Tiers currently carry a large amount of content the running site never uses. The atomic-release rsync excludes only `cache/`, `tmp/`, `backup/`, `logs/`, and `.DS_Store` — so everything else under `config/www/` ships verbatim to every tier: each dependency's **dev tooling and test suites** (phpunit, php-code-coverage, debugbar, `.phan/`), **build sources and source maps** (webpack configs, scss, `*.min.*` map files), **VCS and package metadata** (`.git`, `composer.lock`/`composer.json`), **docs** (CHANGELOG/README), **unused locale files**, and any **disabled plugins**. Cut the deploy down to what Grav needs to serve the site, applied uniformly to every tier.

## Boundaries — what this spec does NOT change

- **No change to what the site does** — pages, themes, the *enabled* plugins' runtime behaviour, per-tier config, and all live state stay exactly as they are. This is a footprint reduction, not a feature change.
- **No change to the atomic-deploy model** — release dirs, the symlink swap, rollback, and the live-state isolation contract are untouched. Only the *file-selection* feeding the release rsync changes.
- **Runtime dependencies stay.** Grav core's `vendor/` and each enabled plugin's *runtime* vendored deps (e.g. login's `twofactorauth`, email's `symfony/mailer`) are required and must continue to ship. Only the **dev/test/build/doc** portions of dependencies are candidates for exclusion.
- **Not a repo cleanup.** Whether committed dev-dependencies (e.g. a plugin's vendored phpunit) should also be pruned from git is out of scope here — this spec governs what is *deployed*, not what is *tracked*. If the determination finds tracked files that serve no runtime or tooling purpose anywhere, **flag** them; do not delete them under this spec.
- **Live state is never in the rsync source** and remains so.

## Architectural requirements

- **Determination first.** Produce an authoritative, documented determination of the minimal file set the running site requires, derived from how Grav loads at runtime: Grav core runtime (`system/`, top-level `vendor/`, `index.php`, the bootstrap files, `bin/grav` for the cache CLI the deploy invokes), the active theme, the **enabled** plugins' runtime code + runtime vendor deps, `pages/`, and per-tier config (`user/config/` + `user/env/<host>/`). Everything off that necessity path is an exclusion candidate. The determination is the artifact that *justifies* each exclusion — record it (a `deploy/` doc or the implementation notes) so the resulting selection is a set of explained rules, not an opaque pile of patterns.
- **One selection, all tiers.** Apply the reduced selection through the **shared** deploy file-selection so dev/test/staging/prod and the apex/landing flow all get the same treatment — no per-tier divergence. The canonical exclude set lives in `deploy/lib/atomic-release.sh` (`bv_atomic_release_excludes`); the apex/landing branch in `deploy.sh` carries its own list and must be kept consistent.
- **Fail-safe selection.** Prefer a mechanism that cannot silently drop something Grav needs — expanding the anchored deny-list over a hand-maintained allow-list — unless the implementer can demonstrate an allow-list is both safer and complete. Whichever is chosen, the dev wipe-and-redeploy below is the proof of completeness.
- **Guard against regression.** Cover the new selection with the deploy test tooling (`tests/deploy/`, `make test-deploy`, `tests/deploy/lint-remote-ssh.sh`) so a later edit can neither quietly re-bloat the deploy nor exclude a needed path.

## Interfaces to the system

- `deploy/lib/atomic-release.sh` — `bv_atomic_release_excludes` (shared release exclude list) and `bv_rsync_to_release_dir`.
- `deploy/deploy.sh` — the staging-dir preparation and the apex/landing in-place rsync flow (its own exclude list and the `--max-delete=0` guard).
- `make deploy` / `make deploy-landing` entry points.
- `tests/deploy/*` and `tests/deploy/lint-remote-ssh.sh` — regression suite and static guards.
- Live state under `<tier>data/` — read-only to this work; must stay out of the rsync tree (existing contract).

## Test requirements

- **Static / regression:** `make test-deploy` and the remote-ssh lint assert the reduced exclude set is present **and** that no needed path (`system/`, top-level `vendor/`, `index.php`, enabled plugins, active theme, `pages/`, `user/config/`, `user/env/<host>/`) is excluded. Cover both the success path and at least one failure path — e.g. an exclude rule that *would* drop a required directory is rejected by the guard.
- **Acceptance via clean redeploy on dev:** wipe the dev tier's deployed **code** (its release dirs + docroot) so no pre-existing file can mask a missing one, then run a normal deploy to dev with the reduced selection and verify the dev site is **fully functional** — every page renders, CSS/JS/assets load, and login/registration/password-reset work — proving nothing the running site needs was excluded. Live-state (`devdata`) handling follows the existing atomic-deploy contract; this test concerns the *code* footprint. Deploys to dev are operator-run (interactive SSH), so the operator executes this step as part of implementation.
- **Footprint evidence:** record before/after file count and size per tier (at least dev) so the reduction is demonstrably real.

## Exit criteria

- A documented determination of the site's necessary files exists and justifies every exclusion.
- The shared deploy file-selection ships only those files; the same selection applies to all tiers and the apex/landing flow.
- `make test-deploy` + the lint guard cover the new selection on success and failure paths and are green.
- The dev tier has been wiped and redeployed with the reduced selection, and the dev site is verified fully functional afterwards; before/after footprint numbers are recorded.
- No change to site behaviour, the atomic-deploy model, or live-state isolation.
