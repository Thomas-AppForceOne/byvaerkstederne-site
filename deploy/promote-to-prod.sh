#!/usr/bin/env bash
# promote-to-prod.sh — promote the staging-blessed combination of code +
# data shape + flags to PRODUCTION, behind a hard gate.
#
# WHY
# ---
# The constraint Thomas stated: never allow pushing a version to prod
# unless it has first been deployed to staging with migrated prod data.
# This is the fourth and final step of the data-lifecycle series
# (backup → restore → promote-to-staging → promote-to-prod). It reuses
# every shipped piece (backup.sh, restore.sh, migrate.sh, deploy.sh,
# rollback-prod.sh) and the versioned-data-dir SERVING model (ADR-005),
# adding the staging-blessing gate, the branch gate, a flag-sync commit
# on the release branch, and a tagged pre-promotion backup for rollback
# insurance.
#
# See specifications/promote_to_prod_specification.md for the
# authoritative contract, ADR-003 for the release-branch model, and
# ADR-005 for the data-dir serving model this BUILDS + ACTIVATES.
#
# USAGE
# -----
#   ./deploy/promote-to-prod.sh [--reason "..."]
#   ./deploy/promote-to-prod.sh --bypass-staging-gate --reason "..."
#   ./deploy/promote-to-prod.sh --help
#
# Options:
#   --reason "..."          Audit note appended verbatim to the printed
#                           summary + the promotion journal. Optional on a
#                           normal promote; REQUIRED with
#                           --bypass-staging-gate (then 50–500 chars).
#   --bypass-staging-gate   Skip the staging-blessing gate. Requires
#                           --reason (50–500 chars), prompts interactively
#                           (y/N — NOT scriptable with --yes), and appends
#                           an audit entry to prod-bypass-log.yaml on prod.
#   --help                  Show this help.
#
# THE BRANCH GATE (spec §"The branch gate")
# -----------------------------------------
#   * Refuse on develop / main / master — the flag-sync commit (step 6)
#     would otherwise violate the project's "develop & main are sacred"
#     rule (CLAUDE.md, ADR-003).
#   * Warn-but-proceed on a non-release / non-hotfix branch (bedding-in
#     period; tighten later).
#   * Proceed silently on release/* or hotfix/*.
#
# THE BLESSING GATE (spec §"The blessing gate")
# ---------------------------------------------
# Fetch staging's blessing marker (config/www/staging-blessed.yaml, Grav
# root, OUTSIDE user/) over SSH, then verify, refusing on the FIRST
# mismatch with a message naming it:
#   1. present + parseable
#   2. code_commit == local HEAD short sha
#   3. data_version == local config/www/user/data-version.yaml
#   4. features_yaml_sha256 == sha256(local staging features.yaml)
#   5. prod-flag drift: sha256(prod's LIVE features.yaml) ==
#      sha256(the prod features.yaml committed in git). Catches hand-edits
#      on prod that the step-6 flag sync would otherwise silently wipe.
# Bypassed only via --bypass-staging-gate (interactive, audited).
#
# DATA MODEL — versioned-data-dir SERVING (ADR-005)
# -------------------------------------------------
# Identical to promote-to-staging: a release binds to the data-version
# dir <prod>data/current points at AT DEPLOY TIME. So promote BUILDS a
# complete v_<target> dir and repoints `current` at it BEFORE the code
# deploy:
#   1. CURRENT_VDIR = basename(readlink proddata/current)   (v0 fallback)
#   2. VDIR         = bv_version_to_dirname(TARGET_VERSION)  (e.g. v_0_2_0)
#   3. cp -a proddata/<CURRENT_VDIR> proddata/<VDIR>         (inherit secrets)
#      then overlay the migrated accounts/data/pages/uploads
#   4. ln -sfn <VDIR> proddata/current
#   5. deploy.sh prod --skip-data-migration  → wires the new release to <VDIR>
#
# LOCAL MODE (testing)
# --------------------
# When PROMOTE_PROD_LOCAL_TIER_DIR=<absolute-path> is set, the script
# operates against that local directory instead of SSH: it skips the
# reachability probes, the real code deploy, the curl smoke-test, and the
# SFTP blessing/prod-features fetch. It performs the BUILD+ACTIVATE step
# as local cp -a + rsync into $PROMOTE_PROD_LOCAL_TIER_DIR/proddata/<VDIR>/...
# and a local `current` repoint, and writes the bypass-log entry locally.
# The blessing-gate inputs are injectable in local mode so the gate logic
# is testable without SSH:
#   PROMOTE_PROD_LOCAL_BLESSING_FILE=<path>   stand-in for staging's
#                                             staging-blessed.yaml.
#   PROMOTE_PROD_LOCAL_PROD_FEATURES=<path>   stand-in for prod's LIVE
#                                             features.yaml (drift check).
# The live SSH path is reviewed, not run in CI (no SSH; ADR-002/004 also
# gate a real run).
#
# Override points (env vars, all optional):
#   PROMOTE_PROD_SCRATCH_DIR   absolute path for the restore scratch dir
#                              (default: a mktemp dir under $TMPDIR).
#   PROMOTE_PROD_ENV_FILE      override .env.deploy location.
#   PROMOTE_PROD_LOG_FILE      override deploy/promotion-log.jsonl.
#
# All destructive ops (rm -rf of a stale <prod>data/<VDIR>, cp -a,
# rsync --delete) are string-rooted under a validated DATA_ROOT with VDIR
# validated single-component. Everything is quoted; remote paths printf %q.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR PROJECT_DIR

# bv_version_to_dirname (0.2.0 → v_0_2_0) — single source of truth for the
# versioned-data-dir naming convention. Pure shell, no ssh at source time;
# available in BOTH local and live mode.
# shellcheck source=deploy/lib/migrate-integration.sh
. "$SCRIPT_DIR/lib/migrate-integration.sh"

usage() {
    sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

log()  { printf '→ %s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '⚠  %s\n' "$*" >&2; }
die()  { printf '❌  %s\n' "$1" >&2; exit "${2:-1}"; }

# ── 1. Parse args ────────────────────────────────────────────────────
REASON=""
BYPASS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --reason)
            [ $# -ge 2 ] || die "--reason requires a value argument"
            REASON="$2"; shift 2
            ;;
        --reason=*)
            REASON="${1#--reason=}"; shift
            ;;
        --bypass-staging-gate)
            BYPASS=1; shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown arg: $(printf %q "$1")" ;;
    esac
done
readonly BYPASS

# Paths to the two flag files this promotion reconciles.
STAGING_FEATURES="$PROJECT_DIR/config/www/user/env/staging.hackersbychoice.dk/config/features.yaml"
PROD_FEATURES="$PROJECT_DIR/config/www/user/env/www.byvaerkstederne.dk/config/features.yaml"
CODE_MARKER="$PROJECT_DIR/config/www/user/data-version.yaml"
readonly STAGING_FEATURES PROD_FEATURES CODE_MARKER

# ── 2. Determine mode (local vs live) ────────────────────────────────
LOCAL_MODE=0
LOCAL_TIER_DIR=""
if [ -n "${PROMOTE_PROD_LOCAL_TIER_DIR:-}" ]; then
    LOCAL_TIER_DIR="$PROMOTE_PROD_LOCAL_TIER_DIR"
    case "$LOCAL_TIER_DIR" in
        /*) ;;  # absolute — required
        *) die "PROMOTE_PROD_LOCAL_TIER_DIR must be an absolute path (got: $(printf %q "$LOCAL_TIER_DIR"))" ;;
    esac
    case "$LOCAL_TIER_DIR" in
        *..*) die "PROMOTE_PROD_LOCAL_TIER_DIR contains '..' — refusing for safety" ;;
    esac
    if [ ! -d "$LOCAL_TIER_DIR" ]; then
        die "PROMOTE_PROD_LOCAL_TIER_DIR does not exist or is not a directory: $(printf %q "$LOCAL_TIER_DIR")"
    fi
    LOCAL_MODE=1
fi
readonly LOCAL_MODE LOCAL_TIER_DIR

# YAML field extractors — shared helpers. Mirror migrate.sh's parser.
extract_yaml_field() {
    # extract_yaml_field <key> <path>
    local key="$1" path="$2"
    [ -f "$path" ] || { printf ''; return 0; }
    awk -v key="$key" '
        /^[[:space:]]*#/ { next }
        $0 ~ "^"key":[[:space:]]*" {
            v = $0
            sub("^"key":[[:space:]]*", "", v)
            gsub(/^["'\'']|["'\'']$/, "", v)
            sub(/[[:space:]]+#.*$/, "", v)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            print v
            exit
        }
    ' "$path"
}
extract_data_version_field() { extract_yaml_field data_version "$1"; }

# sha256 of a file (portable: shasum on macOS, sha256sum on Linux CI).
sha256_of() {
    local path="$1"
    [ -f "$path" ] || { printf ''; return 0; }
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
    else
        sha256sum "$path" | awk '{print $1}'
    fi
}

echo "=== promote-to-prod ==="
if [ "$LOCAL_MODE" = "1" ]; then
    note "mode:   LOCAL (PROMOTE_PROD_LOCAL_TIER_DIR=$LOCAL_TIER_DIR)"
else
    note "mode:   LIVE (prod)"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 0 — BRANCH GATE (spec §"The branch gate"). Runs before anything
# else, in BOTH modes — the flag-sync commit step would land on whatever
# branch is checked out, so the gate must hold even for local tests.
# ──────────────────────────────────────────────────────────────────────
log "Step 0: branch gate"
BRANCH="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || echo '')"
case "$BRANCH" in
    develop|main|master)
        die "promote-to-prod must run from a release/* or hotfix/* branch (current: $BRANCH). Branch off develop with \`git checkout -b release/v<X> develop\` and re-run."
        ;;
    release/*|hotfix/*)
        note "branch: $BRANCH (release/hotfix — ok)"
        ;;
    '')
        warn "could not determine current git branch — proceeding (detached HEAD?)"
        ;;
    *)
        warn "branch '$BRANCH' is not release/* or hotfix/* — proceeding anyway (allowed during bedding-in; tighten later)"
        ;;
esac
echo ""

# ── 3. Load credentials + helpers (live only) ────────────────────────
# Live mode needs SSH helpers + .env.deploy. Local mode never SSHes, so
# we don't require the env file there (matches the staging promote idiom).
ENV_FILE="${PROMOTE_PROD_ENV_FILE:-$PROJECT_DIR/.env.deploy}"
if [ "$LOCAL_MODE" != "1" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        die "Missing $ENV_FILE — copy .env.deploy.example and fill in prod credentials (or set PROMOTE_PROD_LOCAL_TIER_DIR for local-mode testing)"
    fi
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a

    # ── Staging SSH (to fetch the blessing marker) ──
    # bv_resolve_ssh_password dispatches on TIER, so we resolve the two
    # tiers' passwords under their own TIER below at call time.
    # shellcheck source=deploy/lib/ssh-auth.sh
    . "$SCRIPT_DIR/lib/ssh-auth.sh"

    : "${DEPLOY_HOST:?missing DEPLOY_HOST in .env.deploy (staging — needed to fetch the blessing)}"
    : "${DEPLOY_USER:?missing DEPLOY_USER in .env.deploy}"
    : "${DEPLOY_PATH:?missing DEPLOY_PATH in .env.deploy}"
    : "${DEPLOY_PORT:?missing DEPLOY_PORT in .env.deploy}"
    STAGING_DOCROOT="$DEPLOY_PATH/staging"
    BLESSING_REMOTE="$STAGING_DOCROOT/staging-blessed.yaml"

    # ── Prod SSH (deploy target + data dir + prod-root markers) ──
    : "${DEPLOY_PROD_HOST:?prod promote requires DEPLOY_PROD_HOST in .env.deploy — production is on a separate hosting account}"
    : "${DEPLOY_PROD_USER:?prod promote requires DEPLOY_PROD_USER in .env.deploy}"
    : "${DEPLOY_PROD_PATH:?prod promote requires DEPLOY_PROD_PATH in .env.deploy}"
    PROD_PORT="${DEPLOY_PROD_PORT:-${DEPLOY_PORT}}"
    # deploy.sh ships config/www/* to the prod docroot ($DEPLOY_PROD_PATH)
    # and keeps live state in the sibling proddata/ tree. The prod Grav
    # root is the docroot itself; prod-root markers (the bypass log) live
    # there, OUTSIDE user/ and OUTSIDE proddata/.
    PROD_DOCROOT="$DEPLOY_PROD_PATH"
    DATA_ROOT="$DEPLOY_PROD_PATH/proddata"
    PROD_FEATURES_REMOTE="$PROD_DOCROOT/user/env/www.byvaerkstederne.dk/config/features.yaml"
    BYPASS_LOG_REMOTE="$PROD_DOCROOT/prod-bypass-log.yaml"
else
    DATA_ROOT="$LOCAL_TIER_DIR/proddata"
    BYPASS_LOG_LOCAL="$LOCAL_TIER_DIR/prod-bypass-log.yaml"
fi

# Reusable SSH wrappers (live only). Staging and prod hosts may differ in
# auth (one.com password vs chosting.dk key) — run each under its TIER so
# bv_resolve_ssh_password dispatches correctly.
ssh_staging() {
    ( TIER="staging" bv_ssh_cmd -p "$DEPLOY_PORT" "${DEPLOY_USER}@${DEPLOY_HOST}" "$@" )
}
ssh_prod() {
    ( TIER="prod" bv_ssh_cmd -p "$PROD_PORT" "${DEPLOY_PROD_USER}@${DEPLOY_PROD_HOST}" "$@" )
}

# ── Resolve identity for audit/blessing comparison (both modes) ──
HEAD_COMMIT="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo '')"
[ -n "$HEAD_COMMIT" ] || die "could not resolve local HEAD commit (git rev-parse)"
CODE_VERSION="$(head -n1 "$PROJECT_DIR/config/www/VERSION" 2>/dev/null | tr -d '\r\n' || true)"
CODE_BUILD="$(git -C "$PROJECT_DIR" rev-list --count HEAD 2>/dev/null || echo '')"
TARGET_VERSION="$(extract_data_version_field "$CODE_MARKER")"
[ -n "$TARGET_VERSION" ] || die "could not determine target data version from $CODE_MARKER"
OPERATOR="$(whoami 2>/dev/null || echo unknown)"

# VDIR = the data-version dir name this promote builds + activates. Validate
# up front: it becomes an rm -rf / cp -a / ln target below.
VDIR="$(bv_version_to_dirname "$TARGET_VERSION")"
case "$VDIR" in
    ''|*/*|*..*) die "computed data-version dir name '$VDIR' is unsafe (empty / contains '/' or '..')" ;;
esac
readonly VDIR HEAD_COMMIT TARGET_VERSION OPERATOR

# ──────────────────────────────────────────────────────────────────────
# STEP 1 — THE BLESSING GATE (spec §"The blessing gate"), or the audited
# escape hatch (--bypass-staging-gate).
# ──────────────────────────────────────────────────────────────────────
log "Step 1/11: staging-blessing gate"

# Fetch staging's blessing marker into a local tempfile (live: SFTP/SSH;
# local: the injected stand-in file). Same for prod's live features.yaml.
BLESSING_TMP="$(mktemp "${TMPDIR:-/tmp}/bv-bless.XXXXXXXX")"
PROD_FEATURES_TMP="$(mktemp "${TMPDIR:-/tmp}/bv-prodfeat.XXXXXXXX")"
cleanup_gate_tmp() { rm -f "$BLESSING_TMP" "$PROD_FEATURES_TMP" 2>/dev/null || true; }
trap cleanup_gate_tmp EXIT INT TERM

run_blessing_gate() {
    # Returns 0 if every check passes; calls die() on the first failure.

    # (1) Fetch + present + parseable.
    if [ "$LOCAL_MODE" = "1" ]; then
        local src="${PROMOTE_PROD_LOCAL_BLESSING_FILE:-}"
        [ -n "$src" ] || die "local mode: set PROMOTE_PROD_LOCAL_BLESSING_FILE to the staging-blessing stand-in (or pass --bypass-staging-gate)"
        [ -f "$src" ] || die "staging blessing stand-in not found: $(printf %q "$src")"
        cp "$src" "$BLESSING_TMP" || die "could not read staging blessing stand-in: $(printf %q "$src")"
    else
        # No live HTTP read (bypassing Varnish caches) — fetch over SSH.
        # `cat` the marker; absence yields empty stdout we detect below.
        if ! ssh_staging "test -f $(printf %q "$BLESSING_REMOTE") && cat $(printf %q "$BLESSING_REMOTE")" > "$BLESSING_TMP" 2>/dev/null; then
            : # fall through — emptiness is the signal
        fi
    fi
    if [ ! -s "$BLESSING_TMP" ]; then
        die "staging blessing marker missing or empty (staging-blessed.yaml). Run ./deploy/promote-to-staging.sh first, or use --bypass-staging-gate."
    fi
    local b_commit b_dataver b_featsha
    b_commit="$(extract_yaml_field code_commit "$BLESSING_TMP")"
    b_dataver="$(extract_yaml_field data_version "$BLESSING_TMP")"
    b_featsha="$(extract_yaml_field features_yaml_sha256 "$BLESSING_TMP")"
    if [ -z "$b_commit" ] || [ -z "$b_dataver" ] || [ -z "$b_featsha" ]; then
        die "staging blessing marker is unparseable (missing code_commit / data_version / features_yaml_sha256)."
    fi
    note "blessing: code_commit=$b_commit data_version=$b_dataver"

    # (3) code_commit == local HEAD short sha.
    if [ "$b_commit" != "$HEAD_COMMIT" ]; then
        die "staging is blessed for $b_commit, you're trying to promote $HEAD_COMMIT; promote staging first"
    fi

    # (4) data_version == local code's data-version.yaml.
    if [ "$b_dataver" != "$TARGET_VERSION" ]; then
        die "data version mismatch: staging blessed for $b_dataver, local code requires $TARGET_VERSION"
    fi

    # (5) features_yaml_sha256 == sha256(local staging features.yaml).
    [ -f "$STAGING_FEATURES" ] || die "local staging features.yaml not found at $STAGING_FEATURES"
    local local_staging_sha
    local_staging_sha="$(sha256_of "$STAGING_FEATURES")"
    if [ "$b_featsha" != "$local_staging_sha" ]; then
        die "features.yaml SHA mismatch: staging has $b_featsha, local has $local_staging_sha"
    fi
    note "blessing checks passed (commit, data_version, features sha all match)"

    # (6) Prod-flag drift check. Fetch prod's LIVE features.yaml, compare
    # its sha to the prod features.yaml committed in git.
    if [ "$LOCAL_MODE" = "1" ]; then
        local pf="${PROMOTE_PROD_LOCAL_PROD_FEATURES:-}"
        [ -n "$pf" ] || die "local mode: set PROMOTE_PROD_LOCAL_PROD_FEATURES to prod's live-features stand-in (drift check)"
        [ -f "$pf" ] || die "prod live-features stand-in not found: $(printf %q "$pf")"
        cp "$pf" "$PROD_FEATURES_TMP" || die "could not read prod live-features stand-in: $(printf %q "$pf")"
    else
        if ! ssh_prod "test -f $(printf %q "$PROD_FEATURES_REMOTE") && cat $(printf %q "$PROD_FEATURES_REMOTE")" > "$PROD_FEATURES_TMP" 2>/dev/null; then
            : # empty stdout handled below
        fi
    fi
    [ -f "$PROD_FEATURES" ] || die "local git copy of prod features.yaml not found at $PROD_FEATURES"
    local git_prod_sha prod_live_sha
    git_prod_sha="$(sha256_of "$PROD_FEATURES")"
    if [ ! -s "$PROD_FEATURES_TMP" ]; then
        # No live prod features.yaml (fresh tier / first promote) — nothing
        # to drift from. Proceed; the flag sync will create it.
        note "prod has no live features.yaml yet — no drift to reconcile"
    else
        prod_live_sha="$(sha256_of "$PROD_FEATURES_TMP")"
        if [ "$prod_live_sha" != "$git_prod_sha" ]; then
            die "prod features.yaml has drifted from git: prod=$prod_live_sha, git=$git_prod_sha. Reconcile before continuing — either commit the drift to git, or accept that it'll be wiped by the upcoming flag sync. Re-run after reconciling."
        fi
        note "prod-flag drift check passed (prod live == git)"
    fi
    return 0
}

if [ "$BYPASS" = "1" ]; then
    # ── Escape hatch (spec §"The escape hatch") ──
    # Reason required, 50–500 chars; interactive y/N (NOT scriptable).
    if [ -z "$REASON" ]; then
        die "--bypass-staging-gate requires --reason (50–500 chars articulating why staging is being bypassed)"
    fi
    reason_len="${#REASON}"
    if [ "$reason_len" -lt 50 ]; then
        die "--reason is $reason_len chars; the bypass requires at least 50 (articulate the rationale in prose)"
    fi
    if [ "$reason_len" -gt 500 ]; then
        die "--reason is $reason_len chars; the bypass caps it at 500 (don't paste a whole stack trace)"
    fi
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  BYPASSING STAGING GATE                                   ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo "    commit:   $HEAD_COMMIT"
    echo "    operator: $OPERATOR"
    echo "    reason:   $REASON"
    echo ""
    # Interactive confirmation. NON-NEGOTIABLE for v1 — no --yes path.
    printf "  BYPASSING STAGING GATE — proceed (y/N)? "
    read -r bypass_confirm </dev/tty || bypass_confirm=""
    case "$bypass_confirm" in
        y|Y|yes|YES) note "bypass confirmed" ;;
        *) die "bypass aborted by operator (answer was not 'y')" ;;
    esac

    # Append the bypass entry to prod-bypass-log.yaml (append-only,
    # `---`-separated YAML docs, at the Grav root OUTSIDE user/).
    BYPASS_TS="$(date -u +%FT%TZ)"
    BYPASS_ENTRY="$(cat <<EOF
---
bypassed_at: "$BYPASS_TS"
operator: "$OPERATOR"
bypassed_commit: "$HEAD_COMMIT"
reason: "$REASON"
EOF
)"
    if [ "$LOCAL_MODE" = "1" ]; then
        printf '%s\n' "$BYPASS_ENTRY" >> "$BYPASS_LOG_LOCAL" \
            || die "appending bypass entry to $BYPASS_LOG_LOCAL failed"
        note "bypass logged: $BYPASS_LOG_LOCAL"
    else
        # Append over SSH. Stream the entry via stdin to a remote
        # `cat >>` so no shell-meta lands on the command line; the
        # destination path is printf %q-quoted. `>>` is append-only.
        if ! printf '%s\n' "$BYPASS_ENTRY" \
            | ssh_prod "cat >> $(printf %q "$BYPASS_LOG_REMOTE")"; then
            die "appending bypass entry to prod-bypass-log.yaml on prod failed"
        fi
        note "bypass logged on prod: $BYPASS_LOG_REMOTE"
    fi
    warn "STAGING GATE BYPASSED — this run is recorded in prod-bypass-log.yaml"
else
    run_blessing_gate
    note "staging-blessing gate passed"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 2 — tagged "before-promotion" backup of prod (rollback insurance).
# Tag pre-promotion-v<X>-build<N>; the tag exempts it from retention sweeps.
# ──────────────────────────────────────────────────────────────────────
PRE_TAG="pre-promotion-v${TARGET_VERSION}-build${CODE_BUILD:-0}"
# backup.sh's --tag validator allows [A-Za-z0-9._-]; the tag above is safe.
log "Step 2/11: taking a tagged pre-promotion backup of prod (tag: $PRE_TAG)"
BACKUP_ID=""
BACKUP_DATA_VERSION=""
if [ "$LOCAL_MODE" = "1" ]; then
    # In local mode, backup.sh runs against the fixture (BACKUP_FIXTURE_DIR
    # is set by the test harness) and writes to BACKUP_LOCAL_STORE_DIR.
    BACKUP_OUT="$("$SCRIPT_DIR/backup.sh" prod --tag "$PRE_TAG")" \
        || die "pre-promotion backup failed (local mode) — aborting; nothing changed" 2
else
    BACKUP_OUT="$("$SCRIPT_DIR/backup.sh" prod --tag "$PRE_TAG")" \
        || die "pre-promotion backup failed — aborting; nothing changed on prod" 2
fi
BACKUP_ID="$(printf '%s\n' "$BACKUP_OUT" | awk -F= '/^archive=/ { print $2; exit }')"
BACKUP_DATA_VERSION="$(printf '%s\n' "$BACKUP_OUT" | awk -F= '/^data_version=/ { print $2; exit }')"
[ -n "$BACKUP_ID" ] || die "could not parse archive id from backup.sh output" 2
note "backup id:           $BACKUP_ID"
note "backup data_version: ${BACKUP_DATA_VERSION:-<unknown>}"
echo ""

# The verbatim rollback command we print on any post-deploy failure.
ROLLBACK_HINT="    ./deploy/rollback-prod.sh \\
        --to-backup $BACKUP_ID \\
        --yes-i-mean-it"

# ──────────────────────────────────────────────────────────────────────
# STEP 3 — restore the backup into a scratch dir (restore-to-scratch).
# ──────────────────────────────────────────────────────────────────────
if [ -n "${PROMOTE_PROD_SCRATCH_DIR:-}" ]; then
    case "$PROMOTE_PROD_SCRATCH_DIR" in
        /*) ;;
        *) die "PROMOTE_PROD_SCRATCH_DIR must be an absolute path (got: $(printf %q "$PROMOTE_PROD_SCRATCH_DIR"))" ;;
    esac
    case "$PROMOTE_PROD_SCRATCH_DIR" in
        *..*) die "PROMOTE_PROD_SCRATCH_DIR contains '..' — refusing for safety" ;;
    esac
    SCRATCH="$PROMOTE_PROD_SCRATCH_DIR"
    if [ -e "$SCRATCH" ] && [ -n "$(ls -A "$SCRATCH" 2>/dev/null)" ]; then
        die "PROMOTE_PROD_SCRATCH_DIR is not empty: $SCRATCH (move it aside or pick another)"
    fi
else
    SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/bv-promote-prod.XXXXXXXX")"
    rmdir "$SCRATCH" 2>/dev/null || true
    SCRATCH="$SCRATCH/scratch"
fi

log "Step 3/11: restoring backup into scratch dir"
note "scratch: $SCRATCH"
if ! "$SCRIPT_DIR/restore.sh" --to "$SCRATCH" --from "$BACKUP_ID" >/dev/null; then
    die "restore-to-scratch failed for backup id '$BACKUP_ID' — aborting; prod untouched (scratch: $SCRATCH)" 2
fi
note "restore complete"
echo ""

# On any failure from here, leave the scratch dir for inspection.
fail_with_scratch() {
    warn "scratch dir left for inspection: $SCRATCH"
    die "$1" "${2:-1}"
}

# Failures AFTER prod has been touched additionally print the verbatim
# rollback command (spec §"Failure handling").
fail_after_prod_touched() {
    warn "scratch dir left for inspection: $SCRATCH"
    {
        echo ""
        echo "$1"
        echo ""
        echo "prod may be in an inconsistent state. To roll back to the"
        echo "pre-promotion snapshot, run:"
        echo ""
        echo "$ROLLBACK_HINT"
        echo ""
    } >&2
    exit "${2:-1}"
}

# ──────────────────────────────────────────────────────────────────────
# STEP 4 — source + target data versions.
# ──────────────────────────────────────────────────────────────────────
log "Step 4/11: reading source + target data versions"
META="$SCRATCH/backup-meta.yaml"
SOURCE_VERSION=""
if [ -f "$META" ]; then
    SOURCE_VERSION="$(extract_data_version_field "$META")"
fi
if [ -z "$SOURCE_VERSION" ] && [ -n "$BACKUP_DATA_VERSION" ]; then
    SOURCE_VERSION="$BACKUP_DATA_VERSION"
fi
[ -n "$SOURCE_VERSION" ] || fail_with_scratch "could not determine source data version (no data_version in $META and none reported by backup.sh)"
note "source (prod snapshot): $SOURCE_VERSION"
note "target (current code):  $TARGET_VERSION"
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 5 — make the scratch a valid migrate data-dir and migrate it
# (LOCALLY, on the scratch snapshot). Prod promotion never depends on the
# unshipped remote-mode migration runner.
# ──────────────────────────────────────────────────────────────────────
log "Step 5/11: preparing + migrating the scratch snapshot"
mkdir -p "$SCRATCH/user"
SCRATCH_MARKER="$SCRATCH/user/data-version.yaml"

if [ "$SOURCE_VERSION" = "$TARGET_VERSION" ]; then
    note "source == target ($TARGET_VERSION): no migration needed"
    printf 'data_version: "%s"\n' "$TARGET_VERSION" > "$SCRATCH_MARKER"
else
    note "migration required: $SOURCE_VERSION → $TARGET_VERSION"
    printf 'data_version: "%s"\n' "$SOURCE_VERSION" > "$SCRATCH_MARKER"
    if ! "$SCRIPT_DIR/migrate.sh" "$SCRATCH" --to "$TARGET_VERSION"; then
        fail_with_scratch "migration $SOURCE_VERSION → $TARGET_VERSION failed — prod untouched"
    fi
    post="$(extract_data_version_field "$SCRATCH_MARKER")"
    if [ "$post" != "$TARGET_VERSION" ]; then
        fail_with_scratch "post-migration data version is '$post', expected '$TARGET_VERSION'"
    fi
    note "migration complete: scratch now at $TARGET_VERSION"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 6 — sync staging features.yaml → prod features.yaml, and COMMIT it
# on the current release/* or hotfix/* branch. Refuse if the working tree
# has OTHER uncommitted changes (clean checkpoint).
# ──────────────────────────────────────────────────────────────────────
log "Step 6/11: syncing staging flags to prod + committing on $BRANCH"
[ -f "$STAGING_FEATURES" ] || fail_with_scratch "staging features.yaml not found at $STAGING_FEATURES" 6
[ -f "$PROD_FEATURES" ]    || warn "prod features.yaml absent at $PROD_FEATURES — it will be created by the sync"

# Clean-checkpoint guard: the only path we permit to be dirty is the prod
# features file itself (it may already carry the synced bytes from a prior
# aborted run). Anything else dirty → refuse.
PROD_FEATURES_REL="config/www/user/env/www.byvaerkstederne.dk/config/features.yaml"
OTHER_DIRTY="$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null \
    | awk -v keep="$PROD_FEATURES_REL" '{ p=$2 } $2 != keep { print }')"
if [ -n "$OTHER_DIRTY" ]; then
    fail_with_scratch "working tree has uncommitted changes other than the prod features.yaml — commit or stash them first, then re-run (clean-checkpoint required):
$OTHER_DIRTY" 6
fi

# Perform the copy (preserving nothing but bytes — features.yaml is plain
# YAML; deploy.sh ships it as-is).
cp "$STAGING_FEATURES" "$PROD_FEATURES" \
    || fail_with_scratch "copying staging features.yaml → prod features.yaml failed" 6

if git -C "$PROJECT_DIR" diff --quiet -- "$PROD_FEATURES_REL" \
   && git -C "$PROJECT_DIR" diff --cached --quiet -- "$PROD_FEATURES_REL"; then
    note "prod features.yaml already in sync with staging — no commit needed"
else
    git -C "$PROJECT_DIR" add -- "$PROD_FEATURES_REL" \
        || fail_with_scratch "git add of prod features.yaml failed" 6
    if ! git -C "$PROJECT_DIR" commit -m "chore: sync staging flags to prod for v${CODE_VERSION:-$TARGET_VERSION}" -- "$PROD_FEATURES_REL"; then
        fail_with_scratch "git commit of the flag sync failed" 6
    fi
    note "flag-sync committed on $BRANCH"
    # The commit changed HEAD; recompute the short sha so version.json /
    # the audit summary reflect what actually ships.
    HEAD_COMMIT_AFTER_SYNC="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || echo "$HEAD_COMMIT")"
fi
HEAD_COMMIT_AFTER_SYNC="${HEAD_COMMIT_AFTER_SYNC:-$HEAD_COMMIT}"
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 7 — BUILD + ACTIVATE the prod versioned data dir (ADR-005). Runs
# BEFORE the code deploy so deploy.sh wires the new release's symlinks to
# the dir we just activated. (Spec numbers the code deploy as step 7 and
# the data push as step 8; per the serving model the BUILD must precede
# the deploy, so we order BUILD → DEPLOY here, mirroring promote-to-staging.)
# ──────────────────────────────────────────────────────────────────────
STATE_SUBDIRS=(accounts data pages uploads)   # FIXED list — secrets/config untouched
readonly STATE_SUBDIRS

log "Step 7/11: building + activating prod versioned data dir ($DATA_ROOT/$VDIR)"

build_activate_local() {
    local data_root="$1" scratch_marker="$2"
    local current_vdir
    current_vdir="$(basename "$(readlink "$data_root/current" 2>/dev/null || echo v0)")"
    note "current data-version dir: $current_vdir → building $VDIR"

    if [ -d "$data_root/$VDIR" ]; then
        # String-rooted under DATA_ROOT; VDIR validated single-component.
        note "  $VDIR already exists — removing before rebuild"
        rm -rf "$data_root/$VDIR"
    fi
    if [ -d "$data_root/$current_vdir" ]; then
        note "  cp -a $current_vdir → $VDIR (inherit per-tier secrets/config/env)"
        cp -a "$data_root/$current_vdir" "$data_root/$VDIR" \
            || fail_after_prod_touched "cp -a $current_vdir → $VDIR failed" 7
    else
        note "  fresh tier ($current_vdir absent) — creating $VDIR/user skeleton"
        mkdir -p "$data_root/$VDIR/user" \
            || fail_after_prod_touched "could not create $data_root/$VDIR/user" 7
    fi

    mkdir -p "$data_root/$VDIR/user"
    local sub src dst
    for sub in "${STATE_SUBDIRS[@]}"; do
        src="$SCRATCH/user/$sub"
        if [ ! -d "$src" ]; then
            note "  skip user/$sub (absent in scratch)"
            continue
        fi
        dst="$data_root/$VDIR/user/$sub"
        mkdir -p "$dst"
        note "  rsync --delete user/$sub/ → $VDIR"
        rsync -a --delete -- "$src/" "$dst/" \
            || fail_after_prod_touched "local rsync of user/$sub into $dst failed" 7
    done
    if [ -f "$scratch_marker" ]; then
        cp "$scratch_marker" "$data_root/$VDIR/user/data-version.yaml" \
            || fail_after_prod_touched "copying data-version.yaml into $VDIR failed" 7
    fi
    ln -sfn "$VDIR" "$data_root/current" \
        || fail_after_prod_touched "repointing $data_root/current → $VDIR failed" 7
    note "  current → $VDIR (release deployed next binds to this dir)"
}

if [ "$LOCAL_MODE" = "1" ]; then
    build_activate_local "$DATA_ROOT" "$SCRATCH_MARKER"
else
    rsync_e="$(TIER="prod" bv_rsync_ssh_e "$PROD_PORT")" \
        || fail_after_prod_touched "could not build rsync ssh-cmd for prod (sshpass missing?)" 7

    # (a) resolve the live data-version dir over SSH.
    CURRENT_VDIR="$(ssh_prod "basename \"\$(readlink $(printf %q "$DATA_ROOT/current") 2>/dev/null || echo v0)\"")" \
        || fail_after_prod_touched "could not read $DATA_ROOT/current on prod" 7
    CURRENT_VDIR="$(basename "$CURRENT_VDIR")"
    case "$CURRENT_VDIR" in
        ''|*/*|*..*) fail_after_prod_touched "live prod current data-version dir '$CURRENT_VDIR' is unsafe" 7 ;;
    esac
    note "current data-version dir: $CURRENT_VDIR → building $VDIR"

    # (c) build a COMPLETE v_<target> over SSH. VDIR + CURRENT_VDIR are
    # validated single components; DATA_ROOT is operator-config. Each path
    # is printf %q-quoted into the remote command. The rm -rf is
    # string-rooted under DATA_ROOT/<VDIR> and only fires on a pre-existing
    # rebuild of the SAME target dir.
    if ! ssh_prod "
        set -e
        if [ -d $(printf %q "$DATA_ROOT/$VDIR") ]; then rm -rf $(printf %q "$DATA_ROOT/$VDIR"); fi
        if [ -d $(printf %q "$DATA_ROOT/$CURRENT_VDIR") ]; then
            cp -a $(printf %q "$DATA_ROOT/$CURRENT_VDIR") $(printf %q "$DATA_ROOT/$VDIR")
        else
            mkdir -p $(printf %q "$DATA_ROOT/$VDIR/user")
        fi
    "; then
        fail_after_prod_touched "building $VDIR on prod (rm/cp -a) failed" 7
    fi
    ssh_prod "mkdir -p $(printf %q "$DATA_ROOT/$VDIR/user")" \
        || fail_after_prod_touched "could not create $DATA_ROOT/$VDIR/user on prod" 7

    # (d) overlay the migrated snapshot — accounts/data/pages/uploads only.
    for sub in "${STATE_SUBDIRS[@]}"; do
        src="$SCRATCH/user/$sub"
        if [ ! -d "$src" ]; then
            note "  skip user/$sub (absent in scratch)"
            continue
        fi
        remote_dst="$DATA_ROOT/$VDIR/user/$sub"
        ssh_prod "mkdir -p $(printf %q "$remote_dst")" \
            || fail_after_prod_touched "could not create $remote_dst on prod" 7
        note "  rsync --delete user/$sub/ → prod:$VDIR"
        # Per-subdirectory rsync --delete into the versioned data dir — the
        # ONLY destructive overlay write. Touches exactly the four data
        # subdirs, never user/config (secrets inherited by cp -a above),
        # never the bypass log (prod root, different tree).
        ( TIER="prod" bv_rsync_via_ssh -az --delete -e "$rsync_e" \
            "$src/" "${DEPLOY_PROD_USER}@${DEPLOY_PROD_HOST}:${remote_dst}/" ) \
            || fail_after_prod_touched "rsync of user/$sub to prod failed" 7
    done
    if [ -f "$SCRATCH_MARKER" ]; then
        ( TIER="prod" bv_rsync_via_ssh -az -e "$rsync_e" \
            "$SCRATCH_MARKER" "${DEPLOY_PROD_USER}@${DEPLOY_PROD_HOST}:${DATA_ROOT}/${VDIR}/user/data-version.yaml" ) \
            || fail_after_prod_touched "rsync of data-version.yaml to prod failed" 7
    fi

    # (e) repoint current → VDIR (relative target) over SSH.
    ssh_prod "ln -sfn $(printf %q "$VDIR") $(printf %q "$DATA_ROOT/current")" \
        || fail_after_prod_touched "repointing prod current → $VDIR failed" 7
    note "  current → $VDIR (release deployed next binds to this dir)"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 8 — deploy code to prod (code-only; --skip-data-migration).
# `current` already points at v_<target>, so deploy.sh wires the new
# release's symlinks to it. The deploy includes the new prod features.yaml
# from step 6.
# ──────────────────────────────────────────────────────────────────────
log "Step 8/11: deploying code to prod (deploy.sh prod --skip-data-migration)"
if [ "$LOCAL_MODE" = "1" ]; then
    note "local mode: skipping real code deploy"
else
    if ! "$SCRIPT_DIR/deploy.sh" prod --skip-data-migration; then
        fail_after_prod_touched "code deploy to prod failed — prod may have the new data dir with old code; redeploy or roll back" 8
    fi
    note "code deployed to prod (--skip-data-migration); release wired to $VDIR"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 9 — clear prod caches (deploy.sh already clears in the new release;
# this is belt-and-braces for the live docroot).
# ──────────────────────────────────────────────────────────────────────
log "Step 9/11: clearing prod cache"
if [ "$LOCAL_MODE" = "1" ]; then
    grav_bin="$LOCAL_TIER_DIR/bin/grav"
    if [ -f "$grav_bin" ]; then
        if ( cd "$LOCAL_TIER_DIR" && bin/grav clearcache ) >/dev/null 2>&1; then
            note "cache cleared"
        else
            warn "bin/grav clearcache returned non-zero (continuing; cache refills naturally)"
        fi
    else
        note "no Grav binary at $grav_bin — skipping cache clear"
    fi
else
    if ! ssh_prod "cd $(printf %q "$PROD_DOCROOT") && php bin/grav clearcache"; then
        warn "cache clear failed on prod (continuing; cache refills naturally)"
    else
        note "cache cleared"
    fi
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 10 — smoke test (live only). On failure, print the failure AND the
# exact verbatim rollback command (spec §10). No auto-rollback.
# ──────────────────────────────────────────────────────────────────────
log "Step 10/11: smoke test"
if [ "$LOCAL_MODE" = "1" ]; then
    note "local mode: skipping curl smoke test"
else
    SMOKE_BASE="https://www.byvaerkstederne.dk"
    smoke_fail=0
    smoke_failed_url=""
    smoke_want=""
    smoke_got=""
    smoke_check() {
        local rel="$1" want="$2"
        local code
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "$SMOKE_BASE$rel" || echo "000")"
        if [ "$code" != "$want" ]; then
            warn "smoke: $rel returned $code, expected $want"
            if [ "$smoke_fail" = "0" ]; then
                smoke_fail=1
                smoke_failed_url="$SMOKE_BASE$rel"
                smoke_want="$want"
                smoke_got="$code"
            fi
            return 0
        fi
        note "smoke: $rel → $code (ok)"
    }
    smoke_check "/"               200
    smoke_check "/login"          200
    smoke_check "/medlemmer"      302
    smoke_check "/begivenheder"   200
    smoke_check "/vaerksteder"    200
    # Build-is-live is already validated by deploy.sh's own internal smoke
    # probe (the homepage "build <N>" version substring) during step 8, so
    # we do NOT probe /version.json here: the prod .htaccess denies it
    # (Require all denied → 403), which would false-fail this gate. The
    # homepage 200 above + deploy.sh's substring probe are the liveness
    # signal.

    if [ "$smoke_fail" = "1" ]; then
        {
            echo ""
            echo "SMOKE TEST FAILED on $smoke_failed_url"
            echo "Expected $smoke_want, got $smoke_got."
            echo ""
            echo "To roll back to the pre-promotion snapshot, run:"
            echo "$ROLLBACK_HINT"
            echo ""
        } >&2
        # Leave the scratch for inspection; prod is live with the new
        # release — the operator decides whether to roll back.
        warn "scratch dir left for inspection: $SCRATCH"
        exit 1
    fi
    note "all smoke checks passed"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────
# STEP 11 — summary + append to deploy/promotion-log.jsonl (gitignored).
# ──────────────────────────────────────────────────────────────────────
log "Step 11/11: summary"
PROMOTED_AT="$(date -u +%FT%TZ)"
echo ""
echo "  ✓ promote-to-prod complete"
echo "    pre-promotion backup: $BACKUP_ID (tag: $PRE_TAG)"
if [ "$SOURCE_VERSION" = "$TARGET_VERSION" ]; then
    echo "    migrations:           none ($TARGET_VERSION already)"
else
    echo "    migrations:           $SOURCE_VERSION → $TARGET_VERSION"
fi
echo "    code version:         ${CODE_VERSION:-<unknown>} (commit $HEAD_COMMIT_AFTER_SYNC, build ${CODE_BUILD:-<unknown>})"
echo "    data version:         $TARGET_VERSION (served from $DATA_ROOT/$VDIR; current → $VDIR)"
echo "    flag sync:            staging features.yaml → prod features.yaml"
if [ "$BYPASS" = "1" ]; then
    echo "    staging gate:         BYPASSED (logged to prod-bypass-log.yaml)"
else
    echo "    staging gate:         passed (blessing verified)"
fi
echo "    prod url:             https://www.byvaerkstederne.dk/"
echo "    operator:             $OPERATOR"
echo "    reason:               ${REASON:-<none>}"
echo "    promoted_at:          $PROMOTED_AT"
echo ""

# Append a JSON line to the operator-local promotion journal. Built with
# printf so embedded quotes/backslashes in --reason are escaped.
json_escape() {
    # Escape backslash and double-quote, strip control chars (newlines etc.).
    printf '%s' "$1" | awk '
        BEGIN { ORS="" }
        { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, " "); print }
    '
}
PROMOTION_LOG="${PROMOTE_PROD_LOG_FILE:-$PROJECT_DIR/deploy/promotion-log.jsonl}"
{
    printf '{'
    printf '"promoted_at":"%s",' "$(json_escape "$PROMOTED_AT")"
    printf '"pre_promotion_backup":"%s",' "$(json_escape "$BACKUP_ID")"
    printf '"pre_promotion_tag":"%s",' "$(json_escape "$PRE_TAG")"
    if [ "$SOURCE_VERSION" = "$TARGET_VERSION" ]; then
        printf '"migrations":"none",'
    else
        printf '"migrations":"%s→%s",' "$(json_escape "$SOURCE_VERSION")" "$(json_escape "$TARGET_VERSION")"
    fi
    printf '"code_version":"%s",' "$(json_escape "${CODE_VERSION:-}")"
    printf '"code_commit":"%s",' "$(json_escape "$HEAD_COMMIT_AFTER_SYNC")"
    printf '"data_version":"%s",' "$(json_escape "$TARGET_VERSION")"
    printf '"flag_sync":"staging→prod",'
    printf '"bypassed":%s,' "$([ "$BYPASS" = "1" ] && echo true || echo false)"
    printf '"prod_url":"https://www.byvaerkstederne.dk/",'
    printf '"operator":"%s",' "$(json_escape "$OPERATOR")"
    printf '"reason":"%s"' "$(json_escape "$REASON")"
    printf '}\n'
} >> "$PROMOTION_LOG" \
    || warn "could not append to promotion journal $PROMOTION_LOG (promotion itself succeeded)"
note "journal appended: $PROMOTION_LOG"

# Cleanup scratch on success.
if [ -d "$SCRATCH" ]; then
    rm -rf "$SCRATCH"
    note "scratch removed"
fi

exit 0
