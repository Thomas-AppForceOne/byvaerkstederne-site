# Specification — Unify event-card rendering into a single canonical partial

Status: Planned
Owner: thomas@appforceone.dk
Depends on: PR #35 (mobile-rendering polish) — establishes the
`.bv-event-row` class structure this spec extends. The container-query
implementation introduced here **replaces** PR #35's `@media (max-width:
767px)` rules on `.bv-event-row` (see §"CSS — container query supersedes
PR #35 media rules" below). The spec itself lives on
`feature/mobile-rendering`.

Design source (hi-fi, in-repo, normative): the Claude Design handoff
bundle at
[`documentation/design/event-row-handoff/`](../documentation/design/event-row-handoff/README.md).
**Revision 2** of the handoff is the authoritative visual + data
contract — it supersedes revision 1 entirely. References below to
"the handoff" or "the v2 handoff" point at the in-repo bundle as it
stands. The bundle includes a self-contained `reference/demo.html`
that renders both desktop and stacked states with the production CSS
live; agents should open it before writing any code.

Scope: Replace four bespoke event-card markups with a single canonical
Twig partial whose visual + data contract is defined by the v2 handoff,
so future visual changes and bug fixes for "event cards" land in one
place and reach every page that renders one. The desktop look matches
the v2 handoff spec pixel-precisely; the stacked look (card width <
540 px) matches the v2 handoff's stacked spec; this is **not** a
strict-zero-diff faithful reproduction of the current desktop
rendering — minor pixel deltas introduced by adopting the v2 handoff's
typography and spacing are acceptable when they match the v2 handoff.

> **What this spec is NOT.** It is not a redesign of the whole site's
> event surface. It is not a content-schema migration (page YAML files
> are not rewritten beyond extending `event_list` events with the
> per-event fields the partial now consumes). It is not a refactor of
> every BEM class in the stylesheet. Scope is narrowly: introduce one
> partial, route four existing modular templates through it, adopt the
> v2 handoff's container-query layout (with the v2 wrapper-fix), prove
> the four signals + stacked rendering at narrow container widths.

---

## Motivation

The mobile-rendering polish that landed as PR #35 fixed four iPhone-class
defects on event-row cards rendered by `event_list.html.twig`. The
Playwright suite green-lit those fixes against `/vaerkstedskalenderen`.
A user-reported defect on `/vaerksteder/krea-cafe/syvaerkstedet`
(the Lene Pels page) and the Krea Café scrapbook page showed the same
visual defect — drop-in / Tilmeld column overflowing the viewport — but
on pages where none of the fixes applied because the cards on those
pages are rendered by a **different template** (`atelier_sessions.html.twig`)
that does not use the `.bv-event-row` class structure at all. Its card
wrapper is an inline-styled `<div style="display: grid;
grid-template-columns: 8rem 1fr auto; …">` with no class hook — so a
`@media (max-width: 767px)` rule targeting `.bv-event-row` cannot reach
it, and the same mobile bug recurs untouched on every atelier sub-page
that uses this template.

There are currently four templates rendering visually-similar
"event-shaped" cards, in three different shapes of bespoke markup:

| Template | Card markup | Class-based? |
|---|---|---|
| `event_list.html.twig` | `.bv-event-row` BEM (post-#35) | yes — canonical |
| `atelier_sessions.html.twig` | inline-styled grid, no classes | no |
| `calendar_featured.html.twig` | `.bv-featured-event` bespoke BEM | yes — bespoke |
| `event_highlight.html.twig` | `.bv-event-highlight` + nested `.bv-card` + `.bv-event-date` | yes — bespoke |

The proliferation is the bug: a CSS fix to one template does not reach
the others; a future visual tweak requires four edits and four reviews;
a future Playwright probe must enumerate every template's selectors
separately. The blast radius of every event-card change scales with
the number of templates.

The fix is to introduce a single canonical Twig partial that all four
modulars `include`, with the visual + data contract pinned by the v2
in-repo Claude Design handoff. After this lands:

- A future visual change to event cards is one partial edit.
- A future Playwright probe of event-card geometry is one selector set
  (`.bv-event-row[__date|__body|__meta|__title|__desc|__badge|__price|__capacity]`).
- The handoff's container-query stacking automatically applies to every
  page rendering any event card — including the Lene Pels and Krea
  Café atelier sub-pages — and works equally well in a phone viewport
  OR in a narrow desktop sidebar OR in a 2-column tablet grid.
- A new event-shaped surface (a future "upcoming workshops" widget,
  a "your enrolments" listing in a member area, etc.) starts by
  including the partial and is correct-by-construction.

The unification also closes three production-data regressions that an
attempted first pass against the v1 handoff exposed (and that the v2
handoff specifically addresses):

- **F1** — calendar filter regression. The v1 partial conflated the
  workshop accent colour and the filter ID into one field, so
  `data-group` got fed the colour token and the JS filter at
  `site.js:687` stopped matching every non-`kulturhus` button.
- **F2** — badge eyebrow dropped on every event_list row.
- **F3** — CTA + price + capacity collapsed to one meta slot, throwing
  away two of three meta signals on every real calendar event.

The v2 handoff treats those signals as first-class fields. The spec
below absorbs the v2 model directly.

---

## Non-goals

- **No further visual redesign beyond the v2 handoff.** The v2 handoff
  is the ground-truth visual contract. The spec does not introduce
  additional design directions, alternative card shapes, or
  "designer's choice" variants beyond what the v2 handoff specifies.
- **No new card types.** The partial covers the four templates listed
  above and nothing else. It does not absorb `atelier_techniques.html.twig`
  (pitch / technique cards — different visual shape) or
  `workshop_status.html.twig` (project status cards — not event cards).
- **No YAML schema migration of page sources.** Page YAMLs under
  `config/www/user/pages/` are not edited. The Flex Object data file
  `config/www/user/data/flex-objects/begivenheder.yaml` already
  carries every field the v2 model needs (`group`, `button_style`,
  `badge`, `price`, `button_text`, `button_url`, `capacity`, `event_time`,
  etc.); the migration reads them, it does not extend the schema.
- **No `.bv-event-row` class rename.** The canonical class namespace
  stays `.bv-event-row` — reusing the BEM PR #35 introduced rather than
  switching to a new namespace. A new sibling class `.bv-event-item`
  is introduced as the container-query wrapper (per v2; see CSS section).
- **No new media-query breakpoints.** Mobile / responsive handling
  moves to a **container query** on `.bv-event-item` (per the v2
  handoff). PR #35's `@media (max-width: 767px)` rules on
  `.bv-event-row` specifically are deleted; other PR #35 rules
  (workgroup-card, pitch-card) are unaffected.
- **No edits to community-affordance placement** (Forslå Feature,
  Roadmap, Rapportér fejl) — they stay footer-only and auth-gated per
  ADR-001.
- **No PHP plugin work.** Templates and CSS only.
- **No accessibility regression**, but no new ARIA work beyond what the
  canonical partial naturally needs (`aria-hidden` on purely decorative
  elements, semantic landmarks where present). Title is a semantic
  `<h3>` per the v2 handoff (this was a latent a11y regression in the
  v1 attempt that the v2 handoff explicitly fixes).
- **No JavaScript.** The handoff's React reference is an explanation
  artefact only; the production responsive behaviour ships as a CSS
  container query.

---

## Approach

### Canonical event-data shape (per the v2 handoff)

The partial accepts one canonical object. Per the v2 handoff:

```yaml
event:
  # Required
  day: "10"           # numeric or zero-padded string (from event_date|date('j'))
  month: "JUN"        # 3-letter uppercase abbreviation (from event_date|date('M'))
  title: "Elektronik og 3D-print for nybegyndere"

  # Optional body content (above + below the title in the body column)
  badge: "Makerspace & Reparation"  # eyebrow chip above the title; uses .bv-badge
  time: "Onsdag kl. 18–20"           # bold time line below the title
  description: "Drop-in værksted. 12 år og opefter."

  # Optional styling — DISTINCT fields, never conflated.
  accent: "secondary"  # VISUAL: drives --bv-accent (border colour + badge fill)
                       # one of: primary | secondary | tertiary | kulturhus
  filter: "makerspace" # BEHAVIOUR: emitted as data-group="{filter}" for site.js
                       # one of the filter IDs the calendar's filter buttons emit
                       # via data-filter (makerspace, krea-cafe, groenne,
                       # kulturhus, alle)

  # Optional meta-column slots — render any combination, empty slots collapse.
  # ALL three are independently optional. This is the v2 unification: the
  # atelier "Drop-in / Ingen tilmelding" pattern is no longer a special case,
  # it is just the canonical model with capacity empty and price = "Drop-in".
  price: "250 kr / person"            # prominent value at top of meta column
  cta:                                # call-to-action button in meta column
    label: "Tilmeld"
    href: "/tilmeld/elektronik"
    variant: "secondary"              # optional; defaults to accent value
  capacity: "12 / 20"                 # read-only counter with `group` glyph
```

Three rules to internalise:

1. **`accent` and `filter` are NEVER the same thing.** They often
   correlate (`makerspace → secondary blue`) but are set per-event from
   distinct YAML fields. `data-group` MUST be fed the filter ID, never
   the colour token (this was the F1 regression).
2. **All three meta slots are independently optional.** A row with
   only `price` renders just the price. A row with only `cta` renders
   just the button. An atelier drop-in row sets `price: "Drop-in"`,
   `cta: { label: "Se Makerspace", href: "/vaerksteder/makerspace" }`,
   capacity empty. A workshop session sets all three. Empty slots
   collapse with no reserved space.
3. **`badge` is body-column eyebrow, not meta.** It sits above the
   `<h3>` title inside `.bv-event-row__body`, using the existing
   `.bv-badge` class with the accent-variant modifier.

### Mapping per source template (canonicalised against the v2 model)

| Current source | Canonical |
|---|---|
| `begivenheder.yaml` `group:` (filter ID like `makerspace`, `krea-cafe`) | `event.filter` — emitted as `data-group="{filter}"` |
| `begivenheder.yaml` `button_style:` (`primary`/`secondary`/`tertiary`/`kulturhus`) | `event.accent` — emitted as inline `style="--bv-accent: var(--{accent});"` |
| `begivenheder.yaml` `badge:` | `event.badge` |
| `begivenheder.yaml` `event_date|date('M')` | `event.month` |
| `begivenheder.yaml` `event_date|date('j')` | `event.day` |
| `begivenheder.yaml` `event_time:` | `event.time` |
| `begivenheder.yaml` `title:` / `description:` | `event.title` / `event.description` |
| `begivenheder.yaml` `price:` | `event.price` |
| `begivenheder.yaml` `button_text:` + `button_url:` | `event.cta = { label, href, variant: accent }` |
| `begivenheder.yaml` `capacity:` (free-form string) | `event.capacity` |
| `event_list` page-header fallback fields | same canonical fields, page-header sourced when flex-objects absent |
| `atelier_sessions` page-level `h.accent` | `event.accent` (per-session accent overrides not in scope) |
| `atelier_sessions` `s.day/month/title/time/description` | same canonical fields |
| `atelier_sessions` `s.contact_name` + `s.contact_sms` | `event.cta = { label: s.contact_name, href: "sms:+45" ~ s.contact_sms }` |
| `atelier_sessions` `s.no_signup: true` | `event.price = "Drop-in"`, no `cta`, no `capacity` |
| `atelier_sessions` filter (page-level) | `event.filter` (e.g. `krea-cafe`) |
| `calendar_featured` h.event_title / event_description / event_date | `event.title` / `event.description` / parsed (day,month); featured flag → `--featured` modifier |
| `event_highlight` primary featured event | same — featured modifier |
| `event_highlight` secondary events list | one canonical `event` each, no modifier |

### The partial

```
config/www/user/themes/byvaerkstederne/templates/partials/event_card.html.twig
```

Renders the v2 handoff's DOM exactly:

```twig
<li class="bv-event-item">
  <article class="bv-event-row{% if event.featured %} bv-event-row--featured{% endif %}"
           {% if event.filter %}data-group="{{ event.filter }}"{% endif %}
           style="--bv-accent: var(--{{ event.accent|default('primary') }});">

    <div class="bv-event-row__date">
      <span class="bv-event-row__date-month">{{ event.month }}</span>
      <span class="bv-event-row__date-day">{{ event.day }}</span>
    </div>

    <div class="bv-event-row__body">
      {% if event.badge %}
        <span class="bv-badge bv-badge--{{ event.accent|default('primary') }} bv-event-row__badge">{{ event.badge }}</span>
      {% endif %}
      <h3 class="bv-event-row__title">{{ event.title }}</h3>
      {% if event.time %}<p class="bv-event-row__time">{{ event.time }}</p>{% endif %}
      {% if event.description %}<p class="bv-event-row__desc">{{ event.description }}</p>{% endif %}
    </div>

    {% if event.price or event.cta or event.capacity %}
      <div class="bv-event-row__meta">
        {% if event.price %}
          <span class="bv-event-row__price">{{ event.price }}</span>
        {% endif %}
        {% if event.cta and event.cta.label and event.cta.href %}
          <a class="bv-btn bv-btn--{{ event.cta.variant|default(event.accent|default('primary')) }} bv-btn--sm"
             href="{{ event.cta.href }}">{{ event.cta.label }}</a>
        {% endif %}
        {% if event.capacity %}
          <span class="bv-event-row__capacity">
            <span class="material-symbols-outlined" aria-hidden="true">group</span>
            {{ event.capacity }}
          </span>
        {% endif %}
      </div>
    {% endif %}
  </article>
</li>
```

Three structural details called out by the v2 handoff:

1. **`<li class="bv-event-item">` is the container-query target.** It
   sits AROUND `<article class="bv-event-row">`. Setting
   `container-type` on `.bv-event-row` and trying to restyle it from
   its own `@container` query does not work — an element cannot react
   to its own container-type; container queries only affect
   descendants. This was a latent bug in the v1 spec. The v2 fix is
   the wrapper.
2. **Title is `<h3>`, not `<div>`.** Accessibility and heading
   hierarchy.
3. **Each list of cards is wrapped in `<ul class="bv-event-list">`
   (or analogous) at the modular template level.** The `<li>` per
   card preserves semantic list structure.

### CSS — container query on `.bv-event-item`, NOT `.bv-event-row`

Stylesheet changes live in
`config/www/user/themes/byvaerkstederne/css/theme.css` under the
`/* Calendar */` section.

**Removed** (delete from theme.css):

- The `.bv-event-row`, `.bv-event-row__date`, `.bv-event-row__date-day`,
  `.bv-event-row__date-month`, `.bv-event-row__body`,
  `.bv-event-row__title`, `.bv-event-row__desc`,
  `.bv-event-row__meta`, `.bv-event-row__meta .bv-btn`, and
  `.bv-event-row__capacity` rules inside the existing `@media
  (max-width: 767px)` block (introduced by PR #35 commit `ea817e6`,
  now rebased onto the new history but semantically equivalent).
  These rules are functionally replaced by the container query and
  removing them prevents both layers from cascading against each other.
- The bespoke selectors `.bv-featured-event*`,
  `.bv-event-highlight*`, and `.bv-event-date*` — once their consumers
  are migrated, these are dead code. The implementation removes them
  as the last step of the migration; a follow-up grep over
  `config/www/user/` must return zero hits before they can be deleted.

**Added** (insert into the calendar section verbatim from the v2
handoff's `## Production implementation` block):

```css
/* Each entry is its own query container; the row (descendant) reacts. */
.bv-event-item { container-type: inline-size; container-name: event-row; }
.bv-event-item + .bv-event-item { margin-top: var(--space-3); }

.bv-event-row {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    padding: var(--space-6) var(--space-4);
    background: var(--surface-container-lowest);
    border-left: var(--border-thick) solid var(--bv-accent, var(--primary));
    transition: transform 0.2s ease;
}
.bv-event-row:hover { transform: translateX(0.25rem); }

/* DATE */
.bv-event-row__date {
    flex-shrink: 0; min-width: 4rem; text-align: center;
    font-family: var(--font-headline); font-weight: 700; line-height: 1;
    display: flex; flex-direction: column; align-items: center;
}
.bv-event-row__date-month { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--on-surface-variant); }
.bv-event-row__date-day { font-size: 1.5rem; }

/* BODY: badge + h3 + time + description */
.bv-event-row__body { flex: 1; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-1); }
.bv-event-row__badge { margin-bottom: var(--space-1); }
.bv-event-row__title { margin: 0; font-family: var(--font-headline); font-weight: 700; text-transform: uppercase; letter-spacing: var(--tracking-tight); font-size: 1.25rem; line-height: 1.15; }
.bv-event-row__time  { margin: 0; font-family: var(--font-headline); font-weight: 700; font-size: 0.85rem; }
.bv-event-row__desc  { margin: 0; font-size: 0.875rem; color: var(--on-surface-variant); text-wrap: pretty; }

/* META: price over CTA over capacity (each independently optional) */
.bv-event-row__meta { flex-shrink: 0; min-width: 9rem; display: flex; flex-direction: column; align-items: flex-end; gap: var(--space-2); text-align: right; }
.bv-event-row__price { font-family: var(--font-headline); font-weight: 700; font-size: 0.95rem; line-height: 1.2; }
.bv-event-row__capacity { display: inline-flex; align-items: center; gap: 0.25rem; font-size: 0.875rem; color: var(--on-surface-variant); }
.bv-event-row__capacity .material-symbols-outlined { font-size: 1.1rem; }

/* STACKED: when the ROW itself is < 540px */
@container event-row (max-width: 540px) {
    .bv-event-row { flex-direction: column; align-items: flex-start; gap: var(--space-3); }
    .bv-event-row__date { flex-direction: row; align-items: baseline; gap: var(--space-2); min-width: auto; text-align: left; }
    .bv-event-row__date-day { order: -1; font-size: 1.25rem; }   /* "10 JUN" */
    .bv-event-row__date-month { font-size: 0.8rem; }
    .bv-event-row__body,
    .bv-event-row__meta { width: 100%; }
    .bv-event-row__meta { align-items: flex-start; text-align: left; margin-top: var(--space-2); }
    .bv-event-row__meta .bv-btn { width: 100%; }   /* full-width tap target */
}
```

> **Caveat the v2 handoff explicitly calls out:** CSS comments cannot
> be nested. Do not write `/* … /* Calendar */ … */` — the inner `*/`
> closes the comment early and corrupts the next rule. Use a single
> comment per block.

`.bv-event-row--featured` modifier — desktop-only typography bump on
`.bv-event-row__date-day` and tighter spacing for the
`calendar_featured` and `event_highlight` callers; mobile inherits the
canonical stacked layout without modifier-specific overrides. The
implementation adds it only if needed for visual parity.

### Tests

Two new Playwright files:

**`tests/mobile/event-card-unification.js`** — geometric and behavioural
invariants on each migrated route at viewport 390 × 844:

- No `.bv-event-row` child has its right edge past the row's right edge.
- Every `.bv-event-row__title`, `.bv-event-row__desc`, and
  `.bv-event-row__time` respects the body's right padding.
- `document.documentElement.scrollWidth === window.innerWidth` on each
  probed route.
- For atelier-sessions cards specifically: assert
  `getComputedStyle(card).flexDirection === 'column'` (proving the
  container query has fired and the card stacked).
- **F1 filter guard:** for each row, assert
  `row.dataset.group === event.filter` (the filter ID), and
  `row.style.getPropertyValue('--bv-accent')` is the accent token —
  never the same value. Click each filter button on
  `/vaerkstedskalenderen` and assert the visible rows match the
  filter; assert that filtering doesn't hide everything.
- **F2 badge guard:** for any seeded event with a `badge:` value,
  assert `.bv-event-row__badge` is present in the body and contains
  the badge text.
- **F3 three-meta-slots guard:** seed (or use the existing
  fully-populated event001) an event with all four signals (badge +
  price + CTA + capacity). Assert all of `.bv-event-row__price`,
  `a.bv-btn` inside `.bv-event-row__meta`, and
  `.bv-event-row__capacity` are present and contain the expected text.
  Assert that an event with no `capacity:` does NOT render a
  capacity element and that the meta column collapses around the
  remaining slots without reserved space.
- **a11y title guard:** assert that `.bv-event-row__title` resolves to
  an `<h3>` tag (not a `<div>`).

Routes probed (minimum set):

- `/vaerkstedskalenderen` — covers `event_list` (regression guard for
  PR #35 plus the F1/F2/F3 guards above).
- `/vaerksteder/krea-cafe/syvaerkstedet` — covers `atelier_sessions`
  (Krea Café scrapbook page, the user-reported defect).
- A second `atelier_sessions` page rendering the Lene Pels Photo
  Transfer / Silketryk sessions — implementation discovers the route
  via grep.
- Any route that renders `calendar_featured` — implementation discovers
  via grep.
- Any route that renders `event_highlight` — implementation discovers
  via grep.

**`tests/mobile/event-card-container-query.js`** — proves the
container-query mechanism works, not just the viewport-narrow case.
Uses `test.use({ viewport: { width: 1280, height: 800 } })` to force a
desktop viewport, then renders the partial inside a deliberately
narrow wrapper (360 px) on a sandbox HTML page served by the Grav
container OR injected via `page.setContent()` including the canonical
CSS. Assertions:

- `getComputedStyle(card).flexDirection === 'column'` even at 1280 px
  viewport.
- `getComputedStyle(card.querySelector('.bv-event-row__date-day')).order === '-1'`
  (the DOM-order flip is present and active).
- The CTA inside the row is `100%` wide at this stacked width
  (full-width tap target).
- No horizontal overflow within the wrapper.

This test is what catches a future regression to viewport-media-query
layout (the PR #35 approach), and what catches a regression to setting
`container-type` on `.bv-event-row` directly (the v1 handoff bug).

**`tests/anonymous/event-card-visual-parity.js`** — desktop visual
parity against the v2 handoff design. Per route, screenshots the
rendered output and compares against a baseline captured AFTER the
partial is introduced AND verified against the v2 handoff's
`demo.html`. Pixel-diff threshold: 5 % per existing project Playwright
convention. Baselines from any prior attempt are discarded.

The failure-path discipline from PR #35 carries through: each new
mobile test must demonstrably fail when the partial migration is
reverted on the affected template, before the migration is restored.

---

## Acceptance criteria

Each criterion is deterministic and verifiable with a Playwright probe
or a grep.

1. **Partial exists** at
   `config/www/user/themes/byvaerkstederne/templates/partials/event_card.html.twig`
   and accepts the documented canonical-event-data interface (Required:
   `day`, `month`, `title`; Optional: `badge`, `time`, `description`,
   `accent`, `filter`, `price`, `cta { label, href, variant? }`,
   `capacity`, `featured`).
2. **`event_list.html.twig` renders through the partial** —
   `grep -nE '<article class="bv-event-row|<div class="bv-event-row'
   config/www/user/themes/byvaerkstederne/templates/modular/event_list.html.twig`
   returns no inline matches (all rendering is via the partial).
3. **`atelier_sessions.html.twig` renders through the partial** —
   `grep -nE 'display: grid|grid-template-columns'
   config/www/user/themes/byvaerkstederne/templates/modular/atelier_sessions.html.twig`
   returns no inline matches on the card-wrapper line.
4. **`calendar_featured.html.twig` renders through the partial** —
   `.bv-featured-event` selectors are gone from the modular's card
   markup.
5. **`event_highlight.html.twig` renders through the partial** —
   `.bv-event-highlight` and `.bv-event-date` selectors are removed
   from the modular's card markup.
6. **Bespoke CSS classes are deleted** —
   `grep -rn '\.bv-featured-event\|\.bv-event-highlight\|\.bv-event-date'
   config/www/user/themes/byvaerkstederne/css/theme.css` returns no
   matches at the end of the run.
7. **PR #35's `@media (max-width: 767px)` rules on `.bv-event-row`
   are deleted** — `awk '/@media \(max-width: 767px\)/,/^}/'
   config/www/user/themes/byvaerkstederne/css/theme.css | grep
   '\.bv-event-row'` returns no matches.
8. **`.bv-event-item` declares itself a query container** —
   `grep -nE 'container-type: inline-size'
   config/www/user/themes/byvaerkstederne/css/theme.css | grep -c
   .bv-event-item` returns at least 1. **`.bv-event-row` itself does
   NOT declare `container-type`** — declaring it on the row was the v1
   bug. Verify: `awk '/^\.bv-event-row \{/,/^}/'
   config/www/user/themes/byvaerkstederne/css/theme.css | grep
   container-type` returns no matches.
9. **The container query is present** —
   `grep -n '@container event-row (max-width: 540px)'
   config/www/user/themes/byvaerkstederne/css/theme.css` returns at
   least 1 match.
10. **DOM order flip is in place** — the container query block
    contains `order: -1` on `.bv-event-row__date-day` (verified by
    grep within the container block, not just anywhere in the file).
11. **Mobile rendering** — every route listed under "Tests" above
    passes the four-rule mobile invariant at viewport 390 × 844. The
    `mobile-chromium` Playwright project's exit code is 0.
12. **Container-query mechanism proven** —
    `tests/mobile/event-card-container-query.js` renders the partial
    in a 360 px wrapper on a 1280 px viewport and asserts
    `flexDirection: 'column'` AND `order: -1` on `__date-day` AND CTA
    width === 100%. Test passes on HEAD.
13. **F1 filter contract preserved** —
    `tests/mobile/event-card-unification.js` asserts that for each
    rendered row, `row.dataset.group` equals the filter ID (not the
    accent token), and that clicking a filter button on
    `/vaerkstedskalenderen` shows only matching rows (and does NOT
    hide all rows).
14. **F2 badge slot honoured** — for any event with a `badge:` YAML
    value, the rendered DOM contains a `.bv-event-row__badge` element
    with the badge text in `body` (not meta).
15. **F3 three-meta-slots honoured** — for the event001 row (or a
    seeded equivalent carrying badge + price + CTA + capacity), the
    rendered DOM contains `.bv-event-row__price`, `a.bv-btn` inside
    `.bv-event-row__meta`, AND `.bv-event-row__capacity` simultaneously.
    For an atelier drop-in row (no capacity), the capacity element
    does NOT render and the meta column collapses without reserved
    space.
16. **a11y heading hierarchy** — `.bv-event-row__title` is rendered
    as an `<h3>` (not a `<div>`) in every event-card route.
17. **Mobile failure-path coverage** — each affected route has at
    least one new mobile test that demonstrably fails when the partial
    migration is reverted on the corresponding template. The evaluator
    captures the baseline-revert log.
18. **Desktop visual parity vs. v2 handoff** —
    `tests/anonymous/event-card-visual-parity.js` passes the baselines
    captured against the v2 handoff design on every affected route.
    Tolerance threshold documented inline; baselines from any
    previous run are discarded.
19. **No desktop regression** — the differential check from PR #35
    carries over: every test that passes on the run's base ref under
    `--project=chromium` must also pass on HEAD.
20. **No `test.skip()` introduced** — `git diff <base>..HEAD -- 'tests/'`
    contains no added `test.skip(`, `xit(`, `it.skip(`, `describe.skip(`.
21. **Scope discipline** — `git diff --name-only <base>..HEAD` lists
    only paths under
    `config/www/user/themes/byvaerkstederne/templates/`,
    `config/www/user/themes/byvaerkstederne/css/`, `tests/`,
    `playwright.config.js`, and `documentation/design/event-row-handoff/`
    (the last only to capture any maintainer notes added during the
    migration; agents do not edit the handoff bundle's reference files
    themselves). No edits to page YAMLs, plugins, deploy, scripts,
    specifications/, decisions/, ROADMAP.md, CLAUDE.md, or
    docker-compose.yml.
22. **Material Symbols `group` icon is reachable** — the implementation
    confirms `base.html.twig` already loads the Material Symbols
    Outlined font (per the v2 handoff). No new font load is added.
23. **Twig cache discipline** — the verification log shows
    `bin/grav clearcache` (no hyphen) run inside the worktree's Grav
    container after every `.html.twig` edit and before every Playwright
    probe.

---

## File-level scope

Allowed prefixes for any change in this run:

- `config/www/user/themes/byvaerkstederne/templates/partials/` — new
  `event_card.html.twig`.
- `config/www/user/themes/byvaerkstederne/templates/modular/` — edits
  to the four modular templates being migrated; no other modulars
  touched.
- `config/www/user/themes/byvaerkstederne/css/theme.css` — additions,
  dead-class removals, and the deletion of PR #35's `.bv-event-row`
  rules from the `@media (max-width: 767px)` block.
- `tests/mobile/` — the two new mobile test files
  (`event-card-unification.js`, `event-card-container-query.js`).
- `tests/anonymous/` — the new visual-parity test file (this is the
  only reason `tests/anonymous/` is in scope).
- `playwright.config.js` — only if a new project for visual-parity
  baselines needs configuring.
- `documentation/design/event-row-handoff/` — read-only access for
  the planner / generator. The bundle's contents are authoritative;
  agents do not edit them.

Out of scope:

- `config/www/user/pages/` — page YAMLs not edited.
- `config/www/user/data/flex-objects/` — flex-object YAMLs not edited.
- `config/www/user/plugins/` — no PHP changes.
- `config/www/user/accounts/`, `config/www/user/data/` — no live state
  touched.
- `apex/`, `deploy/`, `scripts/`, `migrations/` — out of scope.
- `tests/authenticated/` — the unification does not affect any
  authenticated route; no credential dependency.
- `specifications/`, `decisions/`, `ROADMAP.md` — orchestrator's
  PR-time responsibility, not the run's.

---

## Implementation order

Two sprints is the natural split — the partial + the highest-pain
migration (`atelier_sessions`, which is the user-reported defect) +
the F1/F2/F3-correctness test guards in sprint 1; the remaining three
callers + dead-class deletion in sprint 2.

Suggested ordering inside sprint 1:

1. Read the v2 handoff bundle (`documentation/design/event-row-handoff/`,
   including `reference/demo.html`) end-to-end before writing any code.
   Render `demo.html` in a browser to see the intended desktop +
   stacked behaviour live.
2. Write the partial against the v2 canonical schema, matching the
   v2 handoff's HTML structure exactly. The `<li class="bv-event-item">`
   wrapper is mandatory.
3. Add the base CSS, the container declaration on `.bv-event-item`,
   and the container query block to `theme.css` — verbatim from the
   v2 handoff's `## Production implementation` block. Delete PR #35's
   `@media (max-width: 767px)` rules on `.bv-event-row` in the same
   commit.
4. Migrate `event_list.html.twig` — preserving the existing
   flex-objects ↔ page-header fallback logic. The migration MUST set
   `event.filter` from `ev.group` (NOT from `ev.button_style`) and
   `event.accent` from `ev.button_style` (NOT from `ev.group`). Capture
   desktop visual-parity baselines via Playwright.
5. Run the existing mobile + desktop Playwright suites; both must
   still pass.
6. Migrate `atelier_sessions.html.twig`. Add the mobile probe for
   `/vaerksteder/krea-cafe/syvaerkstedet` and the Lene Pels page.
   Verify the probe fails on the pre-migration revert (the C6-style
   failure-path discipline).
7. Add `tests/mobile/event-card-container-query.js` and verify it
   passes (proving the container query mechanism works on a wide
   viewport with a narrow wrapper) AND that the container is the
   wrapper, not the row.
8. Add the F1/F2/F3-correctness guards to
   `tests/mobile/event-card-unification.js` (filter dataset, badge
   slot, three meta slots).

Suggested ordering inside sprint 2:

9. Migrate `calendar_featured.html.twig`. Decide between adding a
   `.bv-event-row--featured` modifier and re-styling the canonical
   class based on the smallest visual diff. Document the choice in a
   comment on the canonical CSS block.
10. Migrate `event_highlight.html.twig`. Use the modifier for the
    primary featured event; use the canonical (no modifier) for the
    secondary events list.
11. Remove `.bv-featured-event*`, `.bv-event-highlight*`,
    `.bv-event-date*` from `theme.css`.
12. Final full-suite Playwright run on `mobile-chromium` and `chromium`;
    both must be green.

---

## Risks and decisions to make during implementation

- **`.bv-event-row--featured` vs. canonical date scaling.** The
  current `.bv-featured-event__date` is larger than
  `.bv-event-row__date`. The v2 handoff does not directly address the
  featured variant. Implementation picks: (a) the modifier
  `.bv-event-row--featured` opts into bigger date typography for the
  featured callers, or (b) the canonical date scales with viewport
  intrinsically. The simpler outcome is (a); document the choice
  inline.
- **`event_highlight.html.twig`'s secondary-event list.** Currently a
  vertical list of compact cards with their own bespoke
  `.bv-event-date` class. Migration treats each list entry as a
  partial-rendered card with no modifier; if the visual baseline
  differs, the canonical container-query layout already covers
  geometry, but the desktop look may need a `.bv-event-row--compact`
  modifier. Decide after baseline screenshots reveal the actual delta.
- **Material Symbols loading.** The v2 handoff confirms the `group`
  glyph is already loaded by `base.html.twig`. Verify before
  implementation rather than after — if for any reason the load is
  missing, the capacity-variant render shows a fallback glyph; the
  implementation surfaces the discrepancy rather than papering over
  it.
- **`atelier_sessions` accent + filter mapping.** Today the accent is
  picked from the page header (`h.accent`), not from each session.
  The canonical shape allows per-event accent + per-event filter, but
  the migration sets every session's accent to the page-level value
  and the page's filter to the matching workshop ID (e.g. the Krea
  Café atelier-sessions page sets `event.filter = 'krea-cafe'` for
  every session). Per-session overrides are out of scope for this run.
- **Container query browser support.** Container queries ship in
  Chrome / Edge / Safari / Firefox from 2023 onward. The v2 handoff
  commits to the container-query path without a fallback; this spec
  inherits that decision.
- **Inline `style="--bv-accent: var(--{{ event.accent }});"` and
  Twig auto-escape.** The accent token is one of a closed set
  (`primary` / `secondary` / `tertiary` / `kulturhus`). The Twig
  rendering MUST validate the value against the closed set before
  emitting it into the inline style, OR the partial accepts only
  pre-validated values. Either approach avoids a content-injection
  vector via an unexpected `accent:` value.

---

## Hard constraints (echoes for the GAN run)

- `main` and `develop` are both gated; the run's branch merges into
  `develop`. PR must open with `--base develop`.
- No direct commits to `develop` or `main`. Always branch first.
- Tests must not introduce `test.skip()` or any equivalent. New tests
  cover the success path AND at least one failure path.
- After every `.html.twig` edit, run `bin/grav clearcache` (no hyphen)
  inside the worktree's Grav container before re-probing.
- Live testing happens on a worktree-scoped container brought up via
  `scripts/grav-up.sh "$WORKTREE_PATH" <port>` — never against the
  primary `:8080` dev container.
- Confinement applies: sub-agents (planner, proposer, reviewer,
  generator, evaluator) are sandboxed to the run's worktree.
  `specifications/`, `decisions/`, `ROADMAP.md`, the main repo's
  `config/`, `tests/`, `scripts/`, `.claude/`, `CLAUDE.md`, and
  `docker-compose.yml` are read-only to them. Spec archival and ADR
  work is the orchestrator's PR-time responsibility, not sub-agents'.
- The framework's `validateAll` must pass clean before commits.
- Community affordances (Forslå Feature, Roadmap, Rapportér fejl) stay
  footer-only and auth-gated per ADR-001.

---

## Done definition

This spec is fully implemented when:

- The four modular templates each render an event card via the canonical
  partial and contain no inlined event-card markup.
- The canonical partial is the only place that emits `.bv-event-row`
  markup in the codebase.
- The container query (`@container event-row (max-width: 540px)`) is
  declared on `.bv-event-item` and is the only mechanism handling
  responsive stacking of `.bv-event-row`. PR #35's
  `@media (max-width: 767px)` rules on `.bv-event-row` are deleted.
  `.bv-event-row` itself does NOT declare `container-type`.
- The dead bespoke classes (`.bv-featured-event*`,
  `.bv-event-highlight*`, `.bv-event-date*`) are removed from
  `theme.css`.
- Every route that renders an event card passes the four-rule mobile
  invariant at viewport 390 × 844 plus the F1 filter / F2 badge /
  F3 three-meta-slots / a11y heading guards.
- The container-query mechanism is independently proven by a Playwright
  test rendering the partial in a 360 px wrapper on a 1280 px desktop
  viewport.
- Desktop visual-parity tests pass with the v2 handoff design as ground
  truth on every affected route.
- The PR opens against `develop` with the full migration in two (or
  one) sprints' worth of commits.
