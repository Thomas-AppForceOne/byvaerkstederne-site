# Promotion & data-lifecycle runbook — safe test plan

How to verify the data-lifecycle deploy chain (backup → restore → migrate →
promote-to-staging → promote-to-prod) and the member-auth hardening **safely**,
in reversible layers, before anything touches production data.

> Covers the work in **PR #52** (versioned-data-dir serving model + promote-to-staging),
> **PR #53** (promote-to-prod + rollback-prod, stacked on #52), and **PR #54**
> (member-auth hardening). The deploy scripts referenced here land with #52/#53.

---

## 0. Merge order & one reconciliation (do this first)

The deploy PRs are stacked and one overlaps member-auth:

1. **Merge #52** (foundation: versioned serving model).
2. **Retarget & merge #53** (promote-to-prod) — it's based on #52.
3. **Reconcile & merge #54** (member-auth). #54 added a per-tier `email.yaml`
   symlink hardcoded to `…/v0/…` in `bv_wire_release_symlinks` and deploy.sh
   Step 4 (mv) + Step 5 (ln). After #52, change those three `v0` → `$vdir`/`$VDIR`
   so `email.yaml` is versioned like the other secrets, and merge the
   `tests/deploy/atomic-layout.sh` additions from both. (Mechanical; ask me to
   do the rebase once #52 lands.)

Every change is backward-compatible: until a promote moves `<tier>data/current`,
`VDIR=v0` and all deploy wiring is byte-identical to today.

---

## 1. Deploy chain — layered safe test

### Layer 0 — zero infrastructure, zero risk (run now)
```
make test-deploy
```
Runs every local/dry-run suite (atomic-layout, rollback, migrate-integration,
migrate, skip-data-migration, promote-to-staging, promote-to-prod) against
local fixtures — no SSH, no real data. Must be green (exit 0).

For the migration PHP + auth Playwright suites:
```
bash migrations/run-tests.sh          # Docker PHP; data-versioning migrations
```

### Layer 1 — prove no regression on a DISPOSABLE tier (reversible)
The serving-model change only diverges from current behaviour once `current`
moves, so first confirm a plain deploy + rollback still works on **dev**, then
**test** — never staging/prod yet:
```
make deploy tier=dev
#   verify the dev site renders; confirm `devdata/current` still → v0
make rollback tier=dev
#   confirm rollback swaps back AND the new `current`-bookkeeping behaves
```
If anything looks wrong, `make rollback tier=dev` is the instant undo. Repeat on
`tier=test`. **Do not promote until both pass.**

### Layer 2 — promote-to-staging (GDPR-gated; see §3)
Only after the ADR-002 controls are LIVE on staging. Verify the gate yourself:
```
curl -sS -o /dev/null -w '%{http_code}\n' https://staging.hackersbychoice.dk/
#   MUST print 401 (basic-auth), not 200
```
Then:
```
./deploy/promote-to-staging.sh           # fresh prod backup → migrate → staging
#   or: ./deploy/promote-to-staging.sh --from-backup <id>   (reuse an archive)
```
Verify afterwards (behind basic-auth): staging serves prod-shaped data; a real
member can log in; `config/www/staging-blessed.yaml` exists with all seven
fields; `stagingdata/current → v_<target>`. The step-2 prod backup is your
rollback insurance.

### Layer 3 — promote-to-prod (last; needs chosting.dk SSH enabled)
Only after staging is blessed and verified, and only from a release/hotfix branch:
```
git checkout -b release/vX.Y.Z develop        # branch gate requires release/* or hotfix/*
./deploy/promote-to-prod.sh                    # gate verifies staging blessing == your commit
```
A tagged `pre-promotion-vX.Y.Z-build<N>` backup is taken automatically. On any
failure the script prints the exact recovery command. Manual rollback:
```
./deploy/rollback-prod.sh --to-backup pre-promotion-vX.Y.Z-build<N> --yes-i-mean-it
```
The escape hatch `--bypass-staging-gate --reason "<50–500 chars>"` exists for
"prod down, staging also broken" — it's interactive and logged to
`prod-bypass-log.yaml` on prod.

**Safety nets:** Layer 0 (local tests) → Layer 1 (disposable-tier rollback) →
fresh prod backup before any staging/prod data move → tagged pre-promotion
backup + `rollback-prod.sh` (Layer 3). Nothing touches prod data without a
backup taken first.

---

## 2. Member-auth (PR #54) — safe test

Local, no live infra needed (uses Mailpit as a mail sink):
```
scripts/mailpit-up.sh                 # starts Mailpit; relaxes session.secure→false
                                      #   and points email.yaml at Mailpit IN THE
                                      #   WORKING TREE (backed up to .gan/, restored
                                      #   by mailpit-down.sh; committed files untouched)
# seed the test accounts, then:
TEST_PASSWORD=… TEST_ADMIN_PASSWORD=… npx playwright test
scripts/mailpit-down.sh               # restores the relaxed config
```
Without creds/Mailpit the auth specs **skip cleanly** (anonymous-only mode). The
suite covers registration, password-reset, login, the session-cookie flags, and
the password policy — success and failure paths.

What still needs the live stack / real provider:
- **Email deliverability** (SPF/DKIM/DMARC, not spam-foldered) — Mailpit proves
  transport + token usability only.
- **`Secure` cookie through the real TLS proxy** — the named manual release gate
  (localhost only proves Grav emits `Secure`).

---

## 3. ADR-002 staging controls (gate for Layer 2)

Per [ADR-002](../decisions/ADR-002-prod-data-on-staging.md), promote-to-staging
**must not ship** until all three are in place:

1. **HTTP basic auth fronting `staging.hackersbychoice.dk`** — *operator action*
   (one.com `.htaccess` + an htpasswd file the deploy never touches). Suggested
   block at the staging web root:
   ```apache
   AuthType Basic
   AuthName "Byvaerkstederne staging"
   AuthUserFile "/absolute/path/outside/webroot/.htpasswd-staging"
   Require valid-user
   ```
   Generate the credential (shared only with the ops team):
   ```
   htpasswd -c /absolute/path/outside/webroot/.htpasswd-staging opsuser
   ```
   ⚠ one.com fronts sites with Varnish (which has previously caused an
   `X-Forwarded-Proto` HTTPS-redirect loop), so confirm the gate returns
   **401 before any Grav response** with the `curl` check in §1 Layer 2 after
   applying it. Keep the `.htpasswd` out of the web root and out of git.
2. **Privacy-policy disclosure** — ✅ added in this PR (the "Opbevaring" section
   of `06.privatlivspolitik` now discloses non-public-staging replication +
   the overwrite-each-promotion retention).
3. **Retention contract** — ✅ satisfied by design (every promote overwrites
   staging data wholesale; backups live in encrypted managed storage).

---

## 4. Operator secrets & credentials checklist

Nothing below is in git (by design); provision before the matching layer:

- [ ] **SSH/SFTP creds** for staging (one.com) and prod (chosting.dk) in
      `.env.deploy` — and confirm chosting.dk SSH is enabled. *(Layers 1–3)*
- [ ] **Staging basic-auth** `.htpasswd` + `.htaccess` live on staging. *(Layer 2)*
- [ ] **Per-tier SMTP** `email.yaml` (copy each tier's `.example`) — dev/test/
      staging `noreply@hackersbychoice.dk`, prod `noreply@byvaerkstederne.dk`. *(auth)*
- [ ] **Rotate the exposed salt** (`security.yaml` salt `Wbd0yZKOPckagC`) on every
      tier that used it. Invalidates remember-me cookies — acceptable. *(auth)*
- [ ] **DNS deliverability** (SPF/DKIM/DMARC) per sending domain before flipping
      the email-verification gate on a tier. *(auth)*
- [ ] **Playwright creds** `TEST_PASSWORD` / `TEST_ADMIN_PASSWORD` for the
      authenticated suite. *(auth tests)*

---

## 5. Quick recovery reference

| Situation | Command |
|---|---|
| Bad dev/test deploy | `make rollback tier=<dev\|test>` |
| Bad staging data | re-run `./deploy/promote-to-staging.sh` (wholesale refresh) or restore the step-2 backup |
| Bad prod promote | `./deploy/rollback-prod.sh --to-backup pre-promotion-vX.Y.Z-build<N> --yes-i-mean-it` |
| Inspect a backup | `./deploy/restore.sh --to ./scratch --from <id>` |
| List backups | `make list-backups` |
