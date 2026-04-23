# Specification — Apply feature flags to unfinished features for public demo release

Status: Planned
Owner: thomas@appforceone.dk
Depends on: [development_flags_specification.md](development_flags_specification.md) (must ship first)
Scope: Wire the feature-flag system into every page, module, overlay, and nav/footer entry that is not yet ready for public viewing, so a trimmed-down site can be published while development continues.

---

## Motivation

The current site is a demo. Several features are built but not ready to be seen outside the development team — the roadmap surface, the community affordances (Forslå Feature, Rapportér fejl), the membership-creation flow, and a handful of placeholder content sections. We want to ship a "public demo" profile that presents only the finished surface (home, workshop calendar, workshop listings, contact, statutes, privacy) while keeping every unfinished feature wired up behind a flag that the dev team can enable per environment.

The feature-flag mechanism itself is defined in [development_flags_specification.md](development_flags_specification.md) — this spec does not redefine it. This spec lists **what to flag and how it must behave when off**.

---

## Non-goals

- Building the flag system (covered by the flags spec).
- Any visual redesign. A page that is visible in both profiles must look identical.
- Role/user-based gating. Some of these features are already auth-gated; the flag is an additional environment-level kill switch on top of auth.
- Per-user rollout, percentage rollouts, A/B testing. Flags here are boolean, per environment.

---

## Two target profiles

The same codebase must support two configurations by env-specific `features.yaml` only:

### Public demo profile (production-facing)

Only the following top-level pages are reachable and visible in navigation/footer/sitemap:

- `/` (Home) — with some modules hidden, see below
- `/vaerksteder` (Workshops)
- `/privatlivspolitik` (Privacy policy)
- `/login` (Required for the few auth flows that remain, but Forslå/Roadmap/Rapportér are hidden even for logged-in users when the flag is off)

Everything else listed in this document is disabled — including the workshop calendar, contact page, and statutes page, which are flagged out of the initial release pending further polish.

### Internal/dev profile

All flags enabled. The site behaves exactly as it does today.

---

## Flag catalogue

All flags are declared in the `FeatureFlag` enum introduced by the flags spec. Names use snake_case. Every flag in this table must exist; environments only set the ones they want enabled.

| Flag | Gate target | Default (public demo) | Default (internal) |
|---|---|---|---|
| `roadmap` | `/roadmap` page, all nav/footer entries, roadmap card partial | false | true |
| `feature_suggestion` | `/foreslaa-feature` page, footer trigger, overlay partial, `/feature-suggestion/submit` endpoint | false | true |
| `bug_report` | Footer trigger, overlay partial, `/bug-report/submit` endpoint | false | true |
| `community_footer_column` | The entire `Fællesskab` footer column (`h3.bv-footer__heading`) | false | true |
| `membership_signup` | `/opret-medlemskab` (register) page, any link pointing to it | false | true |
| `newsletter_signup` | Home module `_04.newsletter` and any other newsletter form | false | true |
| `event_highlight` | Home module `_02.event-highlight` | false | true |
| `press_page` | `/presse` page and nav/footer links | false | true |
| `minutes_archive` | `/referater` page and nav/footer links | false | true |
| `workshop_calendar_filters` | Filter module `_02.filters` on `/vaerkstedskalenderen` | false | true |
| `workshop_calendar_featured` | Featured module `_03.featured` on `/vaerkstedskalenderen` | false | true |
| `workshop_detail_pages` | Sub-pages under `/vaerksteder/*` (individual workgroup pages) | false | true |
| `press_assets_download` | Downloadable assets section on `/presse` (`_03.assets`) | false | true |
| `press_stats` | Stats section on `/presse` (`_02.stats`) | false | true |
| `workshop_calendar` | `/vaerkstedskalenderen` page and all nav/footer links to it | false | true |
| `contact_page` | `/kontakt` page and all nav/footer links to it | false | true |
| `statutes_page` | `/vedtaegter` page and all nav/footer links to it | false | true |

An environment's `features.yaml` sets exactly the keys it wants on. Omission means off. See the flags spec for value rules.

---

## Gating mechanics per target

The flags spec already describes page-frontmatter gating, Twig helpers, and centralized collection filtering. This spec records **where each gate has to be applied** concretely.

### Pages (use frontmatter `feature:` field)

Edit the page's `*.md` frontmatter to add the `feature:` key:

- [config/www/user/pages/11.roadmap](config/www/user/pages/11.roadmap) → `feature: roadmap`
- [config/www/user/pages/10.foreslaa-feature](config/www/user/pages/10.foreslaa-feature) → `feature: feature_suggestion`
- [config/www/user/pages/09.opret-medlemskab](config/www/user/pages/09.opret-medlemskab) → `feature: membership_signup`
- [config/www/user/pages/08.presse](config/www/user/pages/08.presse) → `feature: press_page` (applied to the modular root so the whole page and all modules disappear together)
- [config/www/user/pages/07.referater](config/www/user/pages/07.referater) → `feature: minutes_archive`
- All subpages under [config/www/user/pages/03.vaerksteder](config/www/user/pages/03.vaerksteder) except `modular.md`, `_01.hero`, `_02.workgroups` (i.e. `det-groenne-faellesskab`, `kreativ-fitness`, `kulturhus`, `makerspace`) → `feature: workshop_detail_pages`
- [config/www/user/pages/02.vaerkstedskalenderen](config/www/user/pages/02.vaerkstedskalenderen) `modular.md` → `feature: workshop_calendar` (applied to the modular root so the whole page and all calendar sub-modules disappear together — when off, the nested `workshop_calendar_filters` and `workshop_calendar_featured` sub-flags are moot)
- [config/www/user/pages/04.kontakt](config/www/user/pages/04.kontakt) → `feature: contact_page`
- [config/www/user/pages/05.vedtaegter](config/www/user/pages/05.vedtaegter) `modular.md` → `feature: statutes_page`

When a page's flag is off:
- Direct request returns 404 (per flags spec).
- Page is absent from any collection, related-page list, sitemap, and `_02.workgroups` card grid.

### Modular home sections (frontmatter on the module folder's `*.md`)

- `config/www/user/pages/01.home/_02.event-highlight/*.md` → `feature: event_highlight`
- `config/www/user/pages/01.home/_04.newsletter/*.md` → `feature: newsletter_signup`

Other home modules (`_01.hero`, `_03.workgroups`) remain always-on.

### Modular calendar sections

- `config/www/user/pages/02.vaerkstedskalenderen/_02.filters/*.md` → `feature: workshop_calendar_filters`
- `config/www/user/pages/02.vaerkstedskalenderen/_03.featured/*.md` → `feature: workshop_calendar_featured`

`_01.hero` and `_04.events` remain always-on so the calendar is never blank.

### Modular press sections

- `config/www/user/pages/08.presse/_02.stats/*.md` → `feature: press_stats`
- `config/www/user/pages/08.presse/_03.assets/*.md` → `feature: press_assets_download`

When the parent `press_page` flag is off the whole page is 404 and these sub-flags are moot. When `press_page` is on, these sub-flags can independently hide their sections.

### Navigation / footer / overlay partials (Twig `feature_enabled()`)

- [config/www/user/themes/byvaerkstederne/templates/partials/navigation.html.twig](config/www/user/themes/byvaerkstederne/templates/partials/navigation.html.twig) — wrap any link that points to a flagged page in `{% if feature_enabled('<flag>') %}` so nav renders cleanly without dead entries. Today the community affordances are footer-only (per ADR-001); keep that — but `press_page`, `minutes_archive`, `membership_signup` links must also be removed from any nav surface when off.
- [config/www/user/themes/byvaerkstederne/templates/partials/footer.html.twig](config/www/user/themes/byvaerkstederne/templates/partials/footer.html.twig):
  - Entire `Fællesskab` column (`h3.bv-footer__heading` "Fællesskab") wrapped in `feature_enabled('community_footer_column')`. When that column's flag is off, the whole column disappears and the three child flags (`roadmap`, `feature_suggestion`, `bug_report`) are not consulted.
  - When the column is on, each child entry inside it is independently wrapped in its own flag check.
  - Links to `/presse`, `/referater`, `/opret-medlemskab`, `/vaerkstedskalenderen`, `/kontakt`, `/vedtaegter` are wrapped in their respective flags.
- [config/www/user/themes/byvaerkstederne/templates/partials/bug_report_overlay.html.twig](config/www/user/themes/byvaerkstederne/templates/partials/bug_report_overlay.html.twig) and [feature_suggestion_overlay.html.twig](config/www/user/themes/byvaerkstederne/templates/partials/feature_suggestion_overlay.html.twig) — the include in `base.html.twig` is guarded by `feature_enabled('bug_report')` / `feature_enabled('feature_suggestion')` so the overlay markup is not emitted at all when off. This also prevents the overlay JS from trying to bind handlers.
- [config/www/user/themes/byvaerkstederne/templates/partials/roadmap_card.html.twig](config/www/user/themes/byvaerkstederne/templates/partials/roadmap_card.html.twig) — callers must guard the include with `feature_enabled('roadmap')`.

### PHP plugin handlers (server-side gate)

Even when overlay markup is hidden, the POST endpoints must reject requests when the flag is off, returning a 404 (not 403 — a disabled feature must not leak its existence). Apply at the top of the plugin's onPagesInitialized / onPageInitialized handler:

- [config/www/user/plugins/roadmap/roadmap.php](config/www/user/plugins/roadmap/roadmap.php): gate `/roadmap/vote` and all admin sub-endpoints on `roadmap`.
- [config/www/user/plugins/feature-suggestion/feature-suggestion.php](config/www/user/plugins/feature-suggestion/feature-suggestion.php): gate `/feature-suggestion/submit|approve|decline` on `feature_suggestion`.
- [config/www/user/plugins/bug-report/bug-report.php](config/www/user/plugins/bug-report/bug-report.php): gate `/bug-report/submit`, `/admin/bug-report-promote`, `/admin/bug-report-image` on `bug_report`.

Plugins must consume `FlagStore` via Grav's container, not re-read YAML directly.

### Sitemap / robots

If a sitemap plugin is enabled, disabled pages must not appear. The flags spec requires centralized collection filtering; this spec adds: verify the site's sitemap output (if any) respects the filter, and add a test.

---

## Content-free behaviour when all community flags are off

With `roadmap`, `feature_suggestion`, `bug_report`, and `community_footer_column` all off:

- Footer has no `Fællesskab` column at all (not an empty column).
- No overlays are loaded, no overlay JS binds, no hidden `<dialog>` markup is present.
- `/roadmap`, `/foreslaa-feature` return 404.
- `/bug-report/submit`, `/feature-suggestion/submit`, `/roadmap/vote` return 404.
- Existing behaviour from [decisions/ADR-001-navigation-footer-placement.md](decisions/ADR-001-navigation-footer-placement.md) (community affordances are footer-only, auth-gated) remains the fallback when flags are on — flags are additive, not a replacement.

---

## Environment files

Two new env-scoped config files are introduced as part of rolling this out:

```
config/www/user/env/<public-demo-hostname>/config/features.yaml
config/www/user/env/<internal-hostname>/config/features.yaml
```

The hostnames are chosen by ops; this spec does not pin them. Examples:

```yaml
# public-demo
enabled:
  # intentionally empty for phase 1 — only finished surfaces visible
  {}

# internal / staging
enabled:
  roadmap: "true"
  feature_suggestion: "true"
  bug_report: "true"
  community_footer_column: "true"
  membership_signup: "true"
  newsletter_signup: "true"
  event_highlight: "true"
  press_page: "true"
  minutes_archive: "true"
  workshop_calendar: "true"
  workshop_calendar_filters: "true"
  workshop_calendar_featured: "true"
  workshop_detail_pages: "true"
  press_assets_download: "true"
  press_stats: "true"
  contact_page: "true"
  statutes_page: "true"
```

A developer working locally uses the internal profile by default.

---

## Acceptance criteria

1. `FeatureFlag` enum contains every flag in the catalogue above, and every flag has exactly one authoritative gate point (page frontmatter, Twig guard, or PHP handler guard) — no duplicated checks.
2. With the public-demo `features.yaml` in effect:
   - Only the pages listed in "Public demo profile" are reachable. Everything else — including `/vaerkstedskalenderen`, `/kontakt`, `/vedtaegter` — returns 404.
   - Navigation contains no entries pointing to disabled pages.
   - Footer contains no `Fællesskab` column and no `/presse`, `/referater`, `/opret-medlemskab` links.
   - View source on any public page shows no overlay markup, no roadmap card markup, no references to disabled routes.
   - `curl -X POST /bug-report/submit`, `/feature-suggestion/submit`, `/roadmap/vote` all return 404.
3. With the internal `features.yaml` in effect, the site behaves identically to today (no regressions against the existing Playwright suite plus the suite from [roadmap_bug_feature_tests_specification.md](roadmap_bug_feature_tests_specification.md)).
4. Flipping a single flag from false to true without any cache clear reflects within one `bin/grav clearcache` cycle — no code deploy required.
5. A Playwright test file `tests/feature-flags.spec.js` is added that runs against both profiles (selected via a `PROFILE=public_demo|internal` env var the test harness sets up) and asserts the relevant presence/absence for each flag. Minimum one test per flag.
6. No user-visible string in the public-demo profile reveals the existence of a disabled feature (no "coming soon", no disabled buttons, no ghost nav entries).
7. No hardcoded flag checks leak into templates that should be calling a centralized filter — collections of pages in nav and card grids go through the shared filter helper from the flags spec.

---

## Rollout order

1. Land the flags spec (must precede this work).
2. Add the `FeatureFlag` enum entries and env `features.yaml` files. All flags default off in public-demo, on in internal. Verify internal parity.
3. Apply page-frontmatter gates (one PR per page group: roadmap+foreslaa, membership, press, referater, workshop details).
4. Apply Twig partial gates for nav/footer/overlays.
5. Apply PHP handler gates.
6. Add the `tests/feature-flags.spec.js` suite.
7. Switch the public demo host to the public-demo profile. The internal host continues on the internal profile.

---

## References

- [development_flags_specification.md](development_flags_specification.md) — the flag mechanism
- [decisions/ADR-001-navigation-footer-placement.md](decisions/ADR-001-navigation-footer-placement.md) — existing placement rules the flags layer on top of
- [roadmap_bug_feature_tests_specification.md](roadmap_bug_feature_tests_specification.md) — the e2e test spec whose coverage must continue to pass under the internal profile
