#!/bin/bash
# SessionStart hook — installs the Node/Playwright test toolchain so tests
# and linters can run in Claude Code on the web sessions.
#
# Mirrors `make test-install`: npm dependencies + the Chromium browser
# Playwright drives. Idempotent and non-interactive; safe to re-run.
set -euo pipefail

# Only run in the remote (web) environment. Locally, contributors manage
# their own toolchain via `make test-install` and Docker.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

# Install JS dependencies. Prefer `npm install` over `npm ci` so a warm
# node_modules from the cached container layer is reused incrementally.
# This is a hard requirement — fail the hook if it doesn't succeed.
npm install

# Install the Chromium browser binary Playwright drives. This is
# best-effort: the download host (cdn.playwright.dev) and apt mirrors for
# system libraries must be reachable under the environment's network
# egress policy. If they aren't, the session still starts with npm deps
# installed — add `cdn.playwright.dev` to the environment's network egress
# allowlist to enable the browser-driven Playwright suite.
if npx playwright install chromium; then
  echo "✓ Playwright toolchain ready (npm deps + Chromium)"
else
  echo "⚠ npm deps installed, but the Chromium download was blocked." >&2
  echo "  Allowlist 'cdn.playwright.dev' in the environment's network" >&2
  echo "  egress settings to enable browser-driven Playwright tests." >&2
fi
