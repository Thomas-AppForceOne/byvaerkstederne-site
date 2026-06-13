#!/usr/bin/env bash
#
# Release-flow helpers — shared by deploy/release-start.sh and
# deploy/release-status.sh to police the branch strategy:
#
#     develop → release/* → main → develop
#
# The one invariant that drifts in practice is the final back-merge
# (main → develop): a release lands on main but nobody merges main back
# into develop, so develop silently falls behind the released code.
# bv_count_commits_ahead is the primitive both scripts use to detect it.
#
# Pure function (takes refs as args), so it unit-tests against a fixture
# repo with local develop/main branches the way release-gate.sh does.

# bv_count_commits_ahead <repo> <base_ref> <tip_ref>
#
# Echoes the number of commits reachable from <tip_ref> but not from
# <base_ref> — i.e. `git rev-list --count <base_ref>..<tip_ref>`.
#
# For the back-merge guard call it as (base=develop, tip=main): a
# non-zero result means main carries commits develop hasn't received,
# so the main → develop back-merge is pending.
#
# Echoes 0 when either ref is missing (so a fresh repo with no main
# branch yet doesn't read as "pending").
bv_count_commits_ahead() {
    local repo="$1" base="$2" tip="$3"
    # Both refs must resolve, else there's nothing to compare → 0.
    git -C "$repo" rev-parse --verify --quiet "$base" >/dev/null || { echo 0; return 0; }
    git -C "$repo" rev-parse --verify --quiet "$tip"  >/dev/null || { echo 0; return 0; }
    git -C "$repo" rev-list --count "${base}..${tip}" 2>/dev/null || echo 0
}
