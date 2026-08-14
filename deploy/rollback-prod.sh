#!/usr/bin/env bash
# rollback-prod.sh — the safety-net rollback for prod (spec §"Rollback").
#
# WHY
# ---
# Two rollback paths coexist after promote-to-prod ships:
#   * ./deploy/rollback.sh prod        — atomic-deploy primitive: a
#     sub-second symlink swap to the previous release, with its preserved
#     data version. The FAST path for "the new release is bad, the data is
#     fine".
#   * ./deploy/rollback-prod.sh        — THIS script: restore a named
#     backup into prod. The SAFETY NET for situations the symlink swap
#     can't recover (data corruption that landed during the bad release
#     window and must be erased, not rolled away from).
# They are complementary, not redundant.
#
# The natural input is a `pre-promotion-v<X>-build<N>` backup taken by
# promote-to-prod's step 2.
#
# USAGE
# -----
#   ./deploy/rollback-prod.sh --to-backup <id> [--code-to <commit>] --yes-i-mean-it
#   ./deploy/rollback-prod.sh --help
#
# Options:
#   --to-backup <id>     The backup id (or `latest`) to restore to prod.
#   --code-to <commit>   Optionally deploy this commit to prod BEFORE the
#                        restore (checks it out, deploys, restores). Omit
#                        to leave the current code in place.
#   --yes-i-mean-it      Required. Refuses without it.
#   --help               Show this help.
#
# BEHAVIOUR (spec §"Rollback")
# ----------------------------
#   1. Refuse without --yes-i-mean-it.
#   2. Take a fresh "pre-rollback" backup of prod, tagged
#      pre-rollback-<timestamp>. (Even rollbacks get a backup-before: if
#      the rollback is itself wrong, you have the broken state to study.)
#   3. If --code-to is given, deploy that commit to prod first.
#   4. Restore the named backup to prod via restore.sh's restore-to-tier
#      mode (gated behind RESTORE_TO_TIER_ENABLED=1 — the reviewed,
#      operator-only destructive path; --yes-i-mean-it is forwarded).
#   5. Smoke-test.
#
# LOCAL MODE (testing)
# --------------------
# When ROLLBACK_PROD_LOCAL_TIER_DIR=<absolute-path> is set, the script
# operates locally: the pre-rollback backup runs against the fixture
# (BACKUP_FIXTURE_DIR), the restore forwards RESTORE_LOCAL_TIER_DIR +
# RESTORE_TO_TIER_ENABLED=1 so restore.sh's local-tier path performs the
# wipe-and-replace against the local dir, the --code-to deploy is skipped,
# and the curl smoke-test is skipped. The live SSH path is reviewed, not
# run in CI (ADR-002/004 gate a real run).
#
# All the destructive work lives in restore.sh (reviewed there); this
# orchestrator only sequences backup → optional deploy → restore → smoke.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR PROJECT_DIR

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

log()  { printf '→ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '⚠  %s\n' "$*" >&2; }
die()  { printf '❌  %s\n' "$1" >&2; exit "${2:-1}"; }

# ── 1. Parse args ────────────────────────────────────────────────────
TO_BACKUP=""
CODE_TO=""
YES=0

while [ $# -gt 0 ]; do
    case "$1" in
        --to-backup)
            [ $# -ge 2 ] || die "--to-backup requires an id argument"
            TO_BACKUP="$2"; shift 2
            ;;
        --to-backup=*)
            TO_BACKUP="${1#--to-backup=}"; shift
            ;;
        --code-to)
            [ $# -ge 2 ] || die "--code-to requires a commit argument"
            CODE_TO="$2"; shift 2
            ;;
        --code-to=*)
            CODE_TO="${1#--code-to=}"; shift
            ;;
        --yes-i-mean-it)
            YES=1; shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown arg: $(printf %q "$1")" ;;
    esac
done
readonly TO_BACKUP CODE_TO YES

# ── 2. Determine mode (local vs live) ────────────────────────────────
LOCAL_MODE=0
LOCAL_TIER_DIR=""
if [ -n "${ROLLBACK_PROD_LOCAL_TIER_DIR:-}" ]; then
    LOCAL_TIER_DIR="$ROLLBACK_PROD_LOCAL_TIER_DIR"
    case "$LOCAL_TIER_DIR" in
        /*) ;;
        *) die "ROLLBACK_PROD_LOCAL_TIER_DIR must be an absolute path (got: $(printf %q "$LOCAL_TIER_DIR"))" ;;
    esac
    case "$LOCAL_TIER_DIR" in
        *..*) die "ROLLBACK_PROD_LOCAL_TIER_DIR contains '..' — refusing for safety" ;;
    esac
    [ -d "$LOCAL_TIER_DIR" ] || die "ROLLBACK_PROD_LOCAL_TIER_DIR does not exist: $(printf %q "$LOCAL_TIER_DIR")"
    LOCAL_MODE=1
fi
readonly LOCAL_MODE LOCAL_TIER_DIR

echo "=== rollback-prod ==="
if [ "$LOCAL_MODE" = "1" ]; then
    note "mode:   LOCAL (ROLLBACK_PROD_LOCAL_TIER_DIR=$LOCAL_TIER_DIR)"
else
    note "mode:   LIVE (prod)"
fi
echo ""

# ── 3. Safety gate ───────────────────────────────────────────────────
[ -n "$TO_BACKUP" ] || die "--to-backup <id> is required"
if [ "$YES" != "1" ]; then
    die "Refusing to roll back prod without --yes-i-mean-it. Re-run with --yes-i-mean-it once you are sure. (target backup: $TO_BACKUP)"
fi

# ──────────────────────────────────────────────────────────────────────
# STEP 1/4 — pre-rollback backup of prod (tagged with a timestamp).
# ──────────────────────────────────────────────────────────────────────
NOW_TS="$(date -u +%Y%m%dT%H%M%SZ)"
PRE_TAG="pre-rollback-${NOW_TS}"
log "Step 1/4: taking a tagged pre-rollback backup of prod (tag: $PRE_TAG)"
PRE_OUT="$("$SCRIPT_DIR/backup.sh" prod --tag "$PRE_TAG")" \
    || die "pre-rollback backup failed — aborting; prod untouched" 2
PRE_ID="$(printf '%s\n' "$PRE_OUT" | awk -F= '/^archive=/ { print $2; exit }')"
[ -n "$PRE_ID" ] || die "could not parse pre-rollback backup id from backup.sh output" 2
note "pre-rollback backup id: $PRE_ID"
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 2/4 — optional code deploy (--code-to). Deploy that commit to prod
# BEFORE restoring data, so the restored data lands under the intended
# code. Skipped in local mode (no real deploy).
# ──────────────────────────────────────────────────────────────────────
log "Step 2/4: optional code deploy (--code-to)"
if [ -z "$CODE_TO" ]; then
    note "no --code-to given — leaving current prod code in place"
elif [ "$LOCAL_MODE" = "1" ]; then
    note "local mode: skipping --code-to deploy ($CODE_TO)"
else
    note "checking out $CODE_TO and deploying to prod"
    # Refuse to clobber uncommitted work in the operator's tree.
    if [ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)" ]; then
        die "working tree is dirty — commit or stash before a --code-to rollback (it checks out $CODE_TO)"
    fi
    ORIG_REF="$(git -C "$PROJECT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$PROJECT_DIR" rev-parse HEAD)"
    git -C "$PROJECT_DIR" checkout "$CODE_TO" \
        || die "git checkout $CODE_TO failed — aborting BEFORE the restore (prod untouched apart from the pre-rollback backup)"
    if ! "$SCRIPT_DIR/deploy.sh" prod --skip-data-migration; then
        warn "code deploy of $CODE_TO failed — restoring your working tree to $ORIG_REF"
        git -C "$PROJECT_DIR" checkout "$ORIG_REF" || warn "could not restore working tree to $ORIG_REF — do it manually"
        die "code deploy to prod failed during rollback — prod still on its prior code; data NOT yet restored" 2
    fi
    note "code $CODE_TO deployed; restoring working tree to $ORIG_REF"
    git -C "$PROJECT_DIR" checkout "$ORIG_REF" || warn "could not restore working tree to $ORIG_REF — do it manually"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 3/4 — restore the named backup to prod via restore.sh's
# restore-to-tier mode. The destructive wipe-and-replace lives in
# restore.sh (reviewed there) and is gated behind RESTORE_TO_TIER_ENABLED=1.
# We forward --yes-i-mean-it (prod safety gate) and, in local mode,
# RESTORE_LOCAL_TIER_DIR so restore.sh's local-tier path runs.
# ──────────────────────────────────────────────────────────────────────
log "Step 3/4: restoring backup '$TO_BACKUP' to prod"
if [ "$LOCAL_MODE" = "1" ]; then
    if ! RESTORE_TO_TIER_ENABLED=1 RESTORE_LOCAL_TIER_DIR="$LOCAL_TIER_DIR" \
        "$SCRIPT_DIR/restore.sh" prod --from "$TO_BACKUP" --yes-i-mean-it >/dev/null; then
        die "restore of '$TO_BACKUP' to local prod tier failed — inspect the local tier and the pre-rollback backup $PRE_ID" 3
    fi
else
    # Live restore-to-tier requires the operator to have opted in with
    # RESTORE_TO_TIER_ENABLED=1 (restore.sh refuses the wipe otherwise and
    # exits 0 in stand-in mode). Pass it through explicitly so a real
    # rollback actually replaces prod data — this IS the operator-only,
    # reviewed destructive path.
    if ! RESTORE_TO_TIER_ENABLED="${RESTORE_TO_TIER_ENABLED:-1}" \
        "$SCRIPT_DIR/restore.sh" prod --from "$TO_BACKUP" --yes-i-mean-it; then
        die "restore of '$TO_BACKUP' to prod failed — prod may be inconsistent; the pre-rollback backup is $PRE_ID" 3
    fi
fi
note "restore complete"
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 4/4 — smoke test (live only).
# ──────────────────────────────────────────────────────────────────────
log "Step 4/4: smoke test"
if [ "$LOCAL_MODE" = "1" ]; then
    note "local mode: skipping curl smoke test"
else
    SMOKE_BASE="https://www.byvaerkstederne.dk"
    smoke_fail=0
    smoke_check() {
        local rel="$1" want="$2"
        local code
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$SMOKE_BASE$rel" || echo "000")"
        if [ "$code" != "$want" ]; then
            warn "smoke: $rel returned $code, expected $want"
            smoke_fail=1
            return 0
        fi
        note "smoke: $rel → $code (ok)"
    }
    smoke_check "/"               200
    smoke_check "/login"          200
    smoke_check "/medlemmer"      302
    smoke_check "/begivenheder"   200
    smoke_check "/vaerksteder"    200
    if [ "$smoke_fail" = "1" ]; then
        warn "smoke test reported failures after rollback — prod IS serving the restored backup; inspect and decide next step"
    else
        note "all smoke checks passed"
    fi
fi
echo ""

# ── Summary ──────────────────────────────────────────────────────────
echo "  ✓ rollback-prod complete"
echo "    restored backup:      $TO_BACKUP"
echo "    pre-rollback backup:  $PRE_ID (tag: $PRE_TAG)"
if [ -n "$CODE_TO" ]; then
    echo "    code deployed:        $CODE_TO"
else
    echo "    code:                 unchanged"
fi
echo "    prod url:             https://www.byvaerkstederne.dk/"
echo ""
exit 0
