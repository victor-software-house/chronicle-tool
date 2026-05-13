#!/usr/bin/env bash
set -euo pipefail
INPUT="$1"
OUT="$2"
mkdir -p "$OUT"

BIN=.build/release/chronicle
T0=$(/bin/date +%s)

echo "── stage 1: classify (speech-gate) ──"
$BIN classify -i "$INPUT" -o "$OUT/01-classify.json" --threshold 0.3 --speech-only
SPEECH_PCT=$(/opt/homebrew/bin/jq -r '.speechRatio * 100 | floor' "$OUT/01-classify.json")
echo "  speech ratio: ${SPEECH_PCT}%"

echo
echo "── stage 2: transcribe ──"
$BIN transcribe -i "$INPUT" -o "$OUT/02-transcribe" --locale en-US
T_CHARS=$(/opt/homebrew/bin/jq -r '.plainText | length' "$OUT/02-transcribe.json")
echo "  transcript: ${T_CHARS} chars"

echo
echo "── stage 3: diarize ──"
$BIN diarize -i "$INPUT" -o "$OUT/03-diarize.json"
SPK=$(/opt/homebrew/bin/jq -r '.speakerCount' "$OUT/03-diarize.json")
SEG=$(/opt/homebrew/bin/jq -r '.segmentCount' "$OUT/03-diarize.json")
echo "  speakers: ${SPK}, segments: ${SEG}"

echo
echo "── stage 4: tag ──"
$BIN tag -i "$OUT/02-transcribe.txt" -o "$OUT/04-tag.json"
TOPICS=$(/opt/homebrew/bin/jq -r '.topics | join(", ")' "$OUT/04-tag.json")
echo "  topics: ${TOPICS}"

echo
echo "── stage 5: summarize ──"
$BIN summarize -i "$OUT/02-transcribe.txt" -o "$OUT/05-summary.json"
TLDR=$(/opt/homebrew/bin/jq -r '.tldr' "$OUT/05-summary.json")
echo "  tldr: ${TLDR}"

T1=$(/bin/date +%s)
echo
echo "──────────────────────────────────"
echo "pipeline total: $((T1-T0))s for $(/opt/homebrew/bin/ffprobe -v error -show_entries format=duration -of default=nw=1 "$INPUT" 2>/dev/null | /usr/bin/awk '{printf "%.0fs audio", $1}')"
