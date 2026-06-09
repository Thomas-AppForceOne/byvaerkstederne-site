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

The v2 handoff was commissioned specifically to close gaps a first
implementation attempt against the v1 handoff exposed. The unification
therefore also closes three production-data regressions and one latent
CSS bug that v1 had not caught:

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
                       # kulturhus, alle). Optional — when absent, no
                       # data-group attribute is emitted.

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
   `.bv-badge` class with the accent-variant modifier. An empty or
   missing `badge` value MUST NOT render an empty `<span>` (the
   partial's `{% if event.badge %}` guard handles this; the badge
   negative-case test guards against a future regression where someone
   replaces it with `{% if event.badge is defined %}` or similar).
4. **`accent` values come from a closed, trusted set.** The four
   workshop tokens (`primary`, `secondary`, `tertiary`, `kulturhus`)
   come from Flex Object YAML or page-header YAML in this codebase —
   never from user input. The partial MUST nevertheless validate the
   incoming value against the closed set before interpolating it into
   the inline `style="--bv-accent: var(--{value});"` attribute, and
   fall back to `primary` on miss. Belt-and-braces: the YAML is
   trusted today, but the partial is the single point that emits the
   token into a style context and is the right place to enforce.

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
| `begivenheder.yaml` `button_text:` + `button_url:` | `event.cta = { label, href, variant: accent }`. **Both fields required**: a `button_text` with no `button_url` (or vice versa) renders no CTA at all (silent drop, not an `href="#"` fallback). This is a deliberate behaviour change from the pre-v1 template, which rendered an unactionable button. |
| `begivenheder.yaml` `capacity:` (free-form string) | `event.capacity` |
| `event_list` page-header fallback fields | same canonical fields, page-header sourced when flex-objects absent |
| `atelier_sessions` page-level `h.accent` | `event.accent` (per-session accent overrides not in scope) |
| `atelier_sessions` `s.day/month/title/time/description` | same canonical fields |
| `atelier_sessions` `s.contact_name` + `s.contact_sms` | `event.cta = { label: s.contact_name, href: "sms:+45" ~ s.contact_sms }` |
| `atelier_sessions` `s.no_signup: true` | `event.price = "Drop-in"`, no `cta`, no `capacity`. **`no_signup` wins** — if a session sets both `no_signup: true` AND `contact_name`/`contact_sms`, render the drop-in form and ignore the contact fields. |
| `atelier_sessions` filter (page-level) | `event.filter` (e.g. `krea-cafe`) |
| `calendar_featured` h.event_title / event_description / event_date | `event.title` / `event.description` / parsed (day,month); featured flag → `--featured` modifier |
| `event_highlight` primary featured event | same — featured modifier |
| `event_highlight` secondary events list | one canonical `event` each, no modifier |

### The partial

```
config/www/user/themes/byvaerkstederne/templates/partials/event_card.html.twig
```

Renders the v2 handoff's DOM exactly. The partial accepts an optional
`inList` flag (default `true`) that picks the wrapper tag — `<li>` for
list contexts (`event_list`, `atelier_sessions`, the secondary list
inside `event_highlight`), and `<div>` for single-card contexts
(`calendar_featured`, the primary featured card inside
`event_highlight`). The container-query target class
`.bv-event-item` is the same regardless of tag.

```twig
{# Validate accent against the closed set. The four workshop tokens are
   the only values theme.css recognises; an unknown value would silently
   produce an inline style that resolves to nothing. #}
{% set _allowed_accents = ['primary', 'secondary', 'tertiary', 'kulturhus'] %}
{% set _accent = event.accent in _allowed_accents ? event.accent : 'primary' %}

{# `inList` is a presentation-context flag the caller passes as a
   top-level include variable, NOT a field of the event data — keeps
   call sites readable and avoids forcing callers to `|merge` into the
   event object. Defaults to true (list context). #}
{% set _in_list = inList ?? true %}

{# Defensive access on event.cta.variant — when event.cta is undefined
   entirely (events without a CTA), Twig with strict_variables on would
   throw on event.cta.variant. Grav usually runs with strict_variables
   off, but be explicit. #}
{% set _cta_variant_raw = (event.cta is defined and event.cta.variant is defined)
                          ? event.cta.variant : _accent %}
{% set _cta_variant = _cta_variant_raw in _allowed_accents ? _cta_variant_raw : 'primary' %}

{% if _in_list %}<li class="bv-event-item">{% else %}<div class="bv-event-item">{% endif %}
  <article class="bv-event-row{% if event.featured %} bv-event-row--featured{% endif %}"
           {% if event.filter %}data-group="{{ event.filter }}"{% endif %}
           style="--bv-accent: var(--{{ _accent }});">

    <div class="bv-event-row__date">
      <span class="bv-event-row__date-month">{{ event.month }}</span>
      <span class="bv-event-row__date-day">{{ event.day }}</span>
    </div>

    <div class="bv-event-row__body">
      {% if event.badge %}
        <span class="bv-badge bv-badge--{{ _accent }} bv-event-row__badge">{{ event.badge }}</span>
      {% endif %}
      <h3 class="bv-event-row__title">{{ event.title }}</h3>
      {% if event.time %}<p class="bv-event-row__time">{{ event.time }}</p>{% endif %}
      {% if event.description %}<p class="bv-event-row__desc">{{ event.description }}</p>{% endif %}
    </div>

    {% if event.price or (event.cta and event.cta.label and event.cta.href) or event.capacity %}
      <div class="bv-event-row__meta">
        {% if event.price %}
          <span class="bv-event-row__price">{{ event.price }}</span>
        {% endif %}
        {% if event.cta and event.cta.label and event.cta.href %}
          <a class="bv-btn bv-btn--{{ _cta_variant }} bv-btn--sm"
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
{% if _in_list %}</li>{% else %}</div>{% endif %}
```

Four structural details called out by the v2 handoff:

1. **`.bv-event-item` is the container-query target.** It sits AROUND
   `<article class="bv-event-row">`. Setting `container-type` on
   `.bv-event-row` and trying to restyle it from its own
   `@container` query does not work — an element cannot react to its
   own container-type; container queries only affect descendants.
   This was a latent bug in the v1 spec. The v2 fix is the wrapper.
2. **The wrapper tag is `<li>` in list contexts and `<div>` in
   single-card contexts.** The `inList` flag picks one; the container
   class stays `.bv-event-item` regardless. `inList` is a top-level
   include variable, NOT a field of the event data:

   ```twig
   {# list caller — for-loop wrapped in <ul class="bv-event-list"> #}
   <ul class="bv-event-list">
     {% for ev in events %}
       {% include 'partials/event_card.html.twig' with { event: ev, inList: true } %}
     {% endfor %}
   </ul>

   {# single-card caller — no <ul>, inList: false #}
   {% include 'partials/event_card.html.twig'
      with { event: featured_event, inList: false } %}
   ```

   `event_list` and `atelier_sessions` use `inList: true` (or omit it
   — it defaults to true). `calendar_featured` and `event_highlight`'s
   primary featured card pass `inList: false`.
3. **Title is `<h3>`, not `<div>`.** Accessibility and heading
   hierarchy. A future Playwright regression check asserts the
   element resolves to an `<h3>` tag.
4. **Meta-column collapse semantics.** When all three meta fields
   (`price`, `cta`, `capacity`) are absent, the entire
   `.bv-event-row__meta` `<div>` is NOT rendered (the partial's outer
   `{% if … %}` guard skips it), and the flex layout reclaims the
   column space. When at least one meta field IS present, the meta
   column renders with its full `min-width: 9rem` (the layout reserves
   the column even when one or two slots are empty — partial-collapse
   keeps the desktop alignment of adjacent rows consistent). The
   "without reserved space" criterion below covers the all-empty case;
   the partial-empty case keeps the 9 rem reservation intentionally.

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
handoff's `## Production implementation` block, plus two new design
tokens to `:root` and a `--featured` modifier):

```css
/* :root additions — the v2 handoff's CSS uses two tokens that
   theme.css does not currently define. Add them in the existing :root
   block (do not introduce a second :root block). */
:root {
    /* … existing tokens … */
    --border-thick: 4px;          /* the visible workshop-accent left border */
    --tracking-tight: -0.02em;    /* title letter-spacing per handoff */
}

/* Event list — reset default <ul> chrome (bullets, padding, margin) so
   the canonical card layout owns its own spacing. The list is just a
   semantic container for the .bv-event-item elements. */
.bv-event-list {
    list-style: none;
    padding: 0;
    margin: 0;
}

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

`.bv-event-row--featured` modifier — desktop-only typography bump and
tighter spacing for the `calendar_featured` and `event_highlight`
primary callers. Mobile inherits the canonical stacked layout without
modifier-specific overrides. The modifier is concrete (not "decide
during implementation"):

```css
/* Featured modifier — used by calendar_featured.html.twig and the
   primary featured card in event_highlight.html.twig. */
.bv-event-row--featured .bv-event-row__date-day { font-size: 2rem; }
.bv-event-row--featured .bv-event-row__date-month { font-size: 0.875rem; }
.bv-event-row--featured .bv-event-row__title { font-size: 1.5rem; }
.bv-event-row--featured { padding: var(--space-8) var(--space-6); }
```

The implementation may further tune these values during sprint 2 to
minimise the visual diff against the existing `.bv-featured-event*`
rendering, but the modifier MUST exist as the place where featured
overrides live; do not move featured overrides onto `.bv-event-row`
itself.

### Trust posture for accent values

`event.accent` values originate from YAML the operator controls:
`begivenheder.yaml`'s `button_style` field for `event_list`, the page-
header `accent:` field for `atelier_sessions`, and page-header
fields for `calendar_featured` and `event_highlight`. None of these
sources accept end-user input — they are admin-edited YAML. The
partial's accent validation (closed set, fallback to `primary` on
miss) is a defensive layer, not a trust boundary: the YAML is the
trust boundary, and the validation guards against typos and
future schema drift, not against an attacker.

### Tests

Two new Playwright files plus a new Playwright project plus a wiring
entry point:

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
convention. Baselines from any prior attempt are discarded. The
test's failure path is implicit: reverting the partial migration
restores the bespoke (pre-v2) desktop rendering, which fails the
baseline comparison; the evaluator's C6-style baseline-revert run
captures this.

**`tests/mobile.spec.js`** — new entry point that loads the two new
mobile test files. Modelled on the existing `tests/anonymous.spec.js`
pattern. Required because `tests/mobile.spec.js` does not exist on
the foundation branch; without this entry point the
`mobile-chromium` Playwright project has nothing to run.

**`playwright.config.js`** — extend the existing `projects` array
with a `mobile-chromium` project alongside the current `chromium`
project. The project's `use` block sets a viewport of 390 × 844
(`devices['iPhone 14 Pro']` is the closest match in the playwright
device registry), and its `testMatch` filters to
`tests/mobile.spec.js`. The existing `chromium` project is unchanged
and continues to drive the anonymous + authenticated suites.

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
6. **Bespoke CSS classes are deleted by end of sprint 2** —
   `grep -rn '\.bv-featured-event\|\.bv-event-highlight\|\.bv-event-date'
   config/www/user/themes/byvaerkstederne/css/theme.css` returns no
   matches at the end of the **run** (both sprints landed). This
   criterion is sprint-2-scored, not sprint-1-scored — sprint 1's
   evaluator should treat the classes still present as expected because
   their consumers (`calendar_featured`, `event_highlight`) are
   migrated in sprint 2.
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
    `tests/mobile/event-card-container-query.js` runs at viewport
    1280 × 800 (via `test.use({ viewport: { width: 1280, height: 800 } })`)
    inside the describe block, renders the partial in a 360 px
    wrapper, and asserts: (a) `getComputedStyle(row).flexDirection ===
    'column'`; (b) `getComputedStyle(row.querySelector('.bv-event-row__date-day')).order === '-1'`;
    (c) the CTA's rendered width matches its parent's content-box
    width within ±1 px:
    `Math.abs(cta.getBoundingClientRect().width - cta.parentElement.getBoundingClientRect().width) <= 1`.
    Note: do NOT compare against the string `"100%"`; the resolved
    style returns a pixel value, not a percentage. Test passes on HEAD.
13. **F1 filter contract preserved** —
    `tests/mobile/event-card-unification.js` asserts that for each
    rendered row, `row.dataset.group` equals the filter ID (not the
    accent token), and that clicking a filter button on
    `/vaerkstedskalenderen` shows only matching rows (and does NOT
    hide all rows).
14. **F2 badge slot honoured (with negative case)** — for any event
    with a non-empty `badge:` YAML value, the rendered DOM contains
    a `.bv-event-row__badge` element with the badge text inside
    `.bv-event-row__body` (not inside `.bv-event-row__meta`). For an
    event with no `badge:` or `badge: ""`, the rendered DOM contains
    NO `.bv-event-row__badge` element at all (not an empty span).
    Both cases are tested.
15. **F3 three-meta-slots honoured** — three sub-cases, all asserted
    against the **desktop viewport** (the meta column's layout
    behaviour is a desktop concept; in stacked layout the meta `<div>`
    just becomes another column-flex row whether present or absent):
    - **Full:** for the event001 row (or a seeded equivalent carrying
      badge + price + CTA + capacity), the rendered DOM contains
      `.bv-event-row__price`, `a.bv-btn` inside `.bv-event-row__meta`,
      AND `.bv-event-row__capacity` simultaneously.
    - **All-empty:** for an event with NO meta fields (all of
      `price`, `cta`, `capacity` absent), the rendered DOM contains
      NO `.bv-event-row__meta` element at all (the partial's outer
      guard skips it entirely; on desktop the flex layout reclaims
      the column space).
    - **Partial:** for an atelier drop-in row (price + cta, no
      capacity), the meta column DOES render with its
      `min-width: 9rem`; the capacity element specifically does not
      render, but the column reservation persists — this preserves
      desktop alignment of adjacent rows.
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
24. **Design tokens defined before use** —
    `grep -nE -- '--border-thick:|--tracking-tight:' config/www/user/themes/byvaerkstederne/css/theme.css`
    returns at least one match per token within the existing `:root`
    block. The v2 handoff's CSS uses both; the foundation branch does
    not define them; the migration adds them.
25. **Accent value is validated by the partial** —
    `grep -nE "_allowed_accents|in.*\['primary'.*'secondary'.*'tertiary'.*'kulturhus'\]"
    config/www/user/themes/byvaerkstederne/templates/partials/event_card.html.twig`
    returns at least one match. The partial does not interpolate
    `event.accent` into the inline `style="--bv-accent: …"` attribute
    without first validating against the closed set.
26. **Wrapper-tag flag honoured** — for the `event_list` and
    `atelier_sessions` migrations the rendered DOM wraps each card
    in `<li class="bv-event-item">`; for the `calendar_featured`
    primary card the rendered DOM wraps in `<div class="bv-event-item">`
    (not `<li>`). The container-query class `.bv-event-item` appears
    on the wrapper regardless of tag.
27. **`mobile-chromium` Playwright project exists** —
    `grep -n 'mobile-chromium' playwright.config.js` returns at
    least one match, and `tests/mobile.spec.js` exists and `require`s
    both new mobile test files. Without these, the project has
    nothing to run and the entire mobile suite silently passes with
    zero tests.
28. **No silent-zero-tests on `mobile-chromium`** — after the wiring
    step (sprint-1 step 2), running
    `npx playwright test --project=mobile-chromium --reporter=list`
    reports at least one PASSING test (the wiring-smoke assertion
    described in step 2). A run that reports `0 passed, 0 failed`
    indicates the project's `testMatch` did not pick up
    `tests/mobile.spec.js`, OR the spec file's `require`s do not
    resolve to test files with at least one `test(...)` call. Both
    are silent failures the criterion catches before sprint 1's
    content lands.
29. **`.bv-event-list` styling reset** —
    `grep -A 3 '\.bv-event-list \{' config/www/user/themes/byvaerkstederne/css/theme.css`
    contains `list-style: none`, `padding: 0`, and `margin: 0`. Without
    the reset, every event list inherits the browser's default `<ul>`
    bullets + left padding, regressing the current bullet-less flat
    rendering on `/vaerkstedskalenderen` and the atelier sub-pages.
30. **Visual-parity baselines captured per migrated route** — sprint
    1's evaluator log shows baselines were captured for
    `/vaerkstedskalenderen` (event_list), `/vaerksteder/krea-cafe/syvaerkstedet`
    (atelier_sessions), and the Lene Pels page (atelier_sessions)
    AFTER all sprint-1 migrations landed, not piecemeal during each
    migration step. Sprint 2's evaluator log shows the same for the
    `calendar_featured` and `event_highlight` routes after sprint 2's
    migrations.

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
- `tests/mobile.spec.js` — new entry-point file required by the
  `mobile-chromium` Playwright project's `testMatch`.
- `tests/anonymous/` — the new visual-parity test file (this is the
  only reason `tests/anonymous/` is in scope).
- `playwright.config.js` — adds the `mobile-chromium` project; may
  also add a project for visual-parity baselines if needed.
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
2. **Scaffold the mobile Playwright project.** Add `mobile-chromium`
   to `playwright.config.js`'s `projects` array (viewport 390 × 844,
   `testMatch: 'tests/mobile.spec.js'`). Create `tests/mobile.spec.js`
   modelled on `tests/anonymous.spec.js`. Both test files
   (`event-card-unification.js`, `event-card-container-query.js`) get
   stub `test.describe` blocks at this step, each containing AT LEAST
   ONE trivial `test('wiring smoke', () => { expect(1+1).toBe(2); })`
   assertion. Without that assertion the project reports `0 passed,
   0 failed` on a green run, which would shadow real content
   regressions in steps 9 and 10. The wiring-smoke tests are deleted
   when the real content lands in steps 9 and 10.

   Verify with `npx playwright test --project=mobile-chromium
   --reporter=list` — must report at least one passing test before
   moving on (this is criterion #28).
3. **Add the two missing design tokens** (`--border-thick: 4px`,
   `--tracking-tight: -0.02em`) to the existing `:root` block in
   `theme.css`. They underpin the v2 handoff's CSS; without them the
   handoff's rules silently fall back.
4. Write the partial against the v2 canonical schema, matching the
   v2 handoff's HTML structure exactly. The `.bv-event-item` wrapper
   is mandatory; the `inList` flag picks `<li>` vs. `<div>`. The
   accent-validation block is mandatory (criterion #25).
5. Add the base CSS, the container declaration on `.bv-event-item`,
   the `.bv-event-row--featured` modifier, and the container query
   block to `theme.css` — verbatim from the spec's CSS section
   (which is the v2 handoff's `## Production implementation` block
   plus the modifier and the token additions). Delete PR #35's
   `@media (max-width: 767px)` rules on `.bv-event-row` in the same
   commit.
6. Migrate `event_list.html.twig` — preserving the existing
   flex-objects ↔ page-header fallback logic. The migration MUST set
   `event.filter` from `ev.group` (NOT from `ev.button_style`) and
   `event.accent` from `ev.button_style` (NOT from `ev.group`). The
   for-loop is wrapped in `<ul class="bv-event-list">…</ul>` and
   each iteration calls the partial with the top-level include
   variable `inList: true` (default; can be omitted).
7. Run the existing mobile + desktop Playwright suites; both must
   still pass.
8. Migrate `atelier_sessions.html.twig`. The for-loop is wrapped in
   `<ul class="bv-event-list">…</ul>` (sessions are a list); each
   iteration calls the partial with `inList: true` (default). Add
   the mobile probe for `/vaerksteder/krea-cafe/syvaerkstedet` and
   the Lene Pels page. Verify the probe fails on the pre-migration
   revert (the C6-style failure-path discipline).
9. Fill in `tests/mobile/event-card-container-query.js` (it was
   stubbed in step 2) — assert the container query fires on
   `.bv-event-item` (not on `.bv-event-row`), the date-day flip is
   present, and the CTA full-width hold geometrically (per criterion
   #12's exact comparison).
10. Fill in `tests/mobile/event-card-unification.js` with the
    F1/F2/F3-correctness + a11y guards (filter dataset, badge slot
    positive + negative cases, three meta slots positive + meta-
    column-absence case + partial-empty case, h3 tag). Delete the
    wiring-smoke tests from both mobile test files when the real
    content lands.
10a. **Capture desktop visual-parity baselines for sprint-1 routes**
    AFTER all sprint-1 migrations have landed — `/vaerkstedskalenderen`
    (event_list), `/vaerksteder/krea-cafe/syvaerkstedet`
    (atelier_sessions), and the Lene Pels page (atelier_sessions).
    Capturing piecemeal during each migration step would lock in
    half-migrated state. Run the visual-parity test once with
    `--update-snapshots`, then verify the captured PNGs match the
    v2 handoff's `demo.html` desktop rendering side-by-side before
    committing.

Suggested ordering inside sprint 2:

11. Migrate `calendar_featured.html.twig` — single featured card,
    pass `inList: false` so the partial emits a `<div class="bv-event-item">`
    wrapper (not `<li>`), and pass `featured: true` so the
    `.bv-event-row--featured` modifier opts into the bigger date
    typography. No surrounding `<ul>`.
12. Migrate `event_highlight.html.twig`. The primary featured event
    uses `inList: false` + `featured: true` (same as
    `calendar_featured`). The secondary events list wraps the
    for-loop in `<ul class="bv-event-list">…</ul>` and passes
    `inList: true` (default), `featured: false` (default).
13. Remove `.bv-featured-event*`, `.bv-event-highlight*`,
    `.bv-event-date*` from `theme.css`. Verify with grep that no
    consumer remains across `config/www/user/`. This closes
    criterion #6.
13a. **Capture visual-parity baselines for sprint-2 routes** AFTER
    both sprint-2 migrations have landed — every route that renders
    `calendar_featured` and every route that renders
    `event_highlight`. Same single-pass approach as step 10a.
14. Final full-suite Playwright run on `mobile-chromium` and `chromium`;
    both must be green.

---

## Risks and decisions to make during implementation

- **`event_highlight.html.twig`'s secondary-event list desktop look.**
  Currently a vertical list of compact cards with bespoke
  `.bv-event-date` styling. The canonical container-query layout
  covers stacked geometry on any width; the desktop look may differ
  enough from the bespoke rendering that a `.bv-event-row--compact`
  modifier becomes useful for tighter padding / smaller date type.
  Decide after baseline screenshots reveal the actual delta. The
  spec does not commit to a compact modifier upfront — only the
  `--featured` modifier is mandatory.
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
  partial and contain no inlined event-card markup. List callers
  (`event_list`, `atelier_sessions`, `event_highlight` secondary list)
  wrap their for-loop in `<ul class="bv-event-list">…</ul>` and call
  the partial with `inList: true` (default). Single-card callers
  (`calendar_featured`, `event_highlight` primary card) call the
  partial with `inList: false` and `featured: true`.
- The canonical partial is the only place that emits `.bv-event-row`
  markup in the codebase. The partial validates `event.accent` against
  the closed set before interpolation.
- The container query (`@container event-row (max-width: 540px)`) is
  declared on `.bv-event-item` and is the only mechanism handling
  responsive stacking of `.bv-event-row`. PR #35's
  `@media (max-width: 767px)` rules on `.bv-event-row` are deleted.
  `.bv-event-row` itself does NOT declare `container-type`.
- `--border-thick` and `--tracking-tight` are defined in `theme.css`'s
  `:root` block; the v2 handoff's CSS resolves rather than falling
  back silently.
- The dead bespoke classes (`.bv-featured-event*`,
  `.bv-event-highlight*`, `.bv-event-date*`) are removed from
  `theme.css`.
- Every route that renders an event card passes the four-rule mobile
  invariant at viewport 390 × 844 plus the F1 filter / F2 badge
  (positive + negative case) / F3 three-meta-slots (positive +
  meta-column-absence case) / a11y heading guards.
- The container-query mechanism is independently proven by a Playwright
  test rendering the partial in a 360 px wrapper on a 1280 px desktop
  viewport, with geometric (not string-equality) assertions on
  CTA full-width.
- Desktop visual-parity tests pass with the v2 handoff design as ground
  truth on every affected route.
- `playwright.config.js` includes the `mobile-chromium` project and
  `tests/mobile.spec.js` exists with its `require` entries.
- The PR opens against `develop` with the full migration in two (or
  one) sprints' worth of commits.
