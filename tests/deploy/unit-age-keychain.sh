#!/usr/bin/env bash
#
# Unit test for deploy/lib/age-keychain.sh — exercises the public API
# (bv_age_keychain_known_labels, bv_age_keychain_get_identity,
# bv_age_keychain_get_pubkey, bv_age_keychain_try_decrypt,
# bv_age_keychain_store_identity, bv_age_keychain_delete,
# bv_age_recipients_count) against a stub `security` CLI.
#
# Same pattern as unit-ssh-auth.sh: stubs in a mktemp dir prepended
# to PATH; stubs persist Keychain state in a TSV file we can inspect.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=deploy/lib/age-keychain.sh
. "$PROJECT_ROOT/deploy/lib/age-keychain.sh"

PASS=0
FAIL=0

check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then
        echo "  ✓ $name"
        PASS=$((PASS+1))
    else
        echo "  ✗ $name" >&2
        FAIL=$((FAIL+1))
    fi
}

echo "Unit test: age-keychain.sh (against stub security CLI)"
echo "---"

# ─────────────────────────────────────────────────────────────────────
# Stub PATH + state
# ─────────────────────────────────────────────────────────────────────
STUB_PREFIX="bv-unit-age-kc."
find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name "${STUB_PREFIX}*" -mmin +60 \
    -exec rm -rf {} + 2>/dev/null || true

STUB_DIR="$(mktemp -d -t "${STUB_PREFIX}XXXXXX")"
trap 'rm -rf "$STUB_DIR"' EXIT

# State file: each line "<service>\t<base64-of-password>"
KC_STATE="$STUB_DIR/keychain.tsv"
: > "$KC_STATE"
export BV_TEST_KC_STATE="$KC_STATE"

# Stub security CLI: handles add-generic-password (with -w), find-
# generic-password (with -w), delete-generic-password.
cat > "$STUB_DIR/security" <<'EOF'
#!/usr/bin/env bash
mode="$1"; shift
service="" password="" account=""
while [ $# -gt 0 ]; do
    case "$1" in
        -a) account="$2"; shift 2 ;;
        -s) service="$2"; shift 2 ;;
        -w) shift
            # If the next arg exists and isn't another flag, treat
            # it as the password value. Else: prompt mode (we don't
            # implement that here).
            if [ $# -gt 0 ] && [ "${1:0:1}" != "-" ]; then
                password="$1"; shift
            fi
            ;;
        -l|-j|-T|-A|-U) shift 2 ;;     # comment/label/access flags — ignore
        *)  shift ;;
    esac
done

state="${BV_TEST_KC_STATE:-/dev/null}"
case "$mode" in
    add-generic-password)
        # Refuse if duplicate (service already present) — unless
        # caller does delete-then-add (our helper does this for
        # overwrite). For test simplicity we just append.
        if grep -q "^${service}	" "$state" 2>/dev/null; then
            echo "security: SecKeychainItemCreateFromContent: The specified item already exists in the keychain." >&2
            exit 45
        fi
        # base64 the password to keep TSV clean (multi-line OK)
        printf '%s\t%s\n' "$service" "$(printf '%s' "$password" | base64)" >> "$state"
        exit 0
        ;;
    find-generic-password)
        line="$(grep -F "^${service}	" "$state" 2>/dev/null || grep "^${service}	" "$state" 2>/dev/null || true)"
        if [ -z "$line" ]; then
            echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
            exit 44
        fi
        b64="${line#*	}"
        printf '%s' "$b64" | base64 -d 2>/dev/null
        exit 0
        ;;
    delete-generic-password)
        if ! grep -q "^${service}	" "$state" 2>/dev/null; then
            exit 44
        fi
        tmp="$(mktemp)"
        grep -v "^${service}	" "$state" > "$tmp" || true
        mv "$tmp" "$state"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$STUB_DIR/security"

PATH="$STUB_DIR:$PATH"
export PATH

# Recipients file fixture
RF="$STUB_DIR/recipients.txt"
export BV_AGE_RECIPIENTS_FILE="$RF"
: > "$RF"
export USER="${USER:-test-user}"

# ─────────────────────────────────────────────────────────────────────
# Test group A: bv_age_keychain_available
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "A. macOS detection"

if bv_age_keychain_available 2>/dev/null; then
    check "available when 'security' CLI is on PATH" ok
else
    check "available when 'security' CLI is on PATH" fail
fi

# Test "missing security" by removing the stub temporarily
PATH_BACKUP="$PATH"
NO_SEC="$(mktemp -d -t "${STUB_PREFIX}nosec.XXXXXX")"
PATH="$NO_SEC"
err="$(bv_age_keychain_available 2>&1 >/dev/null || true)"
PATH="$PATH_BACKUP"
rm -rf "$NO_SEC"
case "$err" in
    *"security"*"not on PATH"*"macOS"*) check "fails loud + diagnostic when security CLI absent" ok ;;
    *) check "missing security CLI diagnostic (got: '$err')" fail ;;
esac

# ─────────────────────────────────────────────────────────────────────
# Test group B: store / get / pubkey / delete round-trip
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "B. store / read / delete round-trip"

# Build a fake age identity file. Format matches what age-keygen emits.
ID_FILE="$STUB_DIR/identity-thomas.txt"
cat > "$ID_FILE" <<EOF
# created: 2026-05-10T12:00:00Z
# public key: age1qzg83fcsqgvrpxdgg9sjxrqxc4fynp9k08cax9d3qvcvcwcucpysjwgewh
AGE-SECRET-KEY-1FAKE0000000000000000000000000000000000000000000000000000000000
EOF
chmod 600 "$ID_FILE"

# B.1 — store
bv_age_keychain_store_identity "thomas" "$ID_FILE" >/dev/null
out="$(bv_age_keychain_get_identity "thomas")"
if [ "$out" = "$(cat "$ID_FILE")" ]; then
    check "store + get round-trips identity content (multi-line)" ok
else
    check "store + get round-trip (got: '$out')" fail
fi

# B.2 — pubkey extraction
pubkey="$(bv_age_keychain_get_pubkey "thomas")"
if [ "$pubkey" = "age1qzg83fcsqgvrpxdgg9sjxrqxc4fynp9k08cax9d3qvcvcwcucpysjwgewh" ]; then
    check "get_pubkey extracts age1... line from stored identity" ok
else
    check "get_pubkey (got: '$pubkey')" fail
fi

# B.3 — refuse overwrite by default
if bv_age_keychain_store_identity "thomas" "$ID_FILE" 2>/dev/null; then
    check "store refuses to overwrite existing label without --overwrite" fail
else
    check "store refuses to overwrite existing label without --overwrite" ok
fi

# B.4 — overwrite when forced
ID_FILE_2="$STUB_DIR/identity-thomas-2.txt"
cat > "$ID_FILE_2" <<EOF
# public key: age1newpubkey00000000000000000000000000000000000000000000000000
AGE-SECRET-KEY-1FAKE2000000000000000000000000000000000000000000000000000000000
EOF
bv_age_keychain_store_identity "thomas" "$ID_FILE_2" --overwrite >/dev/null
new_pub="$(bv_age_keychain_get_pubkey "thomas")"
if [ "$new_pub" = "age1newpubkey00000000000000000000000000000000000000000000000000" ]; then
    check "store --overwrite replaces existing identity" ok
else
    check "overwrite (got: '$new_pub')" fail
fi

# B.5 — delete
bv_age_keychain_delete "thomas"
if [ -z "$(bv_age_keychain_get_identity "thomas" 2>/dev/null)" ]; then
    check "delete removes the Keychain item" ok
else
    check "delete should remove the item" fail
fi

# B.6 — delete absent label returns non-zero (without crashing)
if bv_age_keychain_delete "no-such-label" 2>/dev/null; then
    check "delete of absent label returns non-zero" fail
else
    check "delete of absent label returns non-zero" ok
fi

# ─────────────────────────────────────────────────────────────────────
# Test group C: known_labels — walks the recipients file's
# `# bv-age-identity-<label>` markers
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "C. known_labels (recipients-file walk)"

# C.1 — empty file → empty output
out="$(bv_age_keychain_known_labels)"
if [ -z "$out" ]; then
    check "known_labels on empty recipients file → empty" ok
else
    check "known_labels empty (got: '$out')" fail
fi

# C.2 — populated file
cat > "$RF" <<EOF
# bv-age-identity-thomas   (added 2026-05-10T12:00Z by thomas@laptop)
age1aaaa0000000000000000000000000000000000000000000000000000000000

# bv-age-identity-alice    (added 2026-05-09T10:30Z by alice@laptop)
age1bbbb0000000000000000000000000000000000000000000000000000000000
EOF
out="$(bv_age_keychain_known_labels)"
expected="alice
thomas"
if [ "$out" = "$expected" ]; then
    check "known_labels enumerates labels from recipients-file markers, sorted" ok
else
    check "known_labels (got: '$out', expected: '$expected')" fail
fi

# C.3 — handles trailing whitespace / extra columns in markers
cat >> "$RF" <<EOF

# bv-age-identity-bob   2026-05-08
age1cccc0000000000000000000000000000000000000000000000000000000000
EOF
out="$(bv_age_keychain_known_labels)"
case "$out" in
    *"bob"*) check "known_labels tolerates extra trailing whitespace/columns" ok ;;
    *) check "known_labels with bob in markers (got: '$out')" fail ;;
esac

# ─────────────────────────────────────────────────────────────────────
# Test group D: bv_age_recipients_count
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "D. recipients_count"

count="$(bv_age_recipients_count)"
if [ "$count" = "3" ]; then
    check "recipients_count counts active age1 lines (3 in fixture)" ok
else
    check "recipients_count (got: '$count')" fail
fi

# Empty file
: > "$RF"
count="$(bv_age_recipients_count)"
if [ "$count" = "0" ]; then
    check "recipients_count on empty file → 0" ok
else
    check "recipients_count empty (got: '$count')" fail
fi

# Missing file
rm -f "$RF"
count="$(bv_age_recipients_count)"
if [ "$count" = "0" ]; then
    check "recipients_count on missing file → 0 (no crash)" ok
else
    check "recipients_count missing (got: '$count')" fail
fi

# ─────────────────────────────────────────────────────────────────────
# Test group E: try_decrypt — end-to-end against a real age-encrypted
# blob. Needs `age` and `age-keygen` on PATH; skip with note if not.
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "E. try_decrypt (real age round-trip)"

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    echo "  (skipped — age / age-keygen not on PATH)"
else
    # Generate two real keypairs; encrypt a payload to one; verify
    # try_decrypt finds the matching identity in our stubbed Keychain.
    REAL_DIR="$STUB_DIR/real"
    mkdir -p "$REAL_DIR"
    age-keygen -o "$REAL_DIR/id-decoy.txt" 2>/dev/null
    age-keygen -o "$REAL_DIR/id-real.txt"  2>/dev/null
    DECOY_PUB="$(awk '/^# public key:/ {print $4; exit}' "$REAL_DIR/id-decoy.txt")"
    REAL_PUB="$(awk '/^# public key:/ {print $4; exit}' "$REAL_DIR/id-real.txt")"

    # Recipients file declares both labels.
    cat > "$RF" <<EOF
# bv-age-identity-decoy
$DECOY_PUB

# bv-age-identity-real
$REAL_PUB
EOF

    # Store BOTH identities in the stubbed Keychain.
    bv_age_keychain_store_identity "decoy" "$REAL_DIR/id-decoy.txt" --overwrite >/dev/null
    bv_age_keychain_store_identity "real"  "$REAL_DIR/id-real.txt"  --overwrite >/dev/null

    # Encrypt a payload to ONLY the real public key — try_decrypt
    # should walk both identities and succeed on the matching one.
    PAYLOAD="$REAL_DIR/payload.txt"
    ENC="$REAL_DIR/payload.age"
    OUT="$REAL_DIR/decrypted.txt"
    echo "secret-content-roundtrip-$$" > "$PAYLOAD"
    age -r "$REAL_PUB" -o "$ENC" "$PAYLOAD"

    if bv_age_keychain_try_decrypt "$ENC" "$OUT"; then
        if [ "$(cat "$OUT")" = "$(cat "$PAYLOAD")" ]; then
            check "try_decrypt finds matching identity among multiple Keychain items" ok
        else
            check "try_decrypt returned 0 but plaintext differs" fail
        fi
    else
        check "try_decrypt should succeed when ONE matching identity is in Keychain" fail
    fi

    # Negative: encrypt to an unknown pubkey, no Keychain identity matches → fail
    age-keygen -o "$REAL_DIR/id-orphan.txt" 2>/dev/null
    ORPHAN_PUB="$(awk '/^# public key:/ {print $4; exit}' "$REAL_DIR/id-orphan.txt")"
    age -r "$ORPHAN_PUB" -o "$ENC" "$PAYLOAD"
    rm -f "$OUT"
    if bv_age_keychain_try_decrypt "$ENC" "$OUT" 2>/dev/null; then
        check "try_decrypt fails when no Keychain identity matches" fail
    else
        check "try_decrypt fails when no Keychain identity matches" ok
    fi
    [ ! -f "$OUT" ] || check "try_decrypt leaves no plaintext on failure path" fail
    [ ! -f "$OUT" ] && check "try_decrypt leaves no plaintext on failure path" ok
fi

# ─────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────"
echo "  Pass: $PASS    Fail: $FAIL"
echo "─────────────────────────────────────"

[ "$FAIL" -eq 0 ]
