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
│           ├── data/flex-objects/  All structured data (YAML flat files)
│           ├── pages/              Content pages (Markdown + frontmatter)
│           ├── plugins/            Custom plugins (PHP)
│           └── themes/
│               └── byvaerkstederne/
│                   ├── css/        Stylesheet(s)
│                   ├── js/         site.js (all frontend logic)
│                   └── templates/  Twig templates + partials
├── decisions/                      Architecture Decision Records
├── deploy/                         Deployment and backup scripts
├── documentation/                  Developer documentation (not deployed)
├── specifications/                 Pre-implementation specs for planned features
├── tests/                          Playwright test suite
├── docker-compose.yml
├── Makefile
└── CLAUDE.md                       Agent instructions
```

`config/` is the only folder Docker mounts (`./config:/config`). Everything else lives outside the container and is never served publicly.

---

## Data layer

Persistent structured data lives in `config/www/user/data/flex-objects/` as YAML files. Grav's Flex Objects plugin reads and writes these directly — no database, no ORM. User accounts are YAML files in `config/www/user/accounts/` (gitignored — bootstrapped via `make create-admin`).

---

## Frontend

All JavaScript lives in a single file: `config/www/user/themes/byvaerkstederne/js/site.js`. Logic is organised as namespaced module objects assigned to `window.*` — no bundler, no ES modules, compatible with how Grav injects scripts.

---

## Authentication and access control

Grav Login plugin handles all authentication. Access to individual pages is controlled via `access:` frontmatter. UI surfaces that should only appear for authenticated users are gated in Twig with `{% if grav.user.authenticated and grav.user.authorized %}`.

Community affordances (Forslå Feature, Roadmap, Rapportér fejl) appear only in the footer for authenticated users — not in the main navigation or anywhere else. See `decisions/ADR-001`.

---

## Docker

`docker-compose.yml` runs a single container: `lscr.io/linuxserver/grav:latest` on port 8080.

```bash
make start         # docker compose up -d, wait for 200
make stop          # docker compose down
make logs          # tail container logs
make cache-clear   # bin/grav clearcache inside container
```

Note: the cache command is `bin/grav clearcache` — **not** `clear-cache` (no hyphen).

---

## Deployment

Scripted via `deploy/deploy.sh` with an environment argument (`prod`, `test`, `dev`, `staging`).

```bash
make deploy        # production
make deploy-test   # test environment
make backup-prod   # pull backup from production
```

---

## Decisions log

Architecture decisions are recorded in `decisions/`. Each ADR is written after a feature is implemented and replaces the spec file. See `decisions/README.md` for the index.
