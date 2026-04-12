# Backup Restore Test — Documentation
**Date performed:** 2026-04-12  
**Performed by:** Thomas Appel (thomasadmin)  
**Environment:** Local Docker environment (isolated from production — `make start` on development machine)  
**Status:** COMPLETE — restore verified successful; all categories confirmed present and consistent

---

## Backup Archive Details

| Field | Value |
|-------|-------|
| Archive directory | `backups/prod/20260405-140136/` |
| Creation timestamp | 2026-04-05 14:01:36 UTC |
| Archive method | rsync via `deploy/backup.sh prod` |
| `latest` symlink | Points to `backups/prod/20260405-140136/` |
| Backup contents | `accounts/`, `config/`, `data/flex-objects/`, `images/`, `pages/` |

The backup was created using `make backup-prod`, which executes `deploy/backup.sh prod`. The script uses rsync over SSH to copy the production server's `user/accounts/`, `user/data/`, `user/config/`, `user/images/`, and `user/pages/` directories to the local `backups/prod/` directory.

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
| Page directories | `pages/` | 9 directories |

**Note on missing Sprint 1–3 Flex Objects:** The backup was taken on 2026-04-05, before the Sprint 1–3 features (bug-reports, feature-suggestions, roadmap-items) were fully deployed to production. These Flex Object YAML files (`bug-reports.yaml`, `feature-suggestions.yaml`, `roadmap-items.yaml`) are present in `config/www/user/data/flex-objects/` in the development environment but were not yet in production at backup time — they are therefore absent from this backup. This is expected. When these features are deployed, future backups will include them.

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
docker compose cp backups/prod/20260405-140136/accounts/thomasadmin.yaml \
  grav:/var/www/html/user/accounts/thomasadmin.yaml
```

### Step 4: Restore Flex Object data

```bash
docker compose cp backups/prod/20260405-140136/data/flex-objects/begivenheder.yaml \
  grav:/var/www/html/user/data/flex-objects/begivenheder.yaml

docker compose cp backups/prod/20260405-140136/data/flex-objects/oenskeliste.yaml \
  grav:/var/www/html/user/data/flex-objects/oenskeliste.yaml

docker compose cp backups/prod/20260405-140136/data/flex-objects/opgaver.yaml \
  grav:/var/www/html/user/data/flex-objects/opgaver.yaml

docker compose cp backups/prod/20260405-140136/data/flex-objects/teammedlemmer.yaml \
  grav:/var/www/html/user/data/flex-objects/teammedlemmer.yaml
```

### Step 5: Restore pages

```bash
docker compose cp backups/prod/20260405-140136/pages/. grav:/var/www/html/user/pages/
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

**Spot-check — 3 individual records verified:**

**Record 1 — `begivenheder.yaml` → `event001`:**

| Field | Expected | Observed | Match? |
|-------|----------|----------|--------|
| `title` | "Stor Arbejdsdag i Byværkstederne" | "Stor Arbejdsdag i Byværkstederne" | ✅ |
| `event_date` | "2026-04-25" | "2026-04-25" | ✅ |
| `published` | `true` | `true` | ✅ |
| `featured` | `true` | `true` | ✅ |

**Record 2 — `teammedlemmer.yaml` → `member001`:**

| Field | Expected | Observed | Match? |
|-------|----------|----------|--------|
| `name` | "Mads Nielsen" | "Mads Nielsen" | ✅ |
| `role` | "Hovedformand" | "Hovedformand" | ✅ |
| `email` | "mads@byvaerkstederne.dk" | "mads@byvaerkstederne.dk" | ✅ |
| `show_on_contact` | `true` | `true` | ✅ |

**Record 3 — `opgaver.yaml` → `opgave001`:**

| Field | Expected | Observed | Match? |
|-------|----------|----------|--------|
| `title` | "Byg nye plantekasser" | "Byg nye plantekasser" | ✅ |
| `group` | "groenne" | "groenne" | ✅ |
| `priority` | "high" | "high" | ✅ |
| `status` | "open" | "open" | ✅ |

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

---

## Findings

| Finding | Description | Severity | Resolution |
|---------|-------------|----------|------------|
| Sprint 1–3 Flex Objects absent from backup | `bug-reports.yaml`, `feature-suggestions.yaml`, `roadmap-items.yaml` not in backup (features not yet deployed to production at backup time) | LOW | Expected — not a backup failure. Future backups after production deployment will include these files. |

**No data missing or corrupted** from the backup that was expected to be present.

---

## Conclusion

The restore test confirms that the `make backup-prod` backup is complete and usable for the data present in production at the time the backup was taken (2026-04-05). All three data categories — member accounts, Flex Object YAML data, and page content — were successfully restored, verified by record count and individual record spot-checks.

**Backup restore verified: ✅**  
**Date of verification:** 2026-04-12  
**Verified by:** Thomas Appel (thomasadmin)

---

## Reference

This document is referenced from the incident response playbook at `security/12-incident-response-playbook.md`.
