# Roadmap

Forward-looking only. Each entry points to its spec; the roadmap does not repeat or extend the spec. When work starts on a spec, that entry leaves the roadmap. Implemented specs are not tracked here — they live in `archive/`.

Lifecycle and folder policy: [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle).

---

## Next

### Clean up deploy
**Spec:** [deploy_cleanup_specification.md](deploy_cleanup_specification.md)

Tiers ship far more than the running site needs. Determine the necessary file set, rewrite the deploy file-selection to ship only that, then wipe the dev tier and redeploy to prove it.

### Auth surface UI/UX
**Spec:** [auth_surface_uiux_specification.md](auth_surface_uiux_specification.md)

One floating-card identity for login, account creation, and forgotten-password, plus a single consistent centred success/error feedback component. Theme/config only — no plugin PHP, no behaviour change.

---

## Backlog (spec pending)

Forward work carried over from the deploy/data-lifecycle and CI tracks; each needs a spec before it is picked up.

- **Remote-mode SSH migration runner** — the outstanding follow-up from the data-versioning work: schema-bump deploys against an SSH tier still abort by design until remote-mode execution lands.
- **CI release protection, Parts 2 & 3** — auto-tag + auto-open the back-merge on merge (needs a token); run the deploys from CI (needs secrets + runner network). Part 1 shipped.
- **Automated real-tier coverage** — exercise the promote/rollback paths against live tiers, not just the local harness.
