# Specification: Foreslå en Feature (Feature Suggestion)

## Reference Design

UI mockup: [`Stitch-designs/forsl_website_feature_v2026_form_only/`](../Stitch-designs/forsl_website_feature_v2026_form_only/code.html)

---

## Purpose

Members have ideas. Better tools for booking, new ways to communicate between workshop groups, features that would make the site genuinely more useful to the community. Without a structured way to submit these ideas, they get lost in conversation or never surface at all. This feature gives members a clear, dedicated place to propose improvements — and signals that their input has a real path towards being acted on.

---

## User Experience

The feature suggestion page is accessible from the site navigation. It has a focused, editorial layout: a guidelines sidebar on the left and the submission form on the right.

### Guidelines Sidebar

Before filling in the form, members see a short set of principles:

1. **Vær specifik** — Describe what you want to happen, not just a vague wish
2. **Fællesskab først** — Proposals that benefit many members get priority
3. **Stem på andre** — If an idea already exists on the roadmap, vote for it rather than duplicating it

The sidebar grounds the member in the spirit of the community and helps them write more actionable suggestions.

### The Suggestion Form

Three fields:

- **Hvad er din idé?** — A short, descriptive title for the suggestion
- **Beskrivelse af idéen** — A fuller explanation of what the feature should do and how it should work from the user's perspective
- **Værdi for fællesskabet** — Why this feature matters; who benefits and how

The form is intentionally simple. Members are not asked for technical details or implementation approaches — just the what and the why.

### Submission

On submit, the member receives a short confirmation: their suggestion has been received and will be reviewed by the team ("maskinmesteren"). There is no immediate public visibility — the submission enters a review queue.

---

## Access

Only logged-in members can submit suggestions. Members who are not logged in see the page content and guidelines but the form is replaced with a prompt to log in.

---

## Admin Side

Submitted suggestions appear in the admin as a list. Each entry shows the member's name, the idea title, the description, and the stated community value. The admin can review each submission and decide to:

- **Approve and add to roadmap** — the suggestion is promoted to a public roadmap item where the community can vote on it
- **Decline** — the suggestion is archived without appearing publicly

---

## Out of Scope

- Public submission feed (suggestions are not visible to other members until promoted to the roadmap)
- Comments or discussion threads on submissions
- Status email notifications back to the submitter in the initial release
