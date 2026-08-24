#!/usr/bin/env bash
#
# Unit test for deploy/lib/smoke-behaviour.sh — the post-deploy probes.
#
# THE FAILURE THIS PINS
# ---------------------
# The probe checked `/` and called the tier healthy. The homepage is modular
# and never runs a page body through Grav's markdown pipeline, so it survives
# failures that break every ordinary page.
#
# On 2026-08-24 a Grav 1.7 → 2.0 deploy onto warm PHP-FPM workers left the
# workers holding the old core. `/` answered 200 and the deploy reported
# success; /login, /vaerksteder and /kontakt were all 500 from
# onMarkdownInitialized. A green deploy on a broken tier — and the probe is
# the one thing standing between that and an operator walking away.
#
# So the suite now asserts the shape directly: homepage fine + content page
# broken must FAIL.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PASS=0
FAIL=0
check() {
    local name="$1" outcome="$2"
    if [ "$outcome" = "ok" ]; then echo "  ✓ $name"; PASS=$((PASS+1));
    else echo "  ✗ $name" >&2; FAIL=$((FAIL+1)); fi
}

echo "Unit test: post-deploy smoke probes (stub HTTP)"
echo "---"

SB="$(mktemp -d -t bv-unit-smoke.XXXXXX)"
STUB_PID=""
cleanup() {
    [ -n "$STUB_PID" ] && kill "$STUB_PID" 2>/dev/null || true
    rm -rf "$SB"
}
trap cleanup EXIT

# ── Stub tier ────────────────────────────────────────────────────────
# /logs/grav.log → 403 (the deny rules are in effect)
# /              → 200, no long max-age
# the content path → whatever $SB/content-status says, so a test can break
#                    exactly one page and nothing else.
echo 200 > "$SB/content-status"

cat > "$SB/stub.py" <<'PY'
import sys, http.server
STATE = sys.argv[1]
PORT = int(sys.argv[2])

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split('?', 1)[0]
        if path.startswith('/logs/'):
            self.send_response(403); self.end_headers(); return
        if path == '/':
            self.send_response(200)
            self.send_header('Cache-Control', 'no-cache, must-revalidate')
            self.end_headers()
            self.wfile.write(b'<html>home</html>')
            return
        with open(STATE) as f:
            code = int(f.read().strip())
        self.send_response(code); self.end_headers()
        self.wfile.write(b'<html>content</html>')
    def log_message(self, *a):
        pass

http.server.HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PY

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
python3 "$SB/stub.py" "$SB/content-status" "$PORT" &
STUB_PID=$!
BASE="http://127.0.0.1:$PORT"

for _ in $(seq 1 40); do
    curl -fsS -o /dev/null -m 2 "$BASE/" 2>/dev/null && break
    sleep 0.25
done

# shellcheck source=deploy/lib/smoke-behaviour.sh
. "$PROJECT_ROOT/deploy/lib/smoke-behaviour.sh"

# ── Everything healthy ───────────────────────────────────────────────
echo 200 > "$SB/content-status"
set +e
out="$(bv_post_deploy_smoke "$BASE" 2>&1)"; rc=$?
set -e
check "a healthy tier passes" \
    "$([ "$rc" -eq 0 ] && echo ok || echo no)"
check "it reports the content page, not just the homepage" \
    "$(printf '%s' "$out" | grep -q 'content page' && echo ok || echo no)"
check "the content check names markdown, so the reason is legible" \
    "$(printf '%s' "$out" | grep -q 'markdown renders' && echo ok || echo no)"

# ── The 2026-08-24 shape: homepage fine, every content page broken ───
echo 500 > "$SB/content-status"
set +e
out="$(bv_post_deploy_smoke "$BASE" 2>&1)"; rc=$?
set -e
check "homepage 200 + content page 500 FAILS the probe" \
    "$([ "$rc" -ne 0 ] && echo ok || echo no)"
check "the homepage check still passes (it is genuinely 200)" \
    "$(printf '%s' "$out" | grep -q '✓ homepage answers 200' && echo ok || echo no)"
check "the failure names the status it got" \
    "$(printf '%s' "$out" | grep -q 'returned HTTP 500' && echo ok || echo no)"
check "the failure explains why the homepage alone was not enough" \
    "$(printf '%s' "$out" | grep -q 'homepage can answer 200' && echo ok || echo no)"

# ── The path is overridable ──────────────────────────────────────────
# A tier could rename the page; a hardcoded slug that cannot be pointed
# elsewhere would turn into a permanently red deploy.
echo 200 > "$SB/content-status"
set +e
out="$(BV_SMOKE_CONTENT_PATH=/en-anden-side bv_post_deploy_smoke "$BASE" 2>&1)"; rc=$?
set -e
check "BV_SMOKE_CONTENT_PATH overrides the probed path" \
    "$(printf '%s' "$out" | grep -q '/en-anden-side' && echo ok || echo no)"
check "the override still passes when that page is healthy" \
    "$([ "$rc" -eq 0 ] && echo ok || echo no)"

# ── The default must not be the homepage ─────────────────────────────
# Defaulting to "/" would silently restore the exact blind spot.
check "the default content path is not the homepage" \
    "$(grep -q 'BV_SMOKE_CONTENT_PATH:-/[a-z]' "$PROJECT_ROOT/deploy/lib/smoke-behaviour.sh" && echo ok || echo no)"

echo "---"
echo "smoke behaviour unit: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
