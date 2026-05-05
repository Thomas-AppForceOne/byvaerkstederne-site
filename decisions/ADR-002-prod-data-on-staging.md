# ADR-002: Prod data on staging — unanonymised, gated by access controls

**Date:** 2026-04-30
**Status:** Accepted

---

## Context

The promote-to-staging spec
([`specifications/promote_to_staging_specification.md`](../specifications/promote_to_staging_specification.md))
needs staging to look like prod so a rehearsal actually rehearses
something real — events, member counts, paginated directories,
realistic upload sizes. The cheapest way to achieve that is to
restore a prod backup directly onto staging without a transformation
pass.

That choice means real personal data (member email addresses,
bcrypt-hashed passwords, bug-report screenshots that may contain
PII) lives on staging. Staging is hosted on the same one.com
account as test and dev, served from
`staging.hackersbychoice.dk`. By default that hostname is reachable
by anyone who knows the URL. Under GDPR — and under our own
implicit promise to members — replicating their data onto an
unrestricted host is not acceptable.

The decision was whether to ship anonymisation as a hard
prerequisite, or to ship the cheaper "no transformation" path and
satisfy GDPR through access controls instead.

## Decision

Promote-to-staging ships prod data **unanonymised**. Member email
addresses and password hashes travel from prod to staging as-is. We
satisfy GDPR through three compensating controls, all of which must
be in place before the spec ships:

1. **Edge gating.** `staging.hackersbychoice.dk` is fronted by HTTP
   basic auth (Apache `.htaccess` on one.com), with credentials
   shared only with the small operator team. Anyone without the
   shared credential gets a 401 before any Grav response is rendered
   — so the URL alone does not expose member data.
2. **Privacy policy disclosure.** The site's privacy policy
   (Danish: privatlivspolitik) states explicitly that member data
   is replicated to a non-public staging environment for testing
   purposes, and names the retention contract.
3. **Retention contract.** Staging's data is fully overwritten by
   each promote-to-staging run. The window during which a particular
   prod snapshot lives on staging is "from one promotion to the
   next" — typically days. Backups containing prod data are governed
   by the backup spec's own retention rules and live in encrypted
   managed storage, not on staging.

Anonymisation is deferred to a future spec. If any of the three
compensating controls weakens (e.g., the basic-auth gate is removed
or the operator pool grows beyond the team), this ADR is superseded
and anonymisation becomes a hard prerequisite.

## Alternatives considered

- **Anonymise on push.** Run a transformation pass over the snapshot
  before pushing to staging — strip emails, scrub uploads, replace
  password hashes with a known fixture password. Rejected for v1:
  significant additional spec surface (what to replace, how to
  preserve referential integrity, how to make the pass deterministic
  for tests), and the basic-auth gate gives us the privacy property
  we need at far lower cost. Revisit if the operator pool grows or
  the gate goes away.
- **Synthetic-only staging.** Skip prod data entirely; populate
  staging from a fixture. Rejected: the rehearsal value of staging
  comes from realistic shape and volume of data, which is exactly
  what fixtures don't deliver.
- **Promote to staging only via a separate, fully-locked-down host.**
  Rejected: introduces a fourth tier the spec has to coordinate, and
  one.com's hosting model doesn't make a "really locked down" tier
  cheap to stand up.

## Consequences

- The promote-to-staging spec must not ship until basic auth is
  live on `staging.hackersbychoice.dk` and the privacy-policy text
  has been updated. The spec carries a checklist linking to this
  ADR; reviewers gate-keep the link before merge.
- Operators with the basic-auth credential are a small, named group;
  rotating that credential is a reviewable change to the team's
  shared secret store.
- Bug-report screenshots are part of `user/uploads/` and travel to
  staging unchanged. Any future spec that introduces a new kind of
  high-sensitivity upload (passport scans, medical info, etc.)
  triggers a re-evaluation of this ADR.
- If we ever introduce a fourth-party reviewer who needs staging
  access without prod-data exposure, anonymisation graduates from
  "future work" to "blocker" and this ADR is superseded.
