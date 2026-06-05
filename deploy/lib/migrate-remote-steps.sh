#!/usr/bin/env bash
#
# Remote-mode migration steps — destructive operations that must run
# on the tier host. Sourced as a stdin script via:
#
#     ssh ... bash -s -- "$DOCROOT" "$DATA_DIR" "$RELEASES_DIR" \
#                          "$BOOTSTRAP_ID" "$ENV" \
#                          < deploy/lib/migrate-remote-steps.sh
#
# This file is the SSH-side counterpart to the inline steps 1, 3, 4, 5,
# and 6 in deploy/migrate-to-atomic-layout.sh. The local script handles:
#   - argument parsing & tier validation       (before this script runs)
#   - step 2: pre-flight backup                (already ssh-aware)
#   - generating BOOTSTRAP_ID                  (passed in as $4)
#   - writing release-meta.yaml + uploading it (after this script runs)
#   - step 7: smoke probe                      (hits the public URL)
#
# Why a separate file rather than inlined into migrate-to-atomic-layout.sh:
#   - Auditability. The destructive operations are reviewable as one
#     contiguous shell program rather than scattered across SSH wrappers.
#   - Atomicity of failure mode. One ssh round-trip = one exit code; if
#     any mv/rmdir/ln fails, the whole remote phase aborts and the local
#     driver surfaces the recovery hint with the pre-flight backup id.
#   - Testability. The file is shellcheck-clean and runs against a local
#     fixture parent for unit tests (see tests/deploy/unit-migrate-remote.sh
#     — added in the same commit as this file).
#
# Constraints (one.com shared hosting):
#   - bash 4+ is NOT guaranteed on the remote. Stick to POSIX-ish syntax
#     where possible; avoid bashisms beyond `[[ ]]` (which dash lacks but
#     bash 3.2 supports).
#   - No `find -print0` reliance — busybox find on shared hosts may lack
#     it. We enumerate with `ls -A` + manual quoting via NUL via a
#     portable read loop (see step 4 below).
#   - No `coreutils` extras — `date +%s%N` is unavailable; the local
#     driver does ms timing on its own clock.
#
# Security:
#   - All five positional args are path components built by the local
#     driver from .env.deploy + the closed-set tier name. The local
#     driver validates them before calling.
#   - Every variable that flows into mv/ln/rmdir/mkdir is double-quoted
#     and passed as a separate argument. No eval.
#   - The script never reads from stdin after the shebang line, so the
#     `bash -s -- ...` invocation is safe to mix script + args without
#     stdin contamination.

set -euo pipefail

# ── Argument receipt ──────────────────────────────────────────────────

if [ "$#" -ne 5 ]; then
    echo "FATAL: migrate-remote-steps.sh expects 5 positional args (got $#)" >&2
    echo "       DOCROOT DATA_DIR RELEASES_DIR BOOTSTRAP_ID ENV" >&2
    exit 1
fi

DOCROOT="$1"
DATA_DIR="$2"
RELEASES_DIR="$3"
BOOTSTRAP_ID="$4"
ENV="$5"

# Defensive: sanity-check the values one more time on the remote side.
# The local driver validates these; this is belt-and-braces in case the
# script is ever invoked outside the driver.
case "$DOCROOT"      in *..*|"") echo "FATAL: bad DOCROOT" >&2; exit 1 ;; esac
case "$DATA_DIR"     in *..*|"") echo "FATAL: bad DATA_DIR" >&2; exit 1 ;; esac
case "$RELEASES_DIR" in *..*|"") echo "FATAL: bad RELEASES_DIR" >&2; exit 1 ;; esac
case "$BOOTSTRAP_ID" in *..*|*/*|"") echo "FATAL: bad BOOTSTRAP_ID" >&2; exit 1 ;; esac
case "$ENV" in
    dev|test|staging|prod) ;;
    *) echo "FATAL: bad ENV '$ENV' (expected dev|test|staging|prod)" >&2; exit 1 ;;
esac
case "$BOOTSTRAP_ID" in
    migrate-bootstrap-[0-9]*) ;;
    *) echo "FATAL: BOOTSTRAP_ID '$BOOTSTRAP_ID' does not match expected prefix" >&2; exit 1 ;;
esac

BOOTSTRAP_DIR="$RELEASES_DIR/$BOOTSTRAP_ID"

# A tier-name-derived basename for the data dir, used in the §Symlink
# contract relative-target paths. Mirrors local mode.
DATA_DIR_NAME="$(basename "$DATA_DIR")"

# ── Step 1: SANITY CHECK ──────────────────────────────────────────────

echo "→ [remote] Step 1: Sanity check — refuse if already atomic..."

DOCROOT_IS_SYMLINK=0
DATA_DIR_EXISTS=0
RELEASES_DIR_HAS_CONTENT=0

if [ -L "$DOCROOT" ]; then DOCROOT_IS_SYMLINK=1; fi
if [ -d "$DATA_DIR" ]; then DATA_DIR_EXISTS=1; fi
if [ -d "$RELEASES_DIR" ] && [ -n "$(ls -A "$RELEASES_DIR" 2>/dev/null || true)" ]; then
    RELEASES_DIR_HAS_CONTENT=1
fi

if [ "$DOCROOT_IS_SYMLINK" = "1" ] || [ "$DATA_DIR_EXISTS" = "1" ] || [ "$RELEASES_DIR_HAS_CONTENT" = "1" ]; then
    if [ "$DOCROOT_IS_SYMLINK" = "1" ] && [ "$DATA_DIR_EXISTS" = "1" ] && [ "$RELEASES_DIR_HAS_CONTENT" = "1" ]; then
        echo "❌  Tier '$ENV' already in atomic layout (already migrated)." >&2
    else
        echo "❌  Tier '$ENV' is in MIXED-SIGNAL state — partial migration or hand-edit." >&2
        [ "$DOCROOT_IS_SYMLINK" = "1" ]      && echo "    • $DOCROOT is a symlink" >&2
        [ "$DATA_DIR_EXISTS" = "1" ]         && echo "    • $DATA_DIR exists" >&2
        [ "$RELEASES_DIR_HAS_CONTENT" = "1" ] && echo "    • $RELEASES_DIR has content" >&2
    fi
    exit 1
fi

if [ ! -d "$DOCROOT" ]; then
    echo "❌  Docroot '$DOCROOT' is not a directory; cannot migrate." >&2
    exit 1
fi

echo "  ✓ Tier in legacy layout."

# ── Step 3: <tier>data/v0/ + state moves ──────────────────────────────

echo "→ [remote] Step 3: Creating $DATA_DIR/v0/ and moving live state subtrees..."

mkdir -p "$DATA_DIR/v0/user/accounts"
mkdir -p "$DATA_DIR/v0/user/data"
mkdir -p "$DATA_DIR/v0/user/config"
mkdir -p "$DATA_DIR/v0/user/env/$ENV/config"
mkdir -p "$DATA_DIR/logs"

# user/accounts/  →  <tier>data/v0/user/accounts/
if [ -d "$DOCROOT/user/accounts" ]; then
    rmdir "$DATA_DIR/v0/user/accounts"
    mv "$DOCROOT/user/accounts" "$DATA_DIR/v0/user/accounts"
    [ -d "$DATA_DIR/v0/user/accounts" ] || { echo "❌  state move failed: user/accounts/" >&2; exit 1; }
fi

# user/data/  →  <tier>data/v0/user/data/
if [ -d "$DOCROOT/user/data" ]; then
    rmdir "$DATA_DIR/v0/user/data"
    mv "$DOCROOT/user/data" "$DATA_DIR/v0/user/data"
    [ -d "$DATA_DIR/v0/user/data" ] || { echo "❌  state move failed: user/data/" >&2; exit 1; }
fi

# user/config/security.yaml  →  <tier>data/v0/user/config/security.yaml
if [ -f "$DOCROOT/user/config/security.yaml" ]; then
    mv "$DOCROOT/user/config/security.yaml" "$DATA_DIR/v0/user/config/security.yaml"
    [ -f "$DATA_DIR/v0/user/config/security.yaml" ] || { echo "❌  state move failed: user/config/security.yaml" >&2; exit 1; }
fi

# user/env/<env>/config/security.yaml  →  <tier>data/v0/user/env/<env>/config/security.yaml
if [ -f "$DOCROOT/user/env/$ENV/config/security.yaml" ]; then
    mv "$DOCROOT/user/env/$ENV/config/security.yaml" "$DATA_DIR/v0/user/env/$ENV/config/security.yaml"
    [ -f "$DATA_DIR/v0/user/env/$ENV/config/security.yaml" ] || { echo "❌  state move failed: user/env/$ENV/config/security.yaml" >&2; exit 1; }
fi

# logs/  →  <tier>data/logs/
if [ -d "$DOCROOT/logs" ]; then
    rmdir "$DATA_DIR/logs"
    mv "$DOCROOT/logs" "$DATA_DIR/logs"
    [ -d "$DATA_DIR/logs" ] || { echo "❌  state move failed: logs/" >&2; exit 1; }
fi

# Bootstrap data-dir 'current' symlink (v0 is the only data version
# in Phase 1; mirrors local mode).
ln -sfn "v0" "$DATA_DIR/current"

echo "  ✓ State subtrees relocated under $DATA_DIR/v0/."

# ── Step 4: bootstrap release dir + move remaining tree in ───────────

echo "→ [remote] Step 4: Creating $BOOTSTRAP_DIR and moving remaining live tree..."

mkdir -p "$BOOTSTRAP_DIR"

# Move every remaining top-level entry from $DOCROOT/ into the bootstrap
# release dir. We avoid `find -print0` for shared-host portability:
# instead, ls -A1 emits one entry per line — we set IFS to newline only
# and read carefully. Filenames with newlines are not produced by Grav
# or rsync deploy.sh; documented assumption.
#
# Notes:
#   - `ls -A` lists dotfiles (.htaccess) but NOT . and ..
#   - The state subtrees that step 3 already moved out are gone, so
#     they cannot be re-moved here.
#   - Any failure inside the loop trips `set -e` and aborts.
old_ifs="$IFS"
IFS='
'
# shellcheck disable=SC2012
for entry in $(ls -A1 "$DOCROOT" 2>/dev/null); do
    case "$entry" in
        ""|.|..) continue ;;
    esac
    mv "$DOCROOT/$entry" "$BOOTSTRAP_DIR/$entry"
done
IFS="$old_ifs"

echo "  ✓ Remaining live-tree entries moved into bootstrap release dir."

# ── Step 5: §Symlink contract — five symlinks ─────────────────────────

echo "→ [remote] Step 5: Wiring §Symlink contract inside bootstrap release dir..."

# Make sure containing dirs exist (rsync may not have created
# user/env/<env>/config/ on a minimal source tree).
mkdir -p "$BOOTSTRAP_DIR/user/config"
mkdir -p "$BOOTSTRAP_DIR/user/env/$ENV/config"

# Remove any plain dirs/files at the symlink targets first so ln -sfn
# can replace them. ln -sfn only replaces existing SYMLINKS atomically;
# a real dir would block it. The targets are, by construction, rooted
# at the freshly-created $BOOTSTRAP_DIR, so this rm cannot escape into
# $DATA_DIR or anywhere else.
for tp in \
    "$BOOTSTRAP_DIR/user/accounts" \
    "$BOOTSTRAP_DIR/user/data" \
    "$BOOTSTRAP_DIR/user/config/security.yaml" \
    "$BOOTSTRAP_DIR/user/env/$ENV/config/security.yaml" \
    "$BOOTSTRAP_DIR/logs"
do
    if [ -e "$tp" ] && [ ! -L "$tp" ]; then
        rm -rf "$tp"
    fi
done

ln -sfn "../../../$DATA_DIR_NAME/v0/user/accounts" \
    "$BOOTSTRAP_DIR/user/accounts"
ln -sfn "../../../$DATA_DIR_NAME/v0/user/data" \
    "$BOOTSTRAP_DIR/user/data"
ln -sfn "../../../../$DATA_DIR_NAME/v0/user/config/security.yaml" \
    "$BOOTSTRAP_DIR/user/config/security.yaml"
ln -sfn "../../../../../../$DATA_DIR_NAME/v0/user/env/$ENV/config/security.yaml" \
    "$BOOTSTRAP_DIR/user/env/$ENV/config/security.yaml"
ln -sfn "../../$DATA_DIR_NAME/logs" \
    "$BOOTSTRAP_DIR/logs"

echo "  ✓ Five symlinks wired."

# ── Step 6: replace <tier>/ with a symlink (offline window) ──────────

echo "→ [remote] Step 6: Replacing $DOCROOT with a symlink..."

# rmdir refuses if not empty, which is the correct safety: if step 4
# missed an entry, this fails loud rather than rm-rf'ing live data.
if ! rmdir "$DOCROOT"; then
    echo "" >&2
    echo "❌  Could not rmdir empty docroot $DOCROOT (step 4 may have left an entry)." >&2
    echo "    Inspect by hand; do NOT rm -rf the docroot — restore step-2 backup and re-run." >&2
    exit 1
fi

# Atomic ln -sfn. Target is RELATIVE: "<tier>-releases/<id>" so the
# docroot stays portable. Same shape as deploy.sh's swap and as the
# local-mode bv_atomic_swap_symlink helper.
RELEASES_PARENT_BASENAME="$(basename "$RELEASES_DIR")"
ln -sfn "$RELEASES_PARENT_BASENAME/$BOOTSTRAP_ID" "$DOCROOT"

echo "  ✓ $DOCROOT now resolves to $BOOTSTRAP_ID."
echo "→ [remote] complete."
