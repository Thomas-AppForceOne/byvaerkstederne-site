# ADR-007: The feature-flag fallback fails closed; the developer's all-on profile lives under `localhost`

**Date:** 2026-08-16
**Status:** Accepted

---

## Context

Grav resolves its environment from the request Host header and loads `user/env/<host>/config/features.yaml`. When the Host matches no such directory it falls back to `user/config/features.yaml` — and that file held the developer's profile, with every flag `"true"`. Its own header said so: *"any host without a dedicated env directory … so every flag is ON here."*

Every tier has more than one entrance. Production answers on the bare apex as well as `www.`; the one.com tiers are folders under `hackersbychoice.dk`, so each is reachable both as a subdomain and as a path. Measured on 2026-08-15, same release and same docroot:

| Entrance | `/vedtaegter` | Front page |
|---|---|---|
| `www.byvaerkstederne.dk` | 404 | 28,954 B |
| `byvaerkstederne.dk` | **200** | 34,116 B |
| `staging.hackersbychoice.dk` | 404 | 28,954 B |
| `hackersbychoice.dk/staging/` | **200** | 50,141 B |

The fallback made the unprofiled entrance an all-features entrance, in production, and those pages are indexable there — `X-Robots-Tag: noindex` is only set off-prod. ADR-006's canonical-host redirect closes the entrances; this decision is about which way the system fails when one is missed.

## Decision

`user/config/features.yaml` declares an empty `enabled: {}` map. An unprofiled Host — unknown hostname, bare apex, health check, CLI run — enables **nothing**. The site's unflagged core still renders; every gated surface stays dark.

The developer's all-on profile moves to `user/env/localhost/config/features.yaml`. Grav aliases `127.0.0.1` and `::1` to `localhost` (`Setup::$environments`), so `make start` and both Playwright suites — all of which reach Grav over `127.0.0.1` — resolve it unchanged. That directory is excluded from the deploy package (`bv_staging_user_excludes`), so an all-on profile never leaves a developer machine.

A flag belongs in the profile of the host that should see it. Nothing goes back into the fallback.

## Alternatives considered

- **Leave the fallback all-on and rely on the canonical-host redirect (ADR-006) alone** — one `.htaccess` rule between production and an all-features site. A hosting migration, a hand-edited file or a rule that stops matching restores the hole silently. Defence in depth costs one file here.
- **Give every known non-canonical host its own empty profile, and nothing more** — shipped alongside this (`byvaerkstederne.dk`, `hackersbychoice.dk`, `www.hackersbychoice.dk`), but it only covers the hosts someone thought of. The fallback is what covers the ones nobody thought of.
- **Point the test suites at a host profile via `--host-resolver-rules` instead of moving the profile** — the mobile project already does this for `dev.hackersbychoice.dk`. Doing it for every project is more machinery than moving one file, and it would leave the fallback all-on for anything that still arrives over `127.0.0.1`.
- **Set `GRAV_ENVIRONMENT` per tier for CLI runs** — genuinely useful, and Grav honours it ahead of the hostname, but it solves a problem we do not have: no CLI or scheduled code path reads a feature flag (audited below). Left for the day one does.

## Consequences

- The safe direction to be wrong in is now the default. A tier reached under a name nobody anticipated shows core content, not unreleased features.
- **CLI is unaffected, verified.** The only flag reads outside vendor and tests are `account-manager.php` (`AccountSelfService`) and `event-manager.php` (`EventRsvp`), both in HTTP request handlers, plus Twig `feature_enabled()` and the page `feature:` gate in page templates. `onSchedulerInitialized` registers the purge and super-watch jobs with no flag check — deliberate, and pinned by *"purge still runs with the flag OFF (unflagged by design)"*. The project's three CLI commands and the whole service layer read no flags. The scheduler itself runs in-process from the token-gated HTTP trigger, so its jobs resolve the tier's environment from the Host header; `cli` applies only to genuine command-line runs.
- **Two Grav behaviours this rests on, both verified against the running container** (the second contradicts Grav's own documentation):
  1. `Setup::$environments` aliases `127.0.0.1` and `::1` to `localhost`. Proved: `/presse` answered 404 with `user/env/localhost/` present and 200 without it.
  2. A CLI run resolves to the environment **`cli`**, not `localhost` — Grav's `--env` help text says *"defaults to localhost"* and is wrong. Proved by placing empty `env/cli/` and `env/localhost/` directories and running `bin/grav clearcache`: Grav wrote `security.yaml` into `env/cli/config/` and left `localhost` untouched.
- Anything that turns a flag off to test the off-path must edit the **localhost** profile; editing the fallback no longer changes what a browser sees. `withLocalhostFlagOff()` in `tests/helpers/self-service.js` is the shared helper, and it throws rather than silently no-oping when the flag is not `"true"` there.
- A new flag now needs a line in the localhost profile as well as in the tier profiles, or it is off for local development and the whole browser suite. `testLocalhostProfileEnablesAllCatalogueFlags` fails first and says so.
