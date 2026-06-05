# Theme-template audit for feature-flag hidden-references (Sprint 3)

Audited against `config/www/user/themes/byvaerkstederne/templates/` at the
time of Sprint 3 implementation. Purpose: identify every surface that
renders a page collection capable of hosting a flag-gated page, confirm
`|feature_visible` is applied where needed, and justify every surface that
intentionally skips the filter.

Nav-hidden verification strategy used: **option (a)** — live HTTP
verification against a fixture modular child at
`user/pages/99.test-flagged/default.md` with `feature: checkout_v2`. With
the empty committed config the fixture's marker string
(`MARKER_FLAG_BODY`) is absent from any rendered modular parent page;
with the localhost env override `checkout_v2: "true"` it appears.

## Templates that iterate a page collection

| Template | Collection source | Action | Rationale |
|---|---|---|---|
| `templates/modular.html.twig` | `page.collection()` | `|feature_visible` applied | Iterates arbitrary child modules; a module page may carry `feature:` frontmatter. This is the only template in the theme that iterates a page-collection capable of surfacing arbitrary child pages. |

## Templates that render links but NOT from a page collection

These surfaces are left unfiltered — justification per surface:

| Template | Surface | Why safe |
|---|---|---|
| `partials/navigation.html.twig` | Top-nav links | Hand-curated hrefs (`/`, `/vaerkstedskalenderen`, `/vaerksteder`, `/kontakt`, `/vedtaegter`, `/privatlivspolitik`, `/referater`, `/presse`). None of these routes are flagged-gated, none are derived from iterating a page collection. A future flagged top-level page would need this audit revisited. |
| `partials/footer.html.twig` | Footer columns | All hrefs are hand-curated. The auth-gated Fællesskab column uses `/roadmap` plus two modal-open buttons — no iteration, no page collection. |
| `templates/default.html.twig` | Single page body | Renders `{{ content|raw }}` for the current page only; no child iteration. |
| `templates/error.html.twig` | Single page body | Error page content; no collection. |
| `templates/foreslaa-feature.html.twig`, `templates/register.html.twig`, `templates/roadmap.html.twig` | Static layouts | No child iteration. |
| `templates/modular/*.html.twig` (all 30+ modules) | Static layouts per module | Each module renders its own fields (CTAs, hero copy, wishlist arrays out of page.header). None fetch an arbitrary page collection of potentially-flagged pages. |
| `partials/base.html.twig` | Site chrome | No page-collection rendering. |
| `partials/roadmap_card.html.twig`, `partials/*_overlay.html.twig` | Fixed markup | No page iteration. |

## Sitemap, breadcrumbs, search

- The theme ships no `sitemap.*.twig`, no `breadcrumbs` partial, and no
  search-result template. The sitemap plugin (if installed) is not in the
  theme's template tree. Search is absent. No further filtering surface
  exists to audit at this time.
- A future install of the `sitemap` or `pagination` plugin must include
  `|feature_visible` on any page-collection it exposes to Twig; this
  audit note is the place to record that decision.

## Test fixtures used during live verification

The following fixture pages were created under `config/www/user/pages/`
for live HTTP verification of Sprint 3 criteria:

- `99.test-flagged/default.md` — `feature: checkout_v2`
- `98.test-partners/default.md` — `feature: partner_portal`
- `97.test-partners-b/default.md` — `feature: partner_portal`
- `96.test-unknown/default.md` — `feature: not_a_flag`
- `95.test-plain/default.md` — no `feature:` key

Per sprint criterion `no_test_fixture_in_content`, these are **removed
before the branch is finalised**. They are committed only during the
evaluator's live-HTTP run so `curl` can hit them. Persistent versions of
these fixtures (for PHPUnit) live in this `tests/fixtures/` tree instead.
