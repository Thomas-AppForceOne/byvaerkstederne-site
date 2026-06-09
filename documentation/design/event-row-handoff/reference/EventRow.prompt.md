Single calendar/event line with a square date block, title, optional time + description, and a meta column; colour-coded by workshop, slides on hover. **Responsive to its own width** — stacks vertically below ~540px (date goes horizontal, meta drops below).

```jsx
<EventRow month="JUN" day="14" title="Åben Makerspace-aften"
  time="Onsdag kl. 15-17" description="Kom og print, lod og byg."
  metaLabel="Drop-in" metaValue="Ingen tilmelding" color="secondary" />

{/* or with a capacity counter instead of meta */}
<EventRow month="JUN" day="18" title="Frøbytte" capacity="8 / 30" color="primary" />
```

Stack several with a small gap to form the calendar list. `color` is the workshop hue of the left border. Use `metaLabel`/`metaValue` for a drop-in/status badge, or `capacity` for a "12 / 20" counter — not both.
