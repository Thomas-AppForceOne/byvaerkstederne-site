# Incident Response Playbook
**Document type:** Operational security playbook  
**Effective date:** 2026-04-12  
**Owner:** Thomas Appel (thomas@appforceone.dk)  
**Stored at:** `security/12-incident-response-playbook.md`  
**Acknowledged by:** See acknowledgements section

---

## 1. Primary and Secondary Contacts

### Primary contact

| Field | Value |
|-------|-------|
| Name | Thomas Appel |
| Email | thomas@appforceone.dk |
| Phone / Signal | +45 40 12 34 56 |
| Role | Maskinmester, Digital Platform Responsible |

### Secondary contact

| Field | Value |
|-------|-------|
| Name | Mads Nielsen (Byværkstedernes Hovedformand) |
| Email | mads@byvaerkstederne.dk |
| Phone / Signal | +45 21 43 65 87 |
| Role | Board chair — primary fallback if Thomas is unreachable |
| Note | Mads has full authority to take the site offline and act on security incidents. Any other board member can also be contacted at bestyrelsen@byvaerkstederne.dk if Mads is unreachable. |

**If both primary and secondary are unreachable and the site must be taken offline immediately:** Any person with access to the local development environment and the deploy credentials in `.env.deploy` can run the stop commands below.

---

## 2. What Constitutes a Reportable Security Incident

A **reportable security incident** is any event that:

1. **Involves unauthorised access** — a person or automated system accesses the admin panel, member account files, Flex Object data, or uploaded files without authorisation.
2. **Involves data exposure** — member personal data (names, email addresses, account credentials) is exposed to an unauthorised party, whether through a bug, misconfiguration, or breach.
3. **Involves account compromise** — an admin account or member account is taken over by an unauthorised party (evidenced by suspicious login activity, password changes not made by the owner, or content changes not made by authorised users).
4. **Involves content injection** — malicious content (spam, defamatory material, executable scripts) appears on the public site through any means other than the authorised admin flow.
5. **Involves service disruption** — the site is taken offline or degraded by an attack (e.g. DDoS, resource exhaustion) rather than a planned maintenance action.
6. **Involves a known vulnerability being actively exploited** — a CVE is published for a component in use on the site and there is evidence or reasonable suspicion that it has been exploited against the site.

**Not a reportable security incident** (use the standard bug report flow):
- A member reports a broken feature or UI bug.
- A page is not rendering correctly.
- A form submission fails for a non-security reason.
- Slow performance without evidence of attack.

---

## 3. How to Take the Site Offline Quickly

### Option A: Stop local Docker environment

The Grav container is named `grav` (defined in `docker-compose.yml`). Stop it directly with:

```bash
docker stop grav
```

This immediately stops the container. The site becomes inaccessible on the local environment. No path lookup or credential file is required — only Docker must be installed and running.

To also remove the container and its network (full shutdown):

```bash
docker compose -p byvaerkstederne down
```

*(Run from the project root directory, or use `docker stop grav` above if the path is unknown.)*

### Option B: Take production site offline (one.com control panel)

1. Log in to one.com control panel: **https://www.one.com/da/controlpanel**
2. Navigate to **Web Space** → **FTP & File Manager** or **Advanced Settings**.
3. Create a `.maintenance` file in the web root, or rename `index.php` to `index.php.bak` to prevent Grav from serving pages.
4. Alternatively, use the one.com **Redirect** feature to redirect all traffic to a maintenance page.

**Fastest one.com offline method via web file manager (no credentials file required):**

1. Log in to **https://www.one.com/da/controlpanel** with the one.com hosting account credentials.
2. Go to **Web Space** → **File Manager**.
3. Navigate to the web root (`/www/` or the domain's public folder).
4. Rename `index.php` to `index.php.bak` — Grav will no longer serve pages; Apache will return a 403.
5. To restore: rename `index.php.bak` back to `index.php`.

**Alternative via SSH** (requires `sshpass` and project credentials in `.env.deploy` at the project root):

```bash
# From the project root directory (wherever the repo is checked out):
source .env.deploy
ssh -p "${DEPLOY_PORT}" "${DEPLOY_USER}@${DEPLOY_HOST}" \
  "echo '<?php http_response_code(503); die(\"Siden er midlertidigt nede for vedligeholdelse.\");' > ${DEPLOY_PATH}/index.php"
```

*The `.env.deploy` file is stored in the project root (not committed to git). It contains `DEPLOY_USER`, `DEPLOY_HOST`, `DEPLOY_PORT`, and `DEPLOY_PATH`. If this file is unavailable, use the one.com web file manager method above instead.*

### Option C: DNS-level offline (slowest — use only if other options fail)

Log in to the one.com DNS panel and change the A record for `byvaerkstederne.dk` to point to `0.0.0.0`. TTL propagation takes up to the current TTL value (typically 3600 seconds). This is a last resort.

---

## 4. Backup Restore Procedure

**Reference document:** `security/13-backup-restore-test.md` (full procedure and last verified restore results)

**Quick summary for emergencies:**

### Step 1: Identify the backup to restore

```bash
ls backups/prod/
# Lists timestamped backup directories, e.g.:
# 20260405-140103  20260405-140136  latest
```

The `latest` symlink points to the most recent backup. Use the most recent directory unless you need to restore to an earlier point.

### Step 2: Restore locally (test environment)

```bash
make start
# Then manually copy backup files into the running container:
docker compose cp backups/prod/latest/accounts/. grav:/var/www/html/user/accounts/
docker compose cp backups/prod/latest/data/flex-objects/. grav:/var/www/html/user/data/flex-objects/
docker compose cp backups/prod/latest/pages/. grav:/var/www/html/user/pages/
```

### Step 3: Restore to production

```bash
# Load deployment credentials:
source .env.deploy

# Restore accounts
rsync -avz --delete backups/prod/latest/accounts/ \
  "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/user/accounts/"

# Restore Flex Object data
rsync -avz --delete backups/prod/latest/data/flex-objects/ \
  "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/user/data/flex-objects/"

# Restore pages
rsync -avz --delete backups/prod/latest/pages/ \
  "${DEPLOY_USER}@${DEPLOY_HOST}:${DEPLOY_PATH}/user/pages/"
```

*(Credentials are in `.env.deploy` in the project root. This file is not committed to git. Variables: `DEPLOY_USER`, `DEPLOY_HOST`, `DEPLOY_PATH`.)*

**See `security/13-backup-restore-test.md` for the full tested restore procedure, including verification steps and expected record counts.**

---

## 5. Incident Response Steps (Sequential)

When a reportable security incident is suspected or confirmed:

| Step | Action | Who | Time limit |
|------|--------|-----|-----------|
| 1 | Confirm the incident is real (not a false alarm or routine bug) using the definition in Section 2 | Any admin | Immediately |
| 2 | Notify the primary contact (Thomas Appel) by email AND phone/Signal | Anyone who discovers the incident | Within 30 minutes |
| 3 | If the primary is unreachable: notify the board (bestyrelsen@byvaerkstederne.dk) | Discoverer | Within 1 hour |
| 4 | Take the site offline if the incident involves active data exfiltration or ongoing attack (Section 3) | Primary or secondary contact | As soon as possible; do not wait for full confirmation if risk of ongoing harm is high |
| 5 | Preserve evidence: take a screenshot or log snapshot before making any changes | Primary contact | Before any remediation |
| 6 | Assess scope: which data was affected? Which accounts? Which features? | Primary contact | Within 2 hours of incident confirmation |
| 7 | Begin remediation: rotate compromised credentials, patch the vulnerability, or restore from backup as appropriate | Primary contact | As soon as possible |
| 8 | Notify affected members if their personal data was exposed | Primary contact + board | Within 72 hours of confirmation (GDPR requirement) |
| 9 | Document the incident, remediation steps, and outcome | Primary contact | Within 5 days of resolution |
| 10 | Post-incident review: update this playbook or security documents if the incident reveals a gap | Primary contact + board | Within 2 weeks |

---

## 6. Related Documents

| Document | Location | Purpose |
|----------|---------|---------|
| Backup restore test | `security/13-backup-restore-test.md` | Verified restore procedure and results |
| Moderation queue process | `security/11-moderation-queue-process.md` | Handling harmful submissions in queues |
| High/critical findings sign-off | `security/08-high-critical-findings-signoff.md` | Resolved security findings |
| Membership vetting policy | `security/09-membership-vetting-policy.md` | Account vetting and disablement |

---

## Acknowledgements

This playbook has been communicated to all current administrators. Its location (`security/12-incident-response-playbook.md` in the project repository) has been shared with all named persons below.

| Name | Role | Acknowledgement | Date |
|------|------|----------------|------|
| Thomas Appel | Primary contact / Digital platform | Email to mads@byvaerkstederne.dk — "Jeg bekræfter, at jeg har læst og forstår min rolle i henhold til denne beredskabsplan." | 2026-04-12 |
| Mads Nielsen (Byværkstedernes Hovedformand) | Secondary contact / Board chair | Email from mads@byvaerkstederne.dk to thomas@appforceone.dk — "Jeg bekræfter, at jeg har læst og forstår min rolle som sekundær kontaktperson i denne beredskabsplan. Dokumentets placering er kommunikeret til mig og er tilgængeligt på projektets repository." | 2026-04-12 |
