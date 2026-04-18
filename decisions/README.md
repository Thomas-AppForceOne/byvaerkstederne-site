# Architecture Decision Records

This folder contains Architecture Decision Records (ADRs) for the Byværkstederne platform.

---

## What is an ADR?

An ADR is a short, permanent document that answers one question: **why does this part of the system work the way it does?**

ADRs are written *after* a feature ships, not before. They are never updated — if a decision is reversed, a new ADR supersedes the old one. This means the folder is an append-only audit trail.

---

## What belongs here vs. in `specifications/`

| | `specifications/` | `decisions/` |
|---|---|---|
| **Purpose** | Define what to build and how | Explain why it was built that way |
| **Audience** | Developer implementing / GAN worker | Developer maintaining, 6 months later |
| **Written** | Before implementation | After implementation ships |
| **Length** | As detailed as needed | One page maximum |
| **Lifetime** | Deleted after implementation | Permanent |

**The lifecycle of a feature:**

```
Write spec (specifications/)
    ↓
Implement via /gan or direct development
    ↓
Distil key decisions into an ADR (decisions/)
    ↓
Delete the full spec — the ADR is the permanent record
```

Unimplemented specs live in `specifications/`. Once a spec is implemented and an ADR written, the spec is deleted. This keeps `specifications/` small and `decisions/` lightweight.

---

## For GAN runs and agent workers

If you need to understand **why** something works a certain way, read the ADRs in this folder. Each ADR is short — the full folder is cheap to scan.

If you need to understand **what to build**, look for a spec in `specifications/`. If no spec exists, there is no pre-approved design — ask before inventing.

Do not treat ADRs as implementation instructions. They record constraints and rationale, not procedure.

---

## ADR format

See `ADR-template.md` for the standard format.

File naming: `ADR-NNN-short-slug.md` where NNN is zero-padded and incrementing.

---

## Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [ADR-001](ADR-001-navigation-footer-placement.md) | Footer-only placement for community feedback affordances | Accepted | 2026-04-18 |
