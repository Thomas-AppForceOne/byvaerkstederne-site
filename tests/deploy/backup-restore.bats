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

    # Plant the live-tier metadata markers that backup.sh reads
    # directly from the source (instead of from the operator's repo).
    # Tests that need different values rewrite these files before
    # invoking backup.sh.
    #
    # IMPORTANT: paths are relative to the FIXTURE root — i.e. the
    # Grav root, NOT <fixture>/config/www/. deploy.sh ships the
    # contents of <repo>/config/www/* directly into the tier root on
    # the remote, so backup.sh reads from <SSH_PATH>/VERSION etc. —
    # never <SSH_PATH>/config/www/VERSION. The fixture mirrors the
    # remote shape (matching the Grav root layout) since 819ffa6.
    mkdir -p "$FIXTURE/user"
    echo '0.1.0' > "$FIXTURE/VERSION"
    echo '247'   > "$FIXTURE/BUILD"
    cat > "$FIXTURE/user/data-version.yaml" <<'EOF'
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
    # Note: BACKUP_FAKE_CODE_VERSION / BACKUP_FAKE_CODE_BUILD /
    # BACKUP_FAKE_DATA_VERSION used to be exported here as a
    # convenience. They were removed because their presence skipped
    # the source-fetch code path — every test that ran with them set
    # was bypassing the very behaviour the contract asks us to
    # exercise. The fixture's `{VERSION,BUILD,user/data-version.yaml}`
    # files (planted above at the FIXTURE root, matching the deployed
    # Grav root layout) ARE the metadata source now, just routed
    # through the same code path an operator run uses.
    export AGE_IDENTITY_FILE="$KEYDIR/identity.txt"
    # Stable backup time (2026-04-29T12:34:00Z UTC) for filename
    # and metadata assertions.
    export BACKUP_FAKE_NOW_EPOCH="1777466040"

    # Isolate the privacy-hygiene banner sentinel from the operator's
    # real ~/.config so each test starts banner-fresh and we never
    # touch the developer's actual sentinel.
    export XDG_CONFIG_HOME="$TMP/xdg-config"
    mkdir -p "$XDG_CONFIG_HOME"

    # The backup script's local-keep dir is now machine-wide (under
    # ~/.byvaerkstederne/backups by default; the path that survives
    # across worktrees so `tmutil addexclusion` is a once-per-machine
    # operation). Tests override it with a per-test temp dir via
    # BV_KEEP_LOCAL_DIR so we never touch the operator's real path.
    export BV_KEEP_LOCAL_DIR="$TMP/keep-local"
    mkdir -p "$BV_KEEP_LOCAL_DIR"

    # Test isolation: stop backup.sh / restore.sh from sourcing the
    # operator's real .env.deploy. backup.sh skips sourcing when
    # BACKUP_FIXTURE_DIR is set (already exported above), but
    # restore.sh has no fixture-awareness — it sources .env.deploy
    # unconditionally and would override BACKUP_LOCAL_STORE_DIR with
    # whatever the operator put there. Pointing BACKUP_ENV_FILE at a
    # non-existent path makes both scripts' `if [ -f $f ]` skip the
    # source. Belt-and-braces against test/operator collision.
    export BACKUP_ENV_FILE="$TMP/no-such-env-file"
}

teardown() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP"
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
    # Persistent path: ./backups/ — must be named verbatim with the
    # exclusion command, since this is the only path the script
    # always writes to.
    # Banner names the keep-local path explicitly. After the
    # machine-wide-keep-local refactor, this is whatever
    # BV_KEEP_LOCAL_DIR resolves to (the test sets it to
    # $TMP/keep-local in setup); the banner is no longer the literal
    # `./backups` it was before.
    [[ "$stderr" == *"tmutil addexclusion $BV_KEEP_LOCAL_DIR"* ]]
    # Operator-chosen paths (`--to <dir>` / `RESTORE_LOCAL_TIER_DIR`):
    # the banner mentions them by env-var name rather than listing
    # made-up `./deploy/staging-stage/` and `./deploy/prod-stage/`
    # paths the scripts never actually create.
    [[ "$stderr" == *"--to <dir>"* ]]
    [[ "$stderr" == *"RESTORE_LOCAL_TIER_DIR"* ]]
    # Cloud-sync warning still names at least two of the four major services.
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
    # Same banner content as on the backup path: the persistent path
    # is named with its `tmutil` command, the operator-chosen paths
    # are referenced by their env-var/flag names rather than by
    # made-up directory names.
    # Banner names the keep-local path explicitly. After the
    # machine-wide-keep-local refactor, this is whatever
    # BV_KEEP_LOCAL_DIR resolves to (the test sets it to
    # $TMP/keep-local in setup); the banner is no longer the literal
    # `./backups` it was before.
    [[ "$stderr" == *"tmutil addexclusion $BV_KEEP_LOCAL_DIR"* ]]
    [[ "$stderr" == *"--to <dir>"* ]]
    [[ "$stderr" == *"RESTORE_LOCAL_TIER_DIR"* ]]

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
    echo '9.9.9' > "$FIXTURE/VERSION"
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
    echo '424242' > "$FIXTURE/BUILD"
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
    cat > "$FIXTURE/user/data-version.yaml" <<'EOF'
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
    rm -f "$FIXTURE/user/data-version.yaml"
    # Use distinctive code_version to ensure the fallback isn't
    # silently inheriting it.
    echo '1.2.3' > "$FIXTURE/VERSION"

    run --separate-stderr "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    # No warning emitted — missing data-version.yaml silently defaults to 0.0.0
    # (the feature is not yet implemented; warning was removed as noise).

    SCRATCH="$TMP/scratch-dvmiss"
    run "$RESTORE_SH" --to "$SCRATCH"
    [ "$status" -eq 0 ]
    grep -q '^data_version: "0.0.0"$' "$SCRATCH/backup-meta.yaml"
    # MUST NOT inherit code_version.
    ! grep -q '^data_version: "1.2.3"$' "$SCRATCH/backup-meta.yaml"
}

@test "malformed data-version.yaml (no parseable version) → hard fail, NOT silent default to 0.0.0" {
    # Regression for PR #16 review finding: a present-but-malformed
    # data-version.yaml used to fall through to "0.0.0" with only a
    # warning. That's unsafe — a corrupt or hand-edited file would
    # produce metadata claiming version 0.0.0, which downstream
    # migration tooling would trust and apply migrations against.
    # The fix: treat malformed-but-present as a hard error (exit 3).
    cat > "$FIXTURE/user/data-version.yaml" <<'EOF'
# This file exists but has no parseable version: field.
something_else: "value"
EOF

    run "$BACKUP_SH" prod
    [ "$status" -eq 3 ]
    [[ "$output" == *"data-version.yaml"* ]]
    [[ "$output" == *"parseable"* || "$output" == *"refusing"* ]]
    # No archive should have been produced.
    ! ls "$BACKUP_LOCAL_STORE_DIR"/*.tar.gz.age >/dev/null 2>&1
}

@test "missing fixture VERSION → hard fail (exit 3) naming the file" {
    rm -f "$FIXTURE/VERSION"

    run "$BACKUP_SH" prod
    [ "$status" -eq 3 ]
    [[ "$output" == *"VERSION"* ]]
    # No archive should have been produced.
    ! ls "$BACKUP_LOCAL_STORE_DIR"/*.tar.gz.age >/dev/null 2>&1
}

@test "missing fixture BUILD → hard fail (exit 3) naming the file" {
    rm -f "$FIXTURE/BUILD"

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

@test "SSH-mode metadata fetch: ssh commands are constructed with printf %q (shell-safe)" {
    # Static check: the SSH commands in source_read_first_line and
    # source_read_data_version_yaml must use printf %q to quote remote
    # paths. Direct interpolation would let an attacker (or a typo in
    # SSH_PATH) inject shell metacharacters into the remote command.
    # This is the cheapest way to catch a regression in command
    # construction without a real SSH daemon.
    #
    # NOTE: paths intentionally have NO `config/www/` prefix — the
    # remote tier root IS the Grav root (deploy.sh ships the contents
    # of <repo>/config/www/* there). An earlier version of this test
    # asserted the wrong shape and masked the bug fixed by 819ffa6.
    grep -q "printf %q \"\$SSH_PATH/\$rel\"" \
         "$REPO_ROOT/deploy/backup.sh"
    grep -q "printf %q \"\$SSH_PATH/user/data-version.yaml\"" \
         "$REPO_ROOT/deploy/backup.sh"
    # Belt-and-braces: explicitly assert the bogus shape is GONE.
    ! grep -q "SSH_PATH/config/www" "$REPO_ROOT/deploy/backup.sh"
}

@test "SSH-mode metadata fetch: end-to-end via fake-ssh shim, asserts correct values land in meta" {
    # Real coverage of the SSH code path without a live SSH daemon.
    # The shim:
    #   - Handles the bare connectivity probe (`ssh user@host true`) by exiting 0.
    #   - Handles the metadata-fetch shape (`test -f X && head|cat X`) by
    #     evaluating the command locally — X is just a path on the test
    #     machine, so the test+head/cat run as-is and produce the right output.
    #   - Returns non-zero for any rsync invocation (rsync's `--server`
    #     subcommand). That intentionally aborts backup.sh at the
    #     source-pull step. The test asserts the rsync failure was
    #     reached AFTER metadata was fetched correctly — i.e. the
    #     metadata code path completed successfully over (fake) SSH.
    unset BACKUP_FIXTURE_DIR

    # Build a "remote" tree at a path the shim can serve. Layout
    # mirrors what deploy.sh actually ships: the Grav root IS the
    # tier root — `<SSH_PATH>/VERSION`, `<SSH_PATH>/user/...` —
    # never `<SSH_PATH>/config/www/...`.
    #
    # Allow-list dirs (per deploy/backup-paths.txt: user/accounts,
    # user/data, user/pages, user/uploads) must exist for the new
    # existence-probe to find them; without them backup.sh would
    # skip every rsync silently and the rsync-failure assertion
    # below would never fire.
    REMOTE_ROOT="$TMP/remote-tier"
    mkdir -p "$REMOTE_ROOT/user/accounts" \
             "$REMOTE_ROOT/user/data" \
             "$REMOTE_ROOT/user/pages" \
             "$REMOTE_ROOT/user/uploads"
    echo '7.7.7' > "$REMOTE_ROOT/VERSION"
    echo '999'   > "$REMOTE_ROOT/BUILD"
    cat > "$REMOTE_ROOT/user/data-version.yaml" <<'EOF'
version: "5.5.5"
EOF

    SHIM_BIN="$TMP/shim-bin"
    mkdir -p "$SHIM_BIN"
    SHIM_TRACE="$TMP/shim-trace.log"
    cat > "$SHIM_BIN/ssh" <<EOF
#!/usr/bin/env bash
# Fake ssh: handle the small subset of remote commands backup.sh issues.
# The remote command is the LAST argument.
cmd="\${!#}"
printf '[%s] cmd=%s\n' "\$\$" "\$cmd" >> "$SHIM_TRACE"
case "\$cmd" in
    true)
        # Bare connectivity probe.
        exit 0
        ;;
    "test -e "*)
        # Existence probe per allow-list entry (added in the
        # missing-allow-list-path-skips-gracefully fix). Pass-through
        # to local fs — "remote" paths are local in the shim, so
        # test -e returns the right thing.
        eval "\$cmd"
        exit \$?
        ;;
    "test -f "*" && head -n 1 "*|"test -f "*" && cat "*)
        # Metadata-fetch shapes (head -n 1 for VERSION/BUILD,
        # cat for data-version.yaml). Run as-is — the path inside
        # is already correctly quoted, and "remote" paths are
        # local on the test machine.
        eval "\$cmd"
        exit \$?
        ;;
    *"rsync --server"*)
        # rsync transport — the shim refuses, which surfaces as a
        # rsync failure in backup.sh. That's fine: we're only
        # testing the metadata code path.
        echo "fake-ssh: rsync transport not supported in this shim" >&2
        exit 255
        ;;
    *)
        echo "fake-ssh: unrecognised remote command: \$cmd" >&2
        exit 255
        ;;
esac
EOF
    chmod +x "$SHIM_BIN/ssh"

    # Configure SSH-mode for tier=prod, which uses DEPLOY_PROD_PATH
    # verbatim (no per-tier subpath suffix). We avoid tier=dev/test/staging
    # because those append `/dev` etc. to DEPLOY_PATH, which would mean
    # planting the fixture under $REMOTE_ROOT/dev/... for the tier name.
    # prod is cleaner.
    export DEPLOY_PROD_HOST=fake.host
    export DEPLOY_PROD_USER=fake
    export DEPLOY_PROD_PORT=22
    export DEPLOY_PROD_PATH="$REMOTE_ROOT"

    PATH="$SHIM_BIN:$PATH" run "$BACKUP_SH" prod --keep-local
    # We expect a rsync failure (exit code 2), NOT a metadata-fetch
    # failure (exit code 3). If the SSH command construction were
    # broken — wrong quoting, wrong path, missing -n — we'd hit the
    # "source tier missing config/www/VERSION" path with exit 3.
    [ "$status" -eq 2 ]
    [[ "$output" == *"rsync"* ]] || [[ "$output" == *"source"* ]]
    # The metadata-fetch should NOT have failed:
    [[ "$output" != *"source tier missing config/www/VERSION"* ]]
    [[ "$output" != *"source tier missing config/www/BUILD"* ]]

    # Trace assertion: the shim should have seen exactly the three
    # expected fetch shapes plus the connectivity probe. Path shapes
    # match the deployed Grav-root layout (NO config/www/ prefix —
    # see source_read_first_line / source_read_data_version_yaml in
    # backup.sh, fixed in 819ffa6).
    [ -f "$SHIM_TRACE" ]
    grep -q "true" "$SHIM_TRACE"
    grep -q "test -f .*VERSION.* && head -n 1" "$SHIM_TRACE"
    grep -q "test -f .*BUILD.* && head -n 1" "$SHIM_TRACE"
    grep -q "test -f .*user/data-version.yaml.* && cat" "$SHIM_TRACE"
    # Belt-and-braces — should NOT see the bogus `config/www/` shape.
    ! grep -q "config/www/VERSION" "$SHIM_TRACE"
}

@test "SSH-mode metadata fetch: missing VERSION on remote → exit 3 with naming error" {
    # Same fake-ssh shim approach, but the remote tree has no VERSION
    # file. The SSH `test -f` returns false → empty stdout → empty
    # CODE_VERSION → die. Exit 3, error names the file.
    unset BACKUP_FIXTURE_DIR

    REMOTE_ROOT="$TMP/remote-tier-no-version"
    mkdir -p "$REMOTE_ROOT/user"
    echo '999' > "$REMOTE_ROOT/BUILD"
    # Deliberately no VERSION.
    cat > "$REMOTE_ROOT/user/data-version.yaml" <<'EOF'
version: "0.1.0"
EOF

    SHIM_BIN="$TMP/shim-novr"
    mkdir -p "$SHIM_BIN"
    cat > "$SHIM_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${!#}"
case "$cmd" in
    "true") exit 0 ;;
    "test -f "*" && head -n 1 "*|"test -f "*" && cat "*) eval "$cmd"; exit $? ;;
    *) exit 255 ;;
esac
EOF
    chmod +x "$SHIM_BIN/ssh"

    export DEPLOY_PROD_HOST=fake.host
    export DEPLOY_PROD_USER=fake
    export DEPLOY_PROD_PORT=22
    export DEPLOY_PROD_PATH="$REMOTE_ROOT"

    PATH="$SHIM_BIN:$PATH" run "$BACKUP_SH" prod
    [ "$status" -eq 3 ]
    [[ "$output" == *"VERSION"* ]]
    [[ "$output" == *"source tier"* ]]
}

@test "SSH-mode: missing allow-list path on remote skips silently, does not abort backup" {
    # Regression test for the user/uploads scenario hit during PR #17
    # Tier 4a real-tier exercise: a fresh dev tier with no
    # `user/uploads/` dir caused backup.sh to abort with rsync
    # exit 23. The fix probes existence per allow-list entry and
    # skips missing ones silently — matching fixture mode's
    # `[ -e $src ]` gate. Missing allow-list paths are normal
    # (e.g. user/uploads on a tier with no uploads) and not a warning.
    unset BACKUP_FIXTURE_DIR

    # Custom allow-list with the MISSING path FIRST. Otherwise the
    # script would rsync (and fail in the shim) for an earlier path
    # before reaching the missing one.
    PATHS_FILE="$TMP/test-allow-list.txt"
    cat > "$PATHS_FILE" <<EOF
user/uploads
user/accounts
EOF
    export BACKUP_PATHS_FILE="$PATHS_FILE"

    # Build a "remote" tree with the metadata files AND user/accounts,
    # but DELIBERATELY OMIT user/uploads/.
    REMOTE_ROOT="$TMP/remote-tier-missing-optional-path"
    mkdir -p "$REMOTE_ROOT/user/accounts"
    # Note: NO user/uploads/ — it is the deliberately absent path.
    echo 'alice'   > "$REMOTE_ROOT/user/accounts/alice.yaml"
    echo '0.2.0' > "$REMOTE_ROOT/VERSION"
    echo '247'   > "$REMOTE_ROOT/BUILD"
    cat > "$REMOTE_ROOT/user/data-version.yaml" <<'EOF'
version: "0.1.0"
EOF

    # Shim: handle test -e (existence probe), the metadata-fetch
    # shapes (test -f && head/cat), and the connectivity probe
    # (true). Anything else (including rsync transport) returns 255
    # so backup.sh aborts there — we only need to assert the WARN
    # for user/uploads fired, not that the subsequent backup
    # completed.
    SHIM_BIN="$TMP/shim-skip"
    mkdir -p "$SHIM_BIN"
    cat > "$SHIM_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
cmd="${!#}"
case "$cmd" in
    "true")                                                  exit 0 ;;
    "test -e "*)                                             eval "$cmd"; exit $? ;;
    "test -f "*" && head -n 1 "*|"test -f "*" && cat "*)     eval "$cmd"; exit $? ;;
    *)                                                       exit 255 ;;
esac
EOF
    chmod +x "$SHIM_BIN/ssh"

    export DEPLOY_PROD_HOST=fake.host
    export DEPLOY_PROD_USER=fake
    export DEPLOY_PROD_PORT=22
    export DEPLOY_PROD_PATH="$REMOTE_ROOT"

    PATH="$SHIM_BIN:$PATH" run --separate-stderr "$BACKUP_SH" prod
    # The load-bearing assertion: user/uploads (the only allow-list
    # path NOT planted on the remote) was silently skipped — no WARN
    # emitted. The loop must have continued rather than aborting.
    [[ "$stderr" != *"uploads"* ]]
    # backup.sh will eventually fail (rsync of EXISTING dirs trips the
    # shim's catch-all), but that's downstream of what we're testing.
    [ "$status" -ne 0 ]
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

@test "local-tier restore for tier=prod skips the real-prod pre-restore safety backup" {
    # Regression for the post-merge review of PR #16:
    # When RESTORE_LOCAL_TIER_DIR is set, the script must NOT take a
    # pre-restore backup against real prod via SSH — that would
    # require live prod credentials, cost a real S3 upload, and
    # contradict the entire premise of local-tier mode being a
    # safe stand-in. The fix: skip step 4 when local-tier mode is
    # active. The SSH path keeps the safety backup unconditionally.

    # Build a fixture-shaped prod backup we can restore from.
    run "$BACKUP_SH" prod
    [ "$status" -eq 0 ]
    archive="$(ls "$BACKUP_LOCAL_STORE_DIR"/prod-*.tar.gz.age | head -n1)"
    id="$(basename "$archive" .tar.gz.age)"

    # Fresh tier-B target. No bin/grav, so clearcache logs "skipped".
    TIER_B="$TMP/tier-b-prod"
    mkdir -p "$TIER_B/user/accounts" "$TIER_B/user/data" \
             "$TIER_B/user/pages" "$TIER_B/user/uploads"

    # Install a fake `ssh` earlier in PATH that records every
    # invocation. If the script tries to SSH to real prod for the
    # pre-restore backup, the marker file appears and the test fails.
    SHIM_BIN="$TMP/shim-bin"
    mkdir -p "$SHIM_BIN"
    cat > "$SHIM_BIN/ssh" <<EOF
#!/usr/bin/env bash
printf 'ssh-invoked: %s\n' "\$*" >> "$TMP/ssh-invocations"
exit 1
EOF
    chmod +x "$SHIM_BIN/ssh"

    # Deliberately leave DEPLOY_PROD_* unset to ensure the SSH path
    # would fail if reached. The test passes only if SSH is NEVER
    # reached — i.e. the local-tier branch correctly skips the
    # real-prod backup.
    PATH="$SHIM_BIN:$PATH" \
    RESTORE_TO_TIER_ENABLED=1 RESTORE_LOCAL_TIER_DIR="$TIER_B" \
        run "$RESTORE_SH" prod --from "$id" --yes-i-mean-it
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode=tier-local"* ]]

    # SSH must never have been invoked.
    [ ! -f "$TMP/ssh-invocations" ]

    # Log file should record the deliberate skip with a clear reason.
    # Search by content rather than by timestamp ordering: $REPO_ROOT/logs/
    # may contain log files from other test scenarios in the same suite run.
    log_file="$(grep -l 'pre-restore safety backup skipped (RESTORE_LOCAL_TIER_DIR set)' \
                    "$REPO_ROOT/logs"/restore-prod-*.log 2>/dev/null | head -n1)"
    [ -n "$log_file" ]

    # Cleanup — remove every prod restore log this test could have produced
    # so a follow-up test doesn't trip over them.
    rm -f "$REPO_ROOT/logs"/restore-prod-*.log
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
