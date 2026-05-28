#!/usr/bin/env bash
# Non-interactive regression smoke for installed signed Chronicle sysaudio + live diarization.
# Guards the current contract: rough transcript starts immediately, diarization is a later
# quality layer, sidecars stay durable, and generated multi-speaker labels appear once
# Sortformer is ready. Uses ElevenLabs voices through fnox by default so ambient audio
# cannot satisfy marker assertions accidentally.

set -euo pipefail
cd "$(dirname "$0")/.."

APP="${CHRONICLE_APP:-/Applications/chronicle.app/Contents/MacOS/chronicle}"
OUT="${CHRONICLE_DIARIZE_SMOKE_OUT:-$(mktemp -d -t chronicle-sysaudio-diarize-smoke)}"
STARTUP_WAIT="${CHRONICLE_DIARIZE_SMOKE_STARTUP_WAIT:-3}"
PREWARM_TIMEOUT="${CHRONICLE_DIARIZE_SMOKE_PREWARM_TIMEOUT:-45}"
FINAL_WAIT="${CHRONICLE_DIARIZE_SMOKE_FINAL_WAIT:-30}"
SPEAKER_COUNT="${CHRONICLE_DIARIZE_SMOKE_SPEAKER_COUNT:-4}"
MIN_MARKER_SPEAKERS="${CHRONICLE_DIARIZE_SMOKE_MIN_MARKER_SPEAKERS:-3}"
ELEVEN_MODEL="${CHRONICLE_ELEVENLABS_MODEL:-eleven_v3}"
AUDIO_FORMAT="${CHRONICLE_ELEVENLABS_OUTPUT_FORMAT:-mp3_44100_128}"

if [[ ! -x "$APP" ]]; then
  echo "✘ installed chronicle app not found: $APP" >&2
  echo "  run: CHRONICLE_TEAM_ID=CXLYTY8DMR scripts/make-app.sh --install" >&2
  exit 2
fi

if ! command -v fnox >/dev/null; then
  echo "✘ fnox is required to retrieve ELEVENLABS_API_KEY" >&2
  exit 2
fi

if ! command -v afplay >/dev/null; then
  echo "✘ afplay is required to play generated ElevenLabs fixtures" >&2
  exit 2
fi

mkdir -p "$OUT"
STDERR_LOG="$OUT/stderr.log"
STDOUT_LOG="$OUT/stdout.log"
LIVE="$OUT/live.md"
FINALS="$OUT/finals.md"
TRACE="$OUT/trace.jsonl"
AUDIO="$OUT/system.caf"
FIXTURE_DIR="$OUT/elevenlabs-fixtures"
mkdir -p "$FIXTURE_DIR"

VOICE_IDS=(
  "EXAVITQu4vr4xnSDxMaL" # Sarah
  "JBFqnCBsd6RMkjVDRZzb" # George
  "IKne3meq5aSn9XLyUdCD" # Charlie
  "Xb7hH8MSUJpSbSDYk0k2" # Alice
)
VOICE_NAMES=("Sarah" "George" "Charlie" "Alice")
MARKERS=("orion-indigo" "maple-quartz" "river-cobalt" "velvet-nimbus")
PHRASES=(
  "Chronicle diarization fixture one. Marker orion indigo. Sarah speaks first for the rollback baseline."
  "Chronicle diarization fixture two. Marker maple quartz. George speaks second for the rollback baseline."
  "Chronicle diarization fixture three. Marker river cobalt. Charlie speaks third for the rollback baseline."
  "Chronicle diarization fixture four. Marker velvet nimbus. Alice speaks fourth for the rollback baseline."
)

if (( SPEAKER_COUNT < 2 || SPEAKER_COUNT > ${#VOICE_IDS[@]} )); then
  echo "✘ CHRONICLE_DIARIZE_SMOKE_SPEAKER_COUNT must be between 2 and ${#VOICE_IDS[@]}" >&2
  exit 2
fi

json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

generate_fixture() {
  local index="$1"
  local voice_id="${VOICE_IDS[$index]}"
  local text="${PHRASES[$index]}"
  local out_file="$FIXTURE_DIR/$((index + 1))-${VOICE_NAMES[$index]}.mp3"
  local body
  body=$(printf '%s' "$text" | json_escape)
  curl -sS --fail \
    -X POST "https://api.elevenlabs.io/v1/text-to-speech/${voice_id}?output_format=${AUDIO_FORMAT}" \
    -H "xi-api-key: $(fnox get ELEVENLABS_API_KEY)" \
    -H "Content-Type: application/json" \
    -d "{\"text\":${body},\"model_id\":\"${ELEVEN_MODEL}\"}" \
    -o "$out_file"
  printf '%s\n' "$out_file"
}

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

fixture_files=()
for ((i = 0; i < SPEAKER_COUNT; i++)); do
  fixture_files+=("$(generate_fixture "$i")")
done

"$APP" sysaudio \
  --locale en-US \
  --quiet \
  --verbose \
  --diarize \
  --live "$LIVE" \
  --append "$FINALS" \
  --save-audio "$AUDIO" \
  --audio-format alac \
  --rotate-audio 60 \
  -o "$TRACE" \
  >"$STDOUT_LOG" 2>"$STDERR_LOG" &
cleanup_pid=$!

sleep "$STARTUP_WAIT"

for _ in $(seq 1 "$PREWARM_TIMEOUT"); do
  if grep -q 'prewarm complete' "$STDERR_LOG" 2>/dev/null; then
    break
  fi
  sleep 1
done

for fixture in "${fixture_files[@]}"; do
  afplay "$fixture"
  sleep 1
done
sleep "$FINAL_WAIT"
cleanup
trap - EXIT
wait "$cleanup_pid" 2>/dev/null || true
cleanup_pid=""

peak_max=$(grep -oE 'sessionPeak=[0-9]+' "$STDERR_LOG" 2>/dev/null | awk -F= '{if ($2 > m) m = $2} END {print m + 0}')
trace_lines=$(wc -l <"$TRACE" 2>/dev/null || echo 0)
finals_bytes=$(wc -c <"$FINALS" 2>/dev/null || echo 0)
stdout_bytes=$(wc -c <"$STDOUT_LOG" 2>/dev/null || echo 0)
debug_lines=$(grep -c '\[sysaudio\.tap\.debug\]' "$STDERR_LOG" 2>/dev/null || true)
capture_line=$(grep -n 'capture started' "$STDERR_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)
prewarm_line=$(grep -n 'prewarm complete' "$STDERR_LOG" 2>/dev/null | head -1 | cut -d: -f1 || true)

metrics=$(python3 - "$TRACE" "$FINALS" "$LIVE" "$SPEAKER_COUNT" "$MIN_MARKER_SPEAKERS" <<'PY'
import json, re, sys
trace, finals, live, speaker_count, min_marker_speakers = sys.argv[1:]
speaker_count = int(speaker_count)
markers = ["orion indigo", "maple quartz", "river cobalt", "velvet nimbus"][:speaker_count]
marker_hits = {m: 0 for m in markers}
marker_speakers = {}
known = 0
speakers = set()
final_speaker_events = 0
texts = []
for path in (finals, live):
    try:
        texts.append(open(path, errors='ignore').read())
    except FileNotFoundError:
        pass
try:
    trace_lines = list(open(trace, errors='ignore'))
except FileNotFoundError:
    trace_lines = []
for line in trace_lines:
    texts.append(line)
    try:
        event = json.loads(line)
    except Exception:
        continue
    text = event.get('text') or ''
    speaker = event.get('speakerId')
    if speaker:
        known += 1
        speakers.add(str(speaker))
        if event.get('eventKind') == 'final' or event.get('isFinal') is True:
            final_speaker_events += 1
        lowered = text.lower()
        for marker in markers:
            if all(part in lowered for part in marker.split()):
                marker_speakers.setdefault(marker, set()).add(str(speaker))
all_text = '\n'.join(texts).lower()
for marker in markers:
    if all(part in all_text for part in marker.split()):
        marker_hits[marker] = 1
print(f'speaker_known={known}')
print(f'distinct_speakers={len(speakers)}')
print(f'final_speaker_events={final_speaker_events}')
print(f'marker_hits={sum(marker_hits.values())}')
print(f'marker_speaker_hits={len(marker_speakers)}')
print(f'marker_distinct_speakers={len(set().union(*marker_speakers.values())) if marker_speakers else 0}')
print('missing_markers=' + ','.join(m for m, hit in marker_hits.items() if not hit))
PY
)
eval "$metrics"

printf 'OUT=%s\n' "$OUT"
printf 'model=%s\n' "$ELEVEN_MODEL"
printf 'speaker_count=%s\n' "$SPEAKER_COUNT"
printf 'max_peak=%s\n' "${peak_max:-0}"
printf 'trace_lines=%s\n' "$trace_lines"
printf 'finals_bytes=%s\n' "$finals_bytes"
printf 'stdout_bytes=%s\n' "$stdout_bytes"
printf 'debug_lines=%s\n' "$debug_lines"
printf 'capture_line=%s\n' "${capture_line:-0}"
printf 'prewarm_line=%s\n' "${prewarm_line:-0}"
printf 'speaker_known=%s\n' "${speaker_known:-0}"
printf 'distinct_speakers=%s\n' "${distinct_speakers:-0}"
printf 'final_speaker_events=%s\n' "${final_speaker_events:-0}"
printf 'marker_hits=%s\n' "${marker_hits:-0}"
printf 'marker_speaker_hits=%s\n' "${marker_speaker_hits:-0}"
printf 'marker_distinct_speakers=%s\n' "${marker_distinct_speakers:-0}"
printf 'missing_markers=%s\n' "${missing_markers:-}"

if [[ ! "${peak_max:-0}" =~ ^[0-9]+$ ]] || (( peak_max <= 0 )); then
  echo "✘ diarize smoke failed: no nonzero sessionPeak" >&2
  tail -100 "$STDERR_LOG" >&2 || true
  exit 1
fi

if [[ -z "${capture_line:-}" || -z "${prewarm_line:-}" ]] || (( capture_line >= prewarm_line )); then
  echo "✘ diarize smoke failed: capture did not start before diarizer prewarm completed" >&2
  tail -100 "$STDERR_LOG" >&2 || true
  exit 1
fi

if (( stdout_bytes != 0 )); then
  echo "✘ diarize smoke failed: --quiet wrote stdout transcript spam" >&2
  tail -40 "$STDOUT_LOG" >&2 || true
  exit 1
fi

if (( debug_lines != 0 )); then
  echo "✘ diarize smoke failed: --verbose emitted debug tap spam" >&2
  tail -100 "$STDERR_LOG" >&2 || true
  exit 1
fi

if (( marker_hits < SPEAKER_COUNT )); then
  echo "✘ diarize smoke failed: expected ElevenLabs marker phrases missing from transcript sidecars" >&2
  tail -80 "$FINALS" >&2 || true
  tail -120 "$STDERR_LOG" >&2 || true
  exit 1
fi

if (( speaker_known <= 0 || marker_speaker_hits < MIN_MARKER_SPEAKERS || marker_distinct_speakers < MIN_MARKER_SPEAKERS || final_speaker_events < MIN_MARKER_SPEAKERS )); then
  echo "✘ diarize smoke failed: insufficient live marker speaker labeling" >&2
  tail -80 "$FINALS" >&2 || true
  tail -140 "$STDERR_LOG" >&2 || true
  exit 1
fi

echo "✔ sysaudio diarize smoke passed"
