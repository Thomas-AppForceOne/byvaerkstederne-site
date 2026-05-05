# tests/version/ — SemVer + build helper probe

Sprint-3 shell-level probe for the version display feature defined in
`specifications/semantic_versioning_specification.md` (now archived
when the spec lands). Covers the contract criteria
`shell_probe_apex_*` and `shell_probe_site_*` from the GAN sprint
contract.

## What it asserts

For each of the two helpers (`readApexSiteVersion()` in
`apex/site_version.php` and the `site_version()` Twig function provided
by the `site-version` Grav plugin, both backed by
`Grav\Plugin\SiteVersion\VersionReader`):

| Case                                 | VERSION                | BUILD     | Expected                              |
|--------------------------------------|------------------------|-----------|---------------------------------------|
| Happy path                           | `  0.1.0\n  ` (padded) | `  247\n` | `{ version: '0.1.0', build: '247' }`  |
| VERSION missing                      | (file absent)          | `247`     | `{ version: null, build: '247' }`     |
| VERSION empty                        | `` (zero bytes)        | `247`     | `{ version: null, build: '247' }`     |
| VERSION invalid (`0.1`)              | `0.1`                  | `247`     | `{ version: null, build: '247' }`     |
| VERSION invalid (`latest`)           | `latest`               | `247`     | `{ version: null, build: '247' }`     |
| VERSION rejected (`0.1.0+build`)     | `0.1.0+build`          | `247`     | `{ version: null, build: '247' }`     |
| BUILD missing                        | `0.1.0`                | (absent)  | `{ version: '0.1.0', build: null }`   |
| BUILD empty                          | `0.1.0`                | ``        | `{ version: '0.1.0', build: null }`   |
| BUILD non-digit (`abc`)              | `0.1.0`                | `abc`     | `{ version: '0.1.0', build: null }`   |
| BUILD negative (`-1`)                | `0.1.0`                | `-1`      | `{ version: '0.1.0', build: null }`   |

The probe verifies that an invalid value on one half does not pollute
the other half — exactly what the Sprint-2 fallback semantics require
(see the source spec's "Robustness" section).

## How to run it locally

```bash
# 1. Bring up a worktree-scoped Grav container (any free port).
scripts/grav-up.sh . 9100
# 2. (Optional but recommended) seed the test admin so the home page
#    serves real content rather than the "Register Admin User" dialog.
tests/fixtures/grav-seeds/playwright/apply.sh "$GRAV_CONTAINER"
# 3. Run the probe.
tests/version/run.sh
```

Exit code is `0` on success, non-zero on any failed assertion. Each
failed case prints expected vs. actual to stderr.

## Prerequisites

- **Docker.** The probe uses `docker run --rm php:8.3-cli` for the
  apex half (so no host-side PHP is needed) and `docker exec` against
  the worktree's Grav container for the site half.
- **A running Grav container scoped to this worktree.** Discovery
  follows the chain documented in
  [CLAUDE.md](../../CLAUDE.md#discovery-chain-fail-loud) (env vars →
  `.gan/port-registry.json` → `docker ps` filter). If no container is
  running, the site half exits non-zero (loud fail rather than silent
  skip) — start one with `scripts/grav-up.sh`.
- **Full git clone.** Not strictly required for the probe (no
  `git rev-list` here), but the project as a whole assumes one — see
  the source spec.

## Cleanup contract

The probe writes its own VERSION/BUILD fixtures and **always restores
the originals on exit**, including non-existence of files that were
absent at start. Implementation: an entry-time backup to a `mktemp -d`
dir plus a `trap … EXIT INT TERM`. Re-running the probe twice in
succession leaves the working tree byte-identical
(`git status --porcelain` reports only changes that pre-date this
sprint's work).

The temp directory itself is deleted on exit.

## Mapping to contract criteria

- `shell_probe_exists_and_executable` — the script is `chmod +x`,
  starts with `#!/usr/bin/env bash`, sets `set -euo pipefail`.
- `shell_probe_apex_happy_path` / `shell_probe_apex_failure_paths`
  — covered by the "Apex half" block.
- `shell_probe_site_happy_path` / `shell_probe_site_failure_paths`
  — covered by the "Site half" block.
- `shell_probe_documented` — this README.
- `tests_exercise_success_and_failure_paths` — every block has at
  least one happy-path and ≥6 failure cases.
- `test_fixture_path_safety` — paths are constructed only from
  `$BASH_SOURCE[0]/../..` (the worktree root) plus literal segments,
  never from environment variables, request data, or user input. The
  probe refuses to run if `REPO_ROOT` does not look like a workshop-site
  checkout.
- `test_cleanup_idempotent` — see "Cleanup contract" above.

## Why two execution paths (`docker run` vs. `docker exec`)?

- The **apex** helper is a plain PHP file with no Grav dependency, so
  the cheapest way to exercise it from a host without PHP is a one-shot
  `docker run --rm php:8.3-cli` against the worktree as `/work`. The
  container loads `apex/site_version.php` via `require` and prints the
  result of `readApexSiteVersion()` as JSON.
- The **site** helper is a Grav plugin that the contract mandates be
  invokable through `bin/grav`. The probe runs the canonical Grav-CLI
  entry point:

  ```bash
  docker exec -w /app/www/public <container> bin/plugin site-version read
  ```

  This boots Grav, loads the `site-version` plugin's CLI command
  (`config/www/user/plugins/site-version/cli/ReadCommand.php`), and
  delegates to the same `VersionReader::read()` the plugin's
  `site_version()` Twig function uses. Output is a single line of JSON
  with the same shape (`{"version": "...", "build": "..."}`) the Twig
  function returns.

  Why `bin/plugin` rather than `bin/grav`? Grav splits its CLI between
  core commands (`bin/grav clearcache`, `bin/grav backup`) and per-
  plugin commands (`bin/plugin <name> <subcommand>`). Both share the
  same Grav bootstrap and the same Symfony console framework. The
  contract criterion calls out three acceptable paths — *a small Grav
  CLI command, a Twig render via bin/grav, or by booting Grav and
  calling the plugin's site_version() function* — and the plugin
  command is the cleanest realisation: it boots Grav exactly once per
  invocation, doesn't require a Twig template fixture, and lives
  alongside the plugin it tests.
