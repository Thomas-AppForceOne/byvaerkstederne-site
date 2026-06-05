# Test-tier environment profile

This directory holds the per-host configuration overrides that Grav
applies when the site is served under the host **`test.hackersbychoice.dk`**.

## Tier

This profile represents the **test** tier in the four-tier topology:

| Tier       | Host                            | Code                              | Data     |
|------------|---------------------------------|-----------------------------------|----------|
| production | `www.byvaerkstederne.dk`        | stable, released                  | real     |
| staging    | `staging.hackersbychoice.dk`        | production-ready                  | copy of prod |
| test       | `test.hackersbychoice.dk`       | code ready for super-user testing | dummy    |
| dev        | localhost / `dev.hackersbychoice.dk` | bleeding edge                | dummy    |

## What this profile does

The only file of substance is `config/features.yaml`. It declares an
**empty `enabled:` map**, which in FlagStore terms means every catalogue
flag resolves to `false` via the "missing key" rule. This is the secure
default for the test surface: no roadmap, no bug-report dialog, no
feature-suggestion surface, no community footer column, no membership /
newsletter / event / press / minutes / workshop calendar / workshop
detail pages, no contact page, no statutes page.

Super users opt features in one-by-one by setting
`<flag>: "true"` in `config/features.yaml` on the test deploy, then
running `bin/grav clearcache` on the host.

## What must NOT go in this directory

- Credentials, tokens, API keys — this directory is committed to git
  and visible to every contributor.
- Any non-flag configuration — keep host-specific behaviour documented
  here, not encoded in opaque YAML.
- Any flag value other than the literal strings `"true"` or `"false"`.
  FlagStore treats every other value (bare booleans, `TRUE`, `1`,
  `yes`, nulls, nested maps) as invalid, logs a warning, and fails
  closed — but the profile should not deliberately trigger that path.
