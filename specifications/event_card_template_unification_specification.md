# Specification — Unify event-card rendering into a single canonical partial

Status: Planned
Owner: thomas@appforceone.dk
Depends on: PR #35 (mobile-rendering polish) — the `.bv-event-row` mobile
rules introduced there are the basis for the canonical card's styling.
This spec assumes #35 is on the branch the run starts from (the spec
itself lives on `feature/mobile-rendering`).

Scope: Replace four bespoke event-card markups with a single canonical
Twig partial, so future visual changes and bug fixes affecting "event
cards" land in one place and reach every page that renders one. No new
visual design and no page-content changes — desktop and mobile rendering
must be visually unchanged after the unification (with the explicit
exception that pages currently broken on mobile because they use an
inline-styled markup get fixed by riding the same `.bv-event-row` mobile
rules the other templates already use).

> **What this spec is NOT.** It is not a redesign of the event-card
> visual. It is not a content-schema migration (page YAML files are not
> rewritten). It is not a refactor of every BEM class in the stylesheet.
> Scope is narrowly: introduce one partial, route four existing modular
> templates through it, prove visual parity, prove mobile rendering.

---

## Motivation

The mobile-rendering polish that landed as PR #35 fixed four iPhone-class
defects on event-row cards rendered by `event_list.html.twig`. The
Playwright suite green-lit those fixes against `/vaerkstedskalenderen`.
A user-reported defect on `/vaerksteder/krea-cafe/syvaerkstedet`
(the Lene Pels page) showed the *same* visual defect — drop-in / Tilmeld
column overflowing the viewport — but on a page where none of the fixes
applied because the card on that page is rendered by a **different
template** (`atelier_sessions.html.twig`) that does not use the
`.bv-event-row` class structure at all. Its card wrapper is an
inline-styled `<div style="display: grid; grid-template-columns:
8rem 1fr auto; …">` with no class hook — so a `@media (max-width:
767px)` rule targeting `.bv-event-row` cannot reach it, and the same
mobile bug recurs untouched on every atelier sub-page that uses this
template.

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
modulars `include`. Each modular continues to own its data shape
and section chrome (header, intro, layout container) but delegates the
per-card rendering to the partial. After this lands:

- A future visual change to event cards is one partial edit.
- A future Playwright probe of event-card geometry is one selector set
  (`.bv-event-row[__date|__body|__meta|__title|__desc]`).
- The `.bv-event-row` mobile fixes from PR #35 automatically apply to
  every page rendering any event card, including the Lene Pels and
  Krea Café atelier sub-pages.
- A new event-shaped surface (a future "upcoming workshops" widget,
  a "your enrolments" listing in a member area, etc.) starts by
  including the partial and is correct-by-construction.

---

## Non-goals

- **No new visual design.** Desktop look on every existing route that
  renders an event card must be visually unchanged after this lands.
  The unification is markup-and-CSS-class restructuring only.
- **No new card types.** The partial covers the four templates listed
  above and nothing else. It does not absorb `atelier_techniques.html.twig`
  (pitch / technique cards — different visual shape) or
  `workshop_status.html.twig` (project status cards — not event cards).
- **No YAML schema migration.** Page YAMLs under `config/www/user/pages/`
  are not edited. Each calling modular maps its own existing data shape
  into the canonical event-data shape inside the `{% include with %}`
  call.
- **No `.bv-event-row` class rename.** The canonical class namespace
  stays `.bv-event-row` — reusing the BEM already hardened by PR #35
  rather than introducing a new namespace and rewriting the recent CSS.
- **No new media-query breakpoints.** New mobile rules slot into the
  existing `@media (max-width: 1023px) | (max-width: 767px) |
  (max-width: 480px)` blocks.
- **No edits to community-affordance placement** (Forslå Feature,
  Roadmap, Rapportér fejl) — they stay footer-only and auth-gated per
  ADR-001.
- **No PHP plugin work.** Templates and CSS only.
- **No accessibility regression**, but no new ARIA work beyond what the
  canonical partial naturally needs (`aria-hidden` on purely decorative
  elements, semantic landmarks where present).

---

## Approach

### Canonical event-data shape

Define one canonical object the partial accepts. It is a superset of
what the four current templates pull from YAML — every field is
optional except `day`, `month`, `title`.

```yaml
event:
  # Required
  day: "10"           # numeric or zero-padded string
  month: "JUNI"       # uppercase Danish abbreviation
  title: "PHOTO TRANSFER — INTRO"

  # Optional content
  time: "Onsdag kl. 15-17"        # rendered in body, before description
  description: "Kom og prøv …"    # body text

  # Optional styling
  accent: "tertiary"              # mapped to .bv-event-row--<accent>;
                                  # accepts the same group/filter values
                                  # event_list uses today (primary,
                                  # secondary, tertiary, kulturhus)

  # Optional meta column — exactly one of contact / no_signup / cta can
  # render; if none is present the meta column is omitted entirely.
  contact:
    name: "Lene Pels"
    sms: "12345678"               # without country code
  no_signup: true                 # render as DROP-IN / Ingen tilmelding
  cta:
    label: "Tilmeld"
    href: "/tilmelding/photo-transfer"
  capacity:                       # optional — rendered as "13 / 30"
    used: 13
    total: 30
```

### The partial

```
config/www/user/themes/byvaerkstederne/templates/partials/event_card.html.twig
```

Renders `.bv-event-row` markup with the BEM PR #35 hardened:

```html
<div class="bv-event-row bv-event-row--{{ event.accent|default('primary') }}"
     data-group="{{ event.accent|default('primary') }}">
  <div class="bv-event-row__date">
    <div class="bv-event-row__date-day">{{ event.day }}</div>
    <div class="bv-event-row__date-month">{{ event.month }}</div>
  </div>
  <div class="bv-event-row__body">
    <h3 class="bv-event-row__title">{{ event.title }}</h3>
    {% if event.time %}
      <p class="bv-event-row__time"><strong>{{ event.time }}</strong></p>
    {% endif %}
    {% if event.description %}
      <p class="bv-event-row__desc">{{ event.description }}</p>
    {% endif %}
  </div>
  {% if event.contact or event.no_signup or event.cta or event.capacity %}
    <div class="bv-event-row__meta">
      …  (renders the appropriate sub-block per the optional fields)
    </div>
  {% endif %}
</div>
```

`.bv-event-row__time` is a new BEM element (the existing event_list
events do not have a time field). Its mobile rules sit in the same
767 px block as the other event-row mobile rules.

### Migration of the four callers

Each calling modular keeps its section chrome (header, intro, grid
container) and replaces its inlined card markup with one `{% include %}`.

#### 1. `event_list.html.twig` — already canonical-shaped

This template is already correct in spirit. The migration here is
mechanical: extract its inlined card markup verbatim into the partial,
then have the modular `include` the partial with the event's existing
fields mapped through. Visual diff against the current page must be
empty.

#### 2. `atelier_sessions.html.twig` — the user-reported case

Replace the inline-styled `<div style="display: grid; …">` card with
an include of the partial. Map session fields to the canonical shape:

| Session field             | Canonical field          |
|---|---|
| `s.day`                   | `event.day`              |
| `s.month`                 | `event.month`            |
| `s.title`                 | `event.title`            |
| `s.time`                  | `event.time`             |
| `s.description`           | `event.description`      |
| page-level `h.accent`     | `event.accent`           |
| `s.contact_name`+`.contact_sms` | `event.contact.{name,sms}` |
| `s.no_signup`             | `event.no_signup`        |

Section chrome (the `<section class="bv-section">` header, the intro
paragraph, the column flex container) stays in `atelier_sessions.html.twig`.

#### 3. `calendar_featured.html.twig`

Currently renders one prominent event with bespoke `.bv-featured-event`
classes. Map its page-header fields to the canonical shape and include
the partial. The partial covers it because the "featured event" is just
a single event card with a tag/badge — and the tag becomes
`event.cta.label` or a new optional `event.tag` field (decide during
implementation; favour reusing existing canonical fields).

The visual-parity requirement here is the strictest: the
`.bv-featured-event__date` styling is more prominent than the
`.bv-event-row__date`. Either (a) keep `.bv-featured-event__date` as an
additional modifier the partial accepts (`<div class="bv-event-row
bv-event-row--featured">`) or (b) restyle `.bv-event-row--featured` so
the date looks like the current featured variant. Either works; the
implementation chooses based on which keeps the desktop pixel-diff
smallest.

#### 4. `event_highlight.html.twig`

Currently renders one prominent event with a sidebar narrative + a
nested list of secondary events using `.bv-event-highlight` and
`.bv-event-date`. Migration: the primary featured event uses the partial
with a `bv-event-row--featured` modifier (same as `calendar_featured`);
the secondary events list uses the partial directly without the modifier.
Section chrome (sidebar narrative, the layout grid that pairs the
sidebar with the events list) stays in `event_highlight.html.twig`.

### CSS

Stylesheet changes live in
`config/www/user/themes/byvaerkstederne/css/theme.css`.

- **Add `.bv-event-row__time`** — base styles for the new BEM element
  (font weight, color, spacing). One rule, parallels `.bv-event-row__title`.
- **Add `.bv-event-row--featured`** (only if needed by `calendar_featured`
  + `event_highlight`) — a desktop modifier that bumps the date font
  size, tightens spacing, and re-applies the larger visual prominence of
  the current `.bv-featured-event__date`. Mobile inherits the existing
  `.bv-event-row` mobile rules without modifier-specific overrides.
- **Mobile rule (`@media (max-width: 767px)`) for `.bv-event-row__time`**
  — stack the time line between title and description, same min-width
  / overflow-wrap discipline as the other body elements.
- **Retain or rewrite the bespoke classes**: `.bv-featured-event*`,
  `.bv-event-highlight*`, `.bv-event-date` — once their consumers are
  migrated, these selectors are dead code. The implementation removes
  them as the last step of the migration; a follow-up grep over
  `config/www/user/` must return zero hits before they can be deleted.

### Tests

A new Playwright file under `tests/mobile/`:

```
tests/mobile/event-card-unification.js
```

probes each migrated page at viewport 390 × 844 and asserts the same
geometric invariants the PR #35 tests already lock in for
`.bv-event-row`:

- No `.bv-event-row` child has its right edge past the row's right edge.
- Every `.bv-event-row__title`, `.bv-event-row__desc`, and
  `.bv-event-row__time` respects the body's right padding.
- `document.documentElement.scrollWidth === window.innerWidth` on each
  probed route.

Routes probed (minimum set):

- `/vaerkstedskalenderen` — covers `event_list` (regression guard).
- `/vaerksteder/krea-cafe/syvaerkstedet` — covers `atelier_sessions`
  (user-reported defect).
- `/vaerksteder/syvaerkstedet/photo-transfer` (or whichever Lene Pels
  page renders `atelier_sessions`) — covers `atelier_sessions` (the
  second user-reported defect).
- Any route that renders `calendar_featured` — implementation discovers
  via grep.
- Any route that renders `event_highlight` — implementation discovers
  via grep.

A new desktop Playwright file probes visual parity on the same routes:

```
tests/anonymous/event-card-visual-parity.js
```

For each route, takes a full-page screenshot at the desktop viewport
(matches the existing chromium project's default), compares against a
baseline captured before any migration starts. Pixel-diff threshold:
**zero** — the desktop look must be visually identical. If a deliberate
pixel-level diff is justified (e.g. a 1 px line-height change because the
canonical class uses a slightly different `line-height`), the
implementation surfaces it for review and the threshold is adjusted by
hand in the test.

The Playwright failure-path discipline from PR #35 carries through: each
new mobile test must demonstrably fail when the migration is reverted on
the affected template, before the migration is restored.

---

## Acceptance criteria

Each criterion is deterministic and verifiable with a Playwright probe
or a grep.

1. **Partial exists** at
   `config/www/user/themes/byvaerkstederne/templates/partials/event_card.html.twig`
   and exports the documented canonical-event-data interface.
2. **`event_list.html.twig` renders through the partial** —
   `grep -nE '<div class="bv-event-row' config/www/user/themes/byvaerkstederne/templates/modular/event_list.html.twig`
   returns no inline matches (all rendering is via the partial).
3. **`atelier_sessions.html.twig` renders through the partial** —
   `grep -nE 'display: grid|grid-template-columns'
   config/www/user/themes/byvaerkstederne/templates/modular/atelier_sessions.html.twig`
   returns no inline matches on the card-wrapper line.
4. **`calendar_featured.html.twig` renders through the partial** —
   `.bv-featured-event` selectors are gone from the modular; the partial
   is the only consumer of the `.bv-event-row--featured` modifier (if
   one was needed).
5. **`event_highlight.html.twig` renders through the partial** —
   `.bv-event-highlight` and `.bv-event-date` selectors are removed
   from the modular's card markup.
6. **Bespoke CSS classes are deleted** —
   `grep -rn '\.bv-featured-event\|\.bv-event-highlight\|\.bv-event-date'
   config/www/user/themes/byvaerkstederne/css/theme.css` returns no
   matches at the end of the run (these classes are dead code once all
   four templates are migrated).
7. **Mobile rendering** — every route listed under "Tests" above passes
   the four-rule mobile invariant (no right-overflow, no
   `documentElement.scrollWidth > innerWidth`, no title/desc/time
   bleeding past body padding) at viewport 390 × 844. The
   `mobile-chromium` Playwright project's exit code is 0.
8. **Mobile failure-path coverage** — each affected route has at least
   one new mobile test that demonstrably fails when the migration is
   reverted on the corresponding template. The evaluator captures the
   baseline-revert log.
9. **Desktop visual parity** — `tests/anonymous/event-card-visual-parity.js`
   passes with zero pixel diff against the baseline screenshots
   captured before migration starts on each route. Any deliberate
   delta must be documented inline in the test with the diff threshold
   it requires and a one-line rationale.
10. **No desktop regression** — the differential C7 from PR #35 carries
    over: every test that passes on the run's base ref under
    `--project=chromium` must also pass on HEAD.
11. **No `test.skip()` introduced** — `git diff <base>..HEAD -- 'tests/'`
    contains no added `test.skip(`, `xit(`, `it.skip(`, `describe.skip(`.
12. **Scope discipline** — `git diff --name-only <base>..HEAD` lists only
    paths under `config/www/user/themes/byvaerkstederne/templates/`,
    `config/www/user/themes/byvaerkstederne/css/`, `tests/`, and
    `playwright.config.js`. No edits to page YAMLs, no PHP plugin
    changes, no deploy / scripts changes, no `specifications/`,
    `decisions/`, `ROADMAP.md`, `CLAUDE.md`, or `docker-compose.yml`
    changes.
13. **No new media-query thresholds** — added CSS rules sit only in the
    existing `(max-width: 1023px) | (max-width: 767px) | (max-width:
    480px)` blocks.
14. **Twig cache discipline** — the verification log shows
    `bin/grav clearcache` (no hyphen) run inside the worktree's Grav
    container after every `.html.twig` edit and before every Playwright
    probe.

---

## File-level scope

Allowed prefixes for any change in this run:

- `config/www/user/themes/byvaerkstederne/templates/partials/` — new
  `event_card.html.twig`.
- `config/www/user/themes/byvaerkstederne/templates/modular/` — edits to
  the four modular templates being migrated; no other modulars touched.
- `config/www/user/themes/byvaerkstederne/css/theme.css` — additions
  and dead-class removals only; existing rules untouched except via
  rename/move that preserves selectors that remain in use.
- `tests/mobile/` — the new event-card unification test file.
- `tests/anonymous/` — the new visual-parity test file (this is the only
  reason `tests/anonymous/` is in scope).
- `playwright.config.js` — only if a new project for visual-parity
  baselines needs configuring.

Out of scope:

- `config/www/user/pages/` — page YAMLs not edited.
- `config/www/user/plugins/` — no PHP changes.
- `config/www/user/accounts/`, `config/www/user/data/` — no live state
  touched.
- `apex/`, `deploy/`, `scripts/`, `migrations/` — out of scope.
- `tests/authenticated/` — the unification does not affect any
  authenticated route; no need to introduce credential dependencies.
- `specifications/`, `decisions/`, `ROADMAP.md` — orchestrator's
  PR-time responsibility, not the run's.

---

## Implementation order

Two sprints is the natural split — the partial + the highest-pain
migration (`atelier_sessions`, which is the user-reported defect) in
sprint 1; the remaining three callers + dead-class deletion in sprint 2.
A planner is free to combine into one sprint if it judges the diff
manageable, but the visual-parity contract makes a two-sprint split
likely safer (sprint 1 establishes the partial and proves the migration
on one caller; sprint 2 rides the established pattern).

Suggested ordering inside sprint 1:

1. Capture desktop baseline screenshots of every affected route, before
   any markup change, into `tests/anonymous/__snapshots__/`. These are
   the ground-truth for visual-parity assertions.
2. Write the partial. Test it in isolation by rendering it through a
   throwaway Twig test page.
3. Migrate `event_list.html.twig` — the lowest-risk migration because
   the partial mirrors what the template already does.
4. Run the existing mobile + desktop Playwright suites; both must still
   pass exactly as they did before.
5. Migrate `atelier_sessions.html.twig`. Add the mobile probe for
   `/vaerksteder/krea-cafe/syvaerkstedet`. Verify the probe fails on
   the pre-migration revert.

Suggested ordering inside sprint 2:

6. Migrate `calendar_featured.html.twig`. Decide between the modifier
   approach and re-styling the canonical class based on the smallest
   visual diff.
7. Migrate `event_highlight.html.twig`.
8. Remove `.bv-featured-event*`, `.bv-event-highlight*`,
   `.bv-event-date*` from `theme.css`.
9. Final full-suite Playwright run on `mobile-chromium` and `chromium`;
   both must be green.

---

## Risks and decisions to make during implementation

- **`event.tag` vs. reusing `event.cta.label` for the calendar-featured
  badge.** The current `calendar_featured.html.twig` renders a tag badge
  (e.g. "Lige nu") that is conceptually distinct from a CTA. The
  implementation either adds an optional `event.tag.{label,severity}`
  field to the canonical shape or maps the badge to an existing field.
  Resolve based on which keeps the partial's interface narrower.
- **`.bv-event-row--featured` vs. styling the canonical date larger.**
  See `calendar_featured.html.twig` migration above. The simpler
  outcome is "featured is a modifier"; the cleaner outcome is "the
  canonical date scales with viewport". Implementation picks one and
  documents the choice in a comment on the canonical CSS block.
- **`event_highlight.html.twig`'s secondary-event list.** Currently
  rendered as a vertical list of compact cards with their own
  bespoke `.bv-event-date` class. Migration treats each list entry as
  a partial-rendered card with no modifier; if the visual baseline
  differs, the canonical mobile rules already cover the geometry, but
  the desktop look may need a `.bv-event-row--compact` modifier (third
  option in addition to default and `--featured`). Decide after the
  baseline screenshots reveal the actual delta.
- **Visual baseline drift.** The screenshots captured in step 1 are
  ground-truth for the run. If the implementation discovers a
  pre-existing visual bug (a subtle pixel misalignment that the bespoke
  templates also exhibited), the test threshold MUST NOT be adjusted to
  paper over it; document the pre-existing bug and either fix it as
  part of this run or surface it as a follow-up.
- **`atelier_sessions` accent mapping.** Today the accent is picked from
  the page header (`h.accent`), not from each session. The canonical
  shape allows per-event accent, but the migration sets every session's
  accent to the page-level accent until a future spec decides whether
  per-session accents are desirable.

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
  `docker-compose.yml` are read-only to them; archival and ADR work is
  the orchestrator's PR-time responsibility, not sub-agents'.
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
- The dead bespoke classes (`.bv-featured-event*`,
  `.bv-event-highlight*`, `.bv-event-date*`) are removed from
  `theme.css`.
- Every route that renders an event card passes the four-rule mobile
  invariant at viewport 390 × 844.
- Desktop visual-parity tests pass with zero pixel diff (or
  implementation-documented deliberate-delta thresholds) on every
  affected route.
- The PR opens against `develop` with the full migration in two (or one)
  sprints worth of commits.
