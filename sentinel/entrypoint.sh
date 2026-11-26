#!/bin/sh
# Starts crisium as a sentinel for one application:
#   1. downloads the application's template (TEMPLATE_URL, a .tar.gz of a stored machine) once;
#   2. stores the epoch-0 checkpoint and checks the template against getTemplateHash() (preflight.lua);
#   3. runs crisium with the anomaly handler (handler/crisium_alerts.lua).
# Everything it keeps is under DATA_DIR (a volume), so a restart resumes where it stopped.
set -eu

fail() { echo "crisium-sentinel: $*" >&2; exit 1; }
log() { echo "crisium-sentinel: $*" >&2; }

: "${RPC_URL:?set RPC_URL (an Ethereum JSON-RPC endpoint)}"
: "${APPLICATION:?set APPLICATION (the application contract address)}"
: "${TEMPLATE_URL:?set TEMPLATE_URL (a .tar.gz of the application's stored template machine)}"
DATA_DIR="${DATA_DIR:-/data}"
DAVE_DIR="${DAVE_DIR:-/opt/dave}"
LABEL="${LABEL:-sentinel}"
RECIPES=/opt/crisium/recipes
SENTINEL=/opt/crisium/sentinel

mkdir -p "$DATA_DIR" || fail "cannot create $DATA_DIR"
[ -w "$DATA_DIR" ] || fail "$DATA_DIR is not writable"
template="$DATA_DIR/template"
checkpoints="$DATA_DIR/checkpoints"
state="$DATA_DIR/state"
mkdir -p "$checkpoints" "$state"

# The template is downloaded once per TEMPLATE_URL. A changed URL replaces it and, since epoch 0's
# checkpoint is built from it, the checkpoints and state too.
source_id="$TEMPLATE_URL ${TEMPLATE_SHA256:-}"
if [ ! -f "$template/config.json" ] || [ "$(cat "$DATA_DIR/template.source" 2>/dev/null)" != "$source_id" ]; then
    log "downloading the template"
    rm -rf "$template" "$DATA_DIR/template.tmp" "$checkpoints" "$state"
    mkdir -p "$DATA_DIR/template.tmp" "$checkpoints" "$state"
    curl -fsSL --retry 3 -o "$DATA_DIR/template.tar.gz" "$TEMPLATE_URL" || fail "cannot download TEMPLATE_URL"
    if [ -n "${TEMPLATE_SHA256:-}" ]; then
        echo "$TEMPLATE_SHA256  $DATA_DIR/template.tar.gz" | sha256sum -c - >/dev/null \
            || fail "the template's SHA-256 is not TEMPLATE_SHA256"
    fi
    # --warning: archives made on macOS carry extended headers GNU tar does not know; they are harmless.
    tar --warning=no-unknown-keyword -xzf "$DATA_DIR/template.tar.gz" -C "$DATA_DIR/template.tmp" \
        || fail "TEMPLATE_URL is not a .tar.gz"
    rm -f "$DATA_DIR/template.tar.gz"
    # Accept the machine at the archive's root or in one directory inside it.
    config=$(find "$DATA_DIR/template.tmp" -maxdepth 2 -name config.json | head -n 1)
    [ -n "$config" ] || fail "the archive has no stored machine (no config.json at its root or one level down)"
    mv "$(dirname "$config")" "$template"
    rm -rf "$DATA_DIR/template.tmp"
    printf '%s' "$source_id" > "$DATA_DIR/template.source"
fi

log "preflight: application $APPLICATION"
template_hash=$(lua5.4 "$SENTINEL/preflight.lua" "$RPC_URL" "$APPLICATION" "$DAVE_DIR" "$template" "$checkpoints/epoch-0") \
    || fail "preflight failed"

# The handler's context. PROVIDER is the RPC host only: a provider URL often carries an API key.
provider=$(printf '%s' "$RPC_URL" | sed -E 's#^[a-z]+://([^/@]*@)?([^/:?]+).*#\2#')
export CRISIUM_ALERTS_LOG="${CRISIUM_ALERTS_LOG:-$DATA_DIR/alerts.jsonl}"
export CRISIUM_ALERTS_SOURCE="${CRISIUM_ALERTS_SOURCE:-crisium sentinel ($LABEL)}"
export CRISIUM_ALERTS_VERSION="${CRISIUM_ALERTS_VERSION:-machine-emulator ${EMULATOR_VERSION:-?}, dave ${DAVE_VERSION:-?}}"
export CRISIUM_ALERTS_TEMPLATE_HASH="${CRISIUM_ALERTS_TEMPLATE_HASH:-$template_hash}"
export CRISIUM_ALERTS_PROVIDER="${CRISIUM_ALERTS_PROVIDER:-$provider}"

set -- --rpc="$RPC_URL" --application="$APPLICATION" --state="$state" --checkpoints="$checkpoints" \
    --dave="$DAVE_DIR" --label="$LABEL" --status-file="$DATA_DIR/status.json" \
    --anomaly-handler=crisium_alerts "$@"
[ -n "${WS_URL:-}" ] && set -- "$@" --ws="$WS_URL"
[ -n "${WARNING_BLOCKS:-}" ] && set -- "$@" --warning-blocks="$WARNING_BLOCKS"
[ -n "${FIRST_EPOCH:-}" ] && set -- "$@" --first-epoch="$FIRST_EPOCH"
[ -n "${POLL_INTERVAL:-}" ] && set -- "$@" --poll-interval="$POLL_INTERVAL"
# shellcheck disable=SC2086 # CRISIUM_ARGS is a list of extra crisium options
[ -n "${CRISIUM_ARGS:-}" ] && set -- "$@" $CRISIUM_ARGS

log "starting crisium (template $template_hash, provider $provider)"
cd "$RECIPES"
exec lua5.4 "$RECIPES/crisium.lua" "$@"
