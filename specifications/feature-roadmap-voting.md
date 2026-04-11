# Specification: Roadmap & Afstemning (Roadmap & Voting)

## Reference Design

UI mockup: [`Stitch-designs/website_roadmap_v7_inline_item_actions/`](../Stitch-designs/website_roadmap_v7_inline_item_actions/code.html)

---

## Purpose

When people report bugs or suggest features, they need to see that something happens. The roadmap page closes that loop: it shows the full picture of what has been reported, what the team is working on, and what's next — and it lets the community actively shape priorities by voting. Transparency and participation are core to how Byværkstederne operates; this page brings that culture into the digital platform itself.

---

## User Experience

The roadmap is a public page, visible to everyone. Voting requires a member login.

### Page Layout

The page opens with a brief introduction explaining what the board is and how it works. A status badge confirms the platform is operational, along with the current version number.

An information button — "Forstå processen" — opens an inline explanation panel describing the status workflow and how voting works, for members who want more context.

The main content is a two-column board:

- **Left column:** Registrerede Website-fejl — tracked bugs
- **Right column:** Forslag til Websitet — approved feature suggestions

---

### Vote Budget

Each logged-in member receives:

- **3 votes** to spend on bugs
- **3 votes** to spend on features

The remaining vote budget is shown above each column. Votes can be removed and reassigned — they are not permanent until the member is happy with their allocation.

---

### Roadmap Items

Each item on the board is a card showing:

- **Priority level** — Kritisk / Høj / Middel / Lav (for bugs) or Nyhed / Forbedring (for features)
- **ID number** — a short reference code
- **Status badge** — current stage in the workflow (see below)
- **Title** — the name of the bug or feature
- **Short description** — a two-line summary

Items are displayed with their current vote count shown on the voting button.

---

### Item Status Workflow

Every item moves through a defined sequence of statuses:

| Status | Meaning |
|--------|---------|
| **Rapporteret** | Received, awaiting initial review |
| **Under afklaring** | The team is investigating or planning the approach |
| **Klar til implementation** | The solution is defined, ready to be built |
| **Under implementation** | Actively being worked on |
| **Klar til test** | Built, in quality review |
| **Løst** | Shipped and live |

Statuses are set and updated by admins. Members see the current status on each card.

---

### Voting Interaction

Clicking on a card reveals an inline action bar with three options:

- **Tilføj stemme** — cast one vote from the member's budget (available if budget remains and not already voted for this item)
- **Fjern stemme** — remove a previously cast vote and return it to the budget

Vote counts update immediately when a vote is added or removed.

**Vote locking:** Items with the status "Under implementation" or beyond cannot receive new votes. The voting button is visually disabled and non-interactive for these items.

**Vote release:** When an item reaches the status "Klar til implementation", all votes cast on that item are automatically returned to their owners' budgets. Members can now spend those votes elsewhere. The fact that they voted on the item is retained for tracking and history purposes — only the budget allocation is released.

**Completed items:** Items with status "Løst" display a completion indicator instead of a vote count — they are shown for transparency but no longer part of the active voting pool.

---

### Process Explanation Panel

The "Forstå processen" button opens an overlay panel that explains:

- How votes work (budget of 3 per category, reassignable)
- How votes are released when an item is selected for implementation
- How the team selects what to build (combination of votes, technical complexity, overall value)
- A summary of the status stages

This ensures new members understand the system without cluttering the main board.

---

## Admin Side

Admins manage all items on the roadmap through the Grav admin panel. For each item they can set:

- Title and description
- Type (bug or feature)
- Priority
- Status
- Whether the item is published (visible on the roadmap) or hidden

Vote counts are visible to admins but cannot be manually edited. Items promoted from bug reports or feature suggestions appear here for final configuration before being published to the roadmap.

---

## Out of Scope

- Discussion threads or discussion links on roadmap items
- Admin-initiated voting resets
- Email notifications when a voted-for item changes status
- Weighting votes by membership tier or contribution level
