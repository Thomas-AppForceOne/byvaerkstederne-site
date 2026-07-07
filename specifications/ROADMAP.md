# Roadmap

Forward-looking only. Each entry points to its spec; the roadmap does not repeat or extend the spec. When work starts on a spec, that entry leaves the roadmap. Implemented specs are not tracked here — they live in `archive/`.

Lifecycle and folder policy: [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle).

---

## Next

### Event RSVP & rich event details
**Spec:** [event_rsvp_specification.md](event_rsvp_specification.md)

Members sign up for (Tilmeld) or mark interest in (Interesseret) events directly from the event card, which expands modally over the calendar; everyone sees seat availability (unlimited events show counts only); organizers see their attendee lists; events gain a WYSIWYG-edited details body with image upload (sanitized server-side). Builds on the merged frontend event CRUD; ships behind the reserved `event_rsvp` flag.

### Account menu & self-service
**Spec:** [account_self_service_specification.md](account_self_service_specification.md)

The logged-in user label in the header becomes a dropdown menu opening a new `/konto` page where members change email (verify-new-address-first), change password, edit display name, see current roles, request arrangør rights (admins notified, granting stays manual), and delete their account — soft delete with a 30-day regret window (signing in reinstates), then automatic GDPR-compliant hard delete with anonymization of authored content. New `account-manager` plugin; ships behind the new `account_self_service` flag.

---

## Backlog (spec pending)

Forward work carried over from the deploy/data-lifecycle and CI tracks; each needs a spec before it is picked up.

- **Remote-mode SSH migration runner** — the outstanding follow-up from the data-versioning work: schema-bump deploys against an SSH tier still abort by design until remote-mode execution lands.
- **CI release protection, Parts 2 & 3** — auto-tag + auto-open the back-merge on merge (needs a token); run the deploys from CI (needs secrets + runner network). Part 1 shipped.
- **Automated real-tier coverage** — exercise the promote/rollback paths against live tiers, not just the local harness.
