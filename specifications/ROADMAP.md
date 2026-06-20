# Roadmap

Forward-looking only. Each entry points to its spec; the roadmap does not repeat or extend the spec. When work starts on a spec, that entry leaves the roadmap. Implemented specs are not tracked here — they live in `archive/`.

Lifecycle and folder policy: [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle).

---

## Next

### Frontend event CRUD
**Spec:** [frontend_event_crud_specification.md](frontend_event_crud_specification.md)

Let approved members ("arrangører") create/read/update/delete events from the public site via themed forms, instead of the admin panel. Builds on the existing `begivenheder` Flex Directory; a new `event-manager` plugin enforces a single handler authorization contract (authn + `admin.events.*` capability + per-object ownership), owner-stamping, and self-service publishing (arrangører manage and publish their own events; admin is a rare escalation only). Complete CRUD is the release gate.

---

## Backlog (spec pending)

Forward work carried over from the deploy/data-lifecycle and CI tracks; each needs a spec before it is picked up.

- **Remote-mode SSH migration runner** — the outstanding follow-up from the data-versioning work: schema-bump deploys against an SSH tier still abort by design until remote-mode execution lands.
- **CI release protection, Parts 2 & 3** — auto-tag + auto-open the back-merge on merge (needs a token); run the deploys from CI (needs secrets + runner network). Part 1 shipped.
- **Automated real-tier coverage** — exercise the promote/rollback paths against live tiers, not just the local harness.
