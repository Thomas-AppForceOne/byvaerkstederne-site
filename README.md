# Byværkstederne — Website

Community workshop website for [Byværkstederne i Hundested](https://hackersbychoice.dk).
Built with [Grav CMS](https://getgrav.org) running in Docker, deployed to one.com shared hosting.

## Quick Start

```bash
git clone <repo-url>
cd workshop-site
make setup
```

This will check dependencies, pull LFS files, start Docker, and prompt you to create an admin account (username, email, password). The site will then be available at **http://localhost:8080** and admin panel at **http://localhost:8080/admin**.

## First-time setup

### Backup operator hygiene (macOS)

`deploy/backup.sh` and `deploy/restore.sh` write encrypted archives and
unpacked PII (member emails, bcrypt hashes, bug-report screenshots)
into local paths. Time Machine, Spotlight, and cloud-sync tools will
silently capture that data unless you exclude the path. Once per
machine, after first checkout, run:

```bash
tmutil addexclusion ~/.byvaerkstederne/backups
tmutil addexclusion ./deploy/staging-stage
tmutil addexclusion ./deploy/prod-stage
```

The first path is **machine-wide** — every checkout (main repo +
worktrees + per-`/gan`-run worktrees) shares
`~/.byvaerkstederne/backups`, so the exclusion is once-per-machine,
not once-per-worktree. Override the location via `BV_KEEP_LOCAL_DIR`
in `.env.deploy` if you want a different path; just exclude whichever
path you pick.

Also, do **not** keep this checkout inside a Dropbox / iCloud Drive /
Google Drive synced root.

`~/.byvaerkstederne/backups/`, `./deploy/staging-stage/`, and
`./deploy/prod-stage/` are private. `restore.sh` writes
`.metadata_never_index` (Spotlight exclusion marker) into any scratch
directory it creates.

### Backup tooling dependencies

`deploy/backup.sh` and `deploy/restore.sh` need:

| Tool | Why |
|------|-----|
| [`age`](https://age-encryption.org) | Encrypts/decrypts the archive (`brew install age`). |
| `tar`, `rsync`, `ssh` | Standard on macOS / Linux. |
| `sshpass` | Same reason as the atomic-deploy section: password-auth shared hosting (one.com, chosting.dk) requires it. backup.sh / restore.sh dispatch through `deploy/lib/ssh-auth.sh` which picks between sshpass+`DEPLOY_PASS` and bare-ssh+key-auth based on whether the password is set for the active tier. Install: `brew install esolitos/ipa/sshpass`. |
| (optional) `aws` CLI | Only when uploading to S3-compatible managed storage. |

The committed test suite (`tests/deploy/backup-restore.bats`) needs
[`bats-core`](https://github.com/bats-core/bats-core) — `brew install
bats-core`.

### Atomic-deploy tooling dependencies

`deploy/deploy.sh`, `deploy/rollback.sh`, and
`deploy/migrate-to-atomic-layout.sh` need everything the backup tooling
needs **plus** the items below. Each script asserts these at startup
and fails loud with an install hint if anything is missing.

| Tool | Why |
|------|-----|
| `sshpass` | one.com authenticates with a password rather than an SSH key, so the scripts wrap `ssh` and `rsync` in `sshpass -p "$DEPLOY_PASS"`. Install: `brew install esolitos/ipa/sshpass` (it's not in core Homebrew because of upstream's stance on password-passing, but the IPA tap is the standard macOS workaround). |
| [GNU coreutils](https://www.gnu.org/software/coreutils/) | The scripts measure `swap_duration_ms` for the `release-meta.yaml` audit trail with `date +%s%N` (nanosecond resolution). BSD `date` (macOS default) doesn't support `%N` and would round single-digit-second swaps to 0–999 ms with no useful precision; the startup probe (`bv_require_ms_timing` in `deploy/lib/atomic-release.sh`) refuses to run without GNU `date`. Install: `brew install coreutils`. The scripts prepend `/opt/homebrew/bin` to `$PATH` internally — you do **not** need to add `gnubin` to your shell PATH unless you want GNU semantics in everyday use. |
| GNU bash 4+ | The atomic-release lib uses constructs (nested `$(...)` with single-quotes inside double-quotes) that bash 3.2's parser fails on. macOS ships bash 3.2 at `/bin/bash`; the deploy scripts shebang `#!/usr/bin/env bash` and add a `BASH_VERSINFO[0]` ≥ 4 assertion at startup so the operator gets a readable diagnostic instead of "syntax error near unexpected token \`('". Install: `brew install bash`, and ensure `/opt/homebrew/bin` precedes `/usr/bin` on your `$PATH`. |
| `php` (on the **remote**, not the operator host) | Step 7 of the deploy sequence runs `php bin/grav cache --all` against the freshly-rsync'd release dir. Shared-hosting tiers (one.com, chosting.dk) ship PHP — no operator install required. The cache-clear failure path explicitly aborts before the docroot swap. |

The atomic-deploy probes (`tests/deploy/lint-remote-ssh.sh`,
`unit-remote-run.sh`, `atomic-layout.sh`, `rollback.sh`,
`migrate.sh`) run locally without any of the above tools touching a
real remote — the unit test stubs `ssh`/`sshpass` for local execution
and the rest use `mktemp` fixtures. CI doesn't need `sshpass` to lint
or test the work; only operator-side real-tier exercise does.

See [ADR-004](decisions/ADR-004-atomic-deploy-fixture-only-testing.md)
for the rationale behind the local-fixture-first testing posture and
the operator-supervised real-tier exercise contract.

#### Storing the SSH password in macOS Keychain (recommended)

Plain-text passwords in `.env.deploy` are fine for solo-operator
machines with FileVault on, but Keychain integration is one shell
command away and noticeably better:

- The password never appears in `.env.deploy` — only the Keychain
  *item name* does. `.env.deploy` becomes safe to share between
  operator machines, since the secret is per-machine.
- macOS prompts for unlock on first access; "Always Allow" caches
  the decision for the duration of the Keychain unlock window
  (typically the login session).
- Revocation is `security delete-generic-password ...` — instant
  and obvious.

**One-time setup per tier:**

```sh
# staging / test / dev share one password on the hackersbychoice.dk
# one.com account; store it once under any item name you like.
security add-generic-password -a "$USER" -s bv-deploy-pass-hackersbychoice -w
# (the -w with no value prompts for the password without echoing)

# prod hosting account (separate; populate when chosting.dk creds exist):
security add-generic-password -a "$USER" -s bv-deploy-pass-prod -w
```

Then in `.env.deploy`, **replace** `DEPLOY_PASS=...` with:

```sh
DEPLOY_PASS_KEYCHAIN=bv-deploy-pass-hackersbychoice
DEPLOY_PROD_PASS_KEYCHAIN=bv-deploy-pass-prod   # commented until prod is provisioned
```

`deploy/lib/ssh-auth.sh` consults the Keychain only when the direct
env var is unset, so a one-off CI override via `DEPLOY_PASS=...` still
takes precedence. The unit test
(`tests/deploy/unit-ssh-auth.sh`) covers both code paths.

### Age key management — backup encryption / decryption

Backups are encrypted with [`age`](https://age-encryption.org). The
project uses a multi-recipient model:

- **Public keys** live in `deploy/age-recipients.txt`, committed to
  the repo. Anyone can read them; reviewers gate "who is allowed to
  decrypt our backups" via PR review.
- **Private keys** live in each operator's macOS Keychain as items
  named `bv-age-identity-<label>`. `restore.sh` walks every such item
  at decrypt time and tries each as the identity. The first match
  wins. If none decrypt, falls back to `AGE_IDENTITY_FILE` env var.
- **Cap of 5 active recipients** enforced by `backup.sh` and the
  `manage-age-keys.sh generate` command.
- **Per-backup audit trail**: `backup-meta.yaml` records
  `encrypted_to: [<pubkey-1>, <pubkey-2>, ...]` listing every
  recipient at backup time. `restore.sh` reads this before decrypt to
  tell the operator which keys would work.

Operator setup (once per machine):

```bash
# Generate your first age keypair, store private in Keychain,
# append public to deploy/age-recipients.txt. Pick any label
# unique to you (your first name works).
make add-age-key NAME=thomas

# Or directly:
./deploy/manage-age-keys.sh generate thomas
```

The command:
1. Generates a fresh keypair via `age-keygen`.
2. Stores the **identity file** (public + private) in macOS Keychain
   as `bv-age-identity-thomas`. The identity never touches disk.
3. Appends the public key + a `# bv-age-identity-thomas (added …)`
   marker line to `deploy/age-recipients.txt` for review and commit.

Inspect / manage:

```bash
make list-age-keys           # show recipients; mark which ones YOU hold
make retire-age-key NAME=alice                # remove from age-recipients.txt
make retire-age-key NAME=alice DELETE_KEYCHAIN=1   # also remove from Keychain
```

A retired key remains decryptable for old backups as long as the
private key is still held by some operator. Truly destroying the
ability to decrypt requires every holder to also `retire` with
`DELETE_KEYCHAIN=1`.

### Backup tooling environment variables

Configuration variables for `deploy/backup.sh` and `deploy/restore.sh`.
The standard ones live in `.env.deploy` (gitignored, see
`.env.deploy.example`); the test-mode ones are exported per-invocation.

**Standard configuration** (set in `.env.deploy`):

| Variable | Purpose |
|----------|---------|
| `DEPLOY_PROD_HOST`, `DEPLOY_PROD_USER`, `DEPLOY_PROD_PORT`, `DEPLOY_PROD_PATH` | SSH credentials for the prod tier. |
| `DEPLOY_PROD_PASS` | Password for the prod tier. Plain-text alternative; prefer `DEPLOY_PROD_PASS_KEYCHAIN` below. |
| `DEPLOY_PROD_PASS_KEYCHAIN` | Name of a macOS Keychain generic-password item that holds the prod password. When set (and `DEPLOY_PROD_PASS` is unset), `deploy/lib/ssh-auth.sh` fetches the password at runtime via `security find-generic-password -a "$USER" -s "<item>" -w`. The plaintext password lives only in the Keychain, never in `.env.deploy`. |
| `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_PORT`, `DEPLOY_PATH` | SSH credentials shared across staging / test / dev (see `specifications/archive/prod_backup_restore_specification.md` for the per-tier subpath logic). |
| `DEPLOY_PASS` | Password shared across staging / test / dev. Plain-text alternative; prefer `DEPLOY_PASS_KEYCHAIN`. |
| `DEPLOY_PASS_KEYCHAIN` | macOS Keychain item name for the staging/test/dev password. Same shape as `DEPLOY_PROD_PASS_KEYCHAIN`. |
| `BACKUP_S3_BUCKET`, `BACKUP_S3_ENDPOINT`, `BACKUP_S3_ACCESS_KEY_ID`, `BACKUP_S3_SECRET_ACCESS_KEY` | Managed-storage credentials. Either these or `BACKUP_LOCAL_STORE_DIR` must be set. |
| `BACKUP_LOCAL_STORE_DIR` | Directory acting as managed storage (used for testing and when an S3 bucket is overkill). Mutually exclusive with the S3 backend; if both are set, the local store wins. |
| `AGE_IDENTITY_FILE` | Absolute path to the operator's age private key. **Optional** — by default, `restore.sh` walks every `bv-age-identity-*` item in your macOS Keychain and tries each as the decrypt identity. Set this env-var only as a fallback for CI / Linux operators / one-off overrides. See "Age key management" below for the recommended Keychain workflow. |

**Disaster-recovery gates** (`deploy/restore.sh` only):

| Variable | Purpose |
|----------|---------|
| `RESTORE_TO_TIER_ENABLED=1` | Master safety gate. Without this, `restore.sh <tier> --from <id>` exits early with a stand-in message instead of executing the destructive wipe. Defaults to `0`. |
| `RESTORE_LOCAL_TIER_DIR=<abs-path>` | When set together with `RESTORE_TO_TIER_ENABLED=1`, the wipe-and-replace runs against this local directory instead of via `rsync` over SSH. Used by the bats test suite to exercise the disaster-recovery code path; operators can use it to dry-run a restore against a scratch tier. The pre-restore safety backup is automatically skipped in this mode (it would SSH to real prod, defeating the dry-run). |

**Test-mode escapes** (set by `tests/deploy/backup-restore.bats`; do not use in production):

| Variable | Purpose |
|----------|---------|
| `BACKUP_FIXTURE_DIR=<abs-path>` | Replaces the SSH source-pull with a local directory. The fixture's `config/www/{VERSION,BUILD,user/data-version.yaml}` files are read for backup metadata; the allow-listed `user/*` subtrees are copied into the staging area instead of rsynced. |
| `BACKUP_RECIPIENTS_FILE=<abs-path>` | Override `deploy/age-recipients.txt` for tests with a throwaway keypair. |
| `BACKUP_FAKE_NOW_EPOCH=<unix-epoch>` | Pin the script's "now" timestamp for deterministic filename/metadata assertions. |
| `BACKUP_SOURCE_HOST=<hostname>` | Override the `source_host` field in `backup-meta.yaml` (defaults to `fixture.local` in fixture mode). |
| `XDG_CONFIG_HOME=<abs-path>` | Standard XDG variable; the bats suite redirects it to a per-test temp dir so the privacy-hygiene banner sentinel is isolated from the operator's real `~/.config/byvaerksted/`. |

There is intentionally no `BACKUP_FAKE_CODE_VERSION` /
`BACKUP_FAKE_CODE_BUILD` / `BACKUP_FAKE_DATA_VERSION` env-var
override. Tests inject metadata by populating
`$BACKUP_FIXTURE_DIR/config/www/{VERSION,BUILD,user/data-version.yaml}`
— the same source-fetch code path an operator run uses.

## Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| [Docker Desktop](https://docker.com/get-started) | 24+ | Runs the Grav container |
| [Git](https://git-scm.com) | 2.30+ | Version control |
| [Git LFS](https://git-lfs.com) | 3.0+ | Stores images/videos efficiently |

> `make setup` will check for all dependencies and attempt to install Git LFS if missing.

For deploy / backup / restore tooling, see [Backup tooling
dependencies](#backup-tooling-dependencies) and [Atomic-deploy tooling
dependencies](#atomic-deploy-tooling-dependencies) above. Those are
operator-side requirements only; they do not affect local Docker
development.

## Commands

Run `make help` to see all available commands:

| Command | Description |
|---------|-------------|
| `make setup` | Full first-time setup |
| `make start` | Start the site |
| `make stop` | Stop the site |
| `make restart` | Restart the site |
| `make logs` | Tail container logs |
| `make open` | Open site in browser |
| `make admin` | Open admin panel |
| `make status` | Show container status |
| `make deploy tier=prod` | Deploy to production |
| `make deploy tier=test` | Deploy to test environment |
| `make deploy tier=dev` | Deploy to dev environment |
| `make deploy tier=staging` | Deploy to staging (prod data) |
| `make backup tier=prod` | Backup production data |
| `make backup tier=test` | Backup test environment data |
| `make list-backups [tier=<env>]` | List available backup ids |
| `make restore tier=<env> from=<id>` | Restore a tier (add `RESTORE_TO_TIER_ENABLED=1` to actually wipe; prod refused) |
| `make rollback tier=<env>` | Roll back a tier to its previous release |
| `make migrate-atomic tier=<env>` | One-time migration to atomic-release layout (prod refused) |
| `make cache-clear` | Clear Grav cache |
| `make reset-users` | Delete all user accounts (except admin) |
| `make reset-admin` | Reset admin account (delete and recreate) |
| `make reset-data` | Delete all Flex Objects data |
| `make reset-cache` | Clear Grav cache |
| `make reset-all` | Full reset: users + data + config + restart |

## Architecture

### Design System: "Industrial Brutalism Refined"

- **Fonts:** Space Grotesk (headlines), Work Sans (body)
- **Colors:** Primary `#13483b` (green), Secondary `#325f9b` (blue), Tertiary `#712800` (terracotta), Kulturhus `#27272a` (dark)
- **Rules:** 0px border-radius, no 1px borders, tonal surface layering, glassmorphism overlays

### Theme Structure

Custom theme at `config/www/user/themes/byvaerkstederne/`:

```
byvaerkstederne/
├── css/theme.css                  # All styles (CSS custom properties + responsive)
├── js/site.js                     # Client-side JS (filters, overlays, mobile menu)
├── images/                        # Logo, press photos
├── templates/
│   ├── default.html.twig          # Standard page
│   ├── modular.html.twig          # Modular page orchestrator
│   ├── register.html.twig         # Member registration page
│   ├── error.html.twig            # Error page
│   ├── partials/
│   │   ├── base.html.twig         # HTML skeleton
│   │   ├── navigation.html.twig   # Sticky nav + mobile menu + login/logout
│   │   ├── footer.html.twig       # 4-column footer
│   │   └── login_overlay.html.twig # Floating login panel
│   └── modular/                   # 30+ reusable section components
│       ├── hero.html.twig
│       ├── event_highlight.html.twig
│       ├── workgroups.html.twig
│       ├── event_list.html.twig
│       ├── wishlist.html.twig
│       └── ...
├── blueprints/modular/            # Admin form definitions for each component
└── blueprints.yaml
```

### Modular Page System

Pages are composed from reusable modular components:

```
pages/01.home/
├── modular.md                     # Page container
├── _01.hero/hero.md               # Hero section
├── _02.event-highlight/...        # Featured event + To-Do list
├── _03.workgroups/...             # 4-column workshop cards
└── _04.newsletter/...             # Email signup
```

- **Add a component:** Create `_NN.name/template_name.md` with YAML front matter
- **Reorder sections:** Change the numeric prefix
- **Create new components:** Add Twig template in `templates/modular/`

### Dynamic Content: Flex Objects

Content that non-technical admins need to manage is stored in Flex Objects (flat YAML files with admin CRUD interface):

| Collection | Admin path | Description |
|-----------|-----------|-------------|
| Opgaver | `/admin/flex-objects/opgaver` | To-do tasks per workshop group |
| Ønskeliste | `/admin/flex-objects/oenskeliste` | Equipment wishlist per group |
| Begivenheder | `/admin/flex-objects/begivenheder` | Events and calendar entries |
| Teammedlemmer | `/admin/flex-objects/teammedlemmer` | Contact persons and team |

Data files live in `config/www/user/data/flex-objects/`. Templates pull from Flex Objects automatically, with fallback to page YAML if Flex Objects is unavailable.

### Pages

| Route | Type | Description |
|-------|------|-------------|
| `/` | Public | Homepage — hero, featured event, to-do list, workgroups, newsletter |
| `/vaerkstedskalenderen` | Public | Calendar with category filters |
| `/vaerksteder` | Public | Workshop groups landing |
| `/vaerksteder/makerspace` | Public | Makerspace & Reparation |
| `/vaerksteder/krea-cafe` | Public | Krea Café |
| `/vaerksteder/groent-byvaerksted` | Public | Grønt BYværksted |
| `/vaerksteder/kulturhus` | Public | Kulturhus |
| `/kontakt` | Public | Contact form, team, location |
| `/opret-medlemskab` | Public | Member registration |
| `/vedtaegter` | Public | Bylaws (info nav) |
| `/privatlivspolitik` | Public | Privacy policy (info nav) |
| `/referater` | Public | Meeting minutes archive (info nav) |
| `/presse` | Public | Press kit, photos, contact (info nav) |

### Member System

- **Registration** at `/opret-medlemskab` — creates Grav user account with site login access
- **Login** via floating overlay (accessible from header on all pages)
- **Logout** via nonce-protected link in header
- User accounts stored as flat YAML in `config/www/user/accounts/`
- Login plugin configured in `config/www/user/config/plugins/login.yaml`

### Custom Plugin: flex-cache-bust

`config/www/user/plugins/flex-cache-bust/` handles:
- **Cache invalidation** — clears page cache when Flex Objects data changes via admin
- **Docker port fix** — corrects redirect URLs when running behind Docker port mapping

## Branching Model

```
main              ← production releases only — protected, no direct PRs
develop           ← integration branch, deployed to /test
feature/*         ← working branches (includes gan/<run-id> from /gan)
```

PRs from feature branches always target `develop`. `main` is updated only via a release PR from `develop`, after the change has been verified on `/test`. Agent rules for this are in [CLAUDE.md](CLAUDE.md#git-workflow--branching-and-prs).

| Action | Commands |
|--------|---------|
| Start new feature | `git checkout -b feature/my-feature develop` |
| Deploy feature to dev | `make deploy tier=dev` |
| Merge to test | `git checkout develop && git merge feature/my-feature` then `make deploy tier=test` |
| Release to production | `git checkout main && git merge develop` then `make deploy tier=prod` |

## Environments

| Environment | URL | Deploy command | Branch |
|------------|-----|---------------|--------|
| **Production** | hackersbychoice.dk | `make deploy tier=prod` | `main` |
| **Test** | hackersbychoice.dk/test | `make deploy tier=test` | `develop` |
| **Dev** | hackersbychoice.dk/dev | `make deploy tier=dev` | `feature/*` |
| **Staging** | hackersbychoice.dk/staging | `make deploy tier=staging` | `main` + prod data |
| **Local** | localhost:8080 | `make start` | any branch |

Credentials are in `.env.deploy` (git-ignored). Copy `.env.deploy.example` to get started.

## Backup

```bash
make backup tier=prod    # Backup production data (accounts, flex objects, pages, media)
make backup tier=test    # Backup test environment data
make list-backups        # See available backup ids
make restore tier=<env> from=<id>   # Restore a tier (RESTORE_TO_TIER_ENABLED=1 to actually wipe)
```

Backups are stored locally in `backups/` (git-ignored) as timestamped snapshots. Last 30 backups are kept, older ones are pruned automatically. Ready to sync to NAS or cloud storage.

## Reset (Development)

| Command | What it does |
|---------|-------------|
| `make reset-users` | Delete all user accounts except admin |
| `make reset-admin` | Reset admin account (delete and recreate interactively) |
| `make reset-data` | Delete all Flex Objects data |
| `make reset-cache` | Clear Grav cache |
| `make reset-all` | All of the above + reset config + restart |

## Git LFS

All binary files (images, videos, audio, PDFs) are tracked by Git LFS. This keeps the repo fast to clone while preserving full version history.

Tracked formats: `png jpg jpeg gif webp svg ico pdf mp4 mov avi mkv webm m4v wmv flv mp3 wav ogg flac m4a`

## Content Editing

### Via Admin Panel

1. Go to http://localhost:8080/admin
2. **Pages** — edit page content and component configuration
3. **Flex Objects** — manage tasks, events, wishlist, and team members

### Via Files

Edit markdown files directly in `config/www/user/pages/`. Component configuration lives in YAML front matter.

## Testing

End-to-end tests use [Playwright](https://playwright.dev) and run against the local
Docker Grav container at `http://127.0.0.1:8080`. Configuration lives in
[`playwright.config.js`](playwright.config.js); test files live under `tests/`.

### Environment variables

The suite reads **exactly two secrets**, both supplied via environment variables:

| Variable | Purpose |
|----------|---------|
| `TEST_PASSWORD` | Password for the member account `pw-test-user` (user-facing tests). |
| `TEST_ADMIN_PASSWORD` | Password for the admin account `pw-test-admin` (admin smoke tests only). |

No other test-related secrets exist. Passwords are read from `process.env` and are
never committed, logged, or echoed to stdout by the helper code.

### Account lifecycle — you do not create Grav accounts by hand

`playwright.config.js` wires `tests/global-setup.js` and `tests/global-teardown.js`
as Playwright's `globalSetup` / `globalTeardown`. Before the suite runs, setup
idempotently creates `pw-test-user` (and `pw-test-admin` when
`TEST_ADMIN_PASSWORD` is set) via `docker exec grav bin/plugin login new-user …`.
After the suite, teardown removes the YAMLs under `config/www/user/accounts/`.

You do **not** need to visit `/admin`, run `bin/plugin login new-user` by hand, or
pre-seed any account. Just export the password(s) and run the suite.

### Running the suite

```bash
# Anonymous tests only (authenticated skipped with a named reason)
npx playwright test

# Full user-facing matrix
TEST_PASSWORD='…' npx playwright test

# Plus admin smoke
TEST_PASSWORD='…' TEST_ADMIN_PASSWORD='…' npx playwright test
```

When `TEST_PASSWORD` is unset, authenticated specs skip with a reason that names
the missing variable. Same for `TEST_ADMIN_PASSWORD` on admin-smoke tests.

### Re-run robustness

`globalSetup` is **idempotent** (check-then-create). That means the suite is safe
to re-run in all three common recovery scenarios — no manual intervention
required:

1. **Clean re-run after a successful previous run.** Previous `globalTeardown`
   removed both YAMLs; setup re-creates them. Just re-run the suite.
2. **After a crashed run that left account YAMLs on disk.** Setup detects the
   existing accounts via `docker exec grav bin/plugin login new-user …` returning
   "already exists" and proceeds without error. Just re-run the suite.
3. **After `make reset-users` (or equivalent manual cleanup).** The reset wipes
   non-admin accounts; setup recreates the test accounts on the next run. Just
   re-run the suite.

If you want to force-clean by hand before a re-run:

```bash
rm -f config/www/user/accounts/pw-test-user.yaml
rm -f config/www/user/accounts/pw-test-admin.yaml
```

Both paths are covered by the pre-existing `config/www/user/accounts/*` rule in
[`.gitignore`](.gitignore) — they are never committed. Confirm with:

```bash
git check-ignore config/www/user/accounts/pw-test-user.yaml
git check-ignore config/www/user/accounts/pw-test-admin.yaml
```

### Coverage matrix

See [`tests/ACCEPTANCE.md`](tests/ACCEPTANCE.md) for the mapping of each source-spec
acceptance criterion to the test file(s) that cover it.

### Spec

The full test-suite specification lives at
[`specifications/roadmap_bug_feature_tests_specification.md`](specifications/roadmap_bug_feature_tests_specification.md)
(moved to `specifications/archive/` after merge).

## Contact

**Byværkstederne i Hundested**
Nørregade 11, 3390 Hundested
kontakt@byvaerkstederne.dk
