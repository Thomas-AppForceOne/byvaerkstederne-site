#!/usr/bin/env bash
#
# Promotion gate for deploy.sh — guards the two tiers that must run the
# production line: staging and prod.
#
# Why this exists: deploy.sh records the branch, dirty-state and VERSION
# of every release into version.json, but nothing stopped staging/prod
# being deployed from a feature branch, a dirty tree, or (for prod) an
# untagged commit. The project runs main-promoted staging: staging is a
# faithful prod rehearsal, so it must ship the same `main` commit that
# prod will. Prod additionally requires the annotated release tag.
#
#   tier      checks
#   staging   (a) branch == main   (b) clean
#   prod      (a) branch == main   (b) clean   (c) HEAD tagged v<VERSION>
#   others    none (dev/test deploy freely from any branch)
#
# (a) and (b) carry loud per-tier escape hatches — emergencies happen
# (a hotfix from a detached HEAD, a known-trivial uncommitted tweak):
#
#   ALLOW_PROD_DEPLOY_OFF_MAIN=1     ALLOW_STAGING_DEPLOY_OFF_MAIN=1
#   ALLOW_PROD_DEPLOY_DIRTY=1        ALLOW_STAGING_DEPLOY_DIRTY=1
#
# (c) is a HARD precondition with no override: tagging is one command
# (`make tag-release`), so requiring it even in emergencies costs seconds
# and guarantees every production artifact is reproducible from a tag. An
# emergency hotfix simply tags its own commit first, then overrides (a).
#
# `git describe --exact-match` considers annotated tags only (lightweight
# tags are ignored unless --tags is passed), so (c) also enforces that the
# release tag is annotated.
#
# Source contract:
#   * Pure function — takes everything it needs as positional args, reads
#     only the ALLOW_*_DEPLOY_* env vars. No global state, no .env.deploy
#     dependency. Unit-testable against a fixture repo the way ssh-auth.sh
#     resolvers are.

# bv_promotion_gate <env> <branch> <is_dirty> <version> <project_dir>
#
#   env         the deploy tier (only "staging" and "prod" are gated)
#   branch      current branch name (e.g. from rev-parse --abbrev-ref HEAD)
#   is_dirty    "true" | "false" — working-tree dirty state
#   version     contents of the component VERSION file (e.g. "1.0.3")
#   project_dir absolute path to the git checkout to inspect
#
# Returns 0 if the deploy may proceed, 1 (with diagnostics on stderr,
# all checks reported) if it must be refused.
bv_promotion_gate() {
    local env="$1" branch="$2" is_dirty="$3" version="$4" project_dir="$5"

    # Only the production-line tiers are gated.
    case "$env" in
        staging|prod) ;;
        *) return 0 ;;
    esac

    local rc=0
    local tier_uc
    tier_uc="$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')"   # STAGING | PROD

    # (a) Branch must be main. Per-tier override via indirect expansion.
    if [ "$branch" != "main" ]; then
        local off_var="ALLOW_${tier_uc}_DEPLOY_OFF_MAIN"
        if [ "${!off_var:-}" = "1" ]; then
            printf '⚠️   %s deploy from branch %s (not main) — %s=1 override in effect.\n' "$env" "$branch" "$off_var" >&2
        else
            printf '❌  Refusing %s deploy from branch %s.\n' "$env" "$branch" >&2
            printf '    %s ships from main only (feature/* → develop → release/* → main).\n' "$env" >&2
            printf '    Emergency override:  %s=1 make deploy tier=%s\n' "$off_var" "$env" >&2
            rc=1
        fi
    fi

    # (b) Working tree must be clean.
    if [ "$is_dirty" = "true" ]; then
        local dirty_var="ALLOW_${tier_uc}_DEPLOY_DIRTY"
        if [ "${!dirty_var:-}" = "1" ]; then
            printf '⚠️   %s deploy with a dirty working tree — %s=1 override in effect.\n' "$env" "$dirty_var" >&2
        else
            printf '❌  Refusing %s deploy with uncommitted changes (working tree is dirty).\n' "$env" >&2
            printf '    Commit or stash first so the deploy matches a clean commit.\n' >&2
            printf '    Emergency override:  %s=1 make deploy tier=%s\n' "$dirty_var" "$env" >&2
            rc=1
        fi
    fi

    # (c) PROD ONLY: HEAD must carry an annotated tag matching v<VERSION>.
    # Hard — no override. --exact-match requires the tag to point directly
    # at HEAD; the absence of --tags restricts the search to annotated tags.
    if [ "$env" = "prod" ]; then
        local expected="v${version}"
        if ! git -C "$project_dir" describe --exact-match --match "$expected" HEAD >/dev/null 2>&1; then
            printf '❌  Refusing prod deploy: HEAD is not tagged %s (annotated).\n' "$expected" >&2
            printf '    config/www/VERSION says %s; the deployed commit must carry the matching tag.\n' "$version" >&2
            printf '    After merge to main:  make tag-release   (then re-run the deploy)\n' >&2
            rc=1
        fi
    fi

    return $rc
}
