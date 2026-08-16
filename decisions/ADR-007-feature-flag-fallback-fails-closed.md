# ADR-007: The local all-on profile is never deployed, so a tier has no feature-flag fallback

**Date:** 2026-08-16
**Status:** Accepted

---

## Context

Grav resolves its environment from the request Host header and loads `user/env/<host>/config/features.yaml`. When the Host matches no such directory it falls back to `user/config/features.yaml` — and that file held the developer's profile, with every flag `"true"`. It shipped with every release, so on a tier the fallback was ALL-ON.

Every tier has more than one entrance. Production answers on the bare apex as well as `www.`; the one.com tiers are folders under `hackersbychoice.dk`, reachable both as a subdomain and as a path. Measured on 2026-08-15, same release and same docroot:

| Entrance | `/vedtaegter` | Front page |
|---|---|---|
| `www.byvaerkstederne.dk` | 404 | 28,954 B |
| `byvaerkstederne.dk` | **200** | 34,116 B |
| `staging.hackersbychoice.dk` | 404 | 28,954 B |
| `hackersbychoice.dk/staging/` | **200** | 50,141 B |

Two requirements pull in opposite directions here, and both are non-negotiable:

1. **A tier must behave identically from every device and address.** dev from a phone has to be dev from a desktop. Locally that means the container cannot care whether the browser said `localhost`, `127.0.0.1`, a LAN address or a container name.
2. **An unprofiled Host on a tier must enable nothing.** That is what the apex incident cost.

An earlier draft of this decision satisfied (2) by emptying the fallback and moving the all-on profile to `user/env/localhost/`. It broke (1): a phone reaching the dev container on the machine's LAN address got no profile and saw the flag-less core, while the desktop on `localhost` saw everything.

## Decision

`user/config/features.yaml` stays exactly what it was — the developer's all-on profile, host-agnostic by construction — and is **excluded from the deploy package** (`bv_staging_user_excludes`).

Locally that gives requirement (1) for free: every Host resolves the same file, so the container looks the same from any device. Verified against the running container — `/presse`, a flag-gated route, answers 200 for `127.0.0.1`, `localhost`, `192.168.1.42`, `macbook.local` and `phone-test.lan` alike.

On a tier the file simply does not exist. Grav has no fallback, `FlagStore` seeds every flag false, and an unprofiled Host gets the site's unflagged core and nothing else — requirement (2), without a per-host profile for every name anyone might use. The tiers' real posture lives where it belongs, in `user/env/<host>/`:

| Tier | Posture |
|---|---|
| dev | **all flags on, always** — pinned by `testDevProfileEnablesAllCatalogueFlags` |
| test / staging / prod | **all off by default**; individual flags or sets flipped on when needed |

## Alternatives considered

- **Empty the fallback and move all-on to `user/env/localhost/`** — the earlier draft. Fails requirement (1): Grav aliases only `127.0.0.1` and `::1` to `localhost` (`Setup::$environments`), so any other local address — the LAN IP a phone must use — falls through to the empty fallback and behaves differently from the desktop. Rejected once the requirement was stated.
- **Ship an empty fallback and give every non-canonical host its own profile** — covers the hosts someone thought of; the fallback is what covers the ones nobody thought of. The non-canonical profiles added in ADR-006's change stay as explicit documentation, but they are no longer what makes a tier safe.
- **Leave the fallback all-on and rely on the canonical-host redirect alone** — one `.htaccess` rule between production and an all-features site. A hosting migration or a hand-edited file restores the hole silently.
- **`GRAV_ENVIRONMENT` per tier for CLI runs** — genuinely useful, and Grav honours it ahead of the hostname, but it solves a problem we do not have: no CLI or scheduled path reads a flag (audited below).

## Consequences

- The exclusion is **load-bearing for behaviour**, not just footprint — the only one in that list that is. Removing it re-deploys an all-on fallback to production. `tests/deploy/excludes-preserve-live-state.sh` asserts, through a real rsync, that `config/features.yaml` is dropped while every `user/env/<tier>/` profile survives.
- A tier's safety now rests on a file being **absent**. That is proven behaviour, not an assumption: `FeatureFlagCatalogueTest::testMissingFeaturesYamlDoesNotCrashAndFailsAllClosed` covers the missing-file path, and `FlagStore` seeds all-false before loading anything.
- **Rolling back to a release cut before this change** restores an all-on fallback in that release directory. The canonical-host redirect (ADR-006) keeps unprofiled Hosts from reaching it, but a rollback that spans this change is worth a probe of the apex afterwards.
- **CLI is unaffected, audited rather than assumed.** The only flag reads outside vendor and tests are `account-manager.php` (`AccountSelfService`) and `event-manager.php` (`EventRsvp`), both in HTTP request handlers, plus Twig `feature_enabled()` and the page `feature:` gate in page templates. `onSchedulerInitialized` registers the purge and super-watch jobs with no flag check — deliberate, pinned by *"purge still runs with the flag OFF (unflagged by design)"*. The three project CLI commands and the whole service layer read no flags. The scheduler runs in-process from the token-gated HTTP trigger, so its jobs resolve the tier's environment from the Host header; `cli` applies only to genuine command-line runs.
- **Two Grav behaviours verified against the running container**, the second contradicting Grav's own documentation:
  1. `Setup::$environments` aliases `127.0.0.1` and `::1` to `localhost` — which is precisely why the `env/localhost/` draft could not deliver requirement (1).
  2. A CLI run resolves to the environment **`cli`**, not `localhost`; the `--env` help text says *"defaults to localhost"* and is wrong. Proved by placing empty `env/cli/` and `env/localhost/` directories and running `bin/grav clearcache`: Grav wrote `security.yaml` into `env/cli/config/` and left `localhost` untouched.
- Turning a flag on for a tier stays a one-line, review-gated edit in that tier's profile — the workflow the profile headers already describe.
