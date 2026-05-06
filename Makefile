.PHONY: setup start stop restart logs status clean check-deps lfs-pull open admin help reset-users reset-admin reset-data reset-cache reset-all create-admin deploy deploy-prod deploy-test deploy-dev deploy-staging deploy-landing backup-prod backup-test test test-headed test-auth test-install test-deploy

# Default target
help: ## Show this help
	@echo ""
	@echo "  Byværkstederne — Development Commands"
	@echo "  ══════════════════════════════════════"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo ""

# ── Setup ──────────────────────────────────────────────

setup: check-deps lfs-pull start create-admin ## Full first-time setup (check tools, pull LFS, start site, create admin)
	@echo ""
	@echo "  ✅  Setup complete!"
	@echo "  🌐  Site:  http://localhost:8080"
	@echo "  ⚙️   Admin: http://localhost:8080/admin"
	@echo ""

create-admin: ## Create an admin account (interactive)
	@if [ ! -f config/www/user/accounts/thomasadmin.yaml ]; then \
		echo ""; \
		echo "  No admin account found. Let's create one."; \
		echo ""; \
		read -p "  Username: " username; \
		read -p "  Email: " email; \
		read -p "  Full name: " fullname; \
		read -s -p "  Password: " password; echo ""; \
		CONTAINER=$$(node -e 'try { process.stdout.write(require("./scripts/discover-grav-port.js").discoverGravEnv(".").container) } catch (e) { process.exit(1) }' 2>/dev/null) || { \
			echo "❌  No Grav container for this worktree. Run: scripts/grav-up.sh . [port]"; exit 1; \
		}; \
		docker exec -w /app/www/public "$$CONTAINER" bin/plugin login new-user -u $$username -e $$email -p $$password -n "$$fullname" -t admin -s enabled -a admin.super; \
		echo ""; \
		echo "  ✓ Admin account '$$username' created"; \
	else \
		echo "  Admin account already exists. Skipping."; \
	fi

check-deps: ## Verify all required tools are installed
	@echo "Checking dependencies..."
	@command -v docker >/dev/null 2>&1 || { echo "❌  Docker is not installed. Get it at https://docker.com/get-started"; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "❌  Docker is not running. Please start Docker Desktop."; exit 1; }
	@echo "  ✓ Docker"
	@command -v docker compose >/dev/null 2>&1 || docker-compose --version >/dev/null 2>&1 || { echo "❌  Docker Compose is not available."; exit 1; }
	@echo "  ✓ Docker Compose"
	@command -v git >/dev/null 2>&1 || { echo "❌  Git is not installed."; exit 1; }
	@echo "  ✓ Git"
	@command -v git-lfs >/dev/null 2>&1 || { echo "⚠️  Git LFS not found. Installing..."; brew install git-lfs 2>/dev/null || { echo "❌  Could not install Git LFS. Install manually: https://git-lfs.com"; exit 1; }; }
	@git lfs install --skip-smudge >/dev/null 2>&1
	@echo "  ✓ Git LFS"
	@echo "All dependencies OK ✓"

lfs-pull: ## Pull all LFS files (images, videos, etc.)
	@echo "Pulling LFS files..."
	@git lfs pull
	@echo "LFS files up to date ✓"

# ── Docker ─────────────────────────────────────────────

start: ## Start the site (Docker)
	@scripts/grav-up.sh . 8080

stop: ## Stop the site
	@scripts/grav-down.sh .

restart: stop start ## Restart the site

logs: ## Tail container logs
	@docker compose logs -f --tail=50

status: ## Show container status
	@docker compose ps

# ── Deploy ─────────────────────────────────────────────

deploy: deploy-prod ## Alias for deploy-prod

deploy-prod: ## Deploy to production (www.byvaerkstederne.dk — separate hosting)
	@./deploy/deploy.sh prod

deploy-staging: ## Deploy to staging (staging.hackersbychoice.dk)
	@./deploy/deploy.sh staging

deploy-test: ## Deploy to test (test.hackersbychoice.dk)
	@./deploy/deploy.sh test

deploy-dev: ## Deploy to dev (dev.hackersbychoice.dk)
	@./deploy/deploy.sh dev

deploy-landing: ## Deploy the apex selector page (hackersbychoice.dk)
	@./deploy/deploy.sh landing

# ── Backup ─────────────────────────────────────────────

backup-prod: ## Backup production data (accounts, flex objects, media)
	@./deploy/backup.sh prod

backup-test: ## Backup test environment data
	@./deploy/backup.sh test

# ── Utilities ──────────────────────────────────────────

open: ## Open the site in default browser
	@open http://localhost:8080 2>/dev/null || xdg-open http://localhost:8080 2>/dev/null || echo "Open http://localhost:8080 in your browser"

admin: ## Open the admin panel in default browser
	@open http://localhost:8080/admin 2>/dev/null || xdg-open http://localhost:8080/admin 2>/dev/null || echo "Open http://localhost:8080/admin in your browser"

clean: ## Remove Docker volumes and cache (keeps content)
	@docker compose down -v
	@echo "Containers and volumes removed."

cache-clear: ## Clear Grav cache
	@CONTAINER=$$(node -e 'try { process.stdout.write(require("./scripts/discover-grav-port.js").discoverGravEnv(".").container) } catch (e) { process.exit(1) }' 2>/dev/null) || { \
		echo "❌  No Grav container for this worktree. Run: scripts/grav-up.sh . [port]"; exit 1; \
	}; \
	docker exec -u abc -w /app/www/public "$$CONTAINER" bin/grav clearcache

# ── Tests ──────────────────────────────────────────────

test-install: ## Install Playwright and browser binaries
	@npm install
	@npx playwright install chromium
	@echo "  ✓ Playwright ready"

test: ## Run all anonymous tests (auto-sources ~/.gan-secrets/workshop-site.env if present)
	@PORT="$${GRAV_PORT}"; \
	if [ -z "$$PORT" ]; then PORT=$$(node scripts/discover-grav-port.js 2>/dev/null || echo ""); fi; \
	if [ -z "$$PORT" ]; then \
		echo "❌  No Grav container for this worktree. Run: scripts/grav-up.sh . [port]"; exit 1; \
	fi; \
	curl -s -o /dev/null "http://127.0.0.1:$$PORT" || { echo "❌  Grav not responding on port $$PORT (container is registered but not serving). Check: docker ps ; scripts/grav-down.sh . ; scripts/grav-up.sh . $$PORT"; exit 1; }; \
	if [ -f $$HOME/.gan-secrets/workshop-site.env ]; then \
		set -a; . $$HOME/.gan-secrets/workshop-site.env; set +a; \
		if [ -z "$$TEST_ADMIN_PASSWORD" ]; then \
			echo "❌  ~/.gan-secrets/workshop-site.env exists but TEST_ADMIN_PASSWORD is empty"; exit 1; \
		fi; \
		echo "🔑  Sourced test credentials from ~/.gan-secrets/workshop-site.env"; \
	else \
		echo "ℹ️   No ~/.gan-secrets/workshop-site.env — running in anonymous-only mode"; \
	fi; \
	echo "Running tests against http://127.0.0.1:$$PORT"; \
	GRAV_PORT=$$PORT npx playwright test tests/anonymous.spec.js

test-headed: ## Run tests with browser visible (for debugging)
	@PORT="$${GRAV_PORT}"; \
	if [ -z "$$PORT" ]; then PORT=$$(node scripts/discover-grav-port.js 2>/dev/null || echo ""); fi; \
	if [ -z "$$PORT" ]; then \
		echo "❌  No Grav container for this worktree. Run: scripts/grav-up.sh . [port]"; exit 1; \
	fi; \
	curl -s -o /dev/null "http://127.0.0.1:$$PORT" || { echo "❌  Grav not responding on port $$PORT (container is registered but not serving). Check: docker ps ; scripts/grav-down.sh . ; scripts/grav-up.sh . $$PORT"; exit 1; }; \
	if [ -f $$HOME/.gan-secrets/workshop-site.env ]; then set -a; . $$HOME/.gan-secrets/workshop-site.env; set +a; fi; \
	echo "Running tests against http://127.0.0.1:$$PORT (headed)"; \
	GRAV_PORT=$$PORT npx playwright test tests/anonymous.spec.js --headed

test-deploy: ## Run deploy-script regression tests (rsync excludes preserve live state)
	@bash tests/deploy/excludes-preserve-live-state.sh

test-auth: ## Run authenticated tests (auto-sources ~/.gan-secrets/workshop-site.env)
	@PORT="$${GRAV_PORT}"; \
	if [ -z "$$PORT" ]; then PORT=$$(node scripts/discover-grav-port.js 2>/dev/null || echo ""); fi; \
	if [ -z "$$PORT" ]; then \
		echo "❌  No Grav container for this worktree. Run: scripts/grav-up.sh . [port]"; exit 1; \
	fi; \
	curl -s -o /dev/null "http://127.0.0.1:$$PORT" || { echo "❌  Grav not responding on port $$PORT (container is registered but not serving). Check: docker ps ; scripts/grav-down.sh . ; scripts/grav-up.sh . $$PORT"; exit 1; }; \
	if [ -f $$HOME/.gan-secrets/workshop-site.env ]; then set -a; . $$HOME/.gan-secrets/workshop-site.env; set +a; fi; \
	[ -n "$$TEST_PASSWORD" ] && [ -n "$$TEST_ADMIN_PASSWORD" ] || { echo "❌  TEST_PASSWORD and TEST_ADMIN_PASSWORD required (set via ~/.gan-secrets/workshop-site.env)"; exit 1; }; \
	echo "Running tests against http://127.0.0.1:$$PORT"; \
	GRAV_PORT=$$PORT npx playwright test tests/authenticated.spec.js

# ── Reset ──────────────────────────────────────────────

reset-users: ## Delete all user accounts (except admin)
	@echo "Removing user accounts (keeping thomasadmin)..."
	@find config/www/user/accounts -name "*.yaml" ! -name "thomasadmin.yaml" -delete 2>/dev/null; true
	@echo "  ✓ Users reset (only thomasadmin remains)"

reset-admin: ## Reset admin account (delete and recreate interactively)
	@echo "Removing admin account (thomasadmin)..."
	@rm -f config/www/user/accounts/thomasadmin.yaml
	@$(MAKE) create-admin

reset-data: ## Delete all Flex Objects data
	@echo "Deleting all Flex Objects data..."
	@rm -f config/www/user/data/flex-objects/*.yaml 2>/dev/null; true
	@echo "  ✓ All Flex Objects data deleted"

reset-cache: cache-clear ## Alias for cache-clear

reset-all: reset-users reset-data ## Full reset: users + data + cache + restart
	@echo "Resetting all content to last commit..."
	@git checkout -- config/www/user/ 2>/dev/null || true
	@docker compose restart
	@echo ""
	@echo "  ✅  Full reset complete. Site at http://localhost:8080"
