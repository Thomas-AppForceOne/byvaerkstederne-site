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

## Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| [Docker Desktop](https://docker.com/get-started) | 24+ | Runs the Grav container |
| [Git](https://git-scm.com) | 2.30+ | Version control |
| [Git LFS](https://git-lfs.com) | 3.0+ | Stores images/videos efficiently |

> `make setup` will check for all dependencies and attempt to install Git LFS if missing.

## Commands

Run `make help` to see all available commands:

| Command | Description |
|---------|-------------|
| `make setup` | Full first-time setup |
| `make start` | Start the site |
| `make stop` | Stop the site |
| `make restart` | Restart the site |
| `make deploy` | Deploy to production (one.com) |
| `make logs` | Tail container logs |
| `make open` | Open site in browser |
| `make admin` | Open admin panel |
| `make cache-clear` | Clear Grav cache |
| `make reset-users` | Delete all user accounts (except admin) |
| `make reset-data` | Reset Flex Objects data to last commit |
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
| `/vaerksteder/kreativ-fitness` | Public | Kreativ Fitness |
| `/vaerksteder/det-groenne-faellesskab` | Public | Det Grønne Fællesskab |
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
main              ← production releases only
develop           ← integration branch, deployed to /test
feature/*         ← working branches
```

| Action | Commands |
|--------|---------|
| Start new feature | `git checkout -b feature/my-feature develop` |
| Deploy feature to dev | `make deploy-dev` |
| Merge to test | `git checkout develop && git merge feature/my-feature` then `make deploy-test` |
| Release to production | `git checkout main && git merge develop` then `make deploy-prod` |

## Environments

| Environment | URL | Deploy command | Branch |
|------------|-----|---------------|--------|
| **Production** | hackersbychoice.dk | `make deploy-prod` | `main` |
| **Test** | hackersbychoice.dk/test | `make deploy-test` | `develop` |
| **Dev** | hackersbychoice.dk/dev | `make deploy-dev` | `feature/*` |
| **Staging** | hackersbychoice.dk/staging | `make deploy-staging` | `main` + prod data |
| **Local** | localhost:8080 | `make start` | any branch |

Credentials are in `.env.deploy` (git-ignored). Copy `.env.deploy.example` to get started.

## Backup

```bash
make backup-prod    # Backup production data (accounts, flex objects, pages, media)
make backup-test    # Backup test environment data
```

Backups are stored locally in `backups/` (git-ignored) as timestamped snapshots. Last 30 backups are kept, older ones are pruned automatically. Ready to sync to NAS or cloud storage.

## Reset (Development)

| Command | What it does |
|---------|-------------|
| `make reset-users` | Delete all user accounts except admin |
| `make reset-data` | Reset Flex Objects data to last git commit |
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

## Contact

**Byværkstederne i Hundested**
Nørregade 11, 3390 Hundested
kontakt@byvaerkstederne.dk
