# Implementation roadmap

The order in which the specs in this folder should be tackled. Later specs assume earlier ones have shipped; implementing out of order will either duplicate work or leave gaps.

Folder policy (what belongs here, how specs become ADRs) lives in [CLAUDE.md](../CLAUDE.md#specifications-and-decisions-lifecycle).

---

## Order

### 1. Feature-flag infrastructure — IMPLEMENTED

**Spec (archived):** [archive/development_flags_specification.md](archive/development_flags_specification.md)

Shipped on branch `gan/20260419T154559Z-f8eb`. `FeatureFlag` enum, `FlagStore`, Twig helpers (`feature_enabled`, `enabled_features`, `feature_visible`), page-level `feature:` frontmatter gating, and centralized collection filter are all in place under `config/www/user/plugins/feature-flags/`. Flags default to false; no visible site changes.

**Exit criteria:** met. PHPUnit suite: 122 tests / 397 assertions. Live HTTP verified. ADR to be written at PR-merge time per CLAUDE.md.

### 2. End-to-end test coverage for Roadmap, Rapportér fejl, Forslå Feature — IMPLEMENTED

**Spec (archived):** [archive/roadmap_bug_feature_tests_specification.md](archive/roadmap_bug_feature_tests_specification.md)

Shipped on branch `gan/20260419T200123Z-5ee1`. Playwright suite covers anonymous rejection paths and authenticated flows for Roadmap voting, Rapportér fejl (bug report overlay + submission), and Forslå Feature. Includes globalSetup/globalTeardown-driven account provisioning/cleanup, feature-flag touchpoint assertion, and acceptance-criteria matrix under [tests/ACCEPTANCE.md](../tests/ACCEPTANCE.md).

**Exit criteria:** met. Anonymous suite 23 passed / 34 skipped / 0 failed; authenticated tests skip cleanly with env-var-named reasons when creds are absent.

### 3. Feature-flag rollout to unfinished features and pages — IMPLEMENTED

**Spec (archived):** [archive/feature_flag_rollout_specification.md](archive/feature_flag_rollout_specification.md)

Shipped on branch `gan/20260422T182055Z-5cb6`. 17-flag rollout catalogue declared in the `FeatureFlag` enum; `test.hackersbychoice.dk` and `www.hackersbychoice.dk` env profiles under `config/www/user/env/`; page-level frontmatter gates across home sub-sections, workshop detail pages, roadmap, community affordances, membership-signup, press/minutes/calendar/contact/statutes; Twig partial gates on navigation, footer, base overlays, and the roadmap card grid; `|feature_visible` on the workgroups card grid; PHP handler gates on the roadmap/feature-suggestion/bug-report plugins returning a non-leaking `404 Not Found` before any nonce/auth/input parsing when their flag is off. Playwright coverage across both profiles: 117 anonymous tests passing.

**Exit criteria:** met. Anonymous suite 117/117 passed under both profiles; PHPUnit feature-flags suite 139 tests / 1113 assertions; pre-existing Sprint-1+2 regression baseline intact. ADR to be written at PR-merge time per CLAUDE.md.

---

## Out-of-order risks

- Skipping step 1 → everything else is blocked; there is nothing to gate against.
- Skipping step 2 → step 3 ships without a regression net on the three most behaviourally complex surfaces, and any bug introduced by the flag wiring will be found in production.
- Rolling up steps 1 and 3 into one sprint → large, hard-to-review change; harder to isolate a rollback if the gating mechanism itself is buggy.
