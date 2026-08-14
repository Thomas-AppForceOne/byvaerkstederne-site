# Testing guide — how to run every suite and read the results

This is the operator-facing "run the tests + tell if they passed" guide. For the
*safe live-promotion* progression (dev → staging → prod), see
[`deploy/PROMOTE-RUNBOOK.md`](deploy/PROMOTE-RUNBOOK.md).

> **Where the suites live.** The deploy/auth suites below ship across feature
> branches that aren't all merged yet — `make test-deploy`'s promote probes are
> on **#52/#53**, the member-auth Playwright + Mailpit suites on **#54**. Check
> out the relevant branch (or wait for merge) to run those. Everything else is
> on `develop`. The "Branch" column in §1 says which.

---

## 0. One-time setup

| Need | How | Required for |
|---|---|---|
| Docker running | Docker Desktop | browser tests, migration tests |
| Playwright + Chromium | `make test-install` | `make test`, `make test-auth` |
| `bats` + `age` | `brew install bats-core age` | `make test-backup-restore` |
| Test credentials | `~/.gan-secrets/workshop-site.env` (mode `600`) with `TEST_PASSWORD` and `TEST_ADMIN_PASSWORD` | authenticated browser tests |
| A running Grav container | `make start` (serves :8080); check with `make status` | `make test`, `make test-auth` |
| Seeded test accounts | `tests/fixtures/grav-seeds/playwright/apply.sh <container>` (see that dir's README) | authenticated browser tests |

Without `~/.gan-secrets/workshop-site.env` the authenticated tests **skip** (that's
the documented anonymous-only mode, not a failure).

---

## 1. The suites at a glance

| # | Suite | Command | Infra needed | Branch |
|---|---|---|---|---|
| A | Deploy-script regression (incl. atomic layout, rollback, **promote-to-staging/prod**, skip-data-migration) | `make test-deploy` | none | develop (+ promote probes on #52/#53) |
| B | Data-migration runner | `bash migrations/run-tests.sh` · `bash tests/deploy/migrate-integration.sh` | Docker | develop |
| C | Backup / restore | `make test-backup-restore` | bats + age | develop |
| D | Anonymous browser | `make test` | Grav container | develop |
| E | Authenticated browser | `make test-auth` | Grav container + creds + seeded accounts | develop |
| F | Member-auth (registration/reset/login/session/policy) | `scripts/mailpit-up.sh` → `make test` / `make test-auth` → `scripts/mailpit-down.sh` | Grav container + Mailpit (+ creds for the authed ones) | #54 |

---

## 2. How to read pass vs fail (applies everywhere)

**The single source of truth is the exit code.** After any command:
```
echo $?        # 0 = passed, non-zero = failed
```
On top of that, each runner prints its own summary:

- **Bash suites (A):** each group ends with `Pass: N   Fail: 0` or `N passed, 0 failed`; the migration runner prints `all green`. **Failure** looks like a `FAIL …` line and `make: *** [Makefile:NNN: test-deploy] Error 1`. (Note: lines like `blessing gate FAILS on commit mismatch` are *test names describing a refusal path* — those are passing assertions, not failures. Trust the final `Fail: 0` + exit 0.)
- **bats (C):** `ok N …` per test, `not ok N …` for failures, ending `N tests, 0 failures`.
- **Playwright (D/E/F):** ends with `N passed (12.3s)` in green. `N skipped` = not run (e.g. no creds — fine). `N failed` in red + non-zero exit = real failure; an HTML report is written to `playwright-report/` (`npx playwright show-report`).

---

## 3. Per-suite detail

### A. Deploy-script regression — `make test-deploy`
No infrastructure; pure local fixtures/dry-runs. This is the fastest, highest-value gate.
```
make test-deploy ; echo "exit=$?"
```
**Pass:** every group prints `Fail: 0` / `N passed, 0 failed`, and `exit=0`.
**Fail:** a `FAIL …` line, `Error 1`, and `exit` non-zero.
On the deploy-chain branches this also runs `promote-to-staging` (19/0),
`promote-to-prod` (31/0), and `skip-data-migration` (3/0).

### B. Data-migration runner — Docker
```
bash migrations/run-tests.sh            ; echo "exit=$?"   # PASSED: N / FAILED: 0 / all green
bash tests/deploy/migrate-integration.sh ; echo "exit=$?"  # PASSED: 5 / FAILED: 0
```
First run downloads a Composer/PHP image (slow, one-time). **Pass:** `FAILED: 0` + `all green` + `exit=0`. **Fail:** non-zero `FAILED:` count or non-zero exit. If Docker isn't running you'll get an explicit Docker error — start Docker and retry (this is an environment problem, not a test failure).

### C. Backup / restore — `make test-backup-restore`
```
make test-backup-restore ; echo "exit=$?"
```
Needs `bats` + `age` (the target tells you if they're missing). **Pass:** `N tests, 0 failures` + `exit=0`. **Fail:** any `not ok` line.

### D. Anonymous browser — `make test`
```
make start              # if not already running; confirm with: make status
make test ; echo "exit=$?"
```
**Pass:** `N passed` + `exit=0` (you'll see `🔑 Sourced test credentials…` or
`ℹ️ …anonymous-only mode`). **Fail:** `N failed` + non-zero exit; inspect
`npx playwright show-report`. If it says **"No Grav container for this worktree"**,
run `make start` first.

### E. Authenticated browser — `make test-auth`
Needs creds (§0) **and** seeded accounts (`pw-test-user`, `pw-test-admin`).
```
make test-auth ; echo "exit=$?"
```
**Pass:** `N passed` + `exit=0`. **Refuses up front** (non-zero, before running) if
`TEST_PASSWORD`/`TEST_ADMIN_PASSWORD` aren't set — that's a setup gap, not a test
failure. If accounts aren't seeded, login specs fail — seed them first.

### F. Member-auth surface (#54) — Mailpit
The auth specs need a mail sink. `mailpit-up.sh` ONLY starts the Mailpit
container; the **Playwright run owns the `email.yaml` override** — global-setup
repoints the mailer at `mailpit:1025` when the sink is reachable, and
global-teardown restores it via `git checkout`. So the override exists only for
the duration of a run and can't be left behind by simply starting the sink.
```
scripts/mailpit-up.sh .        # start the sink container (does NOT touch email.yaml)
make test            # registration / password-reset / password-policy / session-cookie (anonymous)
make test-auth       # login (needs creds + seeded accounts)
scripts/mailpit-down.sh .      # stop the sink (also a defensive email.yaml restore)
```
**Pass:** Playwright `N passed`. Without Mailpit/creds the auth specs **skip**
cleanly — skips are expected, not failures.

**Catastrophic guard:** if a run is killed before teardown, `email.yaml` is left
pointing at Mailpit. The next run **refuses to start** with a FATAL message
naming the file — committing that override would break a real tier's mailer.
Recover with `git checkout -- config/www/user/config/plugins/email.yaml` (or
`scripts/mailpit-down.sh .`).

---

## 4. Full local sweep (copy/paste)
From a clean checkout of the branch you want to verify:
```
make test-install                                   # one-time
make test-deploy            && echo "A ok"          # no infra
bash migrations/run-tests.sh && echo "B ok"         # Docker
make test-backup-restore    && echo "C ok"          # bats+age
make start                                          # Grav container
make test                   && echo "D ok"          # browser (anon)
make test-auth              && echo "E ok"          # browser (authed; needs creds)
```
If every line prints its `ok` and no command exits non-zero, the branch is green.
`&&` short-circuits, so the first failure stops the chain and leaves a non-zero `$?`.

---

## 5. CI (GitHub Actions) — the authoritative gate
Every PR runs `test-deploy` and the PHP matrix `test (8.1/8.2/8.3)` automatically.
```
gh pr checks <PR#>                       # every row must read: pass
gh run view <run-id> --log-failed        # read only the failing step of a red run
```
Green example (the current state of #52–#55): all rows `pass`. CI checks out
**shallow**, so any test that shells out to `deploy.sh` must rely on output that
prints before its full-history guard (already handled).

---

## 6. Quick failure triage
| Symptom | Cause / fix |
|---|---|
| `No Grav container for this worktree` | `make start` (or `scripts/grav-up.sh . <port>`) |
| Auth tests all `skipped` | no `~/.gan-secrets/workshop-site.env` — add creds (or it's intended anonymous mode) |
| Auth login specs `failed` | accounts not seeded — run the grav-seeds `apply.sh` |
| `Docker` error in B | Docker Desktop not running |
| `bats`/`age` not found in C | `brew install bats-core age` |
| `make test-deploy` red after editing a deploy script | read the `FAIL` line; re-run the single probe, e.g. `bash tests/deploy/rollback.sh` |
| `FATAL: email.yaml is modified at suite start` | a prior run was killed before teardown — `git checkout -- config/www/user/config/plugins/email.yaml` (or `scripts/mailpit-down.sh .`) and re-run |
