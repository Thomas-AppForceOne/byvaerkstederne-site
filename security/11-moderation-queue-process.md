# Moderation Queue Process
**Document type:** Written operational process  
**Effective date:** 2026-04-12  
**Owner:** Thomas Appel (thomas@appforceone.dk) — Maskinmester / Digital Platform Responsible  
**Backup responsible:** Mads Nielsen — Byværkstedernes Hovedformand (mads@byvaerkstederne.dk, +45 21 43 65 87)  
**Location of this document:** `security/11-moderation-queue-process.md`  
**Cross-referenced from:** `security/12-incident-response-playbook.md`

---

## Scope

This process covers the two admin review queues created by Sprint 1 and Sprint 2:

1. **Bug Report queue** — submissions from the "Rapportér fejl" overlay
2. **Feature Suggestion queue** — submissions from the "Foreslå feature" page

Both queues are accessible in the Grav admin panel at:
`https://byvaerkstederne.dk/admin` → **Flex Objects** → **Bug Reports** / **Feature Suggestions**

---

## Responsible Persons

| Role | Name | Contact | Covers |
|------|------|---------|--------|
| Primary responsible | Thomas Appel | thomas@appforceone.dk | Both queues |
| Backup responsible | Mads Nielsen (Byværkstedernes Hovedformand) | mads@byvaerkstederne.dk / +45 21 43 65 87 | Both queues when primary is unavailable |

The primary responsible person must be reachable by email on weekdays. The named backup is **Mads Nielsen** in his role as elected board chair; he holds the authority to act on behalf of the association and has agreed in writing to fulfil this role (see Acknowledgements section).

---

## Maximum Review Turnaround Time

**Bug reports:** 5 calendar days from submission to an admin decision (promote to roadmap or archive).  
**Feature suggestions:** 7 calendar days from submission to an admin decision (approve → roadmap or decline → archive).

Bug reports are prioritised over feature suggestions because a bug may affect current member experience.

---

## Review Process

### Bug Report Review (5 calendar days)

1. Log in to the Grav admin panel.
2. Navigate to **Flex Objects → Bug Reports**.
3. Open each unreviewed report (those with `promoted: false`).
4. Read the description, expected behaviour, steps, URL, and browser/OS context.
5. Make one of the following decisions:

   **Promote to roadmap:**
   - Click the "Fremme til roadmap" button in the report detail view.
   - The plugin creates a roadmap item pre-populated with the report data.
   - The roadmap item is created as unpublished — a separate admin action publishes it to the public roadmap.
   - Update the report status note if needed.

   **Archive (no action):**
   - If the report is a duplicate, out of scope, or cannot be reproduced: note the reason in the admin notes field (free text) and set the record status to archived via the admin edit view.

6. Log the decision in the review log at `security/membership-review-log.md` (same log used for membership vetting) or the team's shared note.

### Feature Suggestion Review (7 calendar days)

1. Log in to the Grav admin panel.
2. Navigate to **Flex Objects → Feature Suggestions**.
3. Open each pending suggestion (status: `pending`).
4. Read the title, description, and community value fields.
5. Make one of the following decisions:

   **Approve → add to roadmap:**
   - Click the "Godkend og tilføj til roadmap" button.
   - The plugin creates a roadmap item (type: feature) pre-populated with the suggestion data.
   - The roadmap item is created as unpublished.
   - The suggestion status is updated to `approved`.

   **Decline:**
   - Click the "Afvis" button.
   - The suggestion status is updated to `archived` and removed from the active review list.
   - Optionally: note the reason for declining in the admin notes field.

---

## Handling Harmful or Inappropriate Submissions

A submission is considered **harmful or inappropriate** if it contains any of the following:

- Offensive, discriminatory, or abusive language directed at a person or group.
- Personal data of another individual that was not provided with their consent (e.g. another member's private address or phone number).
- Deliberate misinformation.
- Content that appears to be spam, advertising, or an automated submission.
- Threats or content that could constitute harassment.

**Exact action for harmful submissions (no ambiguity):**

1. **Immediately archive** the submission by setting its status to `archived` (do not promote or approve it).
2. **Record the username** of the submitter and the submission ID in the review log.
3. **Disable the submitter's account:**
   - Navigate to **Users** in the admin panel.
   - Find the user by username.
   - Set **State** to `disabled`. Save.
4. **Send a notification email** to the submitter's registered address using the template in Appendix A.
5. **Notify the board** at bestyrelsen@byvaerkstederne.dk with a brief description of the content and the action taken, within 24 hours of the discovery.
6. If the content constitutes a potential legal issue (threat, illegal content), additionally contact **Mads Nielsen (Byværkstedernes Hovedformand, +45 21 43 65 87)** by phone immediately and preserve a copy of the submission content in a private, access-controlled location before archiving.

---

## Procedure When Responsible Person Is Unavailable

If the primary responsible person (Thomas Appel) is unavailable (holiday, illness, or otherwise unresponsive) for more than the turnaround window:

1. **Mads Nielsen (backup)** is automatically responsible from the moment the turnaround window expires.
2. Mads logs in to the Grav admin panel at `https://byvaerkstederne.dk/admin` and processes the queue following the review process above.
3. If Mads Nielsen is also unavailable, any other board member he has designated as a temporary stand-in may act on his behalf — Mads must communicate this delegation in writing (email to bestyrelsen@byvaerkstederne.dk) in advance.
4. **No submission should sit in the queue unreviewed for more than 10 calendar days.** If this threshold is reached, the backup must act or escalate.

---

## Queue Location and Access

The queues are accessible to all accounts with `admin.super: true` access. Currently, that is exclusively `thomasadmin`.

To grant another person access to the moderation queue without giving full super-admin rights, a limited-access admin account can be created with the following YAML access flags:

```yaml
access:
  admin:
    login: true
    super: false
    flex:
      objects:
        bug-reports: true
        feature-suggestions: true
```

This is a post-launch improvement item for when a second moderator is named.

---

## Acknowledgements

This document is accessible to all current admins and is referenced from the incident response playbook (`security/12-incident-response-playbook.md`).

| Name | Role | Acknowledgement | Date |
|------|------|----------------|------|
| Thomas Appel | Primary responsible | Email to mads@byvaerkstederne.dk — "Jeg bekræfter, at jeg har læst og accepterer ansvar for modereringskøerne på Byværkstedernes hjemmeside i henhold til denne proces." | 2026-04-12 |
| Mads Nielsen (Byværkstedernes Hovedformand) | Backup responsible | Email from mads@byvaerkstederne.dk to thomas@appforceone.dk — "Jeg bekræfter, at jeg har læst modereringsprocesdokumentet og accepterer rollen som ansvarlig backup for modereringskøerne for fejlrapporter og funktionsforslag på Byværkstedernes hjemmeside. Jeg forstår, at jeg træder til, hvis Thomas Appel er utilgængelig ud over den fastsatte behandlingsperiode." | 2026-04-12 |

---

## Appendix A: Account Suspension Notification Template

```
Subject: Din konto på Byværkstedernes hjemmeside er midlertidigt deaktiveret

Hej [Navn],

Din konto på Byværkstedernes hjemmeside er blevet deaktiveret, fordi et af dine 
bidrag (fejlrapport eller funktionsforslag) indeholdt indhold, der ikke overholder 
vores retningslinjer for fællesskab.

Hvis du mener, at dette er en fejl, eller ønsker at drøfte sagen, er du velkommen 
til at kontakte os på bestyrelsen@byvaerkstederne.dk.

Med venlig hilsen
Byværkstedernes Maskinmester
```
