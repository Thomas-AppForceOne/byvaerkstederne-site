# Specification — Unify event-card rendering into a single canonical partial

Status: Planned
Owner: thomas@appforceone.dk
Depends on: PR #35 (mobile-rendering polish) — establishes the
`.bv-event-row` class structure this spec extends. The container-query
implementation introduced here **replaces** PR #35's `@media (max-width:
767px)` rules on `.bv-event-row` (see §"CSS — container query supersedes
PR #35 media rules" below). The spec itself lives on
`feature/mobile-rendering`.

Design source (hi-fi, in-repo, normative):
[`documentation/design/event-row-handoff/README.md`](../documentation/design/event-row-handoff/README.md)
— a Claude Design handoff bundle that pins the visual contract for the
canonical event row (desktop + stacked variants), the responsive
mechanism (CSS container query, not viewport media query), and the data
model. References below to "the handoff" point at this bundle.

Scope: Replace four bespoke event-card markups with a single canonical
Twig partial whose visual contract is defined by the handoff, so future
visual changes and bug fixes for "event cards" land in one place and
reach every page that renders one. The desktop look matches the handoff
spec pixel-precisely; the stacked look (card width < 540 px) matches the
handoff's stacked spec; this is **not** a strict-zero-diff faithful
reproduction of the current desktop rendering — minor pixel deltas
introduced by adopting the handoff's typography and spacing are
acceptable when they match the handoff.

> **What this spec is NOT.** It is not a redesign of the whole site's
> event surface. It is not a content-schema migration (page YAML files
> are not rewritten). It is not a refactor of every BEM class in the
> stylesheet. Scope is narrowly: introduce one partial, route four
> existing modular templates through it, adopt the handoff's container-
> query layout, prove the stacked rendering at narrow container widths.

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
modulars `include`, with the visual contract pinned by the in-repo
Claude Design handoff. After this lands:

- A future visual change to event cards is one partial edit.
- A future Playwright probe of event-card geometry is one selector set
  (`.bv-event-row[__date|__body|__meta|__title|__desc]`).
- The handoff's container-query stacking automatically applies to every
  page rendering any event card — including the Lene Pels and Krea
  Café atelier sub-pages — and works equally well in a phone viewport
  OR in a narrow desktop sidebar OR in a 2-column tablet grid.
- A new event-shaped surface (a future "upcoming workshops" widget,
  a "your enrolments" listing in a member area, etc.) starts by
  including the partial and is correct-by-construction.

---

## Non-goals

- **No further visual redesign beyond the handoff.** The handoff is the
  ground-truth visual contract. The spec does not introduce additional
  design directions, alternative card shapes, or "designer's choice"
  variants beyond what the handoff specifies.
- **No new card types.** The partial covers the four templates listed
  above and nothing else. It does not absorb `atelier_techniques.html.twig`
  (pitch / technique cards — different visual shape) or
  `workshop_status.html.twig` (project status cards — not event cards).
- **No YAML schema migration.** Page YAMLs under `config/www/user/pages/`
  are not edited. Each calling modular maps its own existing data shape
  into the canonical event-data shape inside the `{% include with %}`
  call.
- **No `.bv-event-row` class rename.** The canonical class namespace
  stays `.bv-event-row` — reusing the BEM PR #35 introduced rather than
  switching to a new namespace.
- **No new media-query breakpoints.** Mobile / responsive handling
  moves to a **container query** on `.bv-event-row` (per the handoff).
  PR #35's `@media (max-width: 767px)` rules on `.bv-event-row`
  specifically are deleted; other PR #35 rules (workgroup-card,
  pitch-card) are unaffected.
- **No edits to community-affordance placement** (Forslå Feature,
  Roadmap, Rapportér fejl) — they stay footer-only and auth-gated per
  ADR-001.
- **No PHP plugin work.** Templates and CSS only.
- **No accessibility regression**, but no new ARIA work beyond what the
  canonical partial naturally needs (`aria-hidden` on purely decorative
  elements, semantic landmarks where present).
- **No JavaScript.** The handoff's React reference is an explanation
  artefact only; the production responsive behaviour ships as a CSS
  container query.

---

## Approach

### Canonical event-data shape (per the handoff, with one extension)

The partial accepts one canonical object. Per the handoff:

```yaml
event:
  # Required
  day: "10"           # numeric or zero-padded string
  month: "JUNI"       # uppercase Danish abbreviation (3-4 letters)
  title: "PHOTO TRANSFER — INTRO"

  # Optional content
  time: "Onsdag kl. 15-17"        # rendered in body, before description
  description: "Kom og prøv …"    # body text

  # Optional styling — workshop hue of the 4 px left border
  accent: "tertiary"              # one of: primary | secondary | tertiary | kulturhus
                                  # mapping per handoff "Farve-mapping" table

  # Optional meta column — render EXACTLY ONE of these two variants, or neither.
  # Per the handoff: status badge OR capacity counter, never both.

  meta:                           # variant 1 — status / signup
    label: "Drop-in"              # eyebrow, uppercase
    value: "Ingen tilmelding"     # value line
    href: "sms:+4512345678"       # OPTIONAL — extension to handoff. If
                                  # present, `value` renders as a link;
                                  # supports the contact-sms case in
                                  # atelier_sessions and the Tilmeld-CTA
                                  # case in event_list.

  capacity:                       # variant 2 — capacity counter
    used: 13
    total: 30                     # rendered as "13 / 30" with the
                                  # Material Symbols `group` glyph
                                  # already loaded by base.html.twig
```

> **`meta.href` is the one extension to the handoff's data model.** The
> handoff defines `metaLabel`/`metaValue` as a read-only pair. The
> production templates have two cases where the value needs to be
> actionable: the SMS link in `atelier_sessions.html.twig` and the
> Tilmeld button in `event_list.html.twig`. Adding an optional `href`
> preserves the handoff's visual layout (eyebrow over value) and lets
> the value wrap in an `<a>` for actionable cases. When `href` is
> absent, the value renders as the handoff specifies (a plain
> `<div>`).

Each calling modular maps its source YAML into this shape inside the
`{% include with %}` call. No page YAMLs are edited.

### Mapping per source template

| Current source | Canonical |
|---|---|
| `event_list` event.day/month/title/desc | `event.day` / `event.month` / `event.title` / `event.description` |
| `event_list` event.time | `event.time` |
| `event_list` event.group (primary/secondary/tertiary/kulturhus) | `event.accent` |
| `event_list` event.cta { label, href } | `event.meta = { label: "", value: cta.label, href: cta.href }` |
| `event_list` event.capacity | `event.capacity = { used, total }` |
| `atelier_sessions` s.day/month/title/time/description | same canonical fields |
| `atelier_sessions` page-level h.accent | `event.accent` |
| `atelier_sessions` s.contact_name + s.contact_sms | `event.meta = { label: "Tilmelding", value: s.contact_name, href: "sms:+45" ~ s.contact_sms }` |
| `atelier_sessions` s.no_signup: true | `event.meta = { label: "Drop-in", value: "Ingen tilmelding" }` |
| `calendar_featured` h.event_title / event_description / event_date | `event.title` / `event.description` / (day,month parsed from event_date) plus `event.featured: true` modifier |
| `event_highlight` primary featured event | same as `calendar_featured` — featured modifier |
| `event_highlight` secondary events list | one canonical `event` each, no modifier |

### The partial

```
config/www/user/themes/byvaerkstederne/templates/partials/event_card.html.twig
```

Renders `.bv-event-row` markup with the BEM PR #35 hardened, plus a new
`.bv-event-row__time` element (the existing event_list rows have no
time field):

```html
<div class="bv-event-row bv-event-row--{{ event.accent|default('primary') }}{% if event.featured %} bv-event-row--featured{% endif %}"
     data-group="{{ event.accent|default('primary') }}">
  <div class="bv-event-row__date">
    <div class="bv-event-row__date-month">{{ event.month }}</div>
    <div class="bv-event-row__date-day">{{ event.day }}</div>
  </div>
  <div class="bv-event-row__body">
    <div class="bv-event-row__title">{{ event.title }}</div>
    {% if event.time %}
      <div class="bv-event-row__time">{{ event.time }}</div>
    {% endif %}
    {% if event.description %}
      <div class="bv-event-row__desc">{{ event.description }}</div>
    {% endif %}
  </div>
  {% if event.meta %}
    <div class="bv-event-row__meta">
      {% if event.meta.label %}
        <div class="bv-event-row__meta-label">{{ event.meta.label }}</div>
      {% endif %}
      {% if event.meta.href %}
        <a class="bv-event-row__meta-value" href="{{ event.meta.href }}">{{ event.meta.value }}</a>
      {% else %}
        <div class="bv-event-row__meta-value">{{ event.meta.value }}</div>
      {% endif %}
    </div>
  {% elseif event.capacity %}
    <div class="bv-event-row__capacity">
      <span class="material-symbols-outlined" aria-hidden="true">group</span>
      {{ event.capacity.used }} / {{ event.capacity.total }}
    </div>
  {% endif %}
</div>
```

**DOM order note** (called out by the handoff): the partial emits
`__date-month` before `__date-day` in DOM (matching the existing
`event_list.html.twig` pattern and the desktop visual order MONTH /
DAY). The container query (see CSS below) uses `order: -1` on
`.bv-event-row__date-day` to flip them visually to DAY MONTH when
stacked. This is a single line, called out in the handoff as the
production fix.

### CSS — container query supersedes PR #35 media rules

Stylesheet changes live in
`config/www/user/themes/byvaerkstederne/css/theme.css` under the
`/* ---------- Calendar ---------- */` section.

**Removed** (delete from theme.css):

- The `.bv-event-row`, `.bv-event-row__date`, `.bv-event-row__date-day`,
  `.bv-event-row__date-month`, `.bv-event-row__body`,
  `.bv-event-row__title`, `.bv-event-row__desc`,
  `.bv-event-row__meta`, `.bv-event-row__meta .bv-btn`, and
  `.bv-event-row__capacity` rules inside the existing `@media
  (max-width: 767px)` block (introduced by PR #35 commit `ea817e6`).
  These rules are functionally replaced by the container query and
  removing them prevents both layers from cascading against each other.
- The bespoke selectors `.bv-featured-event*`,
  `.bv-event-highlight*`, and `.bv-event-date*` — once their consumers
  are migrated, these are dead code. The implementation removes them
  as the last step of the migration; a follow-up grep over
  `config/www/user/` must return zero hits before they can be deleted.

**Added** (insert into the calendar section):

1. **Base rules for `.bv-event-row__time`** — font weight, color,
   spacing. Parallels `.bv-event-row__title` and `.bv-event-row__desc`.
2. **Meta sub-element rules** — `.bv-event-row__meta-label` and
   `.bv-event-row__meta-value` per the handoff layout-spec
   (eyebrow + value, right-aligned on desktop). The `.bv-event-row__meta`
   wrapper also gets `min-width: 7rem; text-align: right; flex-shrink: 0`
   per the handoff desktop spec.
3. **Container declaration on `.bv-event-row`:**
   ```css
   .bv-event-row {
       container-type: inline-size;
       container-name: event-row;
   }
   ```
4. **Container query for stacked layout (< 540 px):**
   ```css
   @container event-row (max-width: 540px) {
       .bv-event-row {
           flex-direction: column;
           align-items: flex-start;
           gap: var(--space-3);
       }
       .bv-event-row__date {
           display: flex;
           flex-direction: row;
           align-items: baseline;
           gap: var(--space-2);
           min-width: auto;
           text-align: left;
       }
       .bv-event-row__date-day   { order: -1; font-size: 1.25rem; }
       .bv-event-row__date-month { font-size: 0.8rem; }
       .bv-event-row__body,
       .bv-event-row__meta,
       .bv-event-row__capacity {
           width: 100%;
       }
       .bv-event-row__meta {
           justify-content: flex-start;
           text-align: left;
           min-width: 0;
           flex-wrap: wrap;
           gap: var(--space-3);
           margin-top: var(--space-2);
       }
   }
   ```
5. **`.bv-event-row--featured` modifier** (only if implementation finds
   it necessary for visual parity on `calendar_featured` and
   `event_highlight`) — desktop-only typography bump on
   `.bv-event-row__date-day` and tighter spacing; mobile inherits the
   canonical stacked layout without modifier-specific overrides.

### Tests

Two new Playwright files:

**`tests/mobile/event-card-unification.js`** — geometric invariants on
each migrated route at viewport 390 × 844:

- No `.bv-event-row` child has its right edge past the row's right edge.
- Every `.bv-event-row__title`, `.bv-event-row__desc`, and
  `.bv-event-row__time` respects the body's right padding.
- `document.documentElement.scrollWidth === window.innerWidth` on each
  probed route.
- For atelier-sessions cards specifically: assert
  `getComputedStyle(card).flexDirection === 'column'` (proving the
  container query has fired and the card stacked).

Routes probed (minimum set):

- `/vaerkstedskalenderen` — covers `event_list` (regression guard
  against PR #35).
- `/vaerksteder/krea-cafe/syvaerkstedet` — covers `atelier_sessions`
  (user-reported defect, Krea Café scrapbook page).
- A second `atelier_sessions` page rendering the Lene Pels Photo
  Transfer / Silketryk sessions — implementation discovers the route
  via grep.
- Any route that renders `calendar_featured` — implementation discovers
  via grep.
- Any route that renders `event_highlight` — implementation discovers
  via grep.

**`tests/mobile/event-card-container-query.js`** — proves the
container-query mechanism works, not just the viewport-narrow case.
Renders the canonical partial inside a deliberately narrow wrapper
(e.g., a 360 px `<div>` on a desktop-viewport-sized page) and asserts:

- The card's computed `flex-direction` is `column` even though the
  viewport is wide.
- The card has no horizontal overflow within the wrapper.

This test is what catches a future regression to viewport-media-query
layout (the PR #35 approach), because such a regression would render
the card as a desktop row inside the narrow wrapper.

**`tests/anonymous/event-card-visual-parity.js`** — desktop visual
parity against the handoff design. Per route, screenshots the rendered
output and compares against a baseline captured AFTER the partial is
introduced (the baseline is the canonical handoff rendering, not the
pre-migration rendering). The pixel-diff threshold is generous for
acceptable text-rendering differences across systems (5 % of pixels,
per existing project Playwright convention) and strict on layout
deltas. Implementation captures baselines as part of sprint 1's
verification.

The failure-path discipline from PR #35 carries through: each new
mobile test must demonstrably fail when the partial migration is
reverted on the affected template, before the migration is restored.

---

## Acceptance criteria

Each criterion is deterministic and verifiable with a Playwright probe
or a grep.

1. **Partial exists** at
   `config/www/user/themes/byvaerkstederne/templates/partials/event_card.html.twig`
   and exports the documented canonical-event-data interface (Required:
   `day`, `month`, `title`; Optional: `time`, `description`, `accent`,
   `meta { label, value, href? }`, `capacity { used, total }`,
   `featured`).
2. **`event_list.html.twig` renders through the partial** —
   `grep -nE '<div class="bv-event-row'
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
8. **`.bv-event-row` declares itself a query container** —
   `grep -nE 'container-type: inline-size'
   config/www/user/themes/byvaerkstederne/css/theme.css | grep -c
   .bv-event-row` returns at least 1.
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
    in a 360 px wrapper on a desktop viewport and asserts
    `flexDirection: 'column'`. Test passes on HEAD.
13. **Mobile failure-path coverage** — each affected route has at least
    one new mobile test that demonstrably fails when the partial
    migration is reverted on the corresponding template. The evaluator
    captures the baseline-revert log.
14. **Desktop visual parity vs. handoff** —
    `tests/anonymous/event-card-visual-parity.js` passes the baselines
    captured against the handoff design (not against pre-migration
    state). Tolerance for sub-pixel text rendering differences is set
    in the test file with a documented threshold.
15. **No desktop regression** — the differential C7 from PR #35 carries
    over: every test that passes on the run's base ref under
    `--project=chromium` must also pass on HEAD.
16. **No `test.skip()` introduced** — `git diff <base>..HEAD -- 'tests/'`
    contains no added `test.skip(`, `xit(`, `it.skip(`, `describe.skip(`.
17. **Scope discipline** — `git diff --name-only <base>..HEAD` lists
    only paths under
    `config/www/user/themes/byvaerkstederne/templates/`,
    `config/www/user/themes/byvaerkstederne/css/`, `tests/`,
    `playwright.config.js`, and `documentation/design/event-row-handoff/`
    (the last only to capture any maintainer notes added during the
    migration; agents do not edit the handoff bundle's reference files
    themselves). No edits to page YAMLs, plugins, deploy, scripts,
    specifications/, decisions/, ROADMAP.md, CLAUDE.md, or
    docker-compose.yml.
18. **Material Symbols `group` icon is reachable** — the implementation
    confirms `base.html.twig` already loads the Material Symbols
    Outlined font (per the handoff). No new font load is added.
19. **Twig cache discipline** — the verification log shows
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
- `documentation/design/event-row-handoff/` — optional read-only access
  for the planner / generator; only writes if a maintainer note is
  added on top of the handoff (out of scope by default).

Out of scope:

- `config/www/user/pages/` — page YAMLs not edited.
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
migration (`atelier_sessions`, which is the user-reported defect) in
sprint 1; the remaining three callers + dead-class deletion in sprint 2.

Suggested ordering inside sprint 1:

1. Read the handoff bundle (`documentation/design/event-row-handoff/`)
   end-to-end before writing any code.
2. Write the partial against the canonical schema, matching the
   handoff's HTML structure.
3. Add the base CSS, the container declaration, and the container
   query block to `theme.css`. Delete PR #35's `@media (max-width:
   767px)` rules on `.bv-event-row` in the same commit.
4. Migrate `event_list.html.twig` — the lowest-risk migration because
   the partial mirrors what the template already does. Capture
   desktop-visual-parity baselines via Playwright.
5. Run the existing mobile + desktop Playwright suites; both must
   still pass.
6. Migrate `atelier_sessions.html.twig`. Add the mobile probe for
   `/vaerksteder/krea-cafe/syvaerkstedet` and the Lene Pels page.
   Verify the probe fails on the pre-migration revert (the C6-style
   failure-path discipline).
7. Add `tests/mobile/event-card-container-query.js` and verify it
   passes (proving the container query mechanism works on a wide
   viewport with a narrow wrapper).

Suggested ordering inside sprint 2:

8. Migrate `calendar_featured.html.twig`. Decide between adding a
   `.bv-event-row--featured` modifier and re-styling the canonical
   class based on the smallest visual diff. Document the choice in a
   comment on the canonical CSS block.
9. Migrate `event_highlight.html.twig`. Use the modifier for the
   primary featured event; use the canonical (no modifier) for the
   secondary events list.
10. Remove `.bv-featured-event*`, `.bv-event-highlight*`,
    `.bv-event-date*` from `theme.css`.
11. Final full-suite Playwright run on `mobile-chromium` and `chromium`;
    both must be green.

---

## Risks and decisions to make during implementation

- **`.bv-event-row--featured` vs. canonical date scaling.** The
  current `.bv-featured-event__date` is larger than
  `.bv-event-row__date`. The handoff does not directly address the
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
- **Material Symbols loading.** The handoff confirms the `group` glyph
  is already loaded by `base.html.twig`. Verify before implementation
  rather than after — if for any reason the load is missing, the
  capacity-variant render shows a fallback glyph; the implementation
  surfaces the discrepancy rather than papering over it.
- **`atelier_sessions` accent mapping.** Today the accent is picked
  from the page header (`h.accent`), not from each session. The
  canonical shape allows per-event accent, but the migration sets
  every session's accent to the page-level accent until a future spec
  decides whether per-session accents are desirable.
- **Container query browser support.** Container queries ship in
  Chrome / Edge / Safari / Firefox from 2023 onward. The handoff's
  README addresses the fallback case ("Hvis I ikke vil bruge
  container queries"); this spec deliberately commits to the container
  query path and accepts the modest browser-floor cost.

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
  the only mechanism handling responsive stacking of `.bv-event-row`.
  PR #35's `@media (max-width: 767px)` rules on `.bv-event-row` are
  deleted.
- The dead bespoke classes (`.bv-featured-event*`,
  `.bv-event-highlight*`, `.bv-event-date*`) are removed from
  `theme.css`.
- Every route that renders an event card passes the four-rule mobile
  invariant at viewport 390 × 844.
- The container-query mechanism is independently proven by a Playwright
  test rendering the partial in a 360 px wrapper on a desktop viewport.
- Desktop visual-parity tests pass with the handoff design as ground
  truth on every affected route.
- The PR opens against `develop` with the full migration in two (or
  one) sprints' worth of commits.
