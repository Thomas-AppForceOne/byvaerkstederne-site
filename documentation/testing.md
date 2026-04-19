# Testing

## Overview

The project uses [Playwright](https://playwright.dev) for integration tests. Tests run against the real Docker site at `http://localhost:8080` — no mocks, no stubs. This mirrors how the GAN evaluator verifies sprints and gives the highest confidence that the site behaves correctly end-to-end.

PHPUnit for PHP unit tests was considered and ruled out. The Grav plugins are tightly coupled to Grav's service container, event lifecycle, and HTTP globals — unit testing them in isolation would require mocking the entire framework, which costs more than it's worth. Playwright covers the same surface area at the HTTP/browser layer.

---

## Setup

Tests live in `tests/`. Dependencies are in `package.json` at the repo root.

**First time setup:**

```bash
npm install
npx playwright install chromium
```

Or via Make:

```bash
make test-install
```

The Docker site must be running before tests execute:

```bash
make start   # starts Docker if not already running
make test    # runs all tests
```

---

## Running tests

| Command | What it does |
|---|---|
| `make test` | Run all tests headlessly |
| `make test-headed` | Run with browser visible (useful for debugging) |
| `make test-auth` | Run authenticated tests (requires credentials — see below) |
| `npx playwright test tests/anonymous.spec.js` | Run a single spec file |
| `npx playwright test --grep "footer"` | Run tests matching a pattern |
| `npx playwright show-report` | Open the HTML report from the last run |

---

## Test structure

```
tests/
  anonymous.spec.js     Tests that require no login — run anywhere, always
  authenticated.spec.js Tests that require a logged-in user — skipped if no credentials set
```

### Anonymous tests (`anonymous.spec.js`)

No credentials needed. These cover:

- **Navigation** — verifies Forslå Feature, Roadmap, and Rapportér fejl are absent from desktop and mobile nav
- **Footer** — verifies the Fællesskab column is hidden for anonymous users
- **Access control** — verifies `/roadmap` redirects to login
- **Smoke** — verifies core pages return 200, theme assets load, no JS console errors

### Authenticated tests (`authenticated.spec.js`)

Skipped automatically when credentials are not set. These cover:

- **Navigation** — verifies the three items are absent from nav even when logged in
- **Footer** — verifies the Fællesskab column is visible and all three triggers work
- **Roadmap** — verifies the page renders and vote add/remove works without errors

---

## Authenticated test credentials

Set these environment variables before running:

```bash
export TEST_USERNAME=yourusername
export TEST_PASSWORD=yourpassword
make test-auth
```

Or inline:

```bash
TEST_USERNAME=yourusername TEST_PASSWORD=yourpassword npx playwright test tests/authenticated.spec.js
```

Create a local `.env.test` file (gitignored) and source it:

```bash
# .env.test
export TEST_USERNAME=yourusername
export TEST_PASSWORD=yourpassword
```

```bash
source .env.test && make test-auth
```

Use a dedicated test account — not your personal admin account. Create one via:

```bash
make create-admin
```

---

## Adding new tests

1. Add a new `*.spec.js` file in `tests/`
2. Import from `@playwright/test`
3. Use `page.goto('/')` — the base URL is `http://localhost:8080` by default

```js
const { test, expect } = require('@playwright/test');

test('example', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveTitle(/Byværkstederne/);
});
```

Keep anonymous and authenticated tests in separate files so the anonymous suite always runs cleanly in CI without needing credentials.

---

## Configuration

`playwright.config.js` at the repo root. Key settings:

| Setting | Value | Notes |
|---|---|---|
| `baseURL` | `http://localhost:8080` | Override with `BASE_URL` env var |
| `timeout` | 30s | Generous for Docker startup lag |
| `retries` | 1 | One retry on failure before marking failed |
| `trace` | on first retry | Saves a trace file for debugging failures |
| `screenshot` | on failure | Saved to `playwright-report/` |

---

## CI (future)

The test suite is ready to run in GitHub Actions. A workflow would:

1. Start the Docker stack
2. Wait for `http://localhost:8080` to respond
3. Run `make test` (anonymous tests only — authenticated tests require secrets)
4. Upload the Playwright HTML report as an artifact

This is not yet configured. See `documentation/ci.md` when it is.

---

## What is not tested

| Area | Why |
|---|---|
| PHP unit logic | Grav plugin coupling makes isolation impractical — covered by integration tests |
| Twig template rendering in isolation | Grav renders templates; integration tests cover the output |
| YAML data format | Verified by the integration tests that POST and read back data |
| Admin panel | Out of scope — admin flows are internal tooling |

---

## Deployment note

The `documentation/` folder is at the repo root, outside `config/www/`. Docker mounts only `./config:/config`, so this folder is never served by the Grav container. No deployment configuration is needed to keep it off public-facing sites.
