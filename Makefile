.PHONY: setup start stop restart logs status clean check-deps lfs-pull open admin help reset-users reset-admin reset-data reset-cache reset-all create-admin deploy rollback migrate-atomic backup list-backups restore restore-scratch test test-headed test-auth test-install test-deploy test-backup-restore add-age-key list-age-keys retire-age-key

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

create-admin: ## Create a super-admin account (interactive)
	@echo ""; \
	echo "  Create a super-admin account."; \
	echo ""; \
	read -p "  Username: " username; \
	if [ -f config/www/user/accounts/$$username.yaml ]; then \
		echo "  ❌  Account '$$username' already exists at config/www/user/accounts/$$username.yaml. Pick a different username or remove the file first."; \
		exit 1; \
	fi; \
	read -p "  Email: " email; \
	read -p "  Full name: " fullname; \
	read -s -p "  Password: " password; echo ""; \
	CONTAINER=$$(node -e 'try { process.stdout.write(require("./scripts/discover-grav-port.js").discoverGravEnv(".").container) } catch (e) { process.exit(1) }' 2>/dev/null) || { \
		echo "❌  No Grav container for this worktree. Run: scripts/grav-up.sh . [port]"; exit 1; \
	}; \
	docker exec -w /app/www/public "$$CONTAINER" bin/plugin login new-user \
		-u "$$username" -e "$$email" -p "$$password" -N "$$fullname" -t admin -s enabled -P b || exit 1; \
	docker exec -w /app/www/public "$$CONTAINER" sh -c "awk '/^  admin:/{print; print \"    super: true\"; next}1' user/accounts/$$username.yaml > user/accounts/$$username.yaml.tmp && mv user/accounts/$$username.yaml.tmp user/accounts/$$username.yaml" || { \
		echo "❌  Failed to elevate '$$username' to super-admin (Login plugin's new-user grants admin.login + site.login via -P b but not admin.super; this step injects 'super: true' into the generated YAML)."; \
		exit 1; \
	}; \
	echo ""; \
	echo "  ✓ Super-admin account '$$username' created"

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
	@git lfs install --skip-smudge --force >/dev/null 2>&1 || true
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
	@CONTAINER=$$(node -e 'try { process.stdout.write(require("./scripts/discover-grav-port.js").discoverGravEnv(".").container) } catch (e) { process.exit(1) }' 2>/dev/null) || { \
		echo "❌  No Grav container for this worktree. Run: scripts/grav-up.sh . [port]"; exit 1; \
	}; \
	docker logs -f --tail=50 "$$CONTAINER"

status: ## Show container status
	@CONTAINER=$$(node -e 'try { process.stdout.write(require("./scripts/discover-grav-port.js").discoverGravEnv(".").container) } catch (e) { process.exit(0) }' 2>/dev/null); \
	if [ -n "$$CONTAINER" ]; then \
		docker ps --filter "name=^$$CONTAINER$$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'; \
	else \
		echo "(no Grav container registered for this checkout — run: scripts/grav-up.sh . [port])"; \
	fi

# ── Tier-parameterised commands ────────────────────────
#
# Tier is passed as a Make variable: `tier=<env>`. Each target validates
# the value against the closed set before invoking the script, so a
# typo can never reach the live remote. Restoring prod is intentionally
# refused at the Make layer — the operator must invoke the script
# directly so the RESTORE_TO_TIER_ENABLED + --yes-i-mean-it gates are
# impossible to miss. Same posture for migrate-atomic on prod.
#
# Examples:
#   make deploy tier=dev
#   make rollback tier=test
#   make migrate-atomic tier=staging
#   make backup tier=prod
#   make restore tier=dev from=<id>   # add RESTORE_TO_TIER_ENABLED=1 to actually wipe

deploy: ## Atomic deploy (tier=dev|test|staging|prod|landing)
	@t="$(tier)"; \
	case "$$t" in \
	  dev|test|staging|prod|landing) ./deploy/deploy.sh "$$t" ;; \
	  "") echo "❌  Usage: make deploy tier=<dev|test|staging|prod|landing>"; exit 1 ;; \
	  *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging|prod|landing)"; exit 1 ;; \
	esac

rollback: ## Roll back a tier to its previous release (tier=dev|test|staging|prod)
	@t="$(tier)"; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/rollback.sh "$$t" ;; \
	  "") echo "❌  Usage: make rollback tier=<dev|test|staging|prod>"; exit 1 ;; \
	  *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

push-data: ## Push local flex-objects YAML to a tier (tier=dev|test|staging|prod, files=<comma-list>, dry_run=1, yes=1, i_mean_it=1)
	@t="$(tier)"; \
	args=""; \
	if [ -n "$(files)" ]; then args="$$args --files=$(files)"; fi; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/push-data.sh "$$t" $$args ;; \
	  "") echo "❌  Usage: make push-data tier=<dev|test|staging|prod> [files=<a.yaml,b.yaml>] [dry_run=1] [yes=1]"; exit 1 ;; \
	  *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

migrate-atomic: ## Migrate a tier to atomic layout — one-time supervised (tier=dev|test|staging; prod refused)
	@t="$(tier)"; \
	case "$$t" in \
	  dev|test|staging) ./deploy/migrate-to-atomic-layout.sh "$$t" ;; \
	  prod) \
	    echo ""; \
	    echo "❌  'make migrate-atomic tier=prod' is intentionally refused."; \
	    echo ""; \
	    echo "    Prod migration is a one-time, operator-supervised, irreversible-"; \
	    echo "    without-restore operation. Invoke the script directly with the"; \
	    echo "    --i-mean-it flag so the gate is impossible to miss:"; \
	    echo ""; \
	    echo "        ./deploy/migrate-to-atomic-layout.sh prod --i-mean-it"; \
	    echo ""; \
	    echo "    See ./deploy/migrate-to-atomic-layout.sh --help for the seven-step"; \
	    echo "    sequence and the recovery path on failure."; \
	    echo ""; \
	    exit 1 ;; \
	  "") echo "❌  Usage: make migrate-atomic tier=<dev|test|staging>"; exit 1 ;; \
	  *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging; prod refused)"; exit 1 ;; \
	esac

backup: ## Backup a tier's data (tier=dev|test|staging|prod)
	@t="$(tier)"; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/backup.sh "$$t" ;; \
	  "") echo "❌  Usage: make backup tier=<dev|test|staging|prod>"; exit 1 ;; \
	  *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

list-backups: ## List backup ids available for restore (optional tier=dev|test|staging|prod)
	@./deploy/list-backups.sh $(tier)

restore: ## Restore a tier from a backup (tier=<env> from=<id> [allow_cross_tier=1]; RESTORE_TO_TIER_ENABLED=1 to actually wipe; prod refused)
	@t="$(tier)"; f="$(from)"; xt="$(allow_cross_tier)"; \
	xt_flag=""; [ "$$xt" = "1" ] && xt_flag="--allow-cross-tier"; \
	case "$$t" in \
	  dev|test|staging) \
	    if [ -z "$$f" ]; then echo "❌  Usage: make restore tier=$$t from=<id> [allow_cross_tier=1]"; exit 1; fi; \
	    ./deploy/restore.sh "$$t" --from "$$f" $$xt_flag ;; \
	  prod) \
	    echo ""; \
	    echo "❌  'make restore tier=prod' is intentionally refused."; \
	    echo ""; \
	    echo "    Restoring prod is a destructive, operator-supervised operation."; \
	    echo "    Invoke the script directly so the safety gates are impossible"; \
	    echo "    to miss:"; \
	    echo ""; \
	    echo "        RESTORE_TO_TIER_ENABLED=1 ./deploy/restore.sh prod \\"; \
	    echo "          --from <id> --yes-i-mean-it"; \
	    echo ""; \
	    exit 1 ;; \
	  "") echo "❌  Usage: make restore tier=<dev|test|staging> from=<id>"; exit 1 ;; \
	  *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging; prod refused)"; exit 1 ;; \
	esac

restore-scratch: ## Restore a backup into a scratch dir for inspection (to=<dir> [from=<id|latest>])
	@if [ -z "$(to)" ]; then echo "❌  Usage: make restore-scratch to=<dir> [from=<id>]"; exit 1; fi
	@if [ -n "$(from)" ]; then \
		./deploy/restore.sh --to $(to) --from $(from); \
	else \
		./deploy/restore.sh --to $(to); \
	fi

# ── Utilities ──────────────────────────────────────────

open: ## Open the site in default browser
	@open http://localhost:8080 2>/dev/null || xdg-open http://localhost:8080 2>/dev/null || echo "Open http://localhost:8080 in your browser"

admin: ## Open the admin panel in default browser
	@open http://localhost:8080/admin 2>/dev/null || xdg-open http://localhost:8080/admin 2>/dev/null || echo "Open http://localhost:8080/admin in your browser"

clean: ## Remove Docker volumes and cache (keeps content)
	@CONTAINER=$$(node -e 'try { process.stdout.write(require("./scripts/discover-grav-port.js").discoverGravEnv(".").container) } catch (e) { process.exit(0) }' 2>/dev/null); \
	if [ -n "$$CONTAINER" ]; then \
		scripts/grav-down.sh . >/dev/null 2>&1 || true; \
		docker rm -f "$$CONTAINER" >/dev/null 2>&1 || true; \
		docker volume ls -q --filter "label=com.docker.compose.project=$$CONTAINER" | xargs -r docker volume rm >/dev/null 2>&1 || true; \
		rm -f .gan/port-registry.json; \
		echo "Container $$CONTAINER + per-checkout volumes removed."; \
	else \
		echo "(no Grav container registered for this checkout — nothing to clean)"; \
	fi

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

add-age-key: ## Generate an age keypair, store private in Keychain, append public to deploy/age-recipients.txt (NAME=<label>)
	@if [ -z "$(NAME)" ]; then echo "❌  Usage: make add-age-key NAME=<label>"; exit 1; fi
	@./deploy/manage-age-keys.sh generate $(NAME)

list-age-keys: ## Show recipients in deploy/age-recipients.txt + which ones have a private key in your local Keychain
	@./deploy/manage-age-keys.sh list

retire-age-key: ## Remove an age key from deploy/age-recipients.txt (NAME=<label> [DELETE_KEYCHAIN=1])
	@if [ -z "$(NAME)" ]; then echo "❌  Usage: make retire-age-key NAME=<label> [DELETE_KEYCHAIN=1]"; exit 1; fi
	@if [ "$(DELETE_KEYCHAIN)" = "1" ]; then \
		./deploy/manage-age-keys.sh retire $(NAME) --delete-keychain; \
	else \
		./deploy/manage-age-keys.sh retire $(NAME); \
	fi

test-deploy: ## Run deploy-script regression tests (lint + unit + atomic-layout + rollback + migration probes)
	@bash tests/deploy/lint-remote-ssh.sh
	@bash tests/deploy/unit-remote-run.sh
	@bash tests/deploy/unit-ssh-auth.sh
	@bash tests/deploy/unit-age-keychain.sh
	@bash tests/deploy/excludes-preserve-live-state.sh
	@bash tests/deploy/atomic-layout.sh
	@bash tests/deploy/rollback.sh
	@bash tests/deploy/migrate.sh

test-backup-restore: ## Run backup/restore tooling tests (bats)
	@command -v bats >/dev/null 2>&1 || { echo "❌  bats not installed. Run: brew install bats-core"; exit 1; }
	@command -v age  >/dev/null 2>&1 || { echo "❌  age not installed. Run: brew install age"; exit 1; }
	@bats tests/deploy/backup-restore.bats

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
