.PHONY: setup start stop restart logs status clean check-deps lfs-pull open admin help reset-users reset-admin reset-data reset-cache reset-all create-admin deploy rollback migrate-atomic backup list-backups restore restore-scratch release-start release-status bump-version tag-release test test-headed test-auth test-install test-deploy test-backup-restore add-age-key list-age-keys retire-age-key

# Help menu groups. Each group lists its target NAMES; the descriptions are
# pulled live from each target's `## ` annotation so they never drift. A
# documented target missing from every group still shows under "Other", so a new
# command is never silently hidden from the menu.
GRP_DEV   := setup start stop restart status logs open admin cache-clear clean create-admin check-deps lfs-pull
GRP_TEST  := test test-headed test-auth test-deploy test-backup-restore test-install test-registration-throttle
GRP_SHIP  := release-start release-status bump-version tag-release deploy rollback migrate-atomic
GRP_TIER  := list-users delete-user cleanup-unverified registration-throttle push-data list-groups grant-rights revoke-rights list-supers grant-super revoke-super scheduler-token
GRP_DATA  := backup list-backups restore restore-scratch add-age-key list-age-keys retire-age-key
GRP_RESET := reset-users reset-admin reset-data reset-cache reset-all

# Default target — grouped help menu
help: ## Show this help
	@printf '\n  \033[1mByværkstederne — make commands\033[0m\n'
	@printf '  ══════════════════════════════════════\n'
	@d() { grep -E "^$$1:.*## " $(MAKEFILE_LIST) | head -1 | sed -E 's/.*## //'; }; \
	g() { printf '\n  \033[1m%s\033[0m\n' "$$1"; shift; for t in "$$@"; do printf '    \033[36m%-28s\033[0m %s\n' "$$t" "$$(d "$$t")"; done; }; \
	g "Local development"          $(GRP_DEV); \
	g "Testing"                    $(GRP_TEST); \
	g "Release & deploy"           $(GRP_SHIP); \
	g "Tier ops — members & data"  $(GRP_TIER); \
	g "Backup, restore & keys"     $(GRP_DATA); \
	g "Reset (destructive; local, or tier=...)"  $(GRP_RESET); \
	all=$$(grep -oE '^[a-zA-Z][a-zA-Z0-9_-]*:' $(MAKEFILE_LIST) | sed 's/://' | sort -u); \
	known=" $(GRP_DEV) $(GRP_TEST) $(GRP_SHIP) $(GRP_TIER) $(GRP_DATA) $(GRP_RESET) help "; \
	other=""; for t in $$all; do case "$$known" in *" $$t "*) ;; *) grep -qE "^$$t:.*## " $(MAKEFILE_LIST) && other="$$other $$t" ;; esac; done; \
	[ -n "$$other" ] && g "Other" $$other; \
	printf '\n'

# ── Setup ──────────────────────────────────────────────

setup: check-deps lfs-pull start seed-content create-admin ## Full first-time setup (check tools, pull LFS, start site, seed sample content, create admin)
	@echo ""
	@echo "  ✅  Setup complete!"
	@echo "  🌐  Site:  http://localhost:8080"
	@echo "  ⚙️   Admin: http://localhost:8080/admin"
	@echo ""

seed-content: ## Seed the local Grav with sample flex content (idempotent; see grav-seeds/sample-content)
	@CONTAINER=$$(node -e 'try { process.stdout.write(require("./scripts/discover-grav-port.js").discoverGravEnv(".").container) } catch (e) { process.exit(1) }' 2>/dev/null) || { \
		echo "❌  No Grav container for this worktree. Run: scripts/grav-up.sh . [port]"; exit 1; \
	}; \
	tests/fixtures/grav-seeds/sample-content/apply.sh "$$CONTAINER"

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
	docker exec -u abc -w /app/www/public "$$CONTAINER" bin/plugin login new-user \
		-u "$$username" -e "$$email" -p "$$password" -N "$$fullname" -t admin -s enabled -P b -n || exit 1; \
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

deploy: ## Atomic deploy (tier=dev|test|staging|prod|landing). prod is gated: clean main, tagged v<VERSION>
	@t="$(tier)"; \
	case "$$t" in \
	  dev|test|staging|prod|landing) ./deploy/deploy.sh "$$t" ;; \
	  "") echo "❌  Usage: make deploy tier=<dev|test|staging|prod|landing>"; exit 1 ;; \
	  *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging|prod|landing)"; exit 1 ;; \
	esac

release-start: ## Cut a release branch off develop + bump version (version=X.Y.Z [component=grav|landing])
	@v="$(version)"; \
	if [ -z "$$v" ]; then echo "❌  Usage: make release-start version=X.Y.Z [component=grav|landing]"; exit 1; fi; \
	comp="$(component)"; [ -z "$$comp" ] && comp="grav"; \
	case "$$comp" in \
	  grav|landing) ./deploy/release-start.sh "$$v" "$$comp" ;; \
	  *) echo "❌  Invalid component '$$comp' (allowed: grav|landing)"; exit 1 ;; \
	esac

release-status: ## Show develop↔main divergence (pending back-merge / unreleased commits)
	@./deploy/release-status.sh

bump-version: ## Bump version core, no tag (part=major|minor|patch [component=grav|landing] [pre=<label>] [no_commit=1])
	@p="$(part)"; \
	if [ -z "$$p" ]; then echo "❌  Usage: make bump-version part=major|minor|patch [component=grav|landing] [pre=<label>] [no_commit=1]"; exit 1; fi; \
	comp="$(component)"; [ -z "$$comp" ] && comp="grav"; \
	args="$$p $$comp"; \
	if [ "$(no_commit)" = "1" ]; then args="$$args --no-commit"; fi; \
	if [ -n "$(pre)" ]; then args="$$args --pre=$(pre)"; fi; \
	case "$$comp" in \
	  grav|landing) ./deploy/bump-version.sh $$args ;; \
	  *) echo "❌  Invalid component '$$comp' (allowed: grav|landing)"; exit 1 ;; \
	esac

tag-release: ## Tag the current (main) commit as a release (component=grav|landing [push=1])
	@comp="$(component)"; [ -z "$$comp" ] && comp="grav"; \
	args="$$comp"; \
	if [ "$(push)" = "1" ]; then args="$$args --push"; fi; \
	case "$$comp" in \
	  grav|landing) ./deploy/tag-release.sh $$args ;; \
	  *) echo "❌  Invalid component '$$comp' (allowed: grav|landing)"; exit 1 ;; \
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

delete-user: ## Delete a member account from a tier (tier=dev|test|staging|prod user=<username>, dry_run=1, yes=1, i_mean_it=1)
	@t="$(tier)"; u="$(user)"; \
	args=""; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	if [ -z "$$t" ] || [ -z "$$u" ]; then \
	  echo "❌  delete-user: missing required argument(s).  Got: tier='$$t' user='$$u'"; \
	  [ -z "$$t" ] && echo "    → 'tier' is empty (required: dev|test|staging|prod)"; \
	  [ -z "$$u" ] && echo "    → 'user' is empty (the account username to delete)"; \
	  echo "    Usage:   make delete-user tier=<dev|test|staging|prod> user=<username> [dry_run=1] [yes=1] [i_mean_it=1]"; \
	  echo "    Example: make delete-user tier=dev user=thomas"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/delete-user.sh "$$t" "$$u" $$args ;; \
	  *) echo "❌  delete-user: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

list-users: ## List member accounts on a tier (tier=dev|test|staging|prod)
	@t="$(tier)"; \
	if [ -z "$$t" ]; then \
	  echo "❌  list-users: missing 'tier'.  Got: tier='$$t'"; \
	  echo "    Usage:   make list-users tier=<dev|test|staging|prod>"; \
	  echo "    Example: make list-users tier=dev"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/list-users.sh "$$t" ;; \
	  *) echo "❌  list-users: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

activate-user: ## Activate a member whose confirmation email never arrived (tier=... user=<username|email>, state=enabled|disabled, dry_run=1, yes=1, i_mean_it=1)
	@t="$(tier)"; u="$(user)"; \
	args=""; \
	if [ -n "$(state)" ]; then args="$$args --state=$(state)"; fi; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	if [ -z "$$t" ] || [ -z "$$u" ]; then \
	  echo "❌  activate-user: missing required argument(s).  Got: tier='$$t' user='$$u'"; \
	  [ -z "$$t" ] && echo "    → 'tier' is empty (required: dev|test|staging|prod)"; \
	  [ -z "$$u" ] && echo "    → 'user' is empty (a username, or an email to resolve)"; \
	  echo "    Usage:   make activate-user tier=<dev|test|staging|prod> user=<username|email> [state=enabled|disabled] [dry_run=1] [yes=1] [i_mean_it=1]"; \
	  echo "    Example: make activate-user tier=dev user=anders@example.dk"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/activate-user.sh "$$t" "$$u" $$args ;; \
	  *) echo "❌  activate-user: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

reset-password: ## Reset a member's password on a tier (tier=... user=<username|email>, generate=1 to auto-generate+print, dry_run=1, yes=1, i_mean_it=1). Never pass the password as an argument — you are prompted, or use generate=1.
	@t="$(tier)"; u="$(user)"; \
	args=""; \
	if [ "$(generate)" = "1" ]; then args="$$args --generate"; fi; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	if [ -z "$$t" ] || [ -z "$$u" ]; then \
	  echo "❌  reset-password: missing required argument(s).  Got: tier='$$t' user='$$u'"; \
	  [ -z "$$t" ] && echo "    → 'tier' is empty (required: dev|test|staging|prod)"; \
	  [ -z "$$u" ] && echo "    → 'user' is empty (a username, or an email to resolve)"; \
	  echo "    Usage:   make reset-password tier=<dev|test|staging|prod> user=<username|email> [generate=1] [dry_run=1] [yes=1] [i_mean_it=1]"; \
	  echo "    Example: make reset-password tier=dev user=anders@example.dk generate=1"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/reset-password.sh "$$t" "$$u" $$args ;; \
	  *) echo "❌  reset-password: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

list-groups: ## List available user groups (repo groups.yaml; add tier=dev|test|staging|prod for a tier's deployed copy)
	@t="$(tier)"; \
	if [ -z "$$t" ]; then \
	  ./deploy/manage-groups.sh list; \
	else \
	  case "$$t" in \
	    dev|test|staging|prod) ./deploy/manage-groups.sh list "$$t" ;; \
	    *) echo "❌  list-groups: invalid tier '$$t' (allowed: dev|test|staging|prod, or omit for the repo copy)"; exit 1 ;; \
	  esac; \
	fi

grant-rights: ## Grant a group to a user on a tier (tier=... user=<username|email> group=<name>, dry_run=1, yes=1, i_mean_it=1)
	@t="$(tier)"; u="$(user)"; g="$(group)"; \
	args=""; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	if [ -z "$$t" ] || [ -z "$$u" ] || [ -z "$$g" ]; then \
	  echo "❌  grant-rights: missing required argument(s).  Got: tier='$$t' user='$$u' group='$$g'"; \
	  [ -z "$$t" ] && echo "    → 'tier' is empty (required: dev|test|staging|prod)"; \
	  [ -z "$$u" ] && echo "    → 'user' is empty (a username, or an email to resolve)"; \
	  [ -z "$$g" ] && echo "    → 'group' is empty (see: make list-groups)"; \
	  echo "    Usage:   make grant-rights tier=<dev|test|staging|prod> user=<username|email> group=<name> [dry_run=1] [yes=1] [i_mean_it=1]"; \
	  echo "    Example: make grant-rights tier=dev user=anders@example.dk group=organizers"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/manage-groups.sh grant "$$t" "$$u" "$$g" $$args ;; \
	  *) echo "❌  grant-rights: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

revoke-rights: ## Revoke a group from a user on a tier (tier=... user=<username|email> group=<name>, dry_run=1, yes=1, i_mean_it=1)
	@t="$(tier)"; u="$(user)"; g="$(group)"; \
	args=""; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	if [ -z "$$t" ] || [ -z "$$u" ] || [ -z "$$g" ]; then \
	  echo "❌  revoke-rights: missing required argument(s).  Got: tier='$$t' user='$$u' group='$$g'"; \
	  [ -z "$$t" ] && echo "    → 'tier' is empty (required: dev|test|staging|prod)"; \
	  [ -z "$$u" ] && echo "    → 'user' is empty (a username, or an email to resolve)"; \
	  [ -z "$$g" ] && echo "    → 'group' is empty (see: make list-groups)"; \
	  echo "    Usage:   make revoke-rights tier=<dev|test|staging|prod> user=<username|email> group=<name> [dry_run=1] [yes=1] [i_mean_it=1]"; \
	  echo "    Example: make revoke-rights tier=dev user=anders group=organizers"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/manage-groups.sh revoke "$$t" "$$u" "$$g" $$args ;; \
	  *) echo "❌  revoke-rights: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

list-supers: ## List super-admins on a tier (tier=dev|test|staging|prod)
	@t="$(tier)"; \
	if [ -z "$$t" ]; then \
	  echo "❌  list-supers: missing 'tier'.  Got: tier='$$t'"; \
	  echo "    Usage:   make list-supers tier=<dev|test|staging|prod>"; \
	  echo "    Example: make list-supers tier=dev"; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/manage-super.sh list "$$t" ;; \
	  *) echo "❌  list-supers: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

grant-super: ## Grant super-admin on a tier (tier=... user=<username|email>, dry_run=1, yes=1, i_mean_it=1)
	@t="$(tier)"; u="$(user)"; \
	args=""; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	if [ -z "$$t" ] || [ -z "$$u" ]; then \
	  echo "❌  grant-super: missing required argument(s).  Got: tier='$$t' user='$$u'"; \
	  [ -z "$$t" ] && echo "    → 'tier' is empty (required: dev|test|staging|prod)"; \
	  [ -z "$$u" ] && echo "    → 'user' is empty (a username, or an email to resolve)"; \
	  echo "    Usage:   make grant-super tier=<dev|test|staging|prod> user=<username|email> [dry_run=1] [yes=1] [i_mean_it=1]"; \
	  echo "    Example: make grant-super tier=dev user=test+admin@hackersbychoice.dk"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/manage-super.sh grant "$$t" "$$u" $$args ;; \
	  *) echo "❌  grant-super: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

revoke-super: ## Revoke super-admin on a tier (tier=... user=<username|email>, dry_run=1, yes=1, i_mean_it=1). Refuses the last super without i_mean_it=1.
	@t="$(tier)"; u="$(user)"; \
	args=""; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	if [ -z "$$t" ] || [ -z "$$u" ]; then \
	  echo "❌  revoke-super: missing required argument(s).  Got: tier='$$t' user='$$u'"; \
	  [ -z "$$t" ] && echo "    → 'tier' is empty (required: dev|test|staging|prod)"; \
	  [ -z "$$u" ] && echo "    → 'user' is empty (a username, or an email to resolve)"; \
	  echo "    Usage:   make revoke-super tier=<dev|test|staging|prod> user=<username|email> [dry_run=1] [yes=1] [i_mean_it=1]"; \
	  echo "    Example: make revoke-super tier=dev user=anders"; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/manage-super.sh revoke "$$t" "$$u" $$args ;; \
	  *) echo "❌  revoke-super: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

scheduler-token: ## Provision/rotate a tier's scheduler-trigger token (tier=dev|test|staging|prod, show=1 to print the URL, status=1, yes=1)
	@t="$(tier)"; \
	args=""; \
	if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	if [ "$(show)" = "1" ]; then args="$$args --show"; fi; \
	if [ "$(status)" = "1" ]; then args="$$args --status"; fi; \
	if [ -z "$$t" ]; then \
	  echo "❌  scheduler-token: missing 'tier'."; \
	  echo "    Usage:   make scheduler-token tier=<dev|test|staging|prod> [show=1] [status=1] [yes=1]"; \
	  echo "    Example: make scheduler-token tier=dev"; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/scheduler-token.sh "$$t" $$args ;; \
	  *) echo "❌  scheduler-token: invalid tier '$$t'"; exit 1 ;; \
	esac

cleanup-unverified: ## Remove unconfirmed accounts older than N min (tier=dev|test|staging|prod, max_age=10, apply=1, i_mean_it=1). Dry-run unless apply=1.
	@t="$(tier)"; \
	args=""; \
	if [ -n "$(max_age)" ]; then args="$$args --max-age=$(max_age)"; fi; \
	if [ "$(apply)" = "1" ]; then args="$$args --apply"; fi; \
	if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	if [ -z "$$t" ]; then \
	  echo "❌  cleanup-unverified: missing 'tier'.  Got: tier='$$t'"; \
	  echo "    Usage:   make cleanup-unverified tier=<dev|test|staging|prod> [max_age=10] [apply=1] [i_mean_it=1]"; \
	  echo "    Dry-run: make cleanup-unverified tier=dev max_age=10"; \
	  echo "    Delete:  make cleanup-unverified tier=dev max_age=10 apply=1"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/cleanup-unverified-users.sh "$$t" $$args ;; \
	  *) echo "❌  cleanup-unverified: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

registration-throttle: ## Toggle the registration throttle on a tier, live/no-redeploy (tier=dev|test|staging|prod state=on|off [i_mean_it=1])
	@t="$(tier)"; s="$(state)"; \
	args=""; \
	if [ "$(i_mean_it)" = "1" ]; then args="--i-mean-it"; fi; \
	if [ -z "$$t" ] || [ -z "$$s" ]; then \
	  echo "❌  registration-throttle: need both tier and state.  Got: tier='$$t' state='$$s'"; \
	  echo "    Usage:   make registration-throttle tier=<dev|test|staging|prod> state=<on|off> [i_mean_it=1]"; \
	  echo "    Example: make registration-throttle tier=dev state=on"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging|prod) ./deploy/throttle.sh "$$t" "$$s" $$args ;; \
	  *) echo "❌  registration-throttle: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	esac

test-registration-throttle: ## Check the throttle's current state on a tier — read-only burst, changes nothing (tier=dev|test|staging|prod [attempts=N] [i_mean_it=1 for prod])
	@t="$(tier)"; a="$(attempts)"; \
	if [ -z "$$t" ]; then \
	  echo "❌  test-registration-throttle: need a tier.  Got: tier='$$t'"; \
	  echo "    Usage:   make test-registration-throttle tier=<dev|test|staging|prod> [attempts=N]"; \
	  echo "    Example: make test-registration-throttle tier=staging   (expect THROTTLE ACTIVE)"; \
	  echo "             make test-registration-throttle tier=dev        (expect THROTTLE INACTIVE)"; \
	  echo "    Tip: check for a typo in the variable name (e.g. 'tire=' instead of 'tier=')."; \
	  exit 1; \
	fi; \
	case "$$t" in \
	  dev|test|staging) ./scripts/registration-throttle-burst.sh "$$t" $$a ;; \
	  prod) \
	    if [ "$(i_mean_it)" != "1" ]; then \
	      echo "❌  prod check fires real registrations at LIVE prod and will throttle your own IP there for ~1h. Re-run with i_mean_it=1."; exit 1; \
	    fi; \
	    PROD_OK=1 ./scripts/registration-throttle-burst.sh prod $$a ;; \
	  *) echo "❌  test-registration-throttle: invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
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

test-deploy: ## Run deploy-script regression tests (lint + unit + atomic-layout + rollback + migration + release-gate probes)
	@bash tests/deploy/lint-remote-ssh.sh
	@bash tests/deploy/unit-remote-run.sh
	@bash tests/deploy/unit-ssh-auth.sh
	@bash tests/deploy/unit-age-keychain.sh
	@bash tests/deploy/excludes-preserve-live-state.sh
	@bash tests/deploy/unit-state-symlink-guard.sh
	@bash tests/deploy/unit-htaccess.sh
	@bash tests/deploy/atomic-layout.sh
	@bash tests/deploy/rollback.sh
	@bash tests/deploy/migrate.sh
	@bash tests/deploy/skip-data-migration.sh
	@bash tests/deploy/promote-to-staging.sh
	@bash tests/deploy/promote-to-prod.sh
	@bash tests/deploy/unit-release-gate.sh
	@bash tests/deploy/tag-release.sh
	@bash tests/deploy/unit-build-id.sh
	@bash tests/deploy/unit-release-flow.sh
	@bash tests/deploy/release-start.sh
	@bash tests/deploy/unit-version-bump.sh
	@bash tests/deploy/unit-release-pr-guard.sh
	@bash tests/deploy/unit-promotion-no-email-sync.sh
	@bash tests/deploy/bump-version.sh
	@bash tests/deploy/unit-manage-groups.sh
	@bash tests/deploy/unit-manage-super.sh
	@bash tests/deploy/unit-activate-user.sh
	@bash tests/deploy/unit-reset-password.sh
	@bash tests/deploy/unit-reset-users.sh
	@bash tests/deploy/unit-reset-data.sh
	@bash tests/deploy/unit-delete-user.sh
	@bash tests/deploy/unit-list-users.sh
	@bash tests/deploy/unit-sample-content-seed.sh
	@bash tests/deploy/unit-push-data-guard.sh

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

reset-users: ## Delete all member accounts — local when no tier; on a tier keeps admins + seeds (tier=dev|test|staging, dry_run=1, yes=1; prod refused)
	@t="$(tier)"; \
	if [ -z "$$t" ]; then \
	  echo "Removing local user accounts (keeping thomasadmin)..."; \
	  find config/www/user/accounts -name "*.yaml" ! -name "thomasadmin.yaml" -delete 2>/dev/null || true; \
	  echo "  ✓ Users reset (only thomasadmin remains)"; \
	else \
	  args=""; \
	  if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	  if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	  if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	  case "$$t" in \
	    dev|test|staging) ./deploy/reset-users.sh "$$t" $$args ;; \
	    prod) \
	      echo "❌  'make reset-users tier=prod' is intentionally refused."; \
	      echo "    Bulk-deleting prod members is an operator-supervised operation."; \
	      echo "    Invoke the script directly so the gate is impossible to miss:"; \
	      echo "        ./deploy/reset-users.sh prod --i-mean-it"; \
	      exit 1 ;; \
	    *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging; prod refused)"; exit 1 ;; \
	  esac; \
	fi

reset-admin: ## Reset the LOCAL admin account (delete and recreate interactively; local-only)
	@if [ -n "$(tier)" ]; then \
	  echo "❌  reset-admin is local-only (got tier='$(tier)')."; \
	  echo "    For tier accounts use: make reset-password / activate-user / delete-user tier=$(tier) user=..."; \
	  exit 1; \
	fi
	@echo "Removing admin account (thomasadmin)..."
	@rm -f config/www/user/accounts/thomasadmin.yaml
	@$(MAKE) create-admin

reset-data: ## Delete all Flex Objects data — local when no tier (tier=dev|test|staging, dry_run=1, yes=1; prod refused)
	@t="$(tier)"; \
	if [ -z "$$t" ]; then \
	  echo "Deleting all Flex Objects data..."; \
	  rm -f config/www/user/data/flex-objects/*.yaml 2>/dev/null || true; \
	  echo "  ✓ All Flex Objects data deleted"; \
	else \
	  args=""; \
	  if [ "$(yes)" = "1" ]; then args="$$args --yes"; fi; \
	  if [ "$(dry_run)" = "1" ]; then args="$$args --dry-run"; fi; \
	  if [ "$(i_mean_it)" = "1" ]; then args="$$args --i-mean-it"; fi; \
	  case "$$t" in \
	    dev|test|staging) ./deploy/reset-data.sh "$$t" $$args ;; \
	    prod) \
	      echo "❌  'make reset-data tier=prod' is intentionally refused."; \
	      echo "    Wiping prod flex data destroys real member activity."; \
	      echo "    Invoke the script directly so the gate is impossible to miss:"; \
	      echo "        ./deploy/reset-data.sh prod --i-mean-it"; \
	      exit 1 ;; \
	    *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging; prod refused)"; exit 1 ;; \
	  esac; \
	fi

reset-cache: ## Clear Grav cache — local container when no tier, or on a tier (tier=dev|test|staging|prod)
	@t="$(tier)"; \
	if [ -z "$$t" ]; then \
	  $(MAKE) cache-clear; \
	else \
	  case "$$t" in \
	    dev|test|staging|prod) ./deploy/clear-cache.sh "$$t" ;; \
	    *) echo "❌  Invalid tier '$$t' (allowed: dev|test|staging|prod)"; exit 1 ;; \
	  esac; \
	fi

reset-all: ## Full LOCAL reset: users + data + cache + restart (local-only)
	@if [ -n "$(tier)" ]; then \
	  echo "❌  reset-all is local-only (got tier='$(tier)'). For a tier, run the pieces explicitly:"; \
	  echo "    make reset-users tier=$(tier)  &&  make reset-data tier=$(tier)  &&  make reset-cache tier=$(tier)"; \
	  exit 1; \
	fi
	@$(MAKE) reset-users reset-data
	@echo "Resetting all content to last commit..."
	@git checkout -- config/www/user/ 2>/dev/null || true
	@docker compose restart
	@echo ""
	@echo "  ✅  Full reset complete. Site at http://localhost:8080"
