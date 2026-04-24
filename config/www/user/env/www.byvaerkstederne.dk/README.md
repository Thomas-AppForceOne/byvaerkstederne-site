# Production environment profile

This directory holds the per-host configuration overrides that Grav
applies when the site is served under the host **`www.byvaerkstederne.dk`**.

## Tier

This profile represents the **production** tier in the four-tier topology:

| Tier       | Host                            | Code                              | Data     |
|------------|---------------------------------|-----------------------------------|----------|
| production | `www.byvaerkstederne.dk`        | stable, released                  | real     |
| staging    | `www.hackersbychoice.dk`        | production-ready                  | copy of prod |
| test       | `test.hackersbychoice.dk`       | code ready for super-user testing | dummy    |
| dev        | `dev.hackersbychoice.dk` (or localhost in docker) | bleeding edge    | dummy    |

## What this profile does

Every catalogue flag is listed explicitly, all defaulting to `"false"`.
This makes prod fail-closed: a feature only goes live on the production
host when someone edits this file and flips a specific flag from
`"false"` to `"true"` in a reviewable one-line change.

Before flipping a flag to `"true"`:

1. The feature must have been exercised end-to-end on staging
   (`www.hackersbychoice.dk`) with production-shaped data.
2. Super users must have signed off after testing on `test.hackersbychoice.dk`.
3. No incident, migration, or rollback is outstanding for the feature.

After editing, run `bin/grav clearcache` on the production host.

## Why not `enabled: {}` like the test profile?

The test profile uses an empty map because it's a scratchpad — whoever
is exercising a feature on test edits the file freely, no audit needed.

Prod is the opposite. The explicit `flag: "false"` list IS the audit
surface. Shortening it to `enabled: {}` would let a flag silently start
resolving differently (e.g., when the catalogue adds a new flag: under
`{}` it defaults to false as "missing key"; under an explicit list it
would fail the test that prod names every known flag, forcing the
operator to decide). Keep the list in sync with `FeatureFlag::cases()`.

## What must NOT go in this directory

- Credentials, tokens, API keys — this directory is committed to git
  and visible to every contributor.
- Any non-flag configuration — keep host-specific behaviour documented
  here, not encoded in opaque YAML.
- Any flag value other than the literal strings `"true"` or `"false"`.
  FlagStore treats every other value (bare booleans, `TRUE`, `1`,
  `yes`, nulls, nested maps) as invalid, logs a warning, and fails
  closed — but the profile should not deliberately trigger that path.
