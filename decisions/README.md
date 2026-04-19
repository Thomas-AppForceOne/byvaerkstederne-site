# Architecture Decision Records

Permanent, append-only record of **why** parts of the system work the way they do. Written after a feature ships. Never edited — a reversed decision is recorded in a new ADR that supersedes the old one.

See [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle) for the spec → implement → ADR → delete lifecycle that feeds this folder.

---

## Specs vs. ADRs

| | [`specifications/`](../specifications/README.md) | `decisions/` |
|---|---|---|
| **Purpose** | Define what to build and how | Explain why it was built that way |
| **Audience** | Developer implementing / GAN worker | Developer maintaining, 6 months later |
| **Written** | Before implementation | After implementation ships |
| **Length** | As detailed as needed | One page maximum |
| **Lifetime** | Deleted after implementation | Permanent |

ADRs record constraints and rationale, not procedure — do not treat them as implementation instructions.

---

## Format

Use [ADR-template.md](ADR-template.md). File naming: `ADR-NNN-short-slug.md` with zero-padded incrementing NNN.

---

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [ADR-001](ADR-001-navigation-footer-placement.md) | Footer-only placement for community feedback affordances | Accepted | 2026-04-18 |
