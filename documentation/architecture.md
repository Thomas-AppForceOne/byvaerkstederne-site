# Architecture

## Overview

Byværkstederne is a Grav CMS site for a community makerspace in Hundested, Denmark. It runs in Docker locally and deploys to a Linux server. The stack is PHP 8 + Twig templates + vanilla JavaScript with no frontend build step.

---

## Technology choices

| Layer | Technology | Why |
|---|---|---|
| CMS | Grav 1.7 | Flat-file, no database, Git-friendly content |
| Language | PHP 8 | Required by Grav |
| Templates | Twig | Grav's built-in template engine |
| Frontend JS | Vanilla JS (ES5-compatible module pattern) | No build step, no npm dependencies in production |
| CSS | Custom (no preprocessor) | Kept simple, single `theme.css` |
| Data storage | Flex Objects (YAML files) | Structured data without a database |
| Auth | Grav Login plugin | Session-based, YAML user accounts |
| Container | Docker (linuxserver/grav image) | Reproducible local dev, mirrors production layout |
| Tests | Playwright (Node.js) | Integration tests against the live site, no mocks |

---

## Repository layout

```
workshop-site/
├── config/                         Grav CMS root (mounted into Docker)
│   └── www/
│       └── user/
│           ├── config/             Grav and plugin config YAML
│           ├── data/
│           │   └── flex-objects/   All structured data (YAML flat files)
│           ├── pages/              Content pages (Markdown + frontmatter)
│           ├── plugins/            Custom plugins (PHP)
│           └── themes/
│               └── byvaerkstederne/
│                   ├── css/        Stylesheet(s)
│                   ├── js/         site.js (all frontend logic)
│                   ├── images/     Theme images
│                   └── templates/  Twig templates
│                       └── partials/  Layout fragments
├── decisions/                      Architecture Decision Records
├── deploy/                         Deployment and backup scripts
├── documentation/                  Developer documentation (not deployed)
├── specifications/                 Pre-implementation specs for planned features
├── tests/                          Playwright test suite
├── docker-compose.yml
├── Makefile
├── playwright.config.js
└── CLAUDE.md                       Agent instructions
```

`config/` is the only folder Docker mounts — `./config:/config`. Everything else (documentation, tests, deploy scripts) lives outside the container and is never served publicly.

---

## Pages

Pages live in `config/www/user/pages/` as numbered folders. Grav uses the numeric prefix for ordering; the slug comes from the folder name after the prefix.

| Folder | URL | Notes |
|---|---|---|
| `01.home` | `/` | Homepage |
| `02.vaerkstedskalenderen` | `/vaerkstedskalenderen` | Workshop calendar |
| `03.vaerksteder` | `/vaerksteder` | Workshop groups |
| `04.kontakt` | `/kontakt` | Contact |
| `05.vedtaegter` | `/vedtaegter` | Articles of association |
| `06.privatlivspolitik` | `/privatlivspolitik` | Privacy policy |
| `07.referater` | `/referater` | Meeting minutes |
| `08.presse` | `/presse` | Press |
| `09.opret-medlemskab` | `/opret-medlemskab` | Join/membership |
| `10.foreslaa-feature` | `/foreslaa-feature` | Feature suggestion landing (calls overlay) |
| `11.roadmap` | `/roadmap` | Public roadmap — authenticated only |

`/roadmap` is access-controlled via `access: site.login: true` in its page frontmatter. Unauthenticated visitors are redirected to `/login` by the Login plugin (`redirect_to_login: true`).

---

## Custom plugins

All three custom plugins follow the same structure: one PHP file, one YAML config, one `blueprints.yaml` for the admin panel form.

### roadmap

**Path:** `config/www/user/plugins/roadmap/`

Serves the public roadmap. Reads roadmap items from Flex Objects (`roadmap-items.yaml`) and handles AJAX vote submissions.

- `GET /roadmap` — page rendered by Twig template, items injected via `onPageInitialized`
- `POST /roadmap/vote` — AJAX endpoint; validates Grav nonce (`Utils::verifyNonce`), reads/writes vote counts in the YAML file

**CSRF protection:** Grav's `Utils::verifyNonce()` is the sole CSRF gate. There is no session-based nonce blacklist — it was removed because it caused 403 errors when users voted on multiple items quickly. See `decisions/ADR-001`.

### bug-report

**Path:** `config/www/user/plugins/bug-report/`

Handles bug report form submissions from the modal overlay.

- `POST /bug-report/submit` — validates form data, writes a new record to `flex-objects/bug-reports.yaml`, sends an email notification

### feature-suggestion

**Path:** `config/www/user/plugins/feature-suggestion/`

Handles feature suggestion form submissions from the modal overlay.

- `POST /feature-suggestion/submit` — validates form data, writes to `flex-objects/feature-suggestions.yaml`, sends an email notification

---

## Flex Objects data

All persistent structured data lives in `config/www/user/data/flex-objects/` as YAML files. Grav's Flex Objects plugin reads and writes these files directly — no database, no ORM.

| File | Contents |
|---|---|
| `roadmap-items.yaml` | Feature/bug items on the roadmap, with vote counts |
| `bug-reports.yaml` | Submitted bug reports |
| `feature-suggestions.yaml` | Submitted feature suggestions |
| `begivenheder.yaml` | Events (calendar) |
| `teammedlemmer.yaml` | Team members |
| `opgaver.yaml` | Tasks |
| `oenskeliste.yaml` | Wish list |
| `submission-tokens.yaml` | Deduplication tokens for form submissions |

---

## Theme

**Path:** `config/www/user/themes/byvaerkstederne/`

### CSS

Single file: `theme.css` (imported via `css/` folder). No preprocessor, no build step. Custom properties (`--space-*`, `--color-*`) define the design tokens.

### JavaScript

Single file: `js/site.js`. All frontend logic lives here as a collection of namespaced module objects. No bundler, no ES modules — plain IIFE-style assignments to `window.*` for cross-template access.

| Module | Purpose |
|---|---|
| `bvBugReport` | Bug report modal — `open()`, `close()`, form validation, POST to `/bug-report/submit` |
| `bvFeatureSuggestion` | Feature suggestion modal — `open()`, `close()`, form validation, POST to `/feature-suggestion/submit` |
| `bvRoadmap` | Roadmap vote buttons — nonce management, AJAX POST to `/roadmap/vote`, optimistic UI updates |

### Templates

**Main layouts:**

| File | Purpose |
|---|---|
| `base.html.twig` | Root layout — includes head, nav, footer, overlays |
| `default.html.twig` | Generic page template |
| `roadmap.html.twig` | Roadmap page with vote buttons |
| `foreslaa-feature.html.twig` | Feature suggestion landing — calls `bvFeatureSuggestion.open()` on load |

**Partials:**

| File | Purpose |
|---|---|
| `navigation.html.twig` | Desktop + mobile nav — community items excluded (footer-only) |
| `footer.html.twig` | Footer — includes auth-gated Fællesskab column |
| `bug_report_overlay.html.twig` | Bug report modal HTML |
| `feature_suggestion_overlay.html.twig` | Feature suggestion modal HTML |
| `login_overlay.html.twig` | Login modal HTML |
| `roadmap_card.html.twig` | Single roadmap item card with vote button |

---

## Authentication and access control

Grav Login plugin handles all authentication. User accounts are YAML files in `config/www/user/accounts/` (gitignored — bootstrapped via `make create-admin`).

**Auth-gated surfaces:**

| Surface | Gate |
|---|---|
| `/roadmap` page | `access: site.login: true` in page frontmatter + Login plugin `redirect_to_login` |
| Footer Fællesskab column | `{% if grav.user.authenticated and grav.user.authorized %}` in Twig |
| Bug report overlay | `{% if grav.user.authenticated %}` in Twig |
| Feature suggestion overlay | `{% if grav.user.authenticated %}` in Twig |

Community affordances (Forslå Feature, Roadmap, Rapportér fejl) appear **only** in the footer for authenticated users. They are absent from the main navigation, page body, and all other surfaces. See `decisions/ADR-001`.

---

## Docker

`docker-compose.yml` runs a single container: `lscr.io/linuxserver/grav:latest`.

```
Port:    8080 → 80
Volume:  ./config:/config
```

The linuxserver image initialises Grav at container start, installs vendor dependencies, and serves via Nginx. Runtime state (cache, logs, tmp, vendor) lives inside the container and is not committed to git (all gitignored).

### Common commands

```bash
make start         # docker compose up -d, wait for 200
make stop          # docker compose down
make restart       # docker compose restart
make logs          # tail container logs
make cache-clear   # bin/grav clearcache inside container
```

Note: the cache command is `bin/grav clearcache` — **not** `clear-cache` (no hyphen). The hyphenated form does not exist.

---

## Deployment

Deployment is scripted via `deploy/deploy.sh` with an environment argument (`prod`, `test`, `dev`, `staging`). The script packages the site and uploads it to the server.

```bash
make deploy        # deploy to production
make deploy-test   # deploy to test environment
```

Backups are pulled from the server with:

```bash
make backup-prod
make backup-test
```

---

## Testing

Playwright integration tests run against the live Docker site at `http://127.0.0.1:8080`. No mocks.

```
tests/
  anonymous.spec.js     No credentials required — runs in CI
  authenticated.spec.js Requires TEST_USERNAME + TEST_PASSWORD env vars
```

```bash
make test-install  # install Playwright + Chromium
make test          # run anonymous tests
make test-auth     # run authenticated tests
```

See `documentation/testing.md` for full details.

---

## Decisions log

Architecture decisions are recorded in `decisions/`. Each ADR is written once a feature is implemented and replaces the original spec file. The index is in `decisions/README.md`.

| ADR | Topic |
|---|---|
| ADR-001 | Navigation footer placement — community affordances are footer-only and auth-gated |
