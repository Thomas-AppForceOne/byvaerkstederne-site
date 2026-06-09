# Handoff (REV 2): EventRow — fuld datamodel + responsiv

> **Revision af** `design_handoff_eventrow_responsive` (2026-06-09).
> Dette er en **revisionsrunde**, ikke en genstart. Den visuelle identitet er
> uændret (sienna/midnat-palet, `--font-headline` på titler, 4-px workshop-accent
> i venstre kant, hover-translate). Ændringerne handler om **datamodel-dækning**:
> de produktionsrækker, der renderes på `/vaerkstedskalenderen`, bærer fire
> samtidige meta-signaler, som den første version kun modellerede to af.

---

## Hvad reviewet fandt (og hvad denne rev løser)

| # | Blocker (verbatim) | Løsning i denne rev |
|---|---|---|
| **F1** | Calendar-filter-regression: migreringen sender `data-group="{accent}"` i stedet for filter-ID'et. `site.js:687` sammenligner knappens `data-filter` mod `row.dataset.group` — filtreringen brød. | **`accent` og `filter` er nu to adskilte felter.** `accent`/`color` styrer KUN venstre-kantens farve (`--bv-accent`). Filter-ID'et renderes som `data-group="{filter}"` på rækken — uændret kontrakt mod `site.js`. Se *“Accent vs. filter”*. |
| **F2** | Badge-eyebrow tabt: partialen har ingen badge-slot; hver række mistede sin badge. | **Ny badge-slot øverst i body**, over titlen. Bruger jeres eksisterende `.bv-badge`. Se *“Body-kolonnen”*. |
| **F3** | CTA + pris + kapacitet kollapset: partialen tillod kun ét `{label, value, href}` ELLER kapacitet. Rigtige kalender-events viser alle tre. | **Meta-kolonnen er nu en lodret stak af tre uafhængigt-valgfrie slots**: pris → CTA → kapacitet. Tomme slots kollapser. Se *“Meta-kolonnen”*. |

---

## Beslutning: én meta-model, ikke to special-cases

Den gamle regel — *“`{label, value, href}` ELLER `capacity`, aldrig begge”* —
behandlede atelier-rækken (Drop-in / Ingen tilmelding) og kalender-rækken som to
forskellige former. **Det er nu unificeret.** Der findes **én** meta-kolonne med
tre valgfrie slots:

1. **Pris** (`price`) — prominent værdi øverst, fx `"250 kr / person"`, `"Gratis"`, `"Drop-in"`.
2. **CTA** (`ctaLabel` + `ctaHref`) — handlingsknap, fx `"Tilmeld"`.
3. **Kapacitet** (`capacity`) — read-only tæller med `group`-ikon, fx `"12 / 20"`.

Atelier-drop-in-rækken er **ikke** længere et special-case: det er bare den fulde
række med kapacitets-slottet tomt (pris `"Drop-in"` + CTA `"Se Makerspace"`, ingen
kapacitet). Det matcher præcis den rå produktions-DOM du sendte. Tomme slots
renderer ingenting og efterlader ingen plads.

---

## Layout-spec

### Body-kolonnen (midten) — badge + titel
Body er nu en lodret flex-stak (`gap: var(--space-1)`):

1. **Badge-eyebrow** (valgfri) — `.bv-badge` chip, øverst, `margin-bottom: var(--space-1)`. Fyldfarve følger som standard accent-farven, men kan overstyres.
2. **Titel** — **`<h3>`** (tilgængeligheds-fix, se F-punkt c), `font-headline`, 700, UPPERCASE, `letter-spacing: var(--tracking-tight)`, `1.25rem`, `margin: 0`.
3. **Tid** (valgfri) — `font-headline`, 700, `0.85rem`.
4. **Beskrivelse** (valgfri) — `font-body`, `0.875rem`, `--on-surface-variant`, `text-wrap: pretty`.

### Meta-kolonnen (højre) — tre stablede slots
Lodret stak, højrejusteret på desktop (`align-items: flex-end; gap: var(--space-2); min-width: 9rem`):

- **Pris** — `font-headline`, 700, `0.95rem`.
- **CTA** — `.bv-btn .bv-btn--{variant} .bv-btn--sm`, square, UPPERCASE.
- **Kapacitet** — `display: inline-flex; gap: 0.25rem; 0.875rem; --on-surface-variant` + Material Symbols `group`.

### Desktop (række ≥ 540px)
`display: flex; align-items: center; gap: var(--space-6); padding: var(--space-6) var(--space-4); background: var(--surface-container-lowest); border-left: 4px solid var(--bv-accent);` — hover: `transform: translateX(0.25rem)`.

### Stablet (række < 540px) — ALLE fire signaler
- Rækken: `flex-direction: column; align-items: flex-start; gap: var(--space-3)`.
- **Dato** flipper vandret til `10 JUN` (`flex-direction: row`, `__date-day { order: -1 }`).
- **Badge** bliver siddende øverst i body (uændret rækkefølge).
- **Body** + **meta** går i fuld bredde.
- **Meta** venstrejusteres; de tre slots forbliver lodret stablet.
- **CTA** strækkes til **fuld bredde** → 44px+ tap-target (`.bv-event-row__meta .bv-btn { width: 100% }`).

> Se `reference/demo.html` for begge tilstande side om side med en række, der bærer alle fire signaler.

---

## Accent vs. filter (F1)

To attributter der ligner hinanden men IKKE er det samme — hold dem adskilt:

| Felt | Rolle | Render |
|---|---|---|
| `accent` / `color` | **Visuel** workshop-farve på venstre-kanten (og som default badge-fyld). Kun præsentation. | `border-left: 4px solid var(--bv-accent)` (sæt `--bv-accent` som inline-style eller via klasse) |
| `filter` | **Adfærd**: filter-ID'et (`makerspace`, `krea-cafe`, …). Kun til at koble filter-knapperne. | `data-group="{filter}"` på rækken |

De korrelerer ofte (makerspace → blå), men skal sættes hver for sig. **`data-group`
må ALDRIG fodres med farve-tokenet** — det var præcis F1-regressionen.

> **YAML-mapping:** i `begivenheder.yaml` er `group:` filter-ID'et (→ `data-group`),
> og `button_style:` driver accent-hue'en. To felter, to formål.

---

## Production implementation (Grav: Twig + theme.css)

### Vigtig rettelse ift. forrige rev — container-query-target
Forrige handoff satte `container-type` på `.bv-event-row` **og** forsøgte at restyle
`.bv-event-row` fra dens egen `@container`-query. **Det virker ikke:** et element kan
ikke reagere på sin egen container-type — en container-query styrer kun **efterkommere**.
Pak derfor hver række i et `.bv-event-item`, der er container'en:

```twig
{# event_list.html.twig #}
<ul class="bv-event-list">
  {% for ev in events %}
    <li class="bv-event-item">
      <article class="bv-event-row"
               data-group="{{ ev.group }}"
               style="--bv-accent: var(--{{ ev.button_style }});">

        <div class="bv-event-row__date">
          <span class="bv-event-row__date-month">{{ ev.event_date|date('M') }}</span>
          <span class="bv-event-row__date-day">{{ ev.event_date|date('j') }}</span>
        </div>

        <div class="bv-event-row__body">
          {% if ev.badge %}
            <span class="bv-badge bv-badge--{{ ev.button_style }} bv-event-row__badge">{{ ev.badge }}</span>
          {% endif %}
          <h3 class="bv-event-row__title">{{ ev.title }}</h3>
          {% if ev.event_time %}<p class="bv-event-row__time">{{ ev.event_time }}</p>{% endif %}
          {% if ev.description %}<p class="bv-event-row__desc">{{ ev.description }}</p>{% endif %}
        </div>

        {% if ev.price or ev.button_text or ev.capacity %}
          <div class="bv-event-row__meta">
            {% if ev.price %}<span class="bv-event-row__price">{{ ev.price }}</span>{% endif %}
            {% if ev.button_text and ev.button_url %}
              <a class="bv-btn bv-btn--{{ ev.button_style }} bv-btn--sm" href="{{ ev.button_url }}">{{ ev.button_text }}</a>
            {% endif %}
            {% if ev.capacity %}
              <span class="bv-event-row__capacity"><span class="material-symbols-outlined">group</span>{{ ev.capacity }}</span>
            {% endif %}
          </div>
        {% endif %}
      </article>
    </li>
  {% endfor %}
</ul>
```

### theme.css (`/* Calendar */`-sektionen)

```css
/* Hver entry er sin egen query-container; rækken (efterkommeren) reagerer. */
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

/* DATO */
.bv-event-row__date {
    flex-shrink: 0; min-width: 4rem; text-align: center;
    font-family: var(--font-headline); font-weight: 700; line-height: 1;
    display: flex; flex-direction: column; align-items: center;
}
.bv-event-row__date-month { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--on-surface-variant); }
.bv-event-row__date-day { font-size: 1.5rem; }

/* BODY: badge + h3 + tid + beskrivelse */
.bv-event-row__body { flex: 1; min-width: 0; display: flex; flex-direction: column; align-items: flex-start; gap: var(--space-1); }
.bv-event-row__badge { margin-bottom: var(--space-1); }
.bv-event-row__title { margin: 0; font-family: var(--font-headline); font-weight: 700; text-transform: uppercase; letter-spacing: var(--tracking-tight); font-size: 1.25rem; line-height: 1.15; }
.bv-event-row__time  { margin: 0; font-family: var(--font-headline); font-weight: 700; font-size: 0.85rem; }
.bv-event-row__desc  { margin: 0; font-size: 0.875rem; color: var(--on-surface-variant); text-wrap: pretty; }

/* META: pris over CTA over kapacitet (alle valgfrie) */
.bv-event-row__meta { flex-shrink: 0; min-width: 9rem; display: flex; flex-direction: column; align-items: flex-end; gap: var(--space-2); text-align: right; }
.bv-event-row__price { font-family: var(--font-headline); font-weight: 700; font-size: 0.95rem; line-height: 1.2; }
.bv-event-row__capacity { display: inline-flex; align-items: center; gap: 0.25rem; font-size: 0.875rem; color: var(--on-surface-variant); }
.bv-event-row__capacity .material-symbols-outlined { font-size: 1.1rem; }

/* STABLET: når RÆKKEN selv er < 540px */
@container event-row (max-width: 540px) {
    .bv-event-row { flex-direction: column; align-items: flex-start; gap: var(--space-3); }
    .bv-event-row__date { flex-direction: row; align-items: baseline; gap: var(--space-2); min-width: auto; text-align: left; }
    .bv-event-row__date-day { order: -1; font-size: 1.25rem; }   /* "10 JUN" */
    .bv-event-row__date-month { font-size: 0.8rem; }
    .bv-event-row__body,
    .bv-event-row__meta { width: 100%; }
    .bv-event-row__meta { align-items: flex-start; text-align: left; margin-top: var(--space-2); }
    .bv-event-row__meta .bv-btn { width: 100%; }   /* fuld-bredde tap-target */
}
```

> **Bemærk:** CSS-kommentarer kan ikke nestes. Skriv ikke `/* … /* Calendar */ … */` —
> den indre `*/` lukker kommentaren for tidligt og korrumperer den efterfølgende regel.

---

## Repræsentativt event (begivenheder.yaml)

Du sendte `event001` (Drop-in, ingen kapacitet). For at vise **alle fire signaler**
samtidig — og afsløre F3 — er her det samme event udvidet med pris + CTA-tilmelding +
kapacitet. Det er denne form, datamodellen nu skal kunne bære:

```yaml
event001:
  published: true
  title: "Elektronik og 3D-print for nybegyndere"
  description: "Drop-in værksted. 12 år og opefter. Tag gerne en ven med."
  group: makerspace            # → data-group (FILTER-ID, ikke farve)
  badge: "Makerspace & Reparation"   # → badge-eyebrow
  event_date: "2026-06-10"
  event_time: "18:00 — 20:00"
  location: "Nørregade 21, Hundested"
  capacity: "12 / 20"          # → kapacitets-slot (read-only)
  price: "250 kr / person"     # → pris-slot
  button_text: "Tilmeld"       # → CTA-label
  button_url: "/tilmeld/elektronik-3dprint"   # → CTA-href
  button_style: secondary      # → accent-hue (--bv-accent) + badge-fyld
  featured: false
  featured_tag: ""
```

Atelier-drop-in-varianten er den samme struktur med tomme slots:
`capacity: ""`, `price: "Drop-in"`, `button_text: "Se Makerspace"` — pris + CTA, ingen kapacitet.

---

## Fidelity
**Hi-fi.** Endelige farver, typografi, spacing og opførsel. Genskab pixel-præcist
med jeres `--token`-system og `.bv-*`-klasser. Den visuelle identitet er uændret
fra forrige rev — kun datamodellen er udvidet.

## Filen der skal ændres
```
config/www/user/themes/byvaerkstederne/css/theme.css   (/* Calendar */-sektionen)
config/www/user/themes/byvaerkstederne/partials/event_list.html.twig
```

## Test (Playwright) — udvid
1. **Filter (F1):** rendér en række med `group: makerspace`, `button_style: secondary`; assert `row.dataset.group === 'makerspace'` (IKKE `'secondary'`), og at en klik på filter-knappen `[data-filter="makerspace"]` viser rækken.
2. **Badge (F2):** assert at `.bv-event-row__badge` findes og har badge-teksten.
3. **Tre meta-slots (F3):** assert at pris, CTA (`a.bv-btn`) og kapacitet alle renderes samtidigt på en fuldt-udfyldt række — og at en række UDEN kapacitet ikke efterlader tom plads.
4. **Tilgængelighed (c):** assert at titlen er en `<h3>` (`row.querySelector('h3.bv-event-row__title')`).
5. **Stabling:** rendér i en 360px-wrapper; assert `getComputedStyle(row).flexDirection === 'column'`, CTA i fuld bredde, og ingen vandret overflow (`scrollWidth <= clientWidth`). Husk: test både success- og edge-sti.

## Git
Jf. `CLAUDE.md`: feature-branch fra `develop` (`git checkout -b feature/eventrow-datamodel develop`), aldrig direkte commit på `develop`/`main`, PR med `--base develop`.

## Filer i denne pakke
- `README.md` — dette dokument (rev 2).
- `reference/demo.html` — **selvstændig** referenceside: alle fire signaler i desktop + stablet, med produktions-CSS'en (container query) live. Åbn den for at se den tilsigtede opførsel.
- `reference/EventRow.reference.jsx` — React-referenceimplementering (ResizeObserver-variant af samme logik; ikke kompileret, kun til læsning).
- `reference/EventRow.prompt.md` — kort props-oversigt + eksempler.
- `reference/patterns.card.html` — lille demo-markup (reference).
