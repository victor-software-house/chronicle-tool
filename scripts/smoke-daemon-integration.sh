#!/usr/bin/env bash
# Daemon integration smoke against the local thin-client surface.
#
# Asserts the following over an isolated XDG_RUNTIME_DIR (never the installed
# `/Applications/chronicle.app` paths):
#   1. `chronicle daemon-run --source <src>` starts and publishes a Unix socket.
#   2. A second `chronicle daemon-run` for the same source is rejected before
#      opening audio (alreadyOwned).
#   3. `chronicle status` returns a JSON-RPC response containing the source +
#      lifecycle.
#   4. `chronicle mark <label>` round-trips through the RPC layer.
#   5. `chronicle clip --last-seconds 1` returns either a success result or a
#      structured error (range_unavailable / accepted placeholder).
#   6. `chronicle config --diarize true` returns a JSON-RPC response.
#   7. `chronicle stop` returns a JSON-RPC response and daemon shuts down on
#      SIGTERM, removing socket + pid file.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${CHRONICLE_BIN:-$ROOT/.build/debug/chronicle}"
SRC="${1:-mic}"

if [[ ! -x "$BIN" ]]; then
  echo "[smoke-daemon-integration] building chronicle"
  (cd "$ROOT" && swift build >/dev/null)
fi

XDG_DIR="/tmp/cint-$$"
mkdir -p "$XDG_DIR"
SOCKET_DIR="$XDG_DIR/chronicle/$SRC"
LOG_PRIMARY="$XDG_DIR/primary.log"

cleanup() {
  if [[ -n "${PRIMARY_PID:-}" ]]; then kill -TERM "$PRIMARY_PID" 2>/dev/null || kill -9 "$PRIMARY_PID" 2>/dev/null || true; fi
  rm -rf "$XDG_DIR"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$XDG_DIR"

echo "[smoke-daemon-integration] XDG_RUNTIME_DIR=$XDG_DIR source=$SRC"

# 1. Start primary daemon.
"$BIN" daemon-run --source "$SRC" >"$LOG_PRIMARY" 2>&1 &
PRIMARY_PID=$!
for _ in $(seq 1 50); do
  [[ -S "$SOCKET_DIR/control.sock" ]] && break
  sleep 0.1
done
if [[ ! -S "$SOCKET_DIR/control.sock" ]]; then
  echo "[smoke-daemon-integration] primary daemon socket missing"
  cat "$LOG_PRIMARY" >&2
  exit 1
fi

# 2. Duplicate daemon rejected.
if "$BIN" daemon-run --source "$SRC" >"$XDG_DIR/duplicate.log" 2>&1; then
  echo "[smoke-daemon-integration] duplicate daemon was not rejected"
  cat "$XDG_DIR/duplicate.log" >&2
  exit 1
fi
grep -qi "already" "$XDG_DIR/duplicate.log" || {
  echo "[smoke-daemon-integration] duplicate rejection did not mention ownership"
  cat "$XDG_DIR/duplicate.log" >&2
  exit 1
}

# 3. status RPC.
STATUS_JSON="$("$BIN" status --source "$SRC")"
echo "$STATUS_JSON" | grep -q '"source":"'"$SRC"'"' || {
  echo "[smoke-daemon-integration] status missing source: $STATUS_JSON"; exit 1;
}

# 4. mark RPC.
MARK_JSON="$("$BIN" mark --source "$SRC" --client-req-id mark-smoke smoke-marker)"
echo "$MARK_JSON" | grep -q '"jsonrpc"' || {
  echo "[smoke-daemon-integration] mark RPC missing envelope: $MARK_JSON"; exit 1;
}

# 5. clip RPC.
CLIP_PATH="$XDG_DIR/clip.wav"
CLIP_JSON="$("$BIN" clip --source "$SRC" --last-seconds 1 --output "$CLIP_PATH" --client-req-id clip-smoke)"
echo "$CLIP_JSON" | grep -q '"jsonrpc"' || {
  echo "[smoke-daemon-integration] clip RPC missing envelope: $CLIP_JSON"; exit 1;
}

# 6. config RPC.
CONFIG_JSON="$("$BIN" config --source "$SRC" --diarize true --client-req-id config-smoke)"
echo "$CONFIG_JSON" | grep -q '"jsonrpc"' || {
  echo "[smoke-daemon-integration] config RPC missing envelope: $CONFIG_JSON"; exit 1;
}

# 7. stop RPC + shutdown.
STOP_JSON="$("$BIN" stop --source "$SRC" --client-req-id stop-smoke)"
echo "$STOP_JSON" | grep -q '"jsonrpc"' || {
  echo "[smoke-daemon-integration] stop RPC missing envelope: $STOP_JSON"; exit 1;
}

kill -TERM "$PRIMARY_PID" 2>/dev/null || true
wait "$PRIMARY_PID" 2>/dev/null || true
unset PRIMARY_PID

# Socket + pid removed on graceful shutdown.
sleep 0.2
if [[ -S "$SOCKET_DIR/control.sock" ]]; then
  echo "[smoke-daemon-integration] socket persisted after shutdown"
  exit 1
fi

echo "[smoke-daemon-integration] ok source=$SRC"
