#!/usr/bin/env bats
#
# Tests for deploy/backup.sh and deploy/restore.sh.

bats_require_minimum_version 1.5.0
#
# Coverage matrix (from sprint-1 contract.committed_tests):
#   (a) backup round-trip — fixture → backup → restore-to-scratch → diff
#   (b) prod safety gate  — `restore.sh prod --from <id>` without
#                           `--yes-i-mean-it` refuses, exit non-zero
#   (c) retention sweep   — 30 simulated daily backups → expected set
#   (d) input validation  — malformed --from id, '..' in --to path
#
# Plus failure-mode regressions:
#   - filename format invariant
#   - allow-list governs included paths (uploads/ MUST be present)
#   - age encryption (no plaintext written to managed storage)
#   - schema validates a sample backup-meta.yaml
#   - missing required env triggers a specific error
#   - tagged backup survives a sweep that would otherwise delete it
#   - `--keep-local` keeps at most 14 archives in ./backups/
#
# Run with:  bats tests/deploy/backup-restore.bats
#
# Requires:  bats-core, age, tar.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    BACKUP_SH="$REPO_ROOT/deploy/backup.sh"
    RESTORE_SH="$REPO_ROOT/deploy/restore.sh"
    [ -x "$BACKUP_SH" ] || { echo "missing $BACKUP_SH" >&2; return 1; }
    [ -x "$RESTORE_SH" ] || { echo "missing $RESTORE_SH" >&2; return 1; }

    TMP="$(mktemp -d "${TMPDIR:-/tmp}/bv-test.XXXXXXXX")"
    export TMP

    # Build a fixture source: a fake `user/` tree with content under
    # each allow-listed path plus some deny-listed noise that should
    # be excluded.
    FIXTURE="$TMP/fixture"
    mkdir -p "$FIXTURE/user/accounts" \
             "$FIXTURE/user/data/flex" \
             "$FIXTURE/user/pages/01.home" \
             "$FIXTURE/user/uploads/2026/04" \
             "$FIXTURE/user/cache" \
             "$FIXTURE/user/logs"
    echo 'username: alice'  > "$FIXTURE/user/accounts/alice.yaml"
    echo 'username: bob'    > "$FIXTURE/user/accounts/bob.yaml"
    echo 'task: hello'      > "$FIXTURE/user/data/flex/tasks.yaml"
    echo 'title: Home'      > "$FIXTURE/user/pages/01.home/default.md"
    echo 'binary-content'   > "$FIXTURE/user/uploads/2026/04/avatar.png"
    echo 'should-not-ship'  > "$FIXTURE/user/cache/cache-noise"
    echo 'should-not-ship'  > "$FIXTURE/user/logs/access.log"
    echo 'tmpdata'          > "$FIXTURE/user/some.tmp"

    # Plant the live-tier metadata markers that backup.sh now reads
    # directly from the source (instead of from the operator's repo).
    # Tests that need different values either override BACKUP_FAKE_*
    # or rewrite these files before invoking backup.sh.
    mkdir -p "$FIXTURE/config/www/user"
    echo '0.1.0' > "$FIXTURE/config/www/VERSION"
    echo '247'   > "$FIXTURE/config/www/BUILD"
    cat > "$FIXTURE/config/www/user/data-version.yaml" <<'EOF'
version: "0.1.0"
EOF

    # Generate a throw-away age keypair for the test run.
    KEYDIR="$TMP/keys"
    mkdir -p "$KEYDIR"
    age-keygen -o "$KEYDIR/identity.txt" 2>"$KEYDIR/keygen.stderr"
    # The pubkey lives on a `# public key: age1...` line at the top
    # of the identity file (and on stderr, but the format on stderr
    # changes across age versions).
    PUBKEY="$(awk '/^# public key:/ {print $4; exit}' "$KEYDIR/identity.txt")"
    [ -n "$PUBKEY" ] || { echo "age-keygen failed to emit pubkey" >&2; cat "$KEYDIR/identity.txt" >&2; return 1; }

    RECIPIENTS="$TMP/recipients.txt"
    printf '# test recipient\n%s\n' "$PUBKEY" > "$RECIPIENTS"

    STORE="$TMP/store"
    mkdir -p "$STORE"

    LOCAL_BACKUPS="$TMP/local-backups"
    mkdir -p "$LOCAL_BACKUPS"

    export BACKUP_RECIPIENTS_FILE="$RECIPIENTS"
    export BACKUP_LOCAL_STORE_DIR="$STORE"
    export BACKUP_FIXTURE_DIR="$FIXTURE"
    export BACKUP_SOURCE_HOST="fixture.local"
    export BACKUP_FAKE_CODE_VERSION="0.1.0"
    export BACKUP_FAKE_CODE_BUILD="247"
    export BACKUP_FAKE_DATA_VERSION="0.1.0"
    export AGE_IDENTITY_FILE="$KEYDIR/identity.txt"
    # Stable backup time (2026-04-29T12:34:00Z UTC) for filename
    # and metadata assertions.
    export BACKUP_FAKE_NOW_EPOCH="1777466040"

    # Isolate the privacy-hygiene banner sentinel from the operator's
    # real ~/.config so each test starts banner-fresh and we never
    # touch the developer's actual sentinel.
    export XDG_CONFIG_HOME="$TMP/xdg-config"
    mkdir -p "$XDG_CONFIG_HOME"

    # The backup script's local-keep dir is fixed at $REPO_ROOT/backups,
    # which we don't want to pollute. Tests that exercise --keep-local
    # set HOME-style isolation by running with a different REPO_ROOT
    # via wrapping; for simplicity we accept the side effect and clean
    # up in teardown.
    KEEP_LOCAL_DIR="$REPO_ROOT/backups"
    KEEP_LOCAL_SNAPSHOT="$TMP/keep-local-snapshot"
    if [ -d "$KEEP_LOCAL_DIR" ]; then
        cp -R "$KEEP_LOCAL_DIR" "$KEEP_LOCAL_SNAPSHOT"
    fi
}

teardown() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
    fi
    # Restore $REPO_ROOT/backups if we touched it.
    if [ -d "$KEEP_LOCAL_SNAPSHOT" ]; then
        rm -rf "$KEEP_LOCAL_DIR"
        mv "$KEEP_LOCAL_SNAPSHOT" "$KEEP_LOCAL_DIR"
    elif [ -d "$KEEP_LOCAL_DIR" ] && [ ! -e "$KEEP_LOCAL_SNAPSHOT" ]; then
        # Tests created ./backups/ where there was none. Remove it
        # if it's empty; otherwise leave content alone — the gitignore
        # handles it.
        rmdir "$KEEP_LOCAL_DIR" 2>/dev/null || true
    fi
}

# ─── (a) backup round-trip ──────────────────────────────────────────

@test "backup → restore-to-scratch round-trip preserves fixture content" {
    run --separate-stderr "$BACKUP_SH" prod
    [ "$status" -eq 0 ]

    # The first stdout line is the URL of the uploaded archive.
    archive_url="$(printf '%s\n' "$output" | head -n1)"
    [[ "$archive_url" == file://* ]]
    archive_path="${archive_url#file://}"
    [ -f "$archive_path" ]

    # Filename must match the deterministic format.
    base="$(basename "$archive_path")"
    [ "$base" = "prod-2026-04-29T12-34Z-v0.1.0-b247.tar.gz.age" ]

    # Restore to a scratch dir and diff against the fixture.
    SCRATCH="$TMP/scratch"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]

    # Spotlight marker present.
    [ -f "$SCRATCH/.metadata_never_index" ]

    # Allow-listed content present.
    [ -f "$SCRATCH/user/accounts/alice.yaml" ]
    [ -f "$SCRATCH/user/accounts/bob.yaml" ]
    [ -f "$SCRATCH/user/data/flex/tasks.yaml" ]
    [ -f "$SCRATCH/user/pages/01.home/default.md" ]
    [ -f "$SCRATCH/user/uploads/2026/04/avatar.png" ]

    # Allow-list-bypassing content absent (deny-list enforced).
    [ ! -e "$SCRATCH/user/cache" ]
    [ ! -e "$SCRATCH/user/logs" ]
    [ ! -e "$SCRATCH/user/some.tmp" ]

    # Diff allow-listed paths against fixture for byte-identical equality.
    diff -r "$FIXTURE/user/accounts" "$SCRATCH/user/accounts"
    diff -r "$FIXTURE/user/data"     "$SCRATCH/user/data"
    diff -r "$FIXTURE/user/pages"    "$SCRATCH/user/pages"
    diff -r "$FIXTURE/user/uploads"  "$SCRATCH/user/uploads"
}

@test "backup-meta.yaml is at the archive root with required fields" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]

    SCRATCH="$TMP/scratch-meta"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -f "$SCRATCH/backup-meta.yaml" ]
    grep -q '^backup_taken_at: "2026-04-29T12:34Z"$'  "$SCRATCH/backup-meta.yaml"
    grep -q '^source_host: "fixture.local"$'           "$SCRATCH/backup-meta.yaml"
    grep -q '^code_version: "0.1.0"$'                  "$SCRATCH/backup-meta.yaml"
    grep -q '^code_build: "247"$'                      "$SCRATCH/backup-meta.yaml"
    grep -q '^data_version: "0.1.0"$'                  "$SCRATCH/backup-meta.yaml"
    grep -q '^producer: "deploy/backup.sh"$'           "$SCRATCH/backup-meta.yaml"
    grep -q '^producer_version: '                      "$SCRATCH/backup-meta.yaml"
}

@test "uploads/ is included (regression sentinel — legacy script omitted it)" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    SCRATCH="$TMP/scratch-uploads"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    [ -f "$SCRATCH/user/uploads/2026/04/avatar.png" ]
}

@test "archive is real age ciphertext, not plaintext" {
    run --separate-stderr "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    archive_url="$(printf '%s\n' "$output" | head -n1)"
    archive_path="${archive_url#file://}"
    # age v1 ciphertexts begin with "age-encryption.org/v1\n".
    head -c 21 "$archive_path" | grep -qF "age-encryption.org/v1"
    # And contain none of the obvious plaintext fixtures.
    if strings "$archive_path" 2>/dev/null | grep -q 'username: alice'; then
        echo "FAIL: alice plaintext leaked into encrypted archive" >&2
        return 1
    fi
}

# ─── (b) prod safety gate ────────────────────────────────────────────

@test "restore.sh prod --from <id> refuses without --yes-i-mean-it" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    archive="$(ls "$BACKUP_LOCAL_STORE_DIR"/prod-*.tar.gz.age | head -n1)"
    id="$(basename "$archive" .tar.gz.age)"

    run "$RESTORE_SH" prod --from "$id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--yes-i-mean-it"* ]]
}

@test "restore.sh prod with --yes-i-mean-it (and tier-stand-in gate) writes a log" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    archive="$(ls "$BACKUP_LOCAL_STORE_DIR"/prod-*.tar.gz.age | head -n1)"
    id="$(basename "$archive" .tar.gz.age)"

    # Without RESTORE_TO_TIER_ENABLED=1, the script takes the
    # pre-restore safety backup and writes a log, but skips the
    # destructive wipe (GAN-safe stand-in).
    run "$RESTORE_SH" prod --from "$id" --yes-i-mean-it
    [ "$status" -eq 0 ]
    [[ "$output" == *"log="* ]]
    log_path="$(printf '%s\n' "$output" | grep -E '^log=' | head -n1 | cut -d= -f2-)"
    [ -f "$log_path" ]
    grep -q "prod safety gate passed" "$log_path"
    grep -q "pre-restore safety backup complete" "$log_path"

    # Pre-restore backup landed in managed storage with a tag marker.
    pre_count=$(ls "$BACKUP_LOCAL_STORE_DIR"/prod-*.tag 2>/dev/null | wc -l | tr -d ' ')
    [ "$pre_count" -ge 1 ]
}

# ─── (c) retention sweep ─────────────────────────────────────────────
#
# Simulate 30 days of daily backups by writing dummy archive files
# directly into BACKUP_LOCAL_STORE_DIR with the deterministic
# filename format. Then trigger a sweep by producing one more backup
# (which runs retention as its final step).

@test "retention: 30 daily archives + 1 tagged → ≤14 daily + tagged retained" {
    # 30 days ago = backup epoch - 30*86400.
    base_epoch="$BACKUP_FAKE_NOW_EPOCH"
    for i in $(seq 1 30); do
        # one day per iteration, oldest first
        delta=$(( (31 - i) * 86400 ))
        epoch=$(( base_epoch - delta ))
        date_part=$(TZ=UTC date -j -f '%s' "$epoch" +'%Y-%m-%dT%H-%MZ' 2>/dev/null \
                 || TZ=UTC date -d "@$epoch" +'%Y-%m-%dT%H-%MZ')
        fname="prod-${date_part}-v0.1.0-b${i}.tar.gz.age"
        # Minimal placeholder content (sweep only inspects filenames).
        printf 'placeholder' > "$BACKUP_LOCAL_STORE_DIR/$fname"
    done
    # Plant one explicitly tagged archive 60 days old that the sweep
    # MUST not delete.
    old_epoch=$(( base_epoch - 60 * 86400 ))
    old_date=$(TZ=UTC date -j -f '%s' "$old_epoch" +'%Y-%m-%dT%H-%MZ' 2>/dev/null \
            || TZ=UTC date -d "@$old_epoch" +'%Y-%m-%dT%H-%MZ')
    tagged="prod-${old_date}-v0.1.0-b1.tar.gz.age"
    printf 'placeholder' > "$BACKUP_LOCAL_STORE_DIR/$tagged"
    printf 'pre-promotion-v0.2.0\n' > "$BACKUP_LOCAL_STORE_DIR/${tagged}.tag"

    before=$(ls "$BACKUP_LOCAL_STORE_DIR"/*.tar.gz.age | wc -l | tr -d ' ')
    [ "$before" -ge 31 ]

    # Trigger sweep by running a real backup.
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]

    # After sweep:
    #   - Archives within the last 14 days (the new "now" archive +
    #     placeholders ≤14 days old) must remain.
    #   - The tagged 60-day-old archive must remain.
    #   - Older daily archives must be gone.
    [ -f "$BACKUP_LOCAL_STORE_DIR/$tagged" ]
    [ -f "$BACKUP_LOCAL_STORE_DIR/${tagged}.tag" ]

    daily_count=0
    for f in "$BACKUP_LOCAL_STORE_DIR"/prod-*.tar.gz.age; do
        # Skip the tagged one and the new "now" archive.
        [ -f "${f}.tag" ] && continue
        daily_count=$((daily_count + 1))
    done
    # Allowance: the contract permits "at most 14 daily + 4 weekly +
    # any tagged". We verify upper bound and lower bound on daily.
    [ "$daily_count" -le 18 ]   # 14 daily + ≤4 weekly buckets
    [ "$daily_count" -ge 14 ]   # at least the past-14-day window remains

    # Specifically: an archive 25 days old must NOT remain (it falls
    # outside both the 14-day daily and any Sunday-weekly bucket
    # unless its date happened to be Sunday — verified by recomputing
    # what we expect).
    far_past=$(( base_epoch - 25 * 86400 ))
    far_past_date=$(TZ=UTC date -j -f '%s' "$far_past" +'%Y-%m-%dT%H-%MZ' 2>/dev/null \
                 || TZ=UTC date -d "@$far_past" +'%Y-%m-%dT%H-%MZ')
    far_past_dow=$(TZ=UTC date -j -f '%s' "$far_past" +'%w' 2>/dev/null \
                || TZ=UTC date -d "@$far_past" +'%w')
    if [ "$far_past_dow" != "0" ]; then
        # Non-Sunday day older than 14 days → must be deleted.
        far_archive="prod-${far_past_date}-v0.1.0-b6.tar.gz.age"
        [ ! -f "$BACKUP_LOCAL_STORE_DIR/$far_archive" ]
    fi
}

@test "retention: --tag survives even when sweep would delete by date" {
    base_epoch="$BACKUP_FAKE_NOW_EPOCH"
    old_epoch=$(( base_epoch - 200 * 86400 ))
    old_date=$(TZ=UTC date -j -f '%s' "$old_epoch" +'%Y-%m-%dT%H-%MZ' 2>/dev/null \
            || TZ=UTC date -d "@$old_epoch" +'%Y-%m-%dT%H-%MZ')
    fname="prod-${old_date}-v0.1.0-b1.tar.gz.age"
    printf 'placeholder' > "$BACKUP_LOCAL_STORE_DIR/$fname"
    printf 'pre-promotion-v0.2.0\n' > "$BACKUP_LOCAL_STORE_DIR/${fname}.tag"

    run "$BACKUP_SH" prod --tag "another-tag"
    [ "$status" -eq 0 ]
    [ -f "$BACKUP_LOCAL_STORE_DIR/$fname" ]
    [ -f "$BACKUP_LOCAL_STORE_DIR/${fname}.tag" ]
}

# ─── (d) input validation ────────────────────────────────────────────

@test "backup.sh refuses unknown tier" {
    run "$BACKUP_SH" wat
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown tier"* ]]
}

@test "backup.sh refuses malformed --tag" {
    run "$BACKUP_SH" prod --tag "bad tag with spaces"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid --tag"* ]]
}

@test "restore.sh refuses --to with traversal" {
    run "$RESTORE_SH" --to "../../../etc"
    [ "$status" -ne 0 ]
    [[ "$output" == *".."* ]]
}

@test "restore.sh refuses malformed --from id" {
    run "$RESTORE_SH" --to "$TMP/scratch-bad" --from "not-a-real-id"
    [ "$status" -ne 0 ]
    [[ "$output" == *"--from"* ]]
}

@test "restore.sh rejects --from with shell metacharacters" {
    run "$RESTORE_SH" --to "$TMP/scratch-bad" --from 'prod-2026-04-29T12-34Z-v0.1.0-b1; rm -rf /'
    [ "$status" -ne 0 ]
}

@test "restore.sh refuses unknown tier" {
    run "$RESTORE_SH" wat --from "prod-2026-04-29T12-34Z-v0.1.0-b1"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown tier"* ]]
}

# ─── failure modes (subset of the contract's failure_modes criterion) ─

@test "missing recipients file → specific error, non-zero exit" {
    BACKUP_RECIPIENTS_FILE="$TMP/nonexistent-recipients.txt" \
        run "$BACKUP_SH" prod
    [ "$status" -ne 0 ]
    [[ "$output" == *"Missing recipients file"* ]]
}

@test "no managed storage configured → local archive preserved, non-zero exit" {
    unset BACKUP_LOCAL_STORE_DIR
    run "$BACKUP_SH" prod
    [ "$status" -ne 0 ]
    [[ "$output" == *"Local archive preserved"* ]]
    # Fail mode (b): the local copy must exist where we said it would.
    grep -q "Local archive preserved at:" <<<"$output"
}

@test "ssh-unreachable: backup fails with specific error message" {
    # Disable fixture mode so the script falls into the SSH path.
    unset BACKUP_FIXTURE_DIR
    # Point at a guaranteed-unreachable host.
    export DEPLOY_PROD_HOST="example-nonexistent-host-127001-test.invalid"
    export DEPLOY_PROD_USER="nobody"
    export DEPLOY_PROD_PORT="2222"
    export DEPLOY_PROD_PATH="/no/where"
    run "$BACKUP_SH" prod
    [ "$status" -ne 0 ]
    [[ "$output" == *"ssh to ${DEPLOY_PROD_HOST}:${DEPLOY_PROD_PORT} failed"* ]]
}

@test "no half-uploaded artifacts: only final filename in store" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    # No .partial files lingering.
    [ -z "$(find "$BACKUP_LOCAL_STORE_DIR" -name '*.partial')" ]
}

# ─── schema sanity ───────────────────────────────────────────────────

@test "backup-meta.yaml conforms to deploy/schemas/backup-meta.schema.yaml" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    SCRATCH="$TMP/scratch-schema"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]

    # Lightweight schema check: ensure every `required` field listed
    # in the schema appears as a top-level key in the produced
    # backup-meta.yaml. We don't pull in a full JSON Schema validator
    # — keeping the test toolchain to bats + standard CLI tools.
    SCHEMA="$REPO_ROOT/deploy/schemas/backup-meta.schema.yaml"
    [ -f "$SCHEMA" ]

    # Extract the `required:` list.
    required="$(awk '
        /^required:/ {flag=1; next}
        /^[a-zA-Z]/ {flag=0}
        flag && /^  - / {gsub(/^  - /, ""); print}
    ' "$SCHEMA")"

    [ -n "$required" ]
    while IFS= read -r key; do
        grep -qE "^${key}: " "$SCRATCH/backup-meta.yaml" \
            || { echo "missing key $key in produced meta" >&2; return 1; }
    done <<<"$required"

    # And `producer` must be exactly `deploy/backup.sh`.
    grep -qE '^producer: "deploy/backup.sh"$' "$SCRATCH/backup-meta.yaml"
}

# ─── allow-list / deny-list invariants ───────────────────────────────

@test "deploy/backup-paths.txt contains the four required paths" {
    P="$REPO_ROOT/deploy/backup-paths.txt"
    grep -qx 'user/accounts' "$P"
    grep -qx 'user/data'     "$P"
    grep -qx 'user/pages'    "$P"
    grep -qx 'user/uploads'  "$P"
}

@test "deploy/age-recipients.txt contains at least one age1... line" {
    grep -qE '^age1[0-9a-z]+$' "$REPO_ROOT/deploy/age-recipients.txt"
}

@test "BACKUP_SCRIPT_VERSION declared near top of backup.sh" {
    head -n 50 "$REPO_ROOT/deploy/backup.sh" \
        | grep -qE '^[[:space:]]*(readonly )?BACKUP_SCRIPT_VERSION='
}

# ─── filename invariant ──────────────────────────────────────────────

@test "filename uses HH-MM not HH:MM (colon swap on time only)" {
    run --separate-stderr "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    archive_url="$(printf '%s\n' "$output" | head -n1)"
    base="$(basename "${archive_url#file://}")"
    # Date stays YYYY-MM-DD; time becomes HH-MMZ.
    [[ "$base" =~ ^prod-2026-04-29T[0-9]{2}-[0-9]{2}Z-v0\.1\.0-b247\.tar\.gz\.age$ ]]
    # Must NOT contain a `:`.
    [[ "$base" != *":"* ]]
}

# ─── secrets hygiene ─────────────────────────────────────────────────

@test "no secrets / private keys in tracked deploy files" {
    cd "$REPO_ROOT"
    # No PEM private keys.
    run grep -RIn -E "BEGIN (OPENSSH|RSA|EC|PRIVATE) KEY" deploy/
    [ "$status" -ne 0 ]
    # No age secret keys.
    run grep -RIn -E "AGE-SECRET-KEY-1[0-9A-Z]+" deploy/
    [ "$status" -ne 0 ]
    # No AWS access key shapes (AKIA*).
    run grep -RIn -E "AKIA[0-9A-Z]{16}" deploy/
    [ "$status" -ne 0 ]
}

# ─── first-write privacy-hygiene banner ──────────────────────────────
#
# The banner reminds the operator to add Time Machine exclusions and
# warns against keeping the checkout under a Dropbox/iCloud-synced
# root. It is shown to stderr the first time backup.sh or restore.sh
# writes into a privacy-sensitive path on a given laptop, then
# suppressed via a sentinel under XDG_CONFIG_HOME. Tests run with
# XDG_CONFIG_HOME pointed at a bats temp dir so the operator's real
# ~/.config is never touched.

@test "banner: first backup.sh --keep-local prints to stderr and creates sentinel" {
    sentinel="$XDG_CONFIG_HOME/byvaerksted/backup-banner-shown"
    [ ! -e "$sentinel" ]

    run --separate-stderr "$BACKUP_SH" prod --keep-local
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"tmutil addexclusion ./backups"* ]]
    [[ "$stderr" == *"tmutil addexclusion ./deploy/staging-stage"* ]]
    [[ "$stderr" == *"tmutil addexclusion ./deploy/prod-stage"* ]]
    [[ "$stderr" == *"Dropbox"* ]] || [[ "$stderr" == *"iCloud"* ]]
    [[ "$stderr" == *"Google Drive"* ]] || [[ "$stderr" == *"OneDrive"* ]]

    [ -e "$sentinel" ]
}

@test "banner: stdout is not polluted by the banner text" {
    run --separate-stderr "$BACKUP_SH" prod --keep-local
    [ "$status" -eq 0 ]
    # stdout still carries the parseable URL/path output (file://...)
    # and key=value diagnostics — but NONE of the banner text.
    [[ "$output" != *"tmutil addexclusion"* ]]
    [[ "$output" != *"Dropbox"* ]]
    [[ "$output" != *"────"* ]]
    # And the parseable URL line is still on stdout.
    archive_url="$(printf '%s\n' "$output" | head -n1)"
    [[ "$archive_url" == file://* ]]
}

@test "banner: second invocation with sentinel present does not re-print" {
    # First run creates the sentinel.
    run --separate-stderr "$BACKUP_SH" prod --keep-local
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"tmutil addexclusion"* ]]

    # Second run must not re-emit the banner text.
    run --separate-stderr "$BACKUP_SH" prod --keep-local
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"tmutil addexclusion"* ]]
    [[ "$stderr" != *"Dropbox"* ]]

    # Removing the sentinel restores the banner.
    rm -f "$XDG_CONFIG_HOME/byvaerksted/backup-banner-shown"
    run --separate-stderr "$BACKUP_SH" prod --keep-local
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"tmutil addexclusion"* ]]
}

@test "banner: first restore.sh --to <dir> prints to stderr and creates sentinel" {
    # Need an archive to restore from.
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]

    # Sentinel hasn't been created yet (backup.sh ran without
    # --keep-local, no fallback). Restore-to-scratch is the first
    # privacy-sensitive write.
    sentinel="$XDG_CONFIG_HOME/byvaerksted/backup-banner-shown"
    [ ! -e "$sentinel" ]

    SCRATCH="$TMP/scratch-banner"
    run --separate-stderr "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"tmutil addexclusion ./backups"* ]]
    [[ "$stderr" == *"tmutil addexclusion ./deploy/staging-stage"* ]]
    [[ "$stderr" == *"tmutil addexclusion ./deploy/prod-stage"* ]]

    [ -e "$sentinel" ]

    # And the restore stdout path is still clean (the path of the scratch dir).
    [[ "$output" == *"$SCRATCH"* ]]
    [[ "$output" != *"tmutil addexclusion"* ]]
}

@test "banner: restore.sh --to with existing sentinel does not re-print" {
    # Pre-create the sentinel so the banner is already suppressed.
    mkdir -p "$XDG_CONFIG_HOME/byvaerksted"
    : > "$XDG_CONFIG_HOME/byvaerksted/backup-banner-shown"

    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    SCRATCH="$TMP/scratch-banner-suppressed"
    run --separate-stderr "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"tmutil addexclusion"* ]]
    [[ "$stderr" != *"Dropbox"* ]]
}

# ─── metadata provenance: source-tier reads ──────────────────────────
#
# The version/build/data-version markers must come from the live tier
# (the fixture in test mode), NOT from the operator's local repo.
# The BACKUP_FAKE_* env-var overrides exist as explicit injection
# points; without them, the script must read from the fixture.

@test "code_version comes from fixture VERSION (not from \$REPO_ROOT)" {
    # Plant a fixture VERSION distinct from the orchestrating repo's
    # VERSION (currently 0.2.0 on this branch).
    echo '9.9.9' > "$FIXTURE/config/www/VERSION"
    # Disable the BACKUP_FAKE_* overrides so the source-read path runs.
    unset BACKUP_FAKE_CODE_VERSION
    unset BACKUP_FAKE_DATA_VERSION

    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    SCRATCH="$TMP/scratch-cv"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '^code_version: "9.9.9"$' "$SCRATCH/backup-meta.yaml"
    # And NOT the repo's VERSION value.
    repo_ver="$(head -n1 "$REPO_ROOT/config/www/VERSION" 2>/dev/null \
                | tr -d '\r\n[:space:]')"
    if [ -n "$repo_ver" ] && [ "$repo_ver" != "9.9.9" ]; then
        ! grep -q "^code_version: \"$repo_ver\"$" "$SCRATCH/backup-meta.yaml"
    fi
}

@test "code_build comes from fixture BUILD (not from \$REPO_ROOT)" {
    echo '424242' > "$FIXTURE/config/www/BUILD"
    unset BACKUP_FAKE_CODE_BUILD
    unset BACKUP_FAKE_DATA_VERSION

    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    SCRATCH="$TMP/scratch-cb"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '^code_build: "424242"$' "$SCRATCH/backup-meta.yaml"
}

@test "data_version comes from fixture data-version.yaml version: field" {
    cat > "$FIXTURE/config/www/user/data-version.yaml" <<'EOF'
# This data version applies to the live tier's flex objects schema.
version: "3.4.5"
EOF
    unset BACKUP_FAKE_DATA_VERSION
    unset BACKUP_DATA_VERSION

    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    SCRATCH="$TMP/scratch-dv"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '^data_version: "3.4.5"$' "$SCRATCH/backup-meta.yaml"
}

@test "data_version defaults to 0.0.0 (NOT code_version) when fixture missing data-version.yaml" {
    rm -f "$FIXTURE/config/www/user/data-version.yaml"
    # Use distinctive code_version to ensure the fallback isn't
    # silently inheriting it.
    echo '1.2.3' > "$FIXTURE/config/www/VERSION"
    unset BACKUP_FAKE_CODE_VERSION
    unset BACKUP_FAKE_DATA_VERSION
    unset BACKUP_DATA_VERSION

    run --separate-stderr "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    # Stderr names the missing file.
    [[ "$stderr" == *"data-version.yaml"* ]]
    [[ "$stderr" == *"0.0.0"* ]]

    SCRATCH="$TMP/scratch-dvmiss"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '^data_version: "0.0.0"$' "$SCRATCH/backup-meta.yaml"
    # MUST NOT inherit code_version.
    ! grep -q '^data_version: "1.2.3"$' "$SCRATCH/backup-meta.yaml"
}

@test "missing fixture VERSION → hard fail (exit 3) naming the file" {
    rm -f "$FIXTURE/config/www/VERSION"
    unset BACKUP_FAKE_CODE_VERSION

    run "$BACKUP_SH" prod
    [ "$status" -eq 3 ]
    [[ "$output" == *"VERSION"* ]]
    # No archive should have been produced.
    ! ls "$BACKUP_LOCAL_STORE_DIR"/*.tar.gz.age >/dev/null 2>&1
}

@test "missing fixture BUILD → hard fail (exit 3) naming the file" {
    rm -f "$FIXTURE/config/www/BUILD"
    unset BACKUP_FAKE_CODE_BUILD

    run "$BACKUP_SH" prod
    [ "$status" -eq 3 ]
    [[ "$output" == *"BUILD"* ]]
    ! ls "$BACKUP_LOCAL_STORE_DIR"/*.tar.gz.age >/dev/null 2>&1
}

@test "backup.sh contains no read of \$REPO_ROOT/config/www metadata files" {
    # Static assertion: the production source must not reference the
    # operator's local-repo VERSION/BUILD/data-version.yaml.
    ! grep -nE 'REPO_ROOT/config/www/(VERSION|BUILD)' "$REPO_ROOT/deploy/backup.sh"
    ! grep -nE 'REPO_ROOT/config/www/user/data-version' "$REPO_ROOT/deploy/backup.sh"
}

# ─── restore-to-tier (local-tier mode) ───────────────────────────────
#
# Exercises the destructive wipe-and-replace code path against a
# bats-temp-dir target instead of via SSH. This is the disaster-
# recovery path's only test — the SSH variant (real operator runs)
# is operator-only by design.

@test "RESTORE_LOCAL_TIER_DIR is ignored without RESTORE_TO_TIER_ENABLED=1" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    archive="$(ls "$BACKUP_LOCAL_STORE_DIR"/prod-*.tar.gz.age | head -n1)"
    id="$(basename "$archive" .tar.gz.age)"

    TIER_B="$TMP/tier-no-gate"
    mkdir -p "$TIER_B/user/accounts"
    echo 'username: existing' > "$TIER_B/user/accounts/existing.yaml"

    # Without the safety gate, the local-tier mode must NOT run; the
    # script falls into the existing tier-standin path.
    RESTORE_LOCAL_TIER_DIR="$TIER_B" \
        run "$RESTORE_SH" prod --from "$id" --yes-i-mean-it
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode=tier-standin"* ]]
    # The tier dir must be untouched.
    [ -f "$TIER_B/user/accounts/existing.yaml" ]
}

@test "RESTORE_LOCAL_TIER_DIR rejects relative path" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    archive="$(ls "$BACKUP_LOCAL_STORE_DIR"/prod-*.tar.gz.age | head -n1)"
    id="$(basename "$archive" .tar.gz.age)"

    RESTORE_TO_TIER_ENABLED=1 RESTORE_LOCAL_TIER_DIR="relative/path" \
        run "$RESTORE_SH" prod --from "$id" --yes-i-mean-it
    [ "$status" -ne 0 ]
    [[ "$output" == *"absolute path"* ]]
}

@test "local-tier restore: backup A → mutate B → restore → byte-identity + log + sentinel" {
    # Step (a): build fixture A (already done in setup() — $FIXTURE).
    # Plant a deterministic content set we can mutate later.
    echo 'sentinel-A' > "$FIXTURE/user/accounts/sentinel.yaml"
    echo 'page-A'     > "$FIXTURE/user/pages/01.home/default.md"
    echo 'data-A'     > "$FIXTURE/user/data/flex/tasks.yaml"
    echo 'avatar-A'   > "$FIXTURE/user/uploads/2026/04/avatar.png"

    # Step (b): take a backup using fixture A.
    run "$BACKUP_SH" dev
    [ "$status" -eq 0 ]
    archive="$(ls "$BACKUP_LOCAL_STORE_DIR"/dev-*.tar.gz.age | head -n1)"
    id="$(basename "$archive" .tar.gz.age)"

    # Step (c): build tier B from the same fixture content, then
    # mutate it: delete one file, modify one, add one untracked.
    TIER_B="$TMP/tier-b"
    mkdir -p "$TIER_B/user/accounts" \
             "$TIER_B/user/data/flex" \
             "$TIER_B/user/pages/01.home" \
             "$TIER_B/user/uploads/2026/04"
    cp "$FIXTURE/user/accounts/alice.yaml"          "$TIER_B/user/accounts/"
    cp "$FIXTURE/user/accounts/bob.yaml"            "$TIER_B/user/accounts/"
    cp "$FIXTURE/user/accounts/sentinel.yaml"       "$TIER_B/user/accounts/"
    cp "$FIXTURE/user/data/flex/tasks.yaml"         "$TIER_B/user/data/flex/"
    cp "$FIXTURE/user/pages/01.home/default.md"    "$TIER_B/user/pages/01.home/"
    cp "$FIXTURE/user/uploads/2026/04/avatar.png"  "$TIER_B/user/uploads/2026/04/"

    # mutation 1: delete sentinel.yaml (must be restored).
    rm "$TIER_B/user/accounts/sentinel.yaml"
    # mutation 2: modify default.md (must match A exactly after restore).
    echo 'page-MUTATED' > "$TIER_B/user/pages/01.home/default.md"
    # mutation 3: add an untracked file (must be gone after restore).
    echo 'rogue'       > "$TIER_B/user/accounts/rogue.yaml"
    [ -f "$TIER_B/user/accounts/rogue.yaml" ]

    # Banner sentinel must not exist yet (we want this run to create it).
    sentinel="$XDG_CONFIG_HOME/byvaerksted/backup-banner-shown"
    [ ! -e "$sentinel" ]

    # Step (d): restore using local-tier mode.
    RESTORE_TO_TIER_ENABLED=1 RESTORE_LOCAL_TIER_DIR="$TIER_B" \
        run --separate-stderr "$RESTORE_SH" dev --from "$id" --yes-i-mean-it
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode=tier-local"* ]]
    [[ "$output" == *"target=$TIER_B"* ]]

    # Step (e) assertions:
    # — the deleted file is back —
    [ -f "$TIER_B/user/accounts/sentinel.yaml" ]
    diff -q "$FIXTURE/user/accounts/sentinel.yaml" "$TIER_B/user/accounts/sentinel.yaml"
    # — the modified file is byte-identical to fixture A —
    diff -q "$FIXTURE/user/pages/01.home/default.md" "$TIER_B/user/pages/01.home/default.md"
    # — the added untracked file is gone (rsync --delete semantics) —
    [ ! -e "$TIER_B/user/accounts/rogue.yaml" ]
    # — every allow-listed path is byte-identical to the fixture —
    diff -r "$FIXTURE/user/accounts" "$TIER_B/user/accounts"
    diff -r "$FIXTURE/user/data"     "$TIER_B/user/data"
    diff -r "$FIXTURE/user/pages"    "$TIER_B/user/pages"
    diff -r "$FIXTURE/user/uploads"  "$TIER_B/user/uploads"

    # — restore log was written and contains the expected lines —
    log_path="$(printf '%s\n' "$output" | grep -E '^log=' | head -n1 | cut -d= -f2-)"
    [ -f "$log_path" ]
    grep -q 'restore op begin' "$log_path"
    grep -q 'restore complete' "$log_path"
    # — clearcache was correctly skipped (no bin/grav at the target) —
    grep -q 'clearcache skipped' "$log_path"

    # — first-write banner sentinel was created during this run —
    [ -e "$sentinel" ]
    [[ "$stderr" == *"tmutil addexclusion"* ]]
}

@test "local-tier restore: clearcache invoked when bin/grav exists at target" {
    echo 'A' > "$FIXTURE/user/accounts/alice.yaml"

    run "$BACKUP_SH" dev
    [ "$status" -eq 0 ]
    archive="$(ls "$BACKUP_LOCAL_STORE_DIR"/dev-*.tar.gz.age | head -n1)"
    id="$(basename "$archive" .tar.gz.age)"

    TIER_B="$TMP/tier-b-grav"
    mkdir -p "$TIER_B/user/accounts" \
             "$TIER_B/user/data" \
             "$TIER_B/user/pages" \
             "$TIER_B/user/uploads" \
             "$TIER_B/bin"
    # Plant a stub `bin/grav` that records the args it was called with
    # to a marker file. Avoids depending on an actual Grav install.
    cat > "$TIER_B/bin/grav" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$TIER_B/grav-invoked"
exit 0
EOF
    chmod +x "$TIER_B/bin/grav"

    RESTORE_TO_TIER_ENABLED=1 RESTORE_LOCAL_TIER_DIR="$TIER_B" \
        run "$RESTORE_SH" dev --from "$id" --yes-i-mean-it
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode=tier-local"* ]]

    [ -f "$TIER_B/grav-invoked" ]
    grep -q '^clearcache$' "$TIER_B/grav-invoked"
}

# ─── restore-to-scratch by id ────────────────────────────────────────

@test "restore.sh --to <dir> --from <id> restores the requested archive" {
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    archive="$(ls "$BACKUP_LOCAL_STORE_DIR"/prod-*.tar.gz.age | head -n1)"
    id="$(basename "$archive" .tar.gz.age)"

    SCRATCH="$TMP/scratch-byid"
    run "$RESTORE_SH" --to "$SCRATCH" --from "$id"
    [ "$status" -eq 0 ]
    [ -f "$SCRATCH/user/accounts/alice.yaml" ]
    [ -f "$SCRATCH/.metadata_never_index" ]
}
