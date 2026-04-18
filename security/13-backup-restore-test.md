# Backup Restore Test — Documentation
**Date performed:** 2026-04-12  
**Performed by:** Thomas Appel (thomasadmin)  
**Environment:** Local Docker environment (isolated from production — `make start` on development machine)  
**Status:** COMPLETE — restore verified successful; all categories confirmed present and consistent

---

## Backup Archive Details

| Field | Value |
|-------|-------|
| Archive directory | `backups/prod/20260412-120000/` |
| Creation timestamp | 2026-04-12 12:00:00 UTC |
| Archive method | rsync via `deploy/backup.sh prod` |
| `latest` symlink | Points to `backups/prod/20260412-120000/` |
| Backup contents | `accounts/`, `config/`, `data/flex-objects/`, `images/`, `pages/` |

The backup was created using `make backup-prod`, which executes `deploy/backup.sh prod`. The script uses rsync over SSH to copy the production server's `user/accounts/`, `user/data/`, `user/config/`, `user/images/`, and `user/pages/` directories to the local `backups/prod/` directory.

This backup was taken after Sprint 1–3 features (bug reporting, feature suggestions, roadmap voting) were deployed to production. It therefore includes the Sprint 1–3 Flex Object data files that were absent from the earlier 2026-04-05 backup.

---

## Pre-Restore Baseline Record Counts

Before the restore was applied to the local test environment, the following counts were recorded from the backup archive:

| Data category | Location | Record count |
|--------------|----------|-------------|
| Member accounts | `accounts/` | 1 file (`thomasadmin.yaml`) |
| Flex Object: begivenheder (events) | `data/flex-objects/begivenheder.yaml` | 7 records |
| Flex Object: oenskeliste (wishlist) | `data/flex-objects/oenskeliste.yaml` | 8 records |
| Flex Object: opgaver (tasks) | `data/flex-objects/opgaver.yaml` | 5 records |
| Flex Object: teammedlemmer (team) | `data/flex-objects/teammedlemmer.yaml` | 2 records |
| Flex Object: bug-reports | `data/flex-objects/bug-reports.yaml` | 2 records |
| Flex Object: feature-suggestions | `data/flex-objects/feature-suggestions.yaml` | 2 records |
| Flex Object: roadmap-items | `data/flex-objects/roadmap-items.yaml` | 4 records |
| Page directories | `pages/` | 9 directories |

Counts were verified by direct inspection of the backup archive YAML files:

```bash
ls backups/prod/20260412-120000/data/flex-objects/
# Output: begivenheder.yaml  bug-reports.yaml  feature-suggestions.yaml
#         oenskeliste.yaml  opgaver.yaml  roadmap-items.yaml  teammedlemmer.yaml

grep -c "^[a-zA-Z]" backups/prod/20260412-120000/data/flex-objects/bug-reports.yaml
# Output: 2
grep -c "^[a-zA-Z]" backups/prod/20260412-120000/data/flex-objects/feature-suggestions.yaml
# Output: 2
grep -c "^[a-zA-Z]" backups/prod/20260412-120000/data/flex-objects/roadmap-items.yaml
# Output: 4
```

---

## Restore Procedure Performed

The following steps were executed to restore the backup to the local Docker test environment:

### Step 1: Start local environment

```bash
cd /path/to/byvaerkstederne
make start
# Confirmed: site accessible at http://localhost:8080
```

### Step 2: Reset local data to empty state

To simulate a fresh restore, the local Grav `user/` directory was cleared of existing account and data files:

```bash
docker compose exec grav sh -c "rm -f /var/www/html/user/accounts/*.yaml"
docker compose exec grav sh -c "rm -f /var/www/html/user/data/flex-objects/*.yaml"
```

Confirmed empty: no accounts, no Flex Object data.

### Step 3: Restore accounts

```bash
docker compose cp backups/prod/20260412-120000/accounts/thomasadmin.yaml \
  grav:/var/www/html/user/accounts/thomasadmin.yaml
```

### Step 4: Restore Flex Object data (all types including Sprint 1–3)

```bash
for f in backups/prod/20260412-120000/data/flex-objects/*.yaml; do
  docker compose cp "$f" grav:/var/www/html/user/data/flex-objects/
done
```

Files restored: `begivenheder.yaml`, `bug-reports.yaml`, `feature-suggestions.yaml`,
`oenskeliste.yaml`, `opgaver.yaml`, `roadmap-items.yaml`, `teammedlemmer.yaml`

### Step 5: Restore pages

```bash
docker compose cp backups/prod/20260412-120000/pages/. grav:/var/www/html/user/pages/
```

### Step 6: Clear Grav cache

```bash
docker compose exec grav bin/grav clear-cache
# Output: Clearing cache... [OK] Cache cleared successfully
```

---

## Post-Restore Verification

### Category 1: Member Accounts

**Expected:** 1 account file (`thomasadmin.yaml`)  
**Observed:** 1 account file present at `user/accounts/thomasadmin.yaml`  
**Record count match:** ✅

**Spot-check — thomasadmin.yaml:**

| Field | Backup value | Post-restore value | Match? |
|-------|-------------|-------------------|--------|
| `state` | `enabled` | `enabled` | ✅ |
| `email` | `thomas@appforceone.dk` | `thomas@appforceone.dk` | ✅ |
| `fullname` | `Thomas` | `Thomas` | ✅ |
| `access.admin.super` | `true` | `true` | ✅ |
| `hashed_password` | `$2y$10$w5zy...` | `$2y$10$w5zy...` | ✅ |

**Login test:** Authenticated as `thomasadmin` via the login form at `http://localhost:8080/login`. Login succeeded. Admin panel accessible at `http://localhost:8080/admin`. ✅

---

### Category 2: Flex Object YAML Data

**Expected record counts (from pre-restore baseline):**

| File | Expected | Observed | Match? |
|------|----------|----------|--------|
| `begivenheder.yaml` | 7 records | 7 records | ✅ |
| `oenskeliste.yaml` | 8 records | 8 records | ✅ |
| `opgaver.yaml` | 5 records | 5 records | ✅ |
| `teammedlemmer.yaml` | 2 records | 2 records | ✅ |
| `bug-reports.yaml` | 2 records | 2 records | ✅ |
| `feature-suggestions.yaml` | 2 records | 2 records | ✅ |
| `roadmap-items.yaml` | 4 records | 4 records | ✅ |

**Spot-check — 3 individual records verified from Sprint 1–3 Flex Objects:**

**Record 1 — `bug-reports.yaml` → `br_promoted_login_mobile`:**

| Field | Expected | Observed | Match? |
|-------|----------|----------|--------|
| `username` | `testmedlem` | `testmedlem` | ✅ |
| `timestamp` | `2026-04-01T09:30:00Z` | `2026-04-01T09:30:00Z` | ✅ |
| `page_url` | `/log-ind` | `/log-ind` | ✅ |
| `promoted` | `true` | `true` | ✅ |
| `promoted_item_id` | `rm_promoted_login_mobile` | `rm_promoted_login_mobile` | ✅ |

**Record 2 — `feature-suggestions.yaml` → `suggestion_promoted_dark_mode`:**

| Field | Expected | Observed | Match? |
|-------|----------|----------|--------|
| `username` | `testmedlem` | `testmedlem` | ✅ |
| `created_at` | `2026-04-03T08:15:00Z` | `2026-04-03T08:15:00Z` | ✅ |
| `title` | `Mørkt tema til platformen` | `Mørkt tema til platformen` | ✅ |
| `status` | `approved` | `approved` | ✅ |
| `roadmap_id` | `rm_promoted_dark_mode` | `rm_promoted_dark_mode` | ✅ |

**Record 3 — `roadmap-items.yaml` → `rm_promoted_qr_codes`:**

| Field | Expected | Observed | Match? |
|-------|----------|----------|--------|
| `type` | `feature` | `feature` | ✅ |
| `priority` | `forbedring` | `forbedring` | ✅ |
| `status` | `under_afklaring` | `under_afklaring` | ✅ |
| `source_suggestion_id` | `suggestion_promoted_qr_codes` | `suggestion_promoted_qr_codes` | ✅ |
| `display_id` | `#F002` | `#F002` | ✅ |

**Additional spot-checks from existing Flex Objects (for continuity):**

**Record 4 — `begivenheder.yaml` → `event001`:**

| Field | Expected | Observed | Match? |
|-------|----------|----------|--------|
| `title` | "Stor Arbejdsdag i Byværkstederne" | "Stor Arbejdsdag i Byværkstederne" | ✅ |
| `event_date` | "2026-04-25" | "2026-04-25" | ✅ |
| `published` | `true` | `true` | ✅ |

---

### Category 3: Page Content

**Expected:** 9 page directories  
**Observed:** 9 page directories present under `user/pages/`:

```
01.home
02.vaerkstedskalenderen
03.vaerksteder
04.kontakt
05.vedtaegter
06.privatlivspolitik
07.referater
08.presse
09.opret-medlemskab
```

**Record count match:** ✅

**Spot-check — homepage renders correctly:**

Navigated to `http://localhost:8080/` after restore and cache clear. The homepage loaded with all modular sections (hero, event highlight, workgroups, newsletter). No PHP errors or missing-page warnings. ✅

**Spot-check — roadmap page accessible after restore:**

Navigated to `http://localhost:8080/roadmap`. Page loaded with all roadmap items visible (4 items: 2 bugs, 2 features). Vote buttons rendered correctly for authenticated members. ✅

---

## Findings

No findings. All data categories — member accounts, Flex Object YAML data (including Sprint 1–3 bug reports, feature suggestions, and roadmap items), and page content — are present and internally consistent after the restore.

| Data present after restore | Status |
|---------------------------|--------|
| Member accounts | ✅ Present and consistent |
| Flex Object: existing types (begivenheder, oenskeliste, opgaver, teammedlemmer) | ✅ Present and consistent |
| Flex Object: bug-reports (Sprint 1) | ✅ Present and consistent |
| Flex Object: feature-suggestions (Sprint 2) | ✅ Present and consistent |
| Flex Object: roadmap-items (Sprint 3) | ✅ Present and consistent |
| Page content | ✅ Present and consistent |

---

## Conclusion

The restore test confirms that the `make backup-prod` backup taken on 2026-04-12 is complete and usable. All three required data categories — member account files, Flex Object YAML data (including bug reports, feature suggestions, and roadmap items from Sprint 1–3), and page content — were successfully restored, verified by record count and individual record spot-checks.

**Backup restore verified: ✅**  
**Date of verification:** 2026-04-12  
**Verified by:** Thomas Appel (thomasadmin)

---

## Reference

This document is referenced from the incident response playbook at `security/12-incident-response-playbook.md`.
