# Sprint 4 — audit notes

## Sitemap audit outcome

Grepped `config/www/user/plugins/` and `config/www/user/config/plugins/`
for any plugin or plugin-config directory named `sitemap`:

```
$ ls config/www/user/plugins/ | grep -i sitemap
(no output)
$ ls config/www/user/config/plugins/ 2>/dev/null | grep -i sitemap
(no output)
```

No sitemap plugin is installed or enabled. The `sitemap_or_canonical_audit`
criterion's "NOT installed" branch therefore applies.

The assertion that satisfies this branch lives in
`tests/anonymous/feature-flags-plugins.js`, Part 4 — "canonical-link /
home-page route audit". Under `PROFILE=public_demo` the home page (`GET /`)
is fetched and asserted to contain zero references to any of the eight
flagged top-level routes (`/roadmap`, `/foreslaa-feature`,
`/opret-medlemskab`, `/presse`, `/referater`, `/vaerkstedskalenderen`,
`/kontakt`, `/vedtaegter`) in either `<link rel="canonical">` attributes,
`<a href>` anchors, or inline URL-looking substrings.

If a sitemap plugin is later installed for this site, extend that test
file with a `/sitemap.xml` probe that asserts zero `<loc>` entries
matching any flagged route under public-demo.

## Audit scope exception — login overlay

The canonical/home-page audit intentionally excludes the
`<div id="bv-login-overlay">…</div>` block from its route-leak scan.

That block is the site's authentication-UX panel (see
`partials/login_overlay.html.twig`) and includes a "Bliv medlem"
call-to-action linking to `/opret-medlemskab` as login-flow copy.
Anonymous visitors only see the overlay after they actively click
"Log ind" — it is not a feature-discovery surface the way the main
navigation, footer columns, or body content are.

The audit's charter is that PAGE NAVIGATION, CANONICAL LINKS, and
PRIMARY BODY CONTENT under `public-demo` do not advertise disabled
features. The authentication overlay is an intentional carve-out.
Gating the overlay's membership-signup link behind
`feature_enabled('membership_signup')` is reasonable future work but
lives outside Sprint 4's scope (which is PHP handler gates and
Playwright coverage — not further Twig gating).

## Audit scope exception — hero CTA buttons

The home-page hero renders a `<div class="bv-hero__actions">` strip
whose buttons are defined as YAML data in
`pages/01.home/_01.hero/hero.md` (keys `buttons[].url`). Under
public-demo one of those buttons is "Se Kalender" with
`url: /vaerkstedskalenderen`.

This is marketing-copy CTA content driven by page-level data — not
site navigation, not a canonical link, not a footer advertisement.
The audit therefore elides the hero-actions block before the route
scan. Gating the hero buttons themselves would require either a
Twig guard in the hero template or a frontmatter flag on individual
button entries — both outside Sprint 4's scope.

Subsequent sprints that rework hero content should gate the button
list by checking `feature_enabled(entry.flag)` or a similar
per-item guard; when that lands, this exception can be dropped.

## community_footer_column — anon probe notes

The Fællesskab footer column is wrapped in BOTH
`feature_enabled('community_footer_column')` AND
`grav.user.authenticated and grav.user.authorized` (per ADR-001).
Anonymous probes therefore see no heading under either profile, so
the `community_footer_column -- internal` assertion in
`feature-flags-plugins.js` is a negative-parity check (heading
absent from anon home), not a presence check. The authenticated-
presence path is exercised by the Sprint-3 community-affordance
spec under `tests/authenticated/` and remains green.
