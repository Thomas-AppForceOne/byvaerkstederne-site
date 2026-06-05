# Testing

## Approach

Playwright integration tests run against the real Docker site — no mocks, no stubs. This gives the highest confidence that the site behaves correctly end-to-end and mirrors how the GAN evaluator verifies sprints.

PHPUnit was considered and ruled out. The Grav plugins are tightly coupled to Grav's service container, event lifecycle, and HTTP globals — unit testing them in isolation would require mocking the entire framework, which costs more than it's worth.

---

## Setup

Tests live in `tests/`. Dependencies are in `package.json` at the repo root.

```bash
make test-install   # install Playwright + Chromium (first time only)
make start          # start Docker site
make test           # run tests
```

---

## Running tests

| Command | What it does |
|---|---|
| `make test` | Run anonymous tests headlessly |
| `make test-headed` | Run with browser visible (debugging) |
| `make test-auth` | Run authenticated tests (requires credentials) |
| `npx playwright test --grep "pattern"` | Run tests matching a pattern |
| `npx playwright show-report` | Open HTML report from last run |

---

## Authenticated tests

Authenticated tests are skipped automatically when credentials are not set. Set them before running:

```bash
export TEST_USERNAME=yourusername
export TEST_PASSWORD=yourpassword
make test-auth
```

Or create a local `.env.test` (gitignored) and source it:

```bash
source .env.test && make test-auth
```

Use a dedicated test account — not your personal admin account (`make create-admin`).

---

## Adding tests

- Anonymous tests go in `tests/anonymous.spec.js` — no credentials, always runnable
- Authenticated tests go in `tests/authenticated.spec.js` — skipped without credentials
- Keep them separate so the anonymous suite always runs cleanly without credentials

The base URL is `http://127.0.0.1:8080` (uses `127.0.0.1` explicitly — on macOS, `localhost` may resolve to IPv6 while Docker only binds IPv4).

---

## Configuration

`playwright.config.js` at the repo root. Override `baseURL` with the `BASE_URL` env var if needed.
