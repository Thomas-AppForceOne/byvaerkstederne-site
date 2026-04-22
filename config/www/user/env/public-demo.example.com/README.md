# Public-demo environment profile

This directory holds the per-host configuration overrides that Grav
applies when the site is served under the host **`public-demo.example.com`**.

The hostname is an **ops-chosen placeholder**. The real public-demo
hostname is chosen at deploy time (it may be `demo.byvaerkstederne.dk`,
`public-demo.byvaerkstederne.dk`, or an ops-specified alternative). To
activate this profile against the real hostname:

1. Decide the real hostname with ops.
2. Either rename this directory from `public-demo.example.com` to match
   the real host, or create a sibling `config/www/user/env/<real-host>/`
   and copy `config/features.yaml` + this README across.
3. Redeploy and clear Grav's cache on the host:
   ```
   bin/grav clearcache
   ```

## What this profile does

The only file of substance is `config/features.yaml`. It declares an
**empty `enabled:` map**, which in FlagStore terms means every catalogue
flag resolves to `false` via the "missing key" rule. This is the secure
default for the public-demo surface: no roadmap, no bug-report dialog,
no feature-suggestion surface, no community footer column, no
membership / newsletter / event / press / minutes / workshop calendar /
workshop detail pages, no contact page, no statutes page.

## What must NOT go in this directory

- Credentials, tokens, API keys — this directory is committed to git
  and visible to every contributor.
- Any non-flag configuration — keep host-specific behaviour documented
  here, not encoded in opaque YAML.
- Any flag value other than the literal strings `"true"` or `"false"`.
  FlagStore treats every other value (bare booleans, `TRUE`, `1`,
  `yes`, nulls, nested maps) as invalid, logs a warning, and fails
  closed — but the profile should not deliberately trigger that path.
