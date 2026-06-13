#!/usr/bin/env bash
#
# Build-identity helpers for deploy.sh — additive, machine-readable
# version surfaces emitted into version.json.
#
# IMPORTANT — these do NOT change the BUILD file contract. Per
# specifications/archive/semantic_versioning_specification.md, the BUILD
# file is a single integer (`git rev-list --count HEAD`) and the footer's
# site-version plugin (VersionReader::BUILD_REGEX = /^\d+$/) and
# backup-meta.schema.yaml both depend on that. These helpers leave BUILD
# alone and add two extra fields to version.json (which apex/index.php
# reads by key, tolerating unknown keys):
#
#   git_describe — the tag-relative build identity, e.g. v1.0.1-3-gda85dfb
#                  (or the bare short sha when no matching annotated tag
#                  is reachable). Component-scoped via the tag glob.
#   semver       — SemVer 2.0.0 string with build metadata:
#                  <version>+<build>.g<sha>[.dirty]  e.g. 1.0.1+247.gda85dfb
#
# Both are pure functions so they unit-test against fixture repos the way
# release-gate.sh / ssh-auth.sh do.

# bv_compute_git_describe <project_dir> <tag_glob>
#
# Echoes `git describe` scoped to the component's annotated tags. Notes:
#   * No --tags flag → lightweight tags are ignored (annotated only),
#     matching the prod gate and the tagger.
#   * --match <tag_glob> restricts to the component namespace
#     (v[0-9]* for the Grav site, landing-v[0-9]* for the apex landing).
#   * --always falls back to the abbreviated sha when no matching
#     annotated tag is reachable, so it never hard-fails.
#   * --dirty appends -dirty when the working tree has uncommitted
#     changes (which deploy.sh ships verbatim, so the marker is honest).
# Echoes empty on a non-repo / no-commit tree; the caller falls back.
bv_compute_git_describe() {
    local project_dir="$1" tag_glob="$2"
    git -C "$project_dir" describe --match "$tag_glob" --always --dirty 2>/dev/null || true
}

# bv_compute_semver <version> <build> <sha> [is_dirty]
#
# Assembles a SemVer-2.0.0 string: the core version from the VERSION
# file plus build metadata after '+'. Build metadata is dot-separated
# identifiers — here <build> (the commit count) and g<sha> (git marker
# + short sha), plus a trailing `dirty` identifier when the tree is
# dirty. All produced identifiers are [0-9A-Za-z-], so the result is a
# valid SemVer build-metadata string.
bv_compute_semver() {
    local version="$1" build="$2" sha="$3" is_dirty="${4:-false}"
    local meta="${build}.g${sha}"
    if [ "$is_dirty" = "true" ]; then
        meta="${meta}.dirty"
    fi
    printf '%s+%s\n' "$version" "$meta"
}
