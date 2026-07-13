# Roadmap

Forward-looking only. Each entry points to its spec; the roadmap does not repeat or extend the spec. When work starts on a spec, that entry leaves the roadmap. Implemented specs are not tracked here — they live in `archive/`.

Lifecycle and folder policy: [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle).

---

## Next

### Event RSVP & rich event details
**Spec:** [event_rsvp_specification.md](event_rsvp_specification.md)

Members sign up for (Tilmeld) or mark interest in (Interesseret) events directly from the event card, which expands modally over the calendar; everyone sees seat availability (unlimited events show counts only); organizers see their attendee lists; events gain a WYSIWYG-edited details body with image upload (sanitized server-side). Builds on the merged frontend event CRUD; ships behind the reserved `event_rsvp` flag.

---

## Backlog (spec pending)

Forward work carried over from the deploy/data-lifecycle and CI tracks; each needs a spec before it is picked up.

- **Remote-mode SSH migration runner** — the outstanding follow-up from the data-versioning work: schema-bump deploys against an SSH tier still abort by design until remote-mode execution lands.
- **CI release protection, Parts 2 & 3** — auto-tag + auto-open the back-merge on merge (needs a token); run the deploys from CI (needs secrets + runner network). Part 1 shipped.
- **Automated real-tier coverage** — exercise the promote/rollback paths against live tiers, not just the local harness.
