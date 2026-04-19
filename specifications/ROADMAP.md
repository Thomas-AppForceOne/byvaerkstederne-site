# Implementation roadmap

The order in which the specs in this folder should be tackled. Later specs assume earlier ones have shipped; implementing out of order will either duplicate work or leave gaps.

Folder policy (what belongs here, how specs become ADRs) lives in [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle).

---

## Order

### 1. Feature-flag infrastructure — IMPLEMENTED

**Spec (archived):** [archive/development_flags_specification.md](archive/development_flags_specification.md)

Shipped on branch `gan/20260419T154559Z-f8eb`. `FeatureFlag` enum, `FlagStore`, Twig helpers (`feature_enabled`, `enabled_features`, `feature_visible`), page-level `feature:` frontmatter gating, and centralized collection filter are all in place under `config/www/user/plugins/feature-flags/`. Flags default to false; no visible site changes.

**Exit criteria:** met. PHPUnit suite: 122 tests / 397 assertions. Live HTTP verified. ADR to be written at PR-merge time per CLAUDE.md.

### 2. End-to-end test coverage for Roadmap, Rapportér fejl, Forslå Feature

**Spec:** [roadmap_bug_feature_tests_specification.md](roadmap_bug_feature_tests_specification.md)

Ship second. Adds Playwright coverage for the three community features before they get flagged. This gives us a regression net: when step 3 wires flags into these surfaces, we can run the same suite under the internal profile and prove nothing broke.

Depends on step 1 only for the test that asserts `feature_enabled()` in templates — otherwise independent.

**Exit criteria:** the suite passes locally under both anonymous and authenticated credentials. Admin tests skip cleanly without admin creds.

### 3. Feature-flag rollout to unfinished features and pages

**Spec:** [feature_flag_rollout_specification.md](feature_flag_rollout_specification.md)

Ship third. This is the payoff: flag every unfinished surface so the public-demo profile exposes only the polished pages, while the internal profile continues to show everything.

Depends on step 1 (the mechanism) and step 2 (the regression net).

**Exit criteria:** public-demo and internal profiles both pass their respective Playwright runs; production host is switched to the public-demo profile.

---

## Out-of-order risks

- Skipping step 1 → everything else is blocked; there is nothing to gate against.
- Skipping step 2 → step 3 ships without a regression net on the three most behaviourally complex surfaces, and any bug introduced by the flag wiring will be found in production.
- Rolling up steps 1 and 3 into one sprint → large, hard-to-review change; harder to isolate a rollback if the gating mechanism itself is buggy.
