#!/usr/bin/env bash
#
# PRD-001 P11 verification (#50) — Opus-in-CAF round-trip WER parity.
#
# Round-trips a reference WAV through `chronicle encode-opus` (which uses the
# production `OpusCAFSink` path) and `chronicle transcribe`, then compares the
# resulting transcript against a baseline transcript using `scripts/wer.py`.
#
# Acceptance gate: WER delta ≤ 1.00 % (0.0100). Exits non-zero if breached.
#
# Default reference is the 2026-05-13 Zoom session (6870 s, 16 kHz mono Int16).
# Override with REF_WAV / REF_TXT / BITRATE / OUT_DIR / LOCALE env vars.
#
# Example:
#
#   scripts/verify-opus-parity.sh
#   BITRATE=32000 scripts/verify-opus-parity.sh
#   REF_WAV=/path/to/other.wav REF_TXT=/path/to/other.txt scripts/verify-opus-parity.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

: "${REF_WAV:=$HOME/Movies/pi-captures/sessions/2026-05-13-zoom-3h/audio/mic-master.wav}"
: "${REF_TXT:=$REPO_ROOT/out/full-session/transcribe.txt}"
: "${BITRATE:=24000}"
: "${OUT_DIR:=$REPO_ROOT/out/parity}"
: "${LOCALE:=en-US}"
: "${ACCEPT_THRESHOLD:=0.01}"  # 1 % WER delta gate
: "${CHRONICLE_BIN:=$REPO_ROOT/.build/release/chronicle}"

err() { printf '[verify-opus-parity] ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '[verify-opus-parity] %s\n' "$*" >&2; }

[ -f "$REF_WAV" ] || err "REF_WAV not found: $REF_WAV"
[ -f "$REF_TXT" ] || err "REF_TXT not found: $REF_TXT"
[ -x "$CHRONICLE_BIN" ] || err "CHRONICLE_BIN not built. Run: swift build -c release"
command -v uv >/dev/null 2>&1 || err "uv not installed. Install via: brew install uv"

mkdir -p "$OUT_DIR"

OPUS_CAF="$OUT_DIR/mic-master.opus.caf"
HYP_BASE="$OUT_DIR/transcribe-opus"
HYP_TXT="$HYP_BASE.txt"

info "ref-wav=$REF_WAV"
info "ref-txt=$REF_TXT"
info "bitrate=$BITRATE locale=$LOCALE threshold=$ACCEPT_THRESHOLD"

info "step 1/3 — encode WAV → Opus-in-CAF"
"$CHRONICLE_BIN" encode-opus -i "$REF_WAV" -o "$OPUS_CAF" --bitrate "$BITRATE"

info "step 2/3 — transcribe Opus-in-CAF"
"$CHRONICLE_BIN" transcribe -i "$OPUS_CAF" -o "$HYP_BASE" --locale "$LOCALE"

info "step 3/3 — compute WER"
WER_LINE=$("$REPO_ROOT/scripts/wer.py" --ref "$REF_TXT" --hyp "$HYP_TXT")
info "$WER_LINE"
"$REPO_ROOT/scripts/wer.py" --ref "$REF_TXT" --hyp "$HYP_TXT" --json \
  > "$OUT_DIR/wer.json"
info "wrote $OUT_DIR/wer.json"

WER_VALUE=$(printf '%s\n' "$WER_LINE" | sed -nE 's/^WER=([0-9.]+).*/\1/p')
[ -n "$WER_VALUE" ] || err "could not parse WER from: $WER_LINE"

# Threshold check via awk (portable, no python re-invocation).
if awk -v w="$WER_VALUE" -v t="$ACCEPT_THRESHOLD" 'BEGIN { exit !(w <= t) }'; then
  info "PASS — WER $WER_VALUE ≤ $ACCEPT_THRESHOLD"
  exit 0
else
  err "FAIL — WER $WER_VALUE > $ACCEPT_THRESHOLD"
fi
