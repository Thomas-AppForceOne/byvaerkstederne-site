# Handoff: Responsiv EventRow (værkstedskalender-række)

## Overview
Event-rækken i værkstedskalenderen (`.bv-event-row`) ser god ud på desktop som en 3-kolonne flex-række — **dato | indhold | meta** — men på smalle skærme løber meta-kolonnen (fx "DROP-IN / Ingen tilmelding" eller kapacitet "12 / 20") ud over højre kant og bliver afskåret.

Denne ændring gør rækken **bredde-bevidst**: når rækken bliver smallere end ~540px, stabler den lodret — datoblokken bliver vandret ("14 JUN"), og meta-kolonnen falder ned under indholdet i fuld bredde. Intet løber ud over kanten.

## About the Design Files
Filerne i `reference/` er **design-referencer skrevet i HTML/React** — de viser den tilsigtede opførsel, ikke produktionskode, der skal kopieres direkte. `EventRow.jsx` bruger en `ResizeObserver` til at reagere på sin egen bredde, fordi det er en framework-agnostisk React-komponent uden adgang til et stylesheet.

**I jeres produktion (Grav: Twig + `theme.css`) skal dette IKKE laves med JavaScript.** Den korrekte produktionsimplementering er en **CSS container query** på `.bv-event-row` (se "Production implementation" nedenfor). Container queries giver præcis den samme "reager-på-egen-bredde"-opførsel som `ResizeObserver`, men i ren CSS — så rækken også stabler korrekt, hvis den sidder i en smal kolonne på desktop, ikke kun på små viewports.

## Fidelity
**Hi-fi.** Endelige farver, typografi, spacing og opførsel. Genskab pixel-præcist med jeres eksisterende `--token`-system og `.bv-*`-klasser.

## Filen der skal ændres
```
config/www/user/themes/byvaerkstederne/css/theme.css
```
Sektionen `/* ---------- Calendar ---------- */` (klasserne `.bv-event-row`, `.bv-event-row__date`, `.bv-event-row__body`, `.bv-event-row__meta` m.fl.).

## Nuværende tilstand i theme.css
- `.bv-event-row` er en flex-række (`align-items: center; gap: var(--space-6)`).
- Der findes allerede en stak-regel — men den ligger i en **viewport** media query (`@media (max-width: 767px)`). Den fanger altså kun små *skærme*, ikke smalle *containere*, og dækker ikke nødvendigvis custom meta-markup som "DROP-IN / Ingen tilmelding".

## Production implementation (anbefalet: container query)

Tilføj `container-type` på rækken og flyt stak-reglerne fra viewport-media-queryen til en container query, så de gælder uanset hvor rækken sidder:

```css
/* Gør hver event-række til sin egen query-container */
.bv-event-row {
    container-type: inline-size;
    container-name: event-row;
}

/* Når rækken selv er smallere end 540px: stabl lodret */
@container event-row (max-width: 540px) {
    .bv-event-row {
        flex-direction: column;
        align-items: flex-start;
        gap: var(--space-3);
    }
    /* Dato bliver vandret: DAG MÅNED */
    .bv-event-row__date {
        display: flex;
        flex-direction: row;
        align-items: baseline;
        gap: var(--space-2);
        min-width: auto;
        text-align: left;
    }
    .bv-event-row__date-day   { font-size: 1.25rem; }
    .bv-event-row__date-month { font-size: 0.8rem; }
    /* Indhold + meta i fuld bredde under datoen */
    .bv-event-row__body,
    .bv-event-row__meta {
        width: 100%;
    }
    .bv-event-row__meta {
        justify-content: flex-start;
        text-align: left;
        flex-wrap: wrap;
        gap: var(--space-3);
        margin-top: var(--space-2);
    }
}
```

> **Bemærk om DAG/MÅNED-rækkefølge:** På desktop er datoblokken `MÅNED` over `DAG` (måned lille ovenover, dag stor). I den stablede visning vendes den til vandret `DAG MÅNED` (stor dag først, så lille måned). Hvis jeres Twig-markup rendrer `__date-month` før `__date-day` i DOM'en, så brug `order:` i container-queryen for at bytte dem, fx `.bv-event-row__date-day { order: -1; }`.

### Hvis I ikke vil bruge container queries
Container queries er understøttet i alle moderne browsere (Chrome/Edge/Safari/Firefox fra 2023). Hvis I skal støtte ældre browsere, behold den eksisterende `@media (max-width: 767px)`-tilgang, men sørg for at custom meta-markup ("DROP-IN / Ingen tilmelding") får `.bv-event-row__meta` (eller tilsvarende `width:100%`-regel) så den også stabler.

## Layout-spec (til reference)

### Desktop (række ≥ 540px)
- **Container:** `display: flex; align-items: center; gap: var(--space-6); padding: var(--space-6) var(--space-4); background: var(--surface-container-lowest); border-left: 4px solid <hue>;`
- **Hover:** `transform: translateX(0.25rem); transition: transform 0.2s;`
- **Dato (venstre):** `font-family: var(--font-headline); font-weight: 700; text-align: center; min-width: 4rem; flex-shrink: 0;`
  - Måned: `0.75rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--on-surface-variant);`
  - Dag: `1.5rem; line-height: 1;`
- **Indhold (midt):** `flex: 1; min-width: 0;`
  - Titel: `font-family: var(--font-headline); font-weight: 700; text-transform: uppercase; letter-spacing: -0.02em;`
  - Tid (valgfri): `font-family: var(--font-headline); font-weight: 700; font-size: 0.85rem; margin-top: 0.25rem;`
  - Beskrivelse: `font-size: 0.875rem; color: var(--on-surface-variant); margin-top: 0.25rem;`
- **Meta (højre):** `flex-shrink: 0;`
  - Kapacitet-variant: `display: flex; align-items: center; gap: 0.25rem; font-size: 0.875rem; color: var(--on-surface-variant);` + Material Symbols-ikon `group`.
  - Status-variant: eyebrow (`font-headline; 700; uppercase; letter-spacing: 0.15em; 0.7rem; color: var(--on-surface-variant)`) over værdi (`font-headline; 700; 0.95rem`), højrejusteret (`text-align: right; min-width: 7rem`).

### Stablet (række < 540px)
- Container: `flex-direction: column; align-items: flex-start; gap: var(--space-3);`
- Dato vandret: `DAG (1.25rem)` + `MÅNED (0.8rem, uppercase, muted)`, `align-items: baseline; gap: var(--space-2);`
- Indhold: `width: 100%`
- Meta: `width: 100%; text-align: left; margin-top: var(--space-2);`

## Farve-mapping (left-border hue)
| `color` | Token | Værksted |
|---|---|---|
| `primary` | `--primary` (#13483b) | Grønt BYværksted |
| `secondary` | `--secondary` (#325f9b) | Makerspace & Reparation |
| `tertiary` | `--tertiary` (#712800) | Krea Café |
| `kulturhus` | `--kulturhus` (#27272a) | Eventværkstedet |

## Assets / ikoner
Kapacitet-varianten bruger Material Symbols Outlined-glyfen `group` (allerede indlæst i `base.html.twig`). Ingen nye assets.

## Test (Playwright)
Tilføj/udvid en test der renderer en `.bv-event-row` i en smal container (fx 360px wrapper) og asserter at `getComputedStyle(...).flexDirection === 'column'` og at rækken ikke har vandret overflow (`scrollWidth <= clientWidth`). Husk jeres regel: test både success- og fejl-/edge-sti.

## Git
Jf. `CLAUDE.md`: lav en feature-branch fra `develop` (`git checkout -b feature/responsive-event-row develop`), aldrig direkte commit på `develop`/`main`, og åbn PR med `--base develop`.

## Files i denne pakke
- `reference/EventRow.reference.jsx` — React-referenceimplementering (ResizeObserver-variant; ikke kompileret, kun til læsning)
- `reference/EventRow.prompt.md` — kort brugsvejledning + eksempler (props: `month`, `day`, `title`, `time?`, `description?`, `capacity?`, `metaLabel?`, `metaValue?`, `color`)
- `reference/patterns.card.html` — lille demo-markup (reference)
