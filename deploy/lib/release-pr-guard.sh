#!/usr/bin/env bash
#
# Release-PR guard — the pure check behind the `release-pr-guard` CI job
# (specifications/ci_release_protection_part1_specification.md).
#
# Moves the release invariants that today live only in the local `make`
# tooling (`bv_promotion_gate`, `release-start`) "left" to the pull
# request, so they hold for every merge path into `main`, regardless of
# who merges or how.
#
# bv_release_pr_guard asserts, for a PR whose base is `main`:
#
#   1. Head is a release branch         (release/* or hotfix/*)
#   2. Component resolves from the head  (grav | landing)
#   3. Head VERSION is a clean SemVer    (^X.Y.Z$, no -dev/-rc suffix)
#   4. Head VERSION is bumped            (> base main's VERSION)
#   5. Tag <prefix><VERSION> is free     (no annotated/lightweight tag)
#
# Rules 1 and 2 are structural: if the head is not a recognised release
# branch there is nothing further to check, so they short-circuit with a
# single diagnostic. Rules 3-5 are reported together — a multiply-broken
# PR surfaces every applicable violation in one run — with rules 4 and 5
# gated on rule 3 (a pre-release / malformed version cannot be compared
# or sensibly tag-checked; they are reported "not evaluated" instead).
#
# The recognised component set is a FIXED, closed set of two — grav and
# landing. It is NOT data-driven: adding a component is a deliberate code
# change to the Rule 2 `case` block below (see the note at its catch-all
# `*)` arm), not a caller argument or external configuration. This is
# intended by the spec (rule 2), not an oversight.
#
# Pure function: takes the head branch name, the checkout dir, and the
# base ref as positional args; reads the head VERSION from the working
# tree and the base VERSION + tags from git. Unit-tested against a
# fixture repo the way release-flow.sh / release-gate.sh are.

# Source the SemVer comparator (rule 4) relative to this file so callers
# need only source release-pr-guard.sh.
_BV_GUARD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=deploy/lib/version-bump.sh
. "$_BV_GUARD_LIB_DIR/version-bump.sh"

# bv_release_pr_guard <head_ref> <repo> <base_ref>
#
#   head_ref   PR head branch name (e.g. from github.head_ref)
#   repo       path to the checked-out PR head
#   base_ref   git ref for the base branch (e.g. "main" / "origin/main")
#
# The checkout MUST carry the base ref and tags (the workflow fetches
# them; the default shallow pull_request checkout does not). Returns 0
# if the PR may merge into main, 1 (all violations on stderr) if not.
bv_release_pr_guard() {
    local head_ref="$1" repo="$2" base_ref="$3"

    # ── Rule 1: head is a release branch ──────────────────────────────
    case "$head_ref" in
        release/*|hotfix/*) ;;
        *)
            printf '❌  [rule 1] head "%s" is not a release branch — main accepts only release/* or hotfix/* heads.\n' "$head_ref" >&2
            return 1
            ;;
    esac

    # ── Rule 2: component resolves from the branch ────────────────────
    # Shell globs: [0-9] pins the char after the v (so release/version-*
    # is rejected); * absorbs the dotted SemVer remainder.
    local version_file tag_prefix component
    case "$head_ref" in
        release/v[0-9]*|hotfix/v[0-9]*)
            component="grav";    version_file="config/www/VERSION"; tag_prefix="v" ;;
        release/landing-v[0-9]*|hotfix/landing-v[0-9]*)
            component="landing"; version_file="apex/VERSION";       tag_prefix="landing-v" ;;
        # Closed set by design (spec rule 2). To add a component, add an arm
        # ABOVE this one mapping its branch globs to <version_file> + <tag_prefix>.
        *)
            printf '❌  [rule 2] cannot resolve component from head "%s" (expected release/v* | release/landing-v* | hotfix/v* | hotfix/landing-v*).\n' "$head_ref" >&2
            return 1
            ;;
    esac

    local rc=0

    # Head VERSION from the working tree (the checkout is the PR head).
    local head_version=""
    if [ -f "$repo/$version_file" ]; then
        head_version="$(tr -d '[:space:]' < "$repo/$version_file")"
    else
        printf '❌  [rule 3] %s does not exist on the PR head (component: %s).\n' "$version_file" "$component" >&2
        rc=1
    fi

    # ── Rule 3: version is a clean release SemVer ─────────────────────
    local clean=0
    if [ -n "$head_version" ]; then
        if bv_is_clean_semver "$head_version"; then
            clean=1
        else
            printf '❌  [rule 3] %s is "%s" — pre-release version must be finalised (expected clean X.Y.Z, no -dev/-rc suffix) before it reaches main.\n' "$version_file" "$head_version" >&2
            rc=1
        fi
    fi

    # Base VERSION (numeric core — main should already be clean, but
    # strip a suffix defensively so a stray -dev never breaks rule 4).
    local base_version base_core=""
    base_version="$(git -C "$repo" show "$base_ref:$version_file" 2>/dev/null | tr -d '[:space:]')"
    base_core="${base_version%%[-+]*}"

    # ── Rule 4: version is bumped (presupposes rule 3) ────────────────
    if [ "$clean" -eq 1 ]; then
        if [ -z "$base_version" ]; then
            printf '❌  [rule 4] could not read base %s at %s (is the base ref fetched?).\n' "$version_file" "$base_ref" >&2
            rc=1
        elif ! bv_is_clean_semver "$base_core"; then
            printf '❌  [rule 4] base %s at %s is "%s" — no clean X.Y.Z core to compare against.\n' "$version_file" "$base_ref" "$base_version" >&2
            rc=1
        else
            local cmp
            if ! cmp="$(bv_semver_compare "$head_version" "$base_core")"; then
                printf '❌  [rule 4] internal: version comparison failed for head %s (%s) vs base %s (%s) — both were expected clean X.Y.Z.\n' "$version_file" "$head_version" "$base_ref" "$base_core" >&2
                rc=1
            elif [ "$cmp" != "1" ]; then
                printf '❌  [rule 4] version not bumped: head %s (%s) is not greater than base %s (%s).\n' "$version_file" "$head_version" "$base_ref" "$base_version" >&2
                rc=1
            fi
        fi
    else
        printf '⤬   [rule 4] not evaluated — version is not a clean release SemVer (see rule 3).\n' >&2
    fi

    # ── Rule 5: tag is free (presupposes rule 3) ──────────────────────
    if [ "$clean" -eq 1 ]; then
        local tag="${tag_prefix}${head_version}"
        # `git tag -l <name>` lists annotated AND lightweight tags; the
        # name carries only dots (literal in a tag pattern), no globs.
        if [ -n "$(git -C "$repo" tag -l "$tag")" ]; then
            printf '❌  [rule 5] tag "%s" already exists (annotated or lightweight) — that version has already shipped; choose a higher version.\n' "$tag" >&2
            rc=1
        fi
    else
        printf '⤬   [rule 5] not evaluated — version is not a clean release SemVer (see rule 3).\n' >&2
    fi

    if [ "$rc" -eq 0 ]; then
        printf '✅  release-pr-guard: %s release %s passes all checks (clean bumped SemVer, free tag %s%s).\n' \
            "$component" "$head_version" "$tag_prefix" "$head_version" >&2
    fi
    return "$rc"
}
