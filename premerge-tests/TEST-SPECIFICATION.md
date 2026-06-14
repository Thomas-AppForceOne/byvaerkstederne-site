# Pre-merge test specification — PR #53 (deploy-chain) & PR #54 (member-auth)

Formal verification to run **before merging** either PR. Each test case has
preconditions, numbered steps with the expected result of each, an overall
pass criterion, and an executable script (`premerge-tests/tcNN-*.sh`).

> **Untracked by design.** This directory is not committed. Run the scripts,
> read the results, delete or keep. Do **not** `git add premerge-tests/`.

## Scope & which branch to test
- #54 (`feature/member-auth-hardening-impl`) is **stacked on** #53
  (`feature/promote-to-prod`) and contains all of #53's commits, so running the
  whole suite **on the #54 branch verifies both PRs at once**.
- To verify them independently (their `deploy.sh`/`atomic-release.sh` differ —
  #54 adds the per-tier `email.yaml` wiring), run TC-01…TC-04 on **each** branch.
- TC-05 / TC-06 (browser + email) only apply to **#54**.

## How to run
```
# from anywhere; each script cd's to the repo root itself
git switch feature/member-auth-hardening-impl   # branch under test
premerge-tests/tc01-bash-n-parse-check.sh
premerge-tests/tc02-deploy-regression-suite.sh
premerge-tests/tc03-migration-runner.sh
premerge-tests/tc04-backup-restore.sh
premerge-tests/tc05-anonymous-browser.sh
premerge-tests/tc06-authenticated-mailpit.sh
# or run them all:
premerge-tests/run-all.sh
```

## Exit-code contract (every script)
- **0 = PASS** — the test ran and succeeded.
- **1 = FAIL** — the test ran and a check failed (the code is wrong; block the merge).
- **2 = BLOCKED** — a precondition is missing (e.g. Docker not running), so the
  test could not run. Fix the environment and re-run; this is **not** a code failure.

## Precondition matrix
| TC | Title | Needs |
|---|---|---|
| 01 | Script syntax (`bash -n`) | bash 4+ only |
| 02 | Deploy regression suite (`make test-deploy`) | Docker, make, git, rsync, age, coreutils, python3 |
| 03 | Data-migration runner | Docker |
| 04 | Backup/restore tooling | `bats`, `age` |
| 05 | Anonymous browser suite | Docker + running Grav container + Playwright |
| 06 | Authenticated + email (Mailpit) | the above + Mailpit + test creds + seeded accounts |

The deterministic merge gate is **TC-01 + TC-02** (these mirror CI exactly).
TC-03/04 add the migration + backup tooling. TC-05/06 exercise the live auth
surface and need a running site.

---

## TC-01 — Deploy/test script syntax (`bash -n`)
**Applies to:** #53, #54 · **Script:** `tc01-bash-n-parse-check.sh`

**Purpose:** parse every deploy/test shell script in full. Catches the class of
bug `make test-deploy` can miss — e.g. an unescaped apostrophe in a comment
inside a single-quoted `bv_remote_run` body (the `065834f` regression). Mirrors
the CI `bash -n` step.

**Preconditions**
- P1. On the branch under test, working tree need not be clean.
- P2. `bash` is version 4+ ( `bash --version` ). macOS: `brew install bash`.

**Steps**
| # | Action | Expected result |
|---|---|---|
| 1 | Enumerate `deploy/*.sh`, `deploy/lib/*.sh`, `tests/deploy/*.sh`, `scripts/*.sh` | a non-empty file list |
| 2 | `bash -n <file>` for each | each exits 0 (no `syntax error`) |
| 3 | Aggregate failures | zero files failed |

**Pass criterion:** all scripts parse; script exits **0**. Any parse error → exit **1** with the offending file named.

---

## TC-02 — Deploy regression suite (`make test-deploy`)
**Applies to:** #53, #54 · **Script:** `tc02-deploy-regression-suite.sh`

**Purpose:** the hermetic deploy suite — atomic-layout, rollback, migrate,
skip-data-migration, lint-remote-ssh, promote-to-staging, promote-to-prod,
release-gate, version-bump, etc. This is the required CI check.

**Preconditions**
- P1. Docker running (`docker info` succeeds) — `tests/deploy/migrate.sh` runs PHP in Docker.
- P2. `make`, `git` (full history, not a shallow clone), `rsync`, `age`, GNU coreutils, `python3`.

**Steps**
| # | Action | Expected result |
|---|---|---|
| 1 | `docker info` | exits 0 (daemon up) |
| 2 | `make test-deploy` | exits 0 |
| 3 | Inspect output | every group prints `Fail: 0` / `N passed, 0 failed`; includes `promote-to-staging: 24 passed, 0 failed`, `promote-to-prod: 35 passed, 0 failed`, `skip-data-migration: 3 passed, 0 failed`; **no** `FAIL ` line, **no** `Error 1` |

**Pass criterion:** `make test-deploy` exits **0**. Note: lines like `… FAILS on commit mismatch` are *test names for refusal paths* — those are passing assertions, not failures; trust the exit code + the per-group `Fail: 0`.

---

## TC-03 — Data-migration runner
**Applies to:** #53, #54 · **Script:** `tc03-migration-runner.sh`

**Purpose:** the data-versioning migration runner + the deploy↔migrate
integration (the `user/`-shaped data-dir contract).

**Preconditions**
- P1. Docker running (the runner installs `migrations/vendor` and runs PHP via Docker; first run pulls an image).

**Steps**
| # | Action | Expected result |
|---|---|---|
| 1 | `docker info` | exits 0 |
| 2 | `bash migrations/run-tests.sh` | exits 0; prints `FAILED: 0` then `all green` |
| 3 | `bash tests/deploy/migrate-integration.sh` | exits 0; prints `PASSED: N  FAILED: 0` |

**Pass criterion:** both commands exit **0** with zero failures.

---

## TC-04 — Backup/restore tooling
**Applies to:** #53, #54 · **Script:** `tc04-backup-restore.sh`

**Purpose:** `backup.sh` + `restore.sh` round-trip, retention, encryption, the
prod safety gate, input validation (bats).

**Preconditions**
- P1. `bats` installed (`brew install bats-core`).
- P2. `age` + `age-keygen` installed (`brew install age`).

**Steps**
| # | Action | Expected result |
|---|---|---|
| 1 | `command -v bats age age-keygen` | all found |
| 2 | `make test-backup-restore` (= `bats tests/deploy/backup-restore.bats`) | exits 0; footer `N tests, 0 failures`; no `not ok` |

**Pass criterion:** exit **0**, zero `not ok`.

---

## TC-05 — Anonymous browser suite (Playwright)
**Applies to:** #54 · **Script:** `tc05-anonymous-browser.sh`

**Purpose:** the anonymous Playwright suite, including #54's
registration / password-reset / password-policy / session-cookie specs that do
not require a real inbox.

**Preconditions**
- P1. Docker running.
- P2. A Grav container for this checkout is up — `make start` (serves :8080); verify `make status`.
- P3. Playwright + Chromium installed — `make test-install` (one-time).

**Steps**
| # | Action | Expected result |
|---|---|---|
| 1 | `node scripts/discover-grav-port.js` (or `make status`) resolves a running container/port | a port; the URL answers `curl` |
| 2 | `make test` | exits 0; Playwright prints `N passed` |
| 3 | Inspect | `0 failed`; specs needing Mailpit/creds may show `skipped` (expected, not a failure) |

**Pass criterion:** `make test` exits **0** (skips allowed). Container missing → exit **2** (BLOCKED) with `make start` instruction.

---

## TC-06 — Authenticated + email-verification (Mailpit)
**Applies to:** #54 · **Script:** `tc06-authenticated-mailpit.sh`

**Purpose:** the full custom auth surface — registration → activation email →
token gate → login, the reset-email flow, and the hardened session cookie —
the heart of the WI-1/WI-2/WI-4 work.

**Preconditions**
- P1. TC-05 preconditions (Docker, running Grav container, Playwright).
- P2. Test credentials at `~/.gan-secrets/workshop-site.env` (mode 600) with `TEST_PASSWORD` + `TEST_ADMIN_PASSWORD`.
- P3. Seeded accounts `pw-test-user`, `pw-test-admin` — `tests/fixtures/grav-seeds/playwright/apply.sh <container>`.

**Steps**
| # | Action | Expected result |
|---|---|---|
| 1 | `scripts/mailpit-up.sh .` | Mailpit starts; `email.yaml` pointed at Mailpit **in the working tree** (backed up to `.gan/`) — prints the Mailpit URL. (The `.` worktree-path arg is required.) |
| 2 | Confirm creds present + accounts seeded | `TEST_PASSWORD`/`TEST_ADMIN_PASSWORD` set; the two accounts exist |
| 3 | `make test` (anonymous: registration/reset/policy/session, now with the inbox) | exits 0; `N passed`; the register→activation-email→token flow drives mail into Mailpit |
| 4 | `make test-auth` (login) | exits 0; `N passed` |
| 5 | `scripts/mailpit-down.sh .` | restores `email.yaml`; **`git diff` is clean** (committed files unchanged) |

> **No `session.secure` relaxation.** `mailpit-up.sh` only overrides `email.yaml`
> — it no longer touches `system.yaml`. The committed `system.yaml` does not
> hard-force `session.secure: true`; Grav emits the `Secure` flag per-scheme
> (`secure_https` + `X-Forwarded-Proto`), so authenticated flows over the
> container's plain HTTP hold a session without any relaxation, and the
> TLS-tier `Secure` behaviour is still asserted by `session-cookie.js` via an
> `X-Forwarded-Proto: https` probe.

**Pass criterion:** steps 3 & 4 exit **0**; step 5 leaves `git status` clean. Missing creds/container → exit **2** (BLOCKED), and `mailpit-down.sh` still runs in cleanup.

---

## Merge decision
- **Block the merge** if any TC returns **1** (a real failure).
- A **2** (BLOCKED) means provision the environment and re-run — it is not, by
  itself, a reason to block, but TC-01 + TC-02 (the CI-equivalent gate) must
  reach **0** before merge.
