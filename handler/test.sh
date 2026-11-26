#!/bin/sh
# Runs the handler tests: once with no webhook (no network), once with a webhook on a closed local port
# to check that posting never blocks the caller, and once with a local listener to check the payload.
set -eu
cd "$(dirname "$0")"
LUA=${LUA:-$(command -v lua5.4 || command -v lua)}
export LUA_PATH="./?.lua;;"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "== no webhook"
CRISIUM_ALERTS_LOG="$tmp/a.jsonl" "$LUA" test.lua

echo "== runbook link"
CRISIUM_ALERTS_LOG="$tmp/r.jsonl" CRISIUM_ALERTS_RUNBOOK="https://runbook.example/{kind}" "$LUA" test.lua

echo "== webhook on a closed port (must not block)"
start=$(date +%s)
CRISIUM_ALERTS_LOG="$tmp/b.jsonl" CRISIUM_ALERTS_WEBHOOK="http://127.0.0.1:9/hook" "$LUA" test.lua
end=$(date +%s)
[ $((end - start)) -le 2 ] || { echo "FAIL: posting blocked for $((end - start)) s"; exit 1; }
echo "returned in $((end - start)) s"

echo "== webhook payload (local listener)"
python3 - "$tmp" <<'EOF' &
import http.server, sys, json, os
out = os.path.join(sys.argv[1], "posts.txt")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n)
        json.loads(body)
        with open(out, "ab") as f:
            f.write(body + b"\n")
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 18766), H)
srv.timeout = 0.5
import time
end = time.time() + 6
while time.time() < end:
    srv.handle_request()
EOF
listener=$!
sleep 1
CRISIUM_ALERTS_LOG="$tmp/c.jsonl" CRISIUM_ALERTS_WEBHOOK="http://127.0.0.1:18766/hook" "$LUA" test.lua
wait $listener || true
posts=$(wc -l < "$tmp/posts.txt" | tr -d ' ')
# Posted: every alarm at or above the default minimum severity (warn); self stays in the log.
expected=$(grep -cE '"severity":"(guardian|operator|warn)"' "$tmp/c.jsonl")
echo "posted $posts of $expected guardian/operator/warn alarms"
[ "$posts" -eq "$expected" ] || { echo "FAIL: webhook count"; exit 1; }
grep -q '"content":"\[guardian\] crisium sentinel: staged_tournament_result_mismatch' "$tmp/posts.txt" \
    || { echo "FAIL: discord payload"; exit 1; }
grep -q 'NOT signable alone' "$tmp/posts.txt" || { echo "FAIL: signable note"; exit 1; }
echo "all ok"
