#!/usr/bin/env bash
# Non-interactive regression smoke for the installed signed Chronicle app.
# Fails unless CoreAudio sysaudio captures a spoken TTS phrase and SpeechAnalyzer
# writes transcript text to sidecars.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${CHRONICLE_APP:-/Applications/chronicle.app/Contents/MacOS/chronicle}"
OUT="${CHRONICLE_SMOKE_OUT:-$(mktemp -d -t chronicle-sysaudio-smoke)}"
VOICE="${CHRONICLE_SMOKE_VOICE:-Samantha}"
PHRASE="${CHRONICLE_SMOKE_PHRASE:-Chronicle baseline smoke. System audio capture works. The quick brown fox jumps over the lazy dog.}"
STARTUP_WAIT="${CHRONICLE_SMOKE_STARTUP_WAIT:-2}"
FINAL_WAIT="${CHRONICLE_SMOKE_FINAL_WAIT:-6}"

if [[ ! -x "$APP" ]]; then
  echo "✘ installed chronicle app not found: $APP" >&2
  echo "  run: CHRONICLE_TEAM_ID=CXLYTY8DMR scripts/make-app.sh --install" >&2
  exit 2
fi

mkdir -p "$OUT"
STDERR_LOG="$OUT/stderr.log"
STDOUT_LOG="$OUT/stdout.log"
LIVE="$OUT/live.md"
FINALS="$OUT/finals.md"
TRACE="$OUT/trace.jsonl"
AUDIO="$OUT/system.caf"

cleanup_pid=""
cleanup() {
  if [[ -n "$cleanup_pid" ]] && kill -0 "$cleanup_pid" 2>/dev/null; then
    kill -INT "$cleanup_pid" 2>/dev/null || true
    for _ in {1..20}; do
      kill -0 "$cleanup_pid" 2>/dev/null || return 0
      sleep 0.2
    done
    kill -TERM "$cleanup_pid" 2>/dev/null || true
    for _ in {1..10}; do
      kill -0 "$cleanup_pid" 2>/dev/null || return 0
      sleep 0.2
    done
    kill -KILL "$cleanup_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$APP" sysaudio \
  --locale en-US \
  --quiet \
  --verbose \
  --live "$LIVE" \
  --append "$FINALS" \
  --save-audio "$AUDIO" \
  --audio-format alac \
  --rotate-audio 60 \
  -o "$TRACE" \
  >"$STDOUT_LOG" 2>"$STDERR_LOG" &
cleanup_pid=$!

sleep "$STARTUP_WAIT"
say -v "$VOICE" "$PHRASE"
sleep "$FINAL_WAIT"
cleanup
trap - EXIT
wait "$cleanup_pid" 2>/dev/null || true
cleanup_pid=""

peak_max=$(grep -oE 'sessionPeak=[0-9]+' "$STDERR_LOG" 2>/dev/null | awk -F= '{if ($2 > m) m = $2} END {print m + 0}')
trace_lines=$(wc -l <"$TRACE" 2>/dev/null || echo 0)
finals_bytes=$(wc -c <"$FINALS" 2>/dev/null || echo 0)
debug_lines=$(grep -c '\[sysaudio\.tap\.debug\]' "$STDERR_LOG" 2>/dev/null || true)
transcript_hit=0
if grep -Eiq 'chronicle|baseline|system audio|quick brown fox|lazy dog' "$FINALS" "$LIVE" "$TRACE" 2>/dev/null; then
  transcript_hit=1
fi

printf 'OUT=%s\n' "$OUT"
printf 'max_peak=%s\n' "${peak_max:-0}"
printf 'trace_lines=%s\n' "$trace_lines"
printf 'finals_bytes=%s\n' "$finals_bytes"
printf 'debug_lines=%s\n' "$debug_lines"
printf 'transcript_hit=%s\n' "$transcript_hit"

if [[ ! "${peak_max:-0}" =~ ^[0-9]+$ ]] || (( peak_max <= 0 )); then
  echo "✘ sysaudio smoke failed: no nonzero sessionPeak" >&2
  tail -80 "$STDERR_LOG" >&2 || true
  exit 1
fi

if (( transcript_hit != 1 )); then
  echo "✘ sysaudio smoke failed: no expected transcript hit" >&2
  tail -40 "$FINALS" >&2 || true
  tail -80 "$STDERR_LOG" >&2 || true
  exit 1
fi

if (( debug_lines != 0 )); then
  echo "✘ sysaudio smoke failed: --verbose emitted debug tap spam" >&2
  tail -80 "$STDERR_LOG" >&2 || true
  exit 1
fi

echo "✔ sysaudio smoke passed"
