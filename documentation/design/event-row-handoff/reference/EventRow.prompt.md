Single calendar/event line for the værkstedskalender. Three columns — **date | body | meta**. The body holds an optional **badge eyebrow** above a semantic `<h3>` title, plus optional time + description. The meta column stacks up to three independently-optional slots: a prominent **price**, a **CTA button** (`ctaLabel` + `ctaHref`), and a read-only **capacity** counter. Any combination renders; empty slots collapse. Colour-coded by workshop, slides on hover. **Responsive to its own width** — stacks vertically below ~540px (date goes horizontal, meta drops below, CTA goes full-width).

```jsx
{/* Calendar event carrying all four signals at once */}
<EventRow
  month="JUN" day="10"
  badge="Makerspace & Reparation"
  title="Elektronik og 3D-print for nybegyndere"
  time="Onsdag kl. 18–20"
  description="Drop-in værksted. 12 år og opefter."
  price="250 kr / person"
  ctaLabel="Tilmeld" ctaHref="/tilmeld/elektronik"
  capacity="12 / 20"
  color="secondary"        /* visual left-border hue */
  filter="makerspace"      /* filter ID → data-group, distinct from color */
/>

{/* Atelier drop-in: price + CTA, no capacity — the same stacked-meta pattern */}
<EventRow month="JUN" day="14" title="Photo Transfer — Intro"
  time="Onsdag kl. 15–17" price="Drop-in"
  ctaLabel="Se Makerspace" ctaHref="/vaerksteder/makerspace"
  color="tertiary" filter="krea-cafe" />
```

`color` is the **visual** border hue; `filter` is the **behavioural** filter ID (emitted as `data-group`) — set them separately even when they correlate. Use `badge` for the eyebrow, `price`/`ctaLabel`+`ctaHref`/`capacity` for any of the three meta slots.
