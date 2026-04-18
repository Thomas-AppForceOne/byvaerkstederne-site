# ADR-001: Footer-only placement for community feedback affordances

**Date:** 2026-04-18
**Status:** Accepted

---

## Context

Three site affordances — Forslå Feature, Roadmap, and Rapportér fejl — were previously in the main navigation. The roadmap and feature suggestion form require authentication; the bug report modal always did. Showing them in the main nav created false expectations for anonymous visitors and added noise to the primary site journey (Forsiden, Værkstedskalenderen, Værksteder, Kontakt).

## Decision

All three affordances are placed exclusively in the footer, gated to authenticated users only. The entire footer column is hidden when no user is logged in — no disabled states, no login prompts at that location.

Forslå Feature is implemented as a modal overlay (`bvFeatureSuggestion`) rather than a page navigation, matching the existing pattern of Rapportér fejl (`bvBugReport`). The page at `/foreslaa-feature` remains as a fallback URL but is no longer the primary entry point.

Roadmap (`/roadmap`) returns a 302 redirect to `/login` for unauthenticated requests — the page content is never rendered publicly.

## Alternatives considered

- **Keep in main nav, hide for anonymous users** — rejected because hidden nav items still communicate that something exists but is inaccessible, which is a worse experience than simply not showing them.
- **Keep Forslå Feature as a page link** — rejected because it duplicated the overlay pattern already established by Rapportér fejl and added an unnecessary full-page load for what is essentially a form.
- **Show Roadmap publicly with a login prompt** — rejected because the roadmap contains community voting data considered member-only content.

## Consequences

- Any new community or members-only affordance follows the same pattern: footer placement, authentication gate, modal trigger preferred over page navigation where applicable.
- `/foreslaa-feature` must not be linked from nav or footer. It exists as a fallback and for bookmarks — do not build features that depend on it as the primary entry point.
- If a future decision makes the roadmap or feature suggestions publicly visible, this ADR is superseded and the auth gate must be revisited across nav, footer, page access, and any sitemap/SEO considerations.
- The vote nonce replay blacklist was removed from the roadmap vote handler (`bv_used_vote_nonces`) as part of this work. Grav's built-in `Utils::verifyNonce()` is the sole CSRF gate for votes. Do not reintroduce per-request single-use nonce enforcement — it breaks concurrent voting on a multi-item page.
