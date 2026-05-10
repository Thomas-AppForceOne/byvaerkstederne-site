#!/usr/bin/env bash
#
# =============================================================================
# Byværkstederne — One-time migration from the in-place layout to the
#                  atomic-release layout.
# =============================================================================
#
# Usage:
#   ./deploy/migrate-to-atomic-layout.sh <env>            # dev/test/staging
#   ./deploy/migrate-to-atomic-layout.sh prod --i-mean-it
#
# Environments (closed set, validated before any path is touched):
#   dev, test, staging, prod
#
# What it does (the seven-step sequence — see the source spec
# §One-time migration, mirrored here line-for-line so an operator
# reading this header gets the full procedure without leaving the file):
#
#   1. SANITY CHECK — refuse if the tier is already atomic. Three
#      independent signals are checked before step 2 is even
#      considered:
#         a. <tier> is already a symlink (test -L)
#         b. <tier>data/ already exists as a directory
#         c. <tier>-releases/ already exists with at least one entry
#      Any one of these fires the refusal; a "mixed signal" condition
#      (e.g. <tier> is a real dir but <tier>data/v0/ already exists)
#      exits with a distinct diagnostic so the operator notices the
#      inconsistency.
#
#   2. PRE-FLIGHT BACKUP — invoke ./deploy/backup.sh <env>. If backup
#      exits non-zero, abort BEFORE any state move. The recovery
#      path on a downstream failure is "restore from this backup
#      via deploy/restore.sh"; the script refuses to start without
#      that snapshot in hand.
#
#   3. CREATE <tier>data/v0/ AND MOVE STATE SUBTREES — via mv
#      (rename within a filesystem). Bit-identity follows from the
#      filesystem semantics. The four state subtrees the source
#      spec enumerates:
#         user/accounts/                      → <tier>data/v0/user/accounts/
#         user/data/                          → <tier>data/v0/user/data/
#         user/config/security.yaml           → <tier>data/v0/user/config/security.yaml
#         user/env/<env>/config/security.yaml → <tier>data/v0/user/env/<env>/config/security.yaml
#      Plus the logs sidecar:
#         logs/                               → <tier>data/logs/
#
#   4. CREATE <tier>-releases/migrate-bootstrap-<UTC-timestamp>/ AND
#      MOVE THE REST OF THE LIVE TREE IN — at directory granularity
#      (mv ./<entry> bootstrap/<entry> per top-level entry). The
#      bootstrap release id has shape `migrate-bootstrap-YYYYMMDDTHHMMSS`,
#      which is INTENTIONALLY DIFFERENT from the standard release-id
#      regex `^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$`. A future reader who
#      grep's <tier>-releases/ for "migrate-bootstrap-" knows this is
#      the seam release; the next deploy.sh run will produce a
#      conventional `<UTC-timestamp>-<git-sha-short>` id.
#
#   5. WIRE SYMLINKS — call bv_wire_release_symlinks (the same helper
#      Sprint 1's deploy.sh uses). Five symlinks per §Symlink contract,
#      all relative-path targets. Idempotent (ln -sfn).
#
#   6. REPLACE THE <tier> DIRECTORY WITH A SYMLINK — this is the
#      brief offline window the source spec calls "single-digit-
#      second in practice". Bound: rmdir the now-empty <tier>/
#      shell, then ln -sfn <tier>-releases/migrate-bootstrap-<ts>
#      <tier>. Step 6 emits start/end markers so the test fixture
#      can measure the window and assert it stays under budget.
#
#   7. POST-SWAP SMOKE PROBE — call the shared bv_smoke_probe helper.
#      Probe failure exits non-zero; the recovery hint is "restore
#      the step-2 backup taken at the start of the run", because
#      this is the first atomic release on the tier so there is no
#      previous release to roll back to via deploy/rollback.sh.
#
# Refusals (each exits non-zero with a clear diagnostic on stderr,
# WITHOUT mutating any path):
#   * env arg not in {dev,test,staging,prod}
#   * env=prod without --i-mean-it (the prod gate; flag is no-op for
#     non-prod)
#   * already-atomic detected in step 1
#   * deploy/backup.sh missing/non-executable, or backup.sh exits
#     non-zero
#
# Local-fixture mode (used by tests/deploy/migrate.sh):
#   * BV_MIGRATE_LOCAL_PARENT=<dir>   — operate against a local parent
#                                        dir instead of an ssh remote.
#   * BV_MIGRATE_BACKUP_FAKE=1        — replace deploy/backup.sh with
#                                        a no-op (the test stubs the
#                                        backup invocation; the test
#                                        in real mode validates the
#                                        backup-meta.yaml schema end-
#                                        to-end).
#   * BV_MIGRATE_BACKUP_FAKE_FAIL=1   — make the backup stub exit non-
#                                        zero (test the abort path).
#   * BV_MIGRATE_BACKUP_INVOKED_MARKER=<file> — when the backup stub
#                                                runs, touch this file.
#   * BV_SMOKE_PROBE_URL_OVERRIDE=<url> — point the probe at a stub
#                                          HTTP responder.
#   * BV_MIGRATE_STEP_6_TIMESTAMP_FILE=<file> — emit "start <ms>",
#                                                 "end <ms>" lines so
#                                                 the test can assert
#                                                 the offline window
#                                                 budget.
#   * BV_MIGRATE_DEPLOYED_BY=<email>   — override the bootstrap
#                                          release-meta's deployed_by
#                                          (so the test can assert a
#                                          known value).
#
# Security:
#   * Tier name validated against the closed set BEFORE any path concat.
#   * Bootstrap release id is generated by this script (not user-
#     supplied) via `date -u +%Y%m%dT%H%M%S` and validated against a
#     tight regex (^migrate-bootstrap-[0-9]{8}T[0-9]{6}$) before being
#     used as a path component.
#   * --i-mean-it is matched as a literal string (no glob, no eval).
#   * Every variable that flows into mv, ln, rm, mkdir, rmdir is double-
#     quoted and passed as a separate argument. No eval anywhere.
#   * Live-state subtrees (user/accounts/, user/data/, the two
#     security.yaml files, logs/) are touched ONLY via mv (rename
#     within the same filesystem — no copy, no rsync, no tar). Bit-
#     identity follows from filesystem semantics. This is the one
#     script in the codebase that legitimately mv's live-state paths
#     (the CLAUDE.md confinement section names these dirs as off-
#     limits to GAN agents — that exception is documented here and
#     enforced by the structural property: only mv, never rm/rsync/cp).
#   * Step 6 (the offline-window step) is bounded — single rmdir of
#     the empty <tier>/ shell followed by a single ln -sfn. The
#     bootstrap release dir is fully prepared on disk BEFORE step 6
#     begins.
#   * Step 7's smoke probe is the existing shared helper; on failure,
#     the rolled-forward layout stays live (no auto-rollback — the
#     spec is explicit on this) and the operator's recovery path is
#     deploy/restore.sh against the step-2 backup.
#
# This script is the only place in the codebase that legitimately
# touches <tier>'s live-state subtrees. The exception is recorded in
# the script header; everywhere else in deploy/ it is a hard error.
# =============================================================================

set -euo pipefail
export PATH="/opt/homebrew/bin:$PATH"

# Hard requirement: bash 4+. The atomic-release lib uses constructs
# (nested $(...) with single-quotes inside double-quotes) that bash 3.2
# (macOS Intel /bin/bash and Apple-shipped /usr/bin/bash) fails to parse.
# Without this check the operator sees a cryptic "syntax error near
# unexpected token `('" instead of a useful instruction.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "❌  bash 4+ required (this is bash ${BASH_VERSION:-?}). On macOS:" >&2
    echo "      brew install bash" >&2
    echo "    Then ensure /opt/homebrew/bin is on PATH ahead of /usr/bin." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=deploy/lib/atomic-release.sh
. "$SCRIPT_DIR/lib/atomic-release.sh"
# shellcheck source=deploy/lib/banner.sh
. "$SCRIPT_DIR/lib/banner.sh"

# Step-6 offline-window measurement requires GNU coreutils for
# ms-resolution; the lib's bv_require_ms_timing fails loud here if it's
# absent. Migration runs MUST have it: an unmeasured offline window
# means the operator can't tell whether step 6 stayed inside the spec's
# "single-digit-second" budget on the live tier.
bv_require_ms_timing

# =============================================================================
# --help — operator-readable usage. Exits 0; writes to stdout.
# =============================================================================

print_help() {
    cat <<'HELPEOF'
Byværkstederne — migrate-to-atomic-layout

Usage:
  ./deploy/migrate-to-atomic-layout.sh <env> [--i-mean-it]
  ./deploy/migrate-to-atomic-layout.sh --help

  <env>            One of: dev, test, staging, prod (closed set).
  --i-mean-it      REQUIRED for env=prod. No effect on dev/test/staging.
                   This is a one-time, supervised, irreversible-without-
                   restore operation; the flag prevents an accidental
                   `make migrate-atomic-prod`.

What this script does — the seven-step §One-time migration sequence:

  1. Sanity check — refuse if the tier is already atomic
     (i.e. <tier> is a symlink, <tier>data/ exists, or
     <tier>-releases/ has any content). No mutation on refusal.
  2. Pre-flight backup — invoke deploy/backup.sh <env>. If the
     backup fails, abort before any move; the recovery path
     downstream is "restore the step-2 backup".
  3. Create <tier>data/v0/ and move the live state subtrees in
     (user/accounts, user/data, the two security.yaml files,
     logs). State is moved via mv — bit-identity follows from
     filesystem semantics, never via copy.
  4. Create <tier>-releases/migrate-bootstrap-<UTC-timestamp>/
     and move the rest of the live tree in at directory
     granularity. The bootstrap release-id shape is
     `migrate-bootstrap-YYYYMMDDTHHMMSS` — intentionally
     distinct from a normal deploy release-id; the next
     deploy.sh run produces a conventional id.
  5. Wire the five symlinks per §Symlink contract inside the
     bootstrap release dir, via the shared lib helper.
  6. Replace <tier>/ with a symlink to the bootstrap release
     dir. THIS IS THE OFFLINE WINDOW (offline only briefly,
     single-digit-second in practice — rmdir + ln -sfn). The
     script logs start/end timestamps; the test fixture asserts
     the budget.
  7. Smoke-probe the live URL via the shared probe helper.

On any failure, the recovery path is:

  ./deploy/restore.sh <env>   # against the backup taken in step 2

…because there is no previous atomic release to roll back to via
deploy/rollback.sh on the first migration of a tier.

The migration is one-time and operator-supervised by design.
There is no make-target that runs it without operator interaction.

Environment (test-only) hooks: see the script header.
HELPEOF
}

# =============================================================================
# Step 0 — argument parsing + closed-set + prod-gate validation
# =============================================================================

# --help short-circuit BEFORE any path-using logic.
for arg in "$@"; do
    case "$arg" in
        --help|-h)
            print_help
            exit 0
            ;;
    esac
done

ENV_RAW="${1:-}"
shift || true

I_MEAN_IT=0
EXTRA_REJECTS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --i-mean-it)
            I_MEAN_IT=1
            shift
            ;;
        *)
            # Collect ALL unexpected positional/flag values (PR-#17
            # review finding 6: report every offender, not just the
            # last one). An operator who passes `dev foo bar` should
            # see both `foo` and `bar` in the diagnostic.
            EXTRA_REJECTS+=("$1")
            shift
            ;;
    esac
done

if [ -z "$ENV_RAW" ]; then
    echo "❌  Usage: $(basename "$0") <dev|test|staging|prod> [--i-mean-it]" >&2
    echo "    See --help for the full seven-step migration sequence." >&2
    exit 1
fi

if [ "${#EXTRA_REJECTS[@]}" -gt 0 ]; then
    echo "❌  Unexpected argument(s):" >&2
    for _r in "${EXTRA_REJECTS[@]}"; do
        echo "      $(printf %q "$_r")" >&2
    done
    echo "    Usage: $(basename "$0") <dev|test|staging|prod> [--i-mean-it]" >&2
    exit 1
fi

# Closed-set validation BEFORE any path is constructed. The validator
# echoes the canonical lowercased name on stdout; we capture it.
if ! ENV="$(bv_validate_tier_name "$ENV_RAW")"; then
    echo "    Usage: $(basename "$0") <dev|test|staging|prod> [--i-mean-it]" >&2
    exit 1
fi

# Apex landing has no atomic layout and no live state to migrate.
# bv_validate_tier_name accepts 'landing' for the deploy script's
# benefit, but the migration tool refuses it explicitly.
if [ "$ENV" = "landing" ]; then
    echo "❌  Apex landing tier has no atomic layout and no mutable state." >&2
    echo "    There is nothing to migrate. The deploy script's landing branch" >&2
    echo "    keeps the existing in-place rsync flow." >&2
    exit 1
fi

# Prod gate. The flag is no-op for non-prod (silently ignored).
if [ "$ENV" = "prod" ] && [ "$I_MEAN_IT" != "1" ]; then
    echo "" >&2
    echo "❌  migrate-to-atomic-layout.sh prod requires the --i-mean-it flag." >&2
    echo "" >&2
    echo "    Why: this is a one-time, operator-supervised, irreversible-" >&2
    echo "    without-restore operation against the production tier. The" >&2
    echo "    flag exists so an accidental 'make migrate-atomic-prod' can" >&2
    echo "    never proceed." >&2
    echo "" >&2
    echo "    Re-run with the flag, supervised:" >&2
    echo "       ./deploy/migrate-to-atomic-layout.sh prod --i-mean-it" >&2
    echo "" >&2
    exit 1
fi

# =============================================================================
# Resolve the docroot parent + naming layout. Local-fixture mode is the
# tested path; real-remote mode reads the same .env.deploy the deploy
# script uses.
# =============================================================================

LOCAL_MODE=0
if [ -n "${BV_MIGRATE_LOCAL_PARENT:-}" ]; then
    LOCAL_MODE=1
    if [ ! -d "$BV_MIGRATE_LOCAL_PARENT" ]; then
        echo "❌  BV_MIGRATE_LOCAL_PARENT='$BV_MIGRATE_LOCAL_PARENT' is not a directory" >&2
        exit 1
    fi
    # Reject traversal in the fixture path.
    case "$BV_MIGRATE_LOCAL_PARENT" in
        *..*) echo "❌  BV_MIGRATE_LOCAL_PARENT contains '..' — refusing" >&2; exit 1 ;;
    esac
    DOCROOT_PARENT="$BV_MIGRATE_LOCAL_PARENT"
    LAYOUT_NAME="$ENV"
    DOCROOT="$DOCROOT_PARENT/$LAYOUT_NAME"
    ENV_URL="${BV_SMOKE_PROBE_URL_OVERRIDE:-http://127.0.0.1/}"
fi

if [ "$LOCAL_MODE" = "0" ]; then
    # Real-remote mode is intentionally NOT exercised by the GAN run
    # (CLAUDE.md confinement: no real remote, no credentials). The
    # operator runs this on a checkout with .env.deploy populated.
    ENV_FILE="$PROJECT_DIR/.env.deploy"
    if [ ! -f "$ENV_FILE" ]; then
        echo "❌  Missing .env.deploy — copy .env.deploy.example and fill in credentials" >&2
        echo "    Or set BV_MIGRATE_LOCAL_PARENT for fixture-mode testing." >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$ENV_FILE"

    case "$ENV" in
        prod)
            : "${DEPLOY_PROD_PATH:?prod migration requires DEPLOY_PROD_PATH in .env.deploy}"
            DOCROOT="$DEPLOY_PROD_PATH"
            ;;
        staging)
            DOCROOT="${DEPLOY_PATH:-}"
            ;;
        test)
            DOCROOT="${DEPLOY_PATH:-}/test"
            ;;
        dev)
            DOCROOT="${DEPLOY_PATH:-}/dev"
            ;;
    esac
    DOCROOT_PARENT="$(dirname "$DOCROOT")"
    LAYOUT_NAME="$(basename "$DOCROOT")"

    # Real-remote migration would require ssh wrappers around every
    # mv/ln/mkdir below — this is intentionally NOT plumbed end-to-end
    # in this sprint. The script header documents fixture mode as the
    # tested path; the real-remote runbook lands in a follow-up commit.
    echo "❌  Real-remote migration mode is not enabled in this build." >&2
    echo "    Run with BV_MIGRATE_LOCAL_PARENT=<dir> against a fixture, or" >&2
    echo "    extend this script's remote-mode wrappers in a follow-up." >&2
    exit 1
fi

RELEASES_DIR="$DOCROOT_PARENT/${LAYOUT_NAME}-releases"
DATA_DIR="$DOCROOT_PARENT/${LAYOUT_NAME}data"

# =============================================================================
# Banner — operator visibility.
# =============================================================================

draw_banner() {
    local lines=("$@") line max=0 w pad inner border
    _w() { printf '%s' "$1" | LC_ALL=en_US.UTF-8 wc -m | tr -d ' '; }
    for line in "${lines[@]}"; do
        w=$(_w "$line")
        [ "$w" -gt "$max" ] && max="$w"
    done
    inner=$((max + 4))
    border=$(printf '═%.0s' $(seq 1 "$inner"))
    echo ""
    echo "  ╔${border}╗"
    for line in "${lines[@]}"; do
        w=$(_w "$line")
        pad=$((max - w))
        printf "  ║  %s%*s  ║\n" "$line" "$pad" ""
    done
    echo "  ╚${border}╝"
    echo ""
}

draw_banner \
    "Byværkstederne — Migrate to atomic layout" \
    "Environment: ${ENV}" \
    "Docroot: ${DOCROOT}"

# =============================================================================
# Step 1 — SANITY CHECK
# =============================================================================
#
# Three signals; any one fires the refusal. Mixed-signal state (a
# real <tier>/ dir but <tier>data/v0/ already exists, etc.) gets a
# distinct diagnostic so the operator notices the inconsistency.

echo "→ Step 1/7: Sanity check — refuse if already atomic..."

DOCROOT_IS_SYMLINK=0
DATA_DIR_EXISTS=0
RELEASES_DIR_HAS_CONTENT=0

if [ -L "$DOCROOT" ]; then
    DOCROOT_IS_SYMLINK=1
fi
if [ -d "$DATA_DIR" ]; then
    DATA_DIR_EXISTS=1
fi
if [ -d "$RELEASES_DIR" ] && [ -n "$(ls -A "$RELEASES_DIR" 2>/dev/null || true)" ]; then
    RELEASES_DIR_HAS_CONTENT=1
fi

# All three signals firing together = clean already-migrated state.
# Any subset firing = mixed-signal state (broken migration mid-way,
# or hand-edited tree). Either way, we refuse — but the diagnostic
# distinguishes so wrappers can branch on it.
if [ "$DOCROOT_IS_SYMLINK" = "1" ] || [ "$DATA_DIR_EXISTS" = "1" ] || [ "$RELEASES_DIR_HAS_CONTENT" = "1" ]; then
    echo "" >&2
    if [ "$DOCROOT_IS_SYMLINK" = "1" ] && [ "$DATA_DIR_EXISTS" = "1" ] && [ "$RELEASES_DIR_HAS_CONTENT" = "1" ]; then
        echo "❌  Tier '${ENV}' is already in the atomic layout (already migrated)." >&2
        echo "    Signals: <tier> is a symlink, <tier>data/ exists, <tier>-releases/ has content." >&2
        echo "    No mutation performed. Nothing to do." >&2
    else
        echo "❌  Tier '${ENV}' is in a MIXED-SIGNAL state — partial migration or hand-edit detected." >&2
        echo "    Signals fired:" >&2
        [ "$DOCROOT_IS_SYMLINK" = "1" ]      && echo "      • <tier> is a symlink (${DOCROOT})" >&2
        [ "$DATA_DIR_EXISTS" = "1" ]         && echo "      • <tier>data/ exists (${DATA_DIR})" >&2
        [ "$RELEASES_DIR_HAS_CONTENT" = "1" ] && echo "      • <tier>-releases/ has content (${RELEASES_DIR})" >&2
        echo "" >&2
        echo "    Inspect the tree by hand and either restore the pre-migration" >&2
        echo "    backup, or remove the partial-state dirs before retrying." >&2
        echo "    No mutation performed by this run." >&2
    fi
    echo "" >&2
    exit 1
fi

# At this point the docroot must be a real directory containing the
# legacy in-place layout. Sanity-check the shape (refuse if it's
# missing or is a regular file).
if [ ! -d "$DOCROOT" ]; then
    echo "❌  Docroot '${DOCROOT}' is not a directory. Cannot migrate." >&2
    exit 1
fi
if [ -L "$DOCROOT" ]; then
    # Defence-in-depth — DOCROOT_IS_SYMLINK already handled this above,
    # but check again before any mutation.
    echo "❌  Docroot '${DOCROOT}' became a symlink mid-check — race condition?" >&2
    exit 1
fi

echo "  ✓ Tier is in legacy layout — proceeding to backup."

# =============================================================================
# Step 2 — PRE-FLIGHT BACKUP
# =============================================================================
#
# Invoke deploy/backup.sh <env>. Non-zero exit aborts the migration
# BEFORE any state move. The backup snapshot is the recovery path on
# any downstream failure (steps 3-7), since there is no previous
# atomic release to roll back to.

echo "→ Step 2/7: Pre-flight backup (deploy/backup.sh ${ENV})..."

BACKUP_SH="$SCRIPT_DIR/backup.sh"
if [ ! -x "$BACKUP_SH" ]; then
    echo "❌  deploy/backup.sh missing or not executable at ${BACKUP_SH}" >&2
    echo "    Cannot proceed without a pre-flight backup." >&2
    exit 1
fi

if [ "${BV_MIGRATE_BACKUP_FAKE:-0}" = "1" ]; then
    # Fixture-mode backup stub. The test asserts the invocation
    # happened (via BV_MIGRATE_BACKUP_INVOKED_MARKER) and, if
    # configured to fail, asserts the migration aborts before any
    # state move (see step 3 boundary).
    if [ -n "${BV_MIGRATE_BACKUP_INVOKED_MARKER:-}" ]; then
        : > "$BV_MIGRATE_BACKUP_INVOKED_MARKER"
    fi
    if [ "${BV_MIGRATE_BACKUP_FAKE_FAIL:-0}" = "1" ]; then
        echo "❌  Pre-flight backup failed (stub injected failure)." >&2
        echo "    Aborting migration before any state move." >&2
        exit 1
    fi
    echo "  ℹ️  fixture-mode backup stub — skipping real backup.sh"
else
    # Real backup invocation. backup.sh's args are quoted; ENV passed
    # as a separate argument. No string-built command line.
    if ! "$BACKUP_SH" "$ENV"; then
        echo "" >&2
        echo "❌  Pre-flight backup (deploy/backup.sh ${ENV}) FAILED." >&2
        echo "    Aborting migration before any state move." >&2
        echo "    Recovery: re-run after fixing the backup pipeline." >&2
        exit 1
    fi
fi

echo "  ✓ Backup snapshot taken."

# =============================================================================
# Generate the bootstrap release id BEFORE step 3 so we can record it
# in markers and announce it before any mutation. The id is generated
# server-side via `date -u` and validated against a tight regex
# (^migrate-bootstrap-[0-9]{8}T[0-9]{6}$) before being used as a path
# component.
#
# This regex is INTENTIONALLY DIFFERENT from the standard release-id
# regex bv_release_id_regex emits (which is
#   ^[0-9]{8}T[0-9]{6}-[0-9a-f]{7,12}$
# — a UTC timestamp + git-sha-short). The bootstrap release predates
# any git context for the live tree (the operator may be migrating a
# tier that diverged from main) and the prefix `migrate-bootstrap-`
# makes the audit trail self-describing.
# =============================================================================

BOOTSTRAP_TS="${BV_MIGRATE_FAKE_TS:-$(date -u +%Y%m%dT%H%M%S)}"
BOOTSTRAP_ID="migrate-bootstrap-${BOOTSTRAP_TS}"

case "$BOOTSTRAP_ID" in
    *..*|*/*|-*)
        echo "❌  Generated bootstrap release id contains forbidden characters: '${BOOTSTRAP_ID}'" >&2
        exit 1
        ;;
esac
if ! printf '%s' "$BOOTSTRAP_ID" | grep -Eq '^migrate-bootstrap-[0-9]{8}T[0-9]{6}$'; then
    echo "❌  Generated bootstrap release id fails regex validation: '${BOOTSTRAP_ID}'" >&2
    exit 1
fi

BOOTSTRAP_DIR="${RELEASES_DIR}/${BOOTSTRAP_ID}"
echo "  ℹ️  Bootstrap release id: ${BOOTSTRAP_ID}"

# =============================================================================
# Step 3 — CREATE <tier>data/v0/ AND MOVE STATE SUBTREES IN
# =============================================================================
#
# Each mv is an explicit, commented line. Source and destination are
# spelled out as path expressions. NO loops over an unvalidated list
# of files. NO rsync, NO cp, NO tar, NO rm.
#
# Bit-identity follows from `mv` semantics within a filesystem (a
# rename, not a copy). The test fixture asserts (size, sha256) match
# pre/post.
#
# Note on idempotence: if step 3 fails partway (rare — mv across the
# same filesystem either succeeds or errors atomically), step 1's
# already-atomic guard will fire on the next run because <tier>data/
# now exists. Recovery in that case is "restore step-2 backup".

echo "→ Step 3/7: Creating <tier>data/v0/ and moving live state subtrees in..."

# Create the data dir skeleton FIRST (mkdir is idempotent; will error
# if a regular file exists at the path, which step 1 ruled out).
mkdir -p "$DATA_DIR/v0/user/accounts"
mkdir -p "$DATA_DIR/v0/user/data"
mkdir -p "$DATA_DIR/v0/user/config"
mkdir -p "$DATA_DIR/v0/user/env/${ENV}/config"
mkdir -p "$DATA_DIR/logs"

# State subtree #1: user/accounts/  →  <tier>data/v0/user/accounts/
# Per-file PII (usernames, hashed passwords, emails). Bit-identity
# critical.
if [ -d "$DOCROOT/user/accounts" ]; then
    # The mkdir -p above created the destination as an empty dir;
    # rmdir it so mv can take over the source dir intact.
    rmdir "$DATA_DIR/v0/user/accounts"
    # mv user/accounts/ -> ../<tier>data/v0/user/accounts/
    mv "$DOCROOT/user/accounts" "$DATA_DIR/v0/user/accounts"
    [ -d "$DATA_DIR/v0/user/accounts" ] || { echo "❌  state move failed: user/accounts/" >&2; exit 1; }
fi

# State subtree #2: user/data/  →  <tier>data/v0/user/data/
# Flex objects (member-submitted feature requests, comments, votes —
# PII-adjacent).
if [ -d "$DOCROOT/user/data" ]; then
    rmdir "$DATA_DIR/v0/user/data"
    # mv user/data/ -> ../<tier>data/v0/user/data/
    mv "$DOCROOT/user/data" "$DATA_DIR/v0/user/data"
    [ -d "$DATA_DIR/v0/user/data" ] || { echo "❌  state move failed: user/data/" >&2; exit 1; }
fi

# State file #3: user/config/security.yaml  →  <tier>data/v0/user/config/security.yaml
# Grav-generated salts; rotating them invalidates every existing
# session and password hash.
if [ -f "$DOCROOT/user/config/security.yaml" ]; then
    # mv user/config/security.yaml -> ../<tier>data/v0/user/config/security.yaml
    mv "$DOCROOT/user/config/security.yaml" "$DATA_DIR/v0/user/config/security.yaml"
    [ -f "$DATA_DIR/v0/user/config/security.yaml" ] || { echo "❌  state move failed: user/config/security.yaml" >&2; exit 1; }
fi

# State file #4: user/env/<env>/config/security.yaml  →  <tier>data/v0/user/env/<env>/config/security.yaml
# Per-tier override of the salts above; same loss-of-undo class.
if [ -f "$DOCROOT/user/env/${ENV}/config/security.yaml" ]; then
    # mv user/env/<env>/config/security.yaml -> ../<tier>data/v0/user/env/<env>/config/security.yaml
    mv "$DOCROOT/user/env/${ENV}/config/security.yaml" "$DATA_DIR/v0/user/env/${ENV}/config/security.yaml"
    [ -f "$DATA_DIR/v0/user/env/${ENV}/config/security.yaml" ] || { echo "❌  state move failed: user/env/${ENV}/config/security.yaml" >&2; exit 1; }
fi

# State subtree #5: logs/  →  <tier>data/logs/
# Operational logs; not PII per se, but operator-relevant history we
# don't want vapourised.
if [ -d "$DOCROOT/logs" ]; then
    rmdir "$DATA_DIR/logs"
    # mv logs/ -> ../<tier>data/logs/
    mv "$DOCROOT/logs" "$DATA_DIR/logs"
    [ -d "$DATA_DIR/logs" ] || { echo "❌  state move failed: logs/" >&2; exit 1; }
fi

# Bootstrap the data-dir 'current' symlink (v0 is the only data
# version in Phase 1).
ln -sfn "v0" "$DATA_DIR/current"

echo "  ✓ State subtrees relocated under ${DATA_DIR}/v0/."

# =============================================================================
# Step 4 — CREATE <tier>-releases/migrate-bootstrap-<ts>/ AND MOVE
#          THE REST OF THE LIVE TREE IN
# =============================================================================
#
# Move at directory granularity — each top-level entry remaining in
# <tier>/ moves into the bootstrap release dir as a single mv. This
# preserves the directory contents bit-identically (it's a rename of
# the parent slot, not a copy).
#
# The state subtrees moved out in step 3 are no longer in <tier>/, so
# we never accidentally re-move them.

echo "→ Step 4/7: Creating ${BOOTSTRAP_DIR} and moving the rest of the live tree in..."

mkdir -p "$BOOTSTRAP_DIR"

# Move every remaining top-level entry from $DOCROOT/ into the
# bootstrap release dir. We enumerate entries via `find -maxdepth 1`
# rather than a glob (a glob would miss dotfiles like .htaccess).
# Each entry is a separate `mv`; the loop variable is a single
# pathname produced by find — no shell metacharacter splitting.
while IFS= read -r -d '' entry; do
    # Skip the docroot itself.
    case "$entry" in
        "$DOCROOT") continue ;;
    esac
    # mv <entry> -> bootstrap/<basename(entry)>
    bn="$(basename "$entry")"
    mv "$entry" "$BOOTSTRAP_DIR/$bn"
done < <(find "$DOCROOT" -mindepth 1 -maxdepth 1 -print0)

echo "  ✓ Remaining live-tree entries moved into bootstrap release dir."

# =============================================================================
# Step 5 — WIRE SYMLINKS per §Symlink contract
# =============================================================================
#
# Same helper Sprint 1's deploy.sh uses (single source of truth — see
# bv_wire_release_symlinks in deploy/lib/atomic-release.sh). Five
# symlinks, all relative-path, ln -sfn idempotent.

echo "→ Step 5/7: Wiring §Symlink contract inside bootstrap release dir..."

bv_wire_release_symlinks "$BOOTSTRAP_DIR" "$DATA_DIR" "$ENV"

echo "  ✓ Five symlinks wired inside ${BOOTSTRAP_DIR}."

# =============================================================================
# Write release-meta.yaml BEFORE the docroot swap (step 6). The
# bootstrap release uses the FULL §Audit schema — same as Sprint 2 —
# with previous_release / previous_data_version explicitly empty
# (this is the first atomic release on the tier).
# =============================================================================

echo "  → Writing bootstrap release-meta.yaml (full §Audit schema, previous_release empty)..."

DEPLOYED_BY="${BV_MIGRATE_DEPLOYED_BY:-$(git -C "$PROJECT_DIR" config user.email 2>/dev/null || echo "unknown")}"
DEPLOYED_AT_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOST_NAME="${BV_MIGRATE_HOST:-$(hostname 2>/dev/null || echo "unknown")}"
CWD_VAL="${BV_MIGRATE_CWD:-$PWD}"
GIT_BRANCH="${BV_MIGRATE_BRANCH:-$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")}"
GIT_SHA="${BV_MIGRATE_SHA:-$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "unknown")}"
GIT_SHA_SHORT="${BV_MIGRATE_SHA_SHORT:-$(git -C "$PROJECT_DIR" rev-parse --short=7 HEAD 2>/dev/null || echo "unknown")}"
IS_DIRTY="false"
if [ -z "${BV_MIGRATE_IS_DIRTY:-}" ]; then
    if ! git -C "$PROJECT_DIR" diff --quiet HEAD 2>/dev/null \
       || ! git -C "$PROJECT_DIR" diff --cached --quiet HEAD 2>/dev/null; then
        IS_DIRTY="true"
    fi
else
    IS_DIRTY="${BV_MIGRATE_IS_DIRTY}"
fi

# Pull VERSION + BUILD from the bootstrap release dir if present, so
# the meta records what's actually live. Default to placeholder values
# if the tier didn't carry them (legacy tiers may not have VERSION/BUILD
# files yet — they'll appear after the first post-migration deploy).
CODE_VERSION="0.0.0"
CODE_BUILD="0"
if [ -f "$BOOTSTRAP_DIR/VERSION" ]; then
    CODE_VERSION="$(tr -d '[:space:]' < "$BOOTSTRAP_DIR/VERSION")"
    [ -z "$CODE_VERSION" ] && CODE_VERSION="0.0.0"
fi
if [ -f "$BOOTSTRAP_DIR/BUILD" ]; then
    CODE_BUILD="$(tr -d '[:space:]' < "$BOOTSTRAP_DIR/BUILD")"
    [ -z "$CODE_BUILD" ] && CODE_BUILD="0"
fi

# bv_write_release_meta_yaml_full validates release_id against the
# strict regex by default — but the bootstrap id has a different
# shape. Emit the meta inline using the same field set, in the same
# order, with the same quoting discipline. Keep this in lock-step
# with bv_write_release_meta_yaml_full's output.
META="$BOOTSTRAP_DIR/release-meta.yaml"
{
    printf 'release_id: %s\n' "$BOOTSTRAP_ID"
    printf 'deployed_at: "%s"\n' "$(bv_yaml_quote_escape "$DEPLOYED_AT_ISO")"
    printf 'deployed_by: "%s"\n' "$(bv_yaml_quote_escape "$DEPLOYED_BY")"
    printf 'deployed_from:\n'
    printf '  host: "%s"\n' "$(bv_yaml_quote_escape "$HOST_NAME")"
    printf '  cwd: "%s"\n' "$(bv_yaml_quote_escape "$CWD_VAL")"
    printf '  branch: "%s"\n' "$(bv_yaml_quote_escape "$GIT_BRANCH")"
    printf '  sha: "%s"\n' "$(bv_yaml_quote_escape "$GIT_SHA")"
    printf '  sha_short: "%s"\n' "$(bv_yaml_quote_escape "$GIT_SHA_SHORT")"
    printf '  is_dirty: %s\n' "$IS_DIRTY"
    printf 'code_version: "%s"\n' "$(bv_yaml_quote_escape "$CODE_VERSION")"
    printf 'build: "%s"\n' "$(bv_yaml_quote_escape "$CODE_BUILD")"
    printf 'data_version: "%s"\n' "v0"
    # Bootstrap release has no predecessor — both empty per contract.
    printf 'previous_release: ""\n'
    printf 'previous_data_version: ""\n'
} > "$META"

echo "  ✓ release-meta.yaml written at ${META}."

# =============================================================================
# Step 6 — REPLACE <tier> DIRECTORY WITH A SYMLINK
# =============================================================================
#
# THIS IS THE BRIEF OFFLINE WINDOW. The bootstrap release dir is fully
# prepared on disk at this point (state in <tier>data/v0/, code under
# <tier>-releases/<bootstrap>/, symlinks wired, release-meta written).
#
# Step 6 itself is a tight sequence:
#   a. rmdir the now-empty <tier>/ shell
#   b. ln -sfn <tier>-releases/<bootstrap-id> <tier>
#
# Both operations are O(1). The window between (a) and (b) is when
# the docroot does not resolve. Single-digit-second in practice;
# the test fixture asserts it.

echo "→ Step 6/7: Replacing ${DOCROOT}/ with a symlink (offline window — single rmdir + ln -sfn)..."

# Step-6 timing markers — the test fixture grep's these to bound the
# offline window. The shared lib helper bv_now_ms trusts the caller has
# already passed bv_require_ms_timing (above).
STEP6_START_MS="$(bv_now_ms)"
echo "  ⏱  step 6 start: ${STEP6_START_MS} ms (epoch)"
if [ -n "${BV_MIGRATE_STEP_6_TIMESTAMP_FILE:-}" ]; then
    printf 'start %s\n' "$STEP6_START_MS" > "$BV_MIGRATE_STEP_6_TIMESTAMP_FILE"
fi

# (a) The docroot must be empty at this point — every entry was
# moved to the bootstrap dir in step 4. rmdir refuses if not empty,
# which is the right safety: if step 4 missed an entry, step 6
# fails loud here rather than silently rming live data.
if ! rmdir "$DOCROOT"; then
    echo "" >&2
    echo "❌  Could not rmdir empty docroot ${DOCROOT}." >&2
    echo "    Step 4 may have left an entry behind. Inspect by hand;" >&2
    echo "    do NOT rm -rf the docroot — restore the step-2 backup" >&2
    echo "    and re-run." >&2
    exit 1
fi

# (b) Atomic ln -sfn. Same shape as deploy.sh's swap. Target is
# relative (release-parent-basename/release-basename), so the
# docroot stays portable.
bv_atomic_swap_symlink "$BOOTSTRAP_DIR" "$DOCROOT"

STEP6_END_MS="$(bv_now_ms)"
STEP6_DURATION_MS=$(( STEP6_END_MS - STEP6_START_MS ))
[ "$STEP6_DURATION_MS" -lt 0 ] && STEP6_DURATION_MS=0

echo "  ⏱  step 6 end: ${STEP6_END_MS} ms (epoch); offline window ${STEP6_DURATION_MS} ms"
if [ -n "${BV_MIGRATE_STEP_6_TIMESTAMP_FILE:-}" ]; then
    printf 'end %s\n' "$STEP6_END_MS" >> "$BV_MIGRATE_STEP_6_TIMESTAMP_FILE"
    printf 'duration_ms %s\n' "$STEP6_DURATION_MS" >> "$BV_MIGRATE_STEP_6_TIMESTAMP_FILE"
fi

SWAPPED_AT_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  ✓ ${DOCROOT} now resolves to ${BOOTSTRAP_ID}."

# =============================================================================
# Step 7 — POST-SWAP SMOKE PROBE
# =============================================================================
#
# Same shared helpers as deploy.sh and rollback.sh. Probe failure
# exits non-zero with a "restore the step-2 backup" hint (since this
# is the first atomic release on the tier — there is no previous
# atomic release to roll back to).

echo "→ Step 7/7: Post-swap smoke probe..."

PROBE_URL="${BV_SMOKE_PROBE_URL_OVERRIDE:-${ENV_URL:-http://127.0.0.1/}}"
PROBE_EXPECTED=""
if [ -f "$BOOTSTRAP_DIR/VERSION" ] && [ -f "$BOOTSTRAP_DIR/BUILD" ]; then
    PROBE_EXPECTED="$(bv_compute_expected_version_substring "$BOOTSTRAP_DIR" 2>/dev/null || echo "")"
fi

PROBE_STATUS=0
PROBE_MATCHED=false
PROBE_RC=0

if [ -n "$PROBE_EXPECTED" ]; then
    PROBE_RESULT="$(bv_smoke_probe "$PROBE_URL" "$PROBE_EXPECTED" || true)"
    PROBE_STATUS="${PROBE_RESULT%%|*}"
    PROBE_MATCHED="${PROBE_RESULT##*|}"
    case "$PROBE_STATUS" in
        ''|*[!0-9]*) PROBE_STATUS=0 ;;
    esac
    case "$PROBE_MATCHED" in
        true|false) ;;
        *) PROBE_MATCHED=false ;;
    esac
    if [ "$PROBE_MATCHED" != "true" ] || [ "$PROBE_STATUS" != "200" ]; then
        PROBE_RC=1
    fi
else
    echo "  ℹ️  No VERSION/BUILD in bootstrap release — skipping substring match (legacy tier)."
    # We still hit the URL to confirm the docroot resolves to
    # something reachable.
    PROBE_RESULT="$(bv_smoke_probe "$PROBE_URL" "</html>" 2>/dev/null || true)"
    PROBE_STATUS="${PROBE_RESULT%%|*}"
    case "$PROBE_STATUS" in
        ''|*[!0-9]*) PROBE_STATUS=0 ;;
    esac
    if [ "$PROBE_STATUS" = "200" ]; then
        PROBE_MATCHED=true
    else
        PROBE_RC=1
    fi
fi

# Append the post-swap fields to release-meta.yaml regardless of
# probe outcome (failure rows are part of the audit trail).
{
    printf 'swapped_at: "%s"\n' "$SWAPPED_AT_ISO"
    printf 'swap_duration_ms: %s\n' "$STEP6_DURATION_MS"
    printf 'smoke_probe:\n'
    printf '  url: "%s"\n' "$(bv_yaml_quote_escape "$PROBE_URL")"
    printf '  status: %s\n' "$PROBE_STATUS"
    printf '  expected_version_substring: "%s"\n' "$(bv_yaml_quote_escape "$PROBE_EXPECTED")"
    printf '  matched: %s\n' "$PROBE_MATCHED"
} >> "$META"

if [ "$PROBE_RC" -ne 0 ]; then
    echo "" >&2
    echo "❌  Post-swap smoke probe FAILED." >&2
    echo "    expected: ${PROBE_EXPECTED}" >&2
    echo "    status:   ${PROBE_STATUS}" >&2
    echo "    matched:  ${PROBE_MATCHED}" >&2
    echo "" >&2
    echo "    The migrated layout IS LIVE — no auto-rollback." >&2
    echo "" >&2
    echo "    Recovery strategy: restore from the pre-flight backup taken in step 2" >&2
    echo "    via ./deploy/restore.sh ${ENV}. There is no previous atomic release" >&2
    echo "    to roll back to (this was the FIRST migration of this tier)." >&2
    echo "" >&2
    exit 1
fi

echo "  ✓ Smoke probe matched."

echo ""
echo "  ✅  Migration complete."
echo "  📦  ${DOCROOT} → ${BOOTSTRAP_ID}"
echo "  📜  Bootstrap meta: ${META}"
echo "  ⏱  Offline window during step 6: ${STEP6_DURATION_MS} ms"
echo ""
