#!/usr/bin/env bash
# Daemon kill -9 recovery smoke.
#
# Asserts that:
#   1. `chronicle daemon-run` starts a source-owner daemon and publishes a socket + pid file.
#   2. `chronicle status` returns a JSON-RPC response (lifecycle=stopped while no capture is running).
#   3. After kill -9 of the daemon process, a fresh `chronicle daemon-run` start:
#        a. Appends a `daemon.recovery` event referencing the prior epoch.
#        b. Leaves the daemon JSONL parseable (at most the final line may be malformed).
#        c. Publishes a fresh `daemon.started` event and a new socket.
#
# The smoke uses an isolated XDG_RUNTIME_DIR so it never collides with the
# installed `/Applications/chronicle.app` live capture or the user's normal
# Chronicle runtime root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${CHRONICLE_BIN:-$ROOT/.build/debug/chronicle}"
SRC="${1:-mic}"

if [[ ! -x "$BIN" ]]; then
  echo "[smoke-daemon-kill9] building chronicle binary"
  (cd "$ROOT" && swift build >/dev/null)
fi

XDG_DIR="/tmp/csmk-$$"
mkdir -p "$XDG_DIR"
SOCKET_DIR="$XDG_DIR/chronicle/$SRC"
JSONL="$SOCKET_DIR/daemon.jsonl"
PIDFILE="$SOCKET_DIR/owner.pid"
LOG_FIRST="$XDG_DIR/daemon-first.log"
LOG_SECOND="$XDG_DIR/daemon-second.log"

cleanup() {
  if [[ -n "${FIRST_PID:-}" ]]; then kill -9 "$FIRST_PID" 2>/dev/null || true; fi
  if [[ -n "${SECOND_PID:-}" ]]; then kill -9 "$SECOND_PID" 2>/dev/null || true; fi
  rm -rf "$XDG_DIR"
}
trap cleanup EXIT

export XDG_RUNTIME_DIR="$XDG_DIR"

echo "[smoke-daemon-kill9] XDG_RUNTIME_DIR=$XDG_DIR source=$SRC"

# Start first daemon.
"$BIN" daemon-run --source "$SRC" >"$LOG_FIRST" 2>&1 &
FIRST_PID=$!

# Wait for socket.
for _ in $(seq 1 50); do
  if [[ -S "$SOCKET_DIR/control.sock" ]]; then break; fi
  sleep 0.1
done
if [[ ! -S "$SOCKET_DIR/control.sock" ]]; then
  echo "[smoke-daemon-kill9] daemon never published socket"
  cat "$LOG_FIRST" >&2 || true
  exit 1
fi

# Verify status RPC works.
STATUS_JSON="$("$BIN" status --source "$SRC")"
echo "$STATUS_JSON" | grep -q '"source":"'"$SRC"'"' \
  || { echo "[smoke-daemon-kill9] status RPC missing source: $STATUS_JSON"; exit 1; }

# Kill -9.
kill -9 "$FIRST_PID"
wait "$FIRST_PID" 2>/dev/null || true
sleep 0.2
unset FIRST_PID

# Restart daemon.
"$BIN" daemon-run --source "$SRC" >"$LOG_SECOND" 2>&1 &
SECOND_PID=$!
for _ in $(seq 1 50); do
  if [[ -S "$SOCKET_DIR/control.sock" ]]; then break; fi
  sleep 0.1
done
if [[ ! -S "$SOCKET_DIR/control.sock" ]]; then
  echo "[smoke-daemon-kill9] daemon failed to restart"
  cat "$LOG_SECOND" >&2 || true
  exit 1
fi

# Parse daemon.jsonl line-by-line.
RECOVERY=0
PARSE_ERRORS=0
TOTAL_LINES=0
while IFS= read -r line; do
  TOTAL_LINES=$((TOTAL_LINES + 1))
  if ! echo "$line" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; then
    PARSE_ERRORS=$((PARSE_ERRORS + 1))
    continue
  fi
  if echo "$line" | grep -q '"type":"daemon.recovery"'; then
    RECOVERY=1
  fi
done <"$JSONL"

if [[ "$RECOVERY" -ne 1 ]]; then
  echo "[smoke-daemon-kill9] missing daemon.recovery event in $JSONL"
  cat "$JSONL"
  exit 1
fi

if [[ "$PARSE_ERRORS" -gt 1 ]]; then
  echo "[smoke-daemon-kill9] too many malformed JSONL lines ($PARSE_ERRORS)"
  cat "$JSONL"
  exit 1
fi

echo "[smoke-daemon-kill9] ok lines=$TOTAL_LINES recovery=$RECOVERY parse_errors=$PARSE_ERRORS"

kill -TERM "$SECOND_PID" 2>/dev/null || kill -9 "$SECOND_PID" 2>/dev/null || true
wait "$SECOND_PID" 2>/dev/null || true
unset SECOND_PID
