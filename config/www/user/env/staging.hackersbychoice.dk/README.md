# Staging-tier environment profile

This directory holds the per-host configuration overrides that Grav
applies when the site is served under the host **`staging.hackersbychoice.dk`**.

## Tier

This profile represents the **staging** tier in the four-tier topology:

| Tier       | Host                                 | Code                              | Data         |
|------------|--------------------------------------|-----------------------------------|--------------|
| production | `www.byvaerkstederne.dk`             | stable, released                  | real         |
| staging    | `staging.hackersbychoice.dk`         | production-ready                  | copy of prod |
| test       | `test.hackersbychoice.dk`            | code ready for super-user testing | dummy        |
| dev        | localhost / `dev.hackersbychoice.dk` | bleeding edge                     | dummy        |

## No preserved test entries on staging

**Staging carries real prod data, overwritten wholesale on each promotion.**
This is the defining difference from `test` and `dev`:

- `test` / `dev` are seeded with **dummy fixtures** and may keep curated test
  entries (test accounts, sample roadmap items, fixture bug reports) across
  deploys.
- `staging` is **not** a place for preserved test entries. Every
  `promote-to-staging` run restores a fresh prod backup over staging's data
  directory — accounts, flex objects (events, roadmap, bug reports), and
  uploads are all replaced from prod. Anything hand-added to staging between
  promotions is discarded by the next promotion, by design. Do not rely on a
  test entry surviving on staging.

The point of staging is to rehearse a release against realistic prod-shaped
data, not to host a separate test dataset.

## GDPR posture — prod data on an access-gated host

Because staging holds **unanonymised prod data** (member emails, bcrypt
password hashes, bug-report uploads that may contain PII), it is protected by
the compensating controls recorded in
[ADR-002 — Prod data on staging](../../../../../decisions/ADR-002-prod-data-on-staging.md):

1. **Edge gating** — `staging.hackersbychoice.dk` sits behind HTTP basic auth
   (one.com `.htaccess`); a request without the shared operator credential gets
   a 401 before Grav renders anything.
2. **Privacy-policy disclosure** — the privatlivspolitik states that member
   data is replicated to a non-public staging environment for testing.
3. **Retention contract** — the data living on staging is "from one promotion
   to the next"; each promotion overwrites it wholesale (the no-preserved-
   entries rule above is the same property, from the data-lifecycle angle).

If any of those three controls weakens, ADR-002 is superseded and
anonymisation becomes a hard prerequisite.

## What this profile does

The only file of substance is `config/features.yaml`. Like every non-dev tier,
it ships every catalogue flag set to `"false"` — staging is all-off by default
(see [`config/features.yaml`](config/features.yaml)).

## What must NOT go in this directory

- Credentials, tokens, API keys — this directory is committed to git and
  visible to every contributor. The basic-auth credential lives in the
  operator team's shared secret store, never here.
- Any non-flag configuration — keep host-specific behaviour documented here,
  not encoded in opaque YAML.
- Any flag value other than the literal strings `"true"` or `"false"`.
