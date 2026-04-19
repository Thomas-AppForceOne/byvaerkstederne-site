.PHONY: setup start stop restart logs status clean check-deps lfs-pull open admin help reset-users reset-admin reset-data reset-cache reset-all create-admin deploy deploy-prod deploy-test deploy-dev deploy-staging backup-prod backup-test test test-headed test-auth test-install

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
		docker exec grav bash -c "cd /var/www/html && bin/plugin login new-user -u $$username -e $$email -p $$password -n '$$fullname' -t admin -s enabled -a admin.super" 2>/dev/null \
			|| docker exec grav bash -c "cd /app/www/public && bin/plugin login new-user -u $$username -e $$email -p $$password -n '$$fullname' -t admin -s enabled -a admin.super"; \
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
	@docker compose up -d
	@echo "Waiting for Grav to start..."
	@for i in 1 2 3 4 5 6 7 8 9 10; do \
		curl -s -o /dev/null http://localhost:8080 && break || sleep 2; \
	done
	@echo "Site is live at http://localhost:8080"

stop: ## Stop the site
	@docker compose down

restart: ## Restart the site
	@docker compose restart
	@echo "Restarted. Site at http://localhost:8080"

logs: ## Tail container logs
	@docker compose logs -f --tail=50

status: ## Show container status
	@docker compose ps

# ── Deploy ─────────────────────────────────────────────

deploy: deploy-prod ## Alias for deploy-prod

deploy-prod: ## Deploy to production (hackersbychoice.dk)
	@./deploy/deploy.sh prod

deploy-test: ## Deploy to test (hackersbychoice.dk/test)
	@./deploy/deploy.sh test

deploy-dev: ## Deploy to dev (hackersbychoice.dk/dev)
	@./deploy/deploy.sh dev

deploy-staging: ## Deploy to staging (hackersbychoice.dk/staging)
	@./deploy/deploy.sh staging

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
	@docker exec grav bash -c 'cd /var/www/html && bin/grav cache' 2>/dev/null || echo "Container not running. Start with: make start"

# ── Tests ──────────────────────────────────────────────

test-install: ## Install Playwright and browser binaries
	@npm install
	@npx playwright install chromium
	@echo "  ✓ Playwright ready"

test: ## Run all anonymous tests (no credentials needed)
	@curl -s -o /dev/null http://127.0.0.1:8080 || { echo "❌  Site not running. Run: make start"; exit 1; }
	@npx playwright test tests/anonymous.spec.js

test-headed: ## Run tests with browser visible (for debugging)
	@curl -s -o /dev/null http://127.0.0.1:8080 || { echo "❌  Site not running. Run: make start"; exit 1; }
	@npx playwright test tests/anonymous.spec.js --headed

test-auth: ## Run authenticated tests (requires TEST_USERNAME and TEST_PASSWORD)
	@curl -s -o /dev/null http://127.0.0.1:8080 || { echo "❌  Site not running. Run: make start"; exit 1; }
	@[ -n "$$TEST_USERNAME" ] && [ -n "$$TEST_PASSWORD" ] || { echo "❌  Set TEST_USERNAME and TEST_PASSWORD before running authenticated tests"; exit 1; }
	@npx playwright test tests/authenticated.spec.js

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
