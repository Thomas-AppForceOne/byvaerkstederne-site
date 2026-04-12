# Membership Vetting Policy
**Document type:** Written policy  
**Effective date:** 2026-04-12  
**Owner:** Thomas Appel (Maskinmester / Digital Platform Responsible)  
**Backup responsible:** Byværkstedernes bestyrelse (board contact: bestyrelsen@byvaerkstederne.dk)  
**Acknowledged by:** See acknowledgements section at the end of this document

---

## Purpose

Byværkstedernes website allows member self-registration. Any person can create an account using an email address and password. Without a vetting process, fake or malicious accounts could use member-only features including bug reporting, feature suggestions, and voting. This policy defines the process for reviewing, approving, and — where necessary — rejecting or disabling new registrations.

---

## Step-by-Step Review Process

### Step 1: Registration notification (Day 0)

When a new user registers an account on the site, an email notification is sent to **thomas@appforceone.dk** (the site administrator). This notification is triggered by the Grav Login plugin's `send_notification_email` setting.

The notification email includes:
- The registered username
- The registered email address
- The full name provided

The responsible person must check this inbox at least once every **2 calendar days**.

### Step 2: Initial identity check (within 2 calendar days of registration)

The responsible person reviews the submitted registration against the following objective criteria:

**Approve if ALL of the following are true:**
1. The email address domain is a recognisable personal or professional domain (not a known disposable email service — see Appendix A for a non-exhaustive reference list).
2. The full name field contains a plausible human name (not a string of random characters, a URL, or promotional text).
3. The username does not impersonate an existing member or a well-known person.
4. No prior account exists for the same email address or an obvious variant of it.

**Reject if ANY of the following is true:**
1. The email address comes from a domain on the disposable-email reference list (Appendix A) or appears automated (e.g. `random123@temp.com`).
2. The full name field contains a URL, phone number, business advertisement, or is blank.
3. The username contains offensive language or impersonation indicators.
4. The same email address or IP address has been used in a previously rejected registration.

**Escalate to the board if:**
- The registration appears suspicious but does not clearly meet rejection criteria (e.g. an unusual email domain from a country not represented in the current membership).
- The responsible person is uncertain.

Escalation email to: **bestyrelsen@byvaerkstederne.dk** — response expected within 3 calendar days.

### Step 3: Decision and action (within 2 calendar days of receipt)

**If approved:**
- The account is already active by default (Grav Login `set_user_disabled: false`).
- No further action is required unless the admin wishes to confirm by sending a welcome email.
- The registration is logged in the review log (Appendix B format).

**If rejected:**
1. The admin logs into the Grav admin panel at `https://byvaerkstederne.dk/admin`.
2. Navigates to **Users** → locate the user by username or email.
3. Changes the **State** field from `enabled` to `disabled`.
4. Saves the user record.
5. Optionally sends a brief rejection email to the registered address (template in Appendix C).
6. The rejection is logged in the review log (Appendix B format).

**If escalated:**
- The account state is set to `disabled` immediately (precautionary) pending board decision.
- Board responds within 3 calendar days.
- Account is enabled or deleted based on board decision.

### Step 4: Confirmation of action (same day as decision)

After approving or rejecting, the responsible person records the decision in the review log maintained at:

> `security/membership-review-log.md` in the project repository, or in the shared team note referenced in the incident response playbook.

---

## Timeline and Consequences

| Stage | Maximum time | Consequence if deadline missed |
|-------|-------------|-------------------------------|
| Initial check (Step 2) | 2 calendar days from registration | Account is **automatically disabled** by running `make disable-unreviewed-users` (see note); responsible person notified by automated task |
| Decision (Step 3) | 2 calendar days from initial check | Escalate to board immediately; account remains disabled |
| Board escalation response | 3 calendar days | Responsible person deletes account and logs the action as "escalation timeout — deleted" |

**Note on automatic disabling:** The 2-day automatic disablement requires implementation of a Grav scheduler task. Until that task is implemented, the responsible person is expected to manually check and disable unreviewed registrations at the 2-day mark. This is tracked as a post-launch improvement item.

**Maximum total time to decision:** 4 calendar days (2 days review + 2 days action).

---

## Accountable Persons

| Role | Name | Contact | Availability |
|------|------|---------|-------------|
| Primary responsible | Thomas Appel | thomas@appforceone.dk | Weekdays; checks email daily |
| Backup (board contact) | Byværkstedernes bestyrelse | bestyrelsen@byvaerkstederne.dk | Response within 3 calendar days |

If the primary responsible person is unavailable for more than 3 calendar days (e.g. holiday, illness):
1. New registrations accumulate as `disabled` accounts (if auto-disable is implemented) or require no immediate action (existing enabled accounts are unaffected).
2. The board contact is notified and assumes review responsibility for the duration.
3. Upon return, the primary responsible person reviews any accumulated registrations.

---

## Appendix A: Disposable / Temporary Email Service Reference

The following domains are examples of known disposable email services. This list is not exhaustive:

- mailinator.com
- guerrillamail.com
- tempmail.com
- throwaway.email
- yopmail.com
- maildrop.cc
- sharklasers.com

Any domain with "temp", "throwaway", "disposable", or "trash" in the name should be treated with heightened scrutiny.

---

## Appendix B: Review Log Format

Review log entries are maintained in `security/membership-review-log.md` with the following format:

```
| Date       | Username      | Email                  | Decision | Reason                  | Reviewed by |
|------------|---------------|------------------------|----------|-------------------------|-------------|
| 2026-04-12 | thomasadmin   | thomas@appforceone.dk  | Approved | Founder account         | Thomas Appel |
```

---

## Appendix C: Rejection Email Template

```
Subject: Din registrering på Byværkstedernes hjemmeside

Hej [Navn],

Vi har modtaget din anmodning om at oprette en konto på Byværkstedernes hjemmeside, 
men vi er desværre ikke i stand til at godkende din registrering på nuværende tidspunkt.

Hvis du mener, at dette er en fejl, er du velkommen til at kontakte os på 
bestyrelsen@byvaerkstederne.dk.

Med venlig hilsen
Byværkstedernes Maskinmester
```

---

## Acknowledgements

This policy has been read and acknowledged by the persons named below. Acknowledgement confirms they understand their responsibilities under this policy and accept the accountability assigned to them.

| Name | Role | Acknowledgement | Date |
|------|------|----------------|------|
| Thomas Appel | Primary responsible / Digital platform | Email to bestyrelsen@byvaerkstederne.dk — "Jeg bekræfter, at jeg har læst og accepteret ansvaret som primær ansvarlig for gennemgang af nye brugerregistreringer på Byværkstedernes hjemmeside." | 2026-04-12 |
| Byværkstedernes bestyrelse | Backup contact | Acknowledgement to be obtained at next board meeting (scheduled 2026-04-28). Interim: board chair is aware of and has verbally accepted the backup role. | 2026-04-12 (verbal) |
