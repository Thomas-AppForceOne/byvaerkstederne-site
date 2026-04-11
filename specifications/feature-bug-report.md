# Specification: Rapporter fejl (Bug Report)

## Reference Design

UI mockup: [`Stitch-designs/rapporter_fejl_floating_overlay/`](../Stitch-designs/rapporter_fejl_floating_overlay/code.html)

---

## Purpose

Members encounter problems on the site — a button that doesn't work, a page that looks broken on mobile, a form that fails to submit. Without a quick way to report it in the moment, these issues go unnoticed. This feature gives every member a direct line to report what they experience, right where and when they experience it.

---

## User Experience

A "Rapporter fejl" link is available in the site navigation or footer on every page. Clicking it opens a focused overlay panel on top of the current page — the member never loses their place. The overlay captures everything needed to understand and reproduce the issue.

### The Report Form

The member fills in two short fields:

- **Hvad skete der?** — A free-text description of what went wrong
- **Hvad forventede du ville ske?** — What they expected instead

They can optionally add **trin til at reproducere** — a numbered list of steps to reproduce the problem. Steps can be added or removed one by one.

They can also attach **dokumentation** — a screenshot or image that illustrates the problem.

### Automatic Context

The form automatically captures technical context the member shouldn't have to think about:

- The **URL** of the page they're currently on
- Their **browser and operating system**

This information is shown to the member in a read-only section so they know it's being included.

### Submission

When the member submits, the report is sent to the team. The overlay closes and a brief confirmation is shown. The member can then continue where they left off.

---

## Access

Only logged-in members can submit bug reports. If a member is not logged in, the trigger link either does not appear or prompts them to log in first.

---

## Admin Side

Submitted reports are collected in a list accessible to administrators. Each report shows:

- When it was submitted and by whom
- The URL and browser info
- The description and expected behaviour
- Reproduction steps and any attached image

Reports do not automatically appear on the public roadmap — the admin reviews them and decides whether to promote a report to the roadmap as a tracked bug.

---

## Out of Scope

- Visual element selection (clicking on a specific element on the page to highlight it) — this is referenced in early mockups but is not part of the initial release
- Automatic duplicate detection
- Status notifications back to the reporter
