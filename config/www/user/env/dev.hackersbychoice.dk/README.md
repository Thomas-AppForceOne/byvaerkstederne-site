# Dev-tier environment profile

This directory holds the per-host configuration overrides that Grav
applies when the site is served under the host **`dev.hackersbychoice.dk`**.

## Tier

This profile represents the **dev** tier in the four-tier topology:

| Tier       | Host                            | Code                              | Data     |
|------------|---------------------------------|-----------------------------------|----------|
| production | `www.byvaerkstederne.dk`        | stable, released                  | real     |
| staging    | `staging.hackersbychoice.dk`        | production-ready                  | copy of prod |
| test       | `test.hackersbychoice.dk`       | code ready for super-user testing | dummy    |
| dev        | `dev.hackersbychoice.dk` (or localhost in docker) | bleeding edge    | dummy    |

## Localhost vs deployed dev

Grav's env selector is Host-keyed. When running in docker locally, Grav
sees `Host: localhost` (or `127.0.0.1`) and this profile does NOT
activate — the default `config/www/user/config/features.yaml` is used
instead, which is the intended knob for local hacking.

This profile only activates for the deployed dev surface at
`dev.hackersbychoice.dk`.

## What this profile does

Every rollout-catalogue flag is enabled. The dev surface is where
bleeding-edge work is exercised end-to-end, so features are ON by
default. If a specific flag needs to be off for a dev investigation,
edit `config/features.yaml` on the deploy and `bin/grav clearcache`.

## What must NOT go in this directory

- Credentials, tokens, API keys — this directory is committed to git
  and visible to every contributor.
- Any non-flag configuration — keep host-specific behaviour documented
  here, not encoded in opaque YAML.
- Any flag value other than the literal strings `"true"` or `"false"`.
  FlagStore treats every other value (bare booleans, `TRUE`, `1`,
  `yes`, nulls, nested maps) as invalid, logs a warning, and fails
  closed — but the profile should not deliberately trigger that path.
