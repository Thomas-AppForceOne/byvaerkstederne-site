# Specification: Sikkerhedsgennemgang (Security Review)

## Reference Design

No UI mockup — this is an operational and technical review process, not a member-facing feature.

---

## Purpose

The site now handles member accounts, personal data, contact form submissions, and is about to add new interactive surfaces for bug reports, feature suggestions, and voting. As the platform grows, so does the responsibility to protect the members who trust it with their information. A thorough security review ensures the site is as solid as the physical workshops it represents — built properly, with no shortcuts that could come back to cause harm.

---

## Scope

The review covers the entire site, not just the new features. That includes the registration and login flows, all forms, how user-provided content is stored and rendered, the hosting and deployment setup, and the platform's exposure to the internet. Where the new features introduce new attack surfaces — particularly the voting endpoint — those receive extra scrutiny.

---

## Review Areas

### Member Accounts & Authentication

The registration flow, login overlay, session handling, and logout are reviewed to ensure accounts cannot be hijacked, sessions cannot be replayed or stolen, and password handling follows current best practices. Any password reset or account recovery flow is included.

### Forms & Input Handling

Every form on the site — contact, registration, bug report, feature suggestion — is reviewed to ensure user-provided content is treated as untrusted. This means checking that input is sanitised before being stored and before being rendered back to any user, to rule out cross-site scripting and injection vulnerabilities.

### Request Forgery Protection

State-changing actions — form submissions, vote actions, logout — are checked to ensure they cannot be triggered by a third-party site acting on behalf of a logged-in member. Grav's nonce mechanism is already used in some flows; the review verifies it is applied consistently everywhere it is needed.

### Voting Integrity

The voting system's rules (budget limits, uniqueness per item, locked-state enforcement) are verified to be enforced on the server, not just in the browser. The review checks that the voting endpoint cannot be manipulated by replaying requests, forging user identities, or exceeding vote budgets through timing or parallel requests.

### File Uploads

Bug reports allow members to attach images. The review ensures uploaded files are validated as images, stored in a location that is not web-executable, and cannot be used as a vector for uploading malicious content.

### Hosting & Deployment

The review examines how the site is exposed to the internet — open ports, directory listings, access to sensitive files (configuration, user data, deploy scripts), and whether the deployment process itself could be exploited. HTTPS is verified across all environments.

### Dependency Review

Grav CMS, its plugins, and any third-party libraries are checked against known vulnerability databases to identify outdated components that should be updated before launch.

---

## Non-Automatable Measures

Some risks cannot be caught by automated tools or code review alone. The following are manual or organisational measures that must also be in place.

**Membership vetting.** The registration flow is open — anyone can create an account. A process must be defined for how new registrations are reviewed and approved, and what happens if an account is found to be fake or malicious. Until that process is defined, consider whether open registration should remain enabled.

**Privilege separation.** Admin credentials must be held by a small, defined set of people. The review should confirm who currently has admin access and ensure former contributors do not retain active credentials.

**Content moderation.** Bug reports and feature suggestions are written by members and reviewed by the team before anything becomes public. The review should define what the moderation queue looks like and who is responsible for acting on it, to prevent harmful content sitting unreviewed for extended periods.

**Incident response.** If the site is compromised or abused, there should be a clear and simple playbook: who to contact, how to take the site offline quickly, and how to restore from backup. This does not need to be elaborate — but it must exist.

**Backup verification.** Backups already exist (via `make backup-prod`). The review should include a test restore to confirm the backups are complete and usable, not just that they are being created.

---

## Out of Scope

- Penetration testing by a third party (may be considered in a future phase)
- Physical security of the hosting infrastructure (handled by one.com)
- Security of members' own devices or passwords outside the platform
