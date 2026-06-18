# Deploy footprint — determination

Authoritative record of **what the running site needs** vs **what currently
ships**, and the justification for every exclusion the deploy applies. This is
the artifact the [deploy-cleanup spec](../specifications/deploy_cleanup_specification.md)
requires ("Determination first") — the exclude set in
`deploy/lib/atomic-release.sh` (`bv_staging_user_excludes`) is the encoding of
the rules below, not an opaque pile of patterns.

Measured 2026-06-18 against `config/www/user/` on `develop`. Re-measure when
plugins are added/upgraded.

---

## How the bundle is assembled (where bloat enters)

The deploy builds a staging tree in three moves (`deploy/deploy.sh`):

1. **Grav core** is extracted from the release zip (`grav-admin-v<X>.zip`) into
   the staging root (`deploy.sh` step 2). This is an upstream **release** build
   — already lean — and is *not* repo-tracked.
2. The repo's site code is copied in: `rsync config/www/user/ → staging/user/`
   (`deploy.sh:411`). **This is the surface where the dependency dev/test/build/
   doc bloat enters the bundle**, so this is where the reduced selection is
   applied (`bv_staging_user_excludes`).
3. Downstream, `bv_rsync_to_release_dir` rsyncs staging → a fresh release dir
   with `bv_atomic_release_excludes` (`cache/ tmp/ backup/ logs/ .DS_Store`,
   `--max-delete=0`). That stays as a belt-and-braces runtime-junk guard; it
   cannot strip what step 2 already pruned.

The apex/landing in-place upload (`-az --delete --max-delete=25`) ships only
`apex/` (no Grav dependency tree) and is **out of scope** for footprint
reduction — its exclude list exists to protect sibling-tier/live-state dirs.

Excludes in step 2 are matched relative to the transfer root
(`config/www/user/`), so a leading-slash pattern (`/themes/quark/`) is anchored
to that root and an unanchored one (`tests/`) matches at any depth.

---

## The necessary set (must ship)

Derived from how Grav loads at runtime:

- **Grav core** — `system/`, top-level `vendor/`, `index.php`, bootstrap files,
  `bin/grav` (the deploy invokes `bin/grav clearcache`). Comes from the zip;
  the step-2 excludes never touch it.
- **Active theme** — `themes/byvaerkstederne/` (set in `config/system.yaml:
  theme: byvaerkstederne`). 13M; ships whole.
- **Enabled plugins' runtime code + runtime vendored deps.** The downloaded
  third-party plugins (`login`, `email`, `form`, `flex-objects`, `admin`,
  `problems`, `markdown-notices`, `error`) each `require .../vendor/autoload.php`
  at runtime — their `vendor/` trees **must ship**. Confirmed runtime deps that
  must survive: `login/vendor/robthree/twofactorauth`, `email/vendor/symfony/
  mailer`.
- **Custom site plugins' runtime code** — `feature-flags`, `site-version`,
  `roadmap`, `bug-report`, `feature-suggestion`, `flex-cache-bust`,
  `registration-throttle` (their `*.php` + `src/`).
- **`pages/`**, **`user/config/`**, **`user/blueprints/`**, **`user/env/<host>/`**,
  **`user/languages/`**, **`user/data/`** (seed copy), **`user/accounts/`**.

### Runtime-dep traps — patterns that must NOT match these

| Trap | Why it must ship | Guard |
|---|---|---|
| `*/vendor/` (third-party plugins) | runtime autoload deps | only `/plugins/feature-flags/vendor/` is excluded — never a bare `vendor/` |
| `symfony/.../Test/` (capital-T) | runtime test-helper namespaces (mailer, messenger, mime, service-contracts) | only lowercase `tests/`/`test/` are excluded — never `Test/`/`Tests/` |
| `polyfill-*/Resources/` | runtime polyfill data | no `Resources/` exclude |
| `*/composer.json` | kept (some code reads it; low value to drop; Grav-core has its own) | not excluded |
| `pages/**/*.md` | page **content** | only specific `CHANGELOG*` filenames excluded — never a blanket `*.md` |

---

## Exclusion candidates (justified)

| Target | Size | Why it's off the necessity path |
|---|---|---|
| `/plugins/feature-flags/vendor/` | **12M** | Pure dev tooling: phpunit (6.4M) + its transitive deps (nikic, twig, sebastian, phar-io, …). `feature-flags` autoloads its `src/` via `spl_autoload_register` and has **no runtime `vendor/autoload` require** ("no install step required at deploy time" — its own code). Gitignored/untracked. |
| `/themes/quark/` | **2.8M** | Grav's default theme. Active theme is `byvaerkstederne`; `quark` is referenced nowhere outside its own dir. `deploy.sh:409` already removes the zip's copy of it — the step-2 rsync was re-adding the repo's copy. |
| `tests/`, `test/` (lowercase) | ~0.3M | Dev test suites: `feature-flags/tests`, `admin/tests`, and vendor package test dirs (`rememberme/test`, `twofactorauth/tests`, `bacon-qr-code/test`, `recaptcha/tests`). Lowercase only — avoids the `Test/` runtime trap. |
| `*.map` | small | Build-output source maps (7 files). |
| `composer.lock` | ~0.5M | Package-resolution metadata; never read at runtime. |
| `.github/`, `.circleci/` | small | CI metadata (5 dirs). |
| `phpunit.xml*`, `phpstan.neon*`, `.php-cs-fixer*`, `.php_cs*` | small | Dev-tool config. |
| `CHANGELOG.md/CHANGELOG/CHANGELOG.txt`, `.gitignore`, `.gitattributes` | small | Docs / VCS metadata; never runtime. |

### Flagged, NOT excluded under this spec

- **`plugins/admin/` (14M)** — the largest remaining item. The site is intended
  frontend-only, but `config/www/user/config/plugins/` has **no `admin.yaml`
  override** and the bundled plugin self-defaults `enabled: true`, so it cannot
  be proven safe to drop from config alone. Excluding a plugin Grav still loads
  would break boot. Per the spec's "flag, don't delete" rule this is recorded
  as a follow-up: decide whether admin is truly disabled (add an explicit
  `admin.yaml: enabled: false`) and only then exclude the dir. Its *internal*
  dev/doc portions (`admin/tests`, `admin/CHANGELOG.md`, `admin/composer.lock`,
  `admin/.github`) are already pruned by the generic patterns above.

---

## Footprint evidence (local simulation)

Simulated `rsync config/www/user/ → tmp` with the exact `bv_staging_user_excludes`
set (the step-2 surface). This is the pre-deploy proxy; the operator records the
real per-tier deployed numbers during the dev wipe-and-redeploy.

| | size | files |
|---|---|---|
| before (full `user/`) | 61M | 4897 |
| after (excludes applied) | 44M | 2606 |
| **reduction** | **−17M (−28%)** | **−2291 (−47%)** |

Dominated by `feature-flags/vendor` (12M, ~thousands of small phpunit files) and
`themes/quark` (2.8M).

---

## Acceptance (operator-run)

Per [ADR-004](../decisions/ADR-004-atomic-deploy-fixture-only-testing.md) the
automated guard is `tests/deploy/excludes-preserve-live-state.sh` (success +
failure paths). The completeness proof is operator-run interactive SSH:

1. Wipe the dev tier's deployed **code** (its `dev-releases/` + docroot) — not
   `devdata` (live state, per the atomic-deploy contract).
2. `make deploy tier=dev` with the reduced selection.
3. Verify the dev site is fully functional: every page renders, CSS/JS/assets
   load, and login / registration / password-reset work.
4. Record the real before/after deployed size + file count for the dev tier
   here.
