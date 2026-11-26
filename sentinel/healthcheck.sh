#!/bin/sh
# Healthy while crisium keeps finishing passes: it rewrites DATA_DIR/status.json after every pass.
# A stuck process, or one that cannot reach its RPC, stops rewriting it. STATUS_MAX_AGE is in seconds.
# The image's start period covers the first catch-up replay, which can take long on an old application.
status="${DATA_DIR:-/data}/status.json"
max_age="${STATUS_MAX_AGE:-300}"
[ -f "$status" ] || { echo "no status file yet"; exit 1; }
age=$(( $(date +%s) - $(stat -c %Y "$status") ))
if [ "$age" -gt "$max_age" ]; then
    echo "status.json is ${age}s old (limit ${max_age}s)"
    exit 1
fi
echo "ok: status.json ${age}s old"
