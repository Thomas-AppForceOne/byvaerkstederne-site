# Specifications

This folder contains pre-implementation specifications for planned features and changes.

---

## What belongs here

A spec lives here from the moment it is written until the feature it describes has shipped and an ADR has been written. After that, the spec is deleted — the ADR in `decisions/` is the permanent record.

**Specs in this folder are active work items.** If a spec exists here, the feature is either planned or in progress. If no spec exists for something you want to build, write one before starting.

---

## What does not belong here

- Implemented features — see `decisions/` for those
- General architecture documentation — put that in `decisions/` or `README.md`
- Drafts or notes that are not actionable — keep those out of the repo

---

## For GAN runs and agent workers

Read specs in this folder when you need to understand **what to build**. Each spec is a detailed, prescriptive document intended for use during implementation.

Once a spec is implemented:
1. Write an ADR in `decisions/` capturing key decisions and rationale
2. Delete this spec file
3. Update `decisions/README.md` index

Do not accumulate implemented specs here. The folder should stay small enough that the entire contents are cheap to load.

---

## Active specifications

| File | Feature | Status |
|---|---|---|
| [development_flags_specification.md](development_flags_specification.md) | Environment-driven feature flag system | Planned |
| [development_flags_specification_condensed.md](development_flags_specification_condensed.md) | Condensed reference version of above | Planned |
