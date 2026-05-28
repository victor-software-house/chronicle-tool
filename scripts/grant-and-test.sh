#!/usr/bin/env bash
# One-shot: build/install chronicle.app, open the right TCC pane + Finder,
# wait for user to toggle, then test system-audio transcription end-to-end.
#
# Signing:
#   - scripts/make-app.sh auto-selects a stable Apple Development identity.
#   - If multiple Apple teams are available, set CHRONICLE_TEAM_ID or pass it
#     through the environment before running this script.
#
# Usage:
#   CHRONICLE_TEAM_ID=CXLYTY8DMR scripts/grant-and-test.sh
#   scripts/grant-and-test.sh --skip-build

set -euo pipefail
cd "$(dirname "$0")/.."

SKIP_BUILD=0
case "${1:-}" in
  --skip-build) SKIP_BUILD=1 ;;
esac

APP_SRC=".build/release/chronicle.app"
APP_DST="/Applications/chronicle.app"
BUNDLE_ID="com.victor-software-house.chronicle"
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
SIGNING_TEAM_LABEL="${CHRONICLE_TEAM_ID:-auto}"

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
step "Verifying local Apple Development signing identity (team=${SIGNING_TEAM_LABEL})"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q 'Apple Development:'; then
  echo "✘ No Apple Development signing identity found."
  echo "  Install one with Xcode account signing, or run scripts/make-app.sh --ad-hoc only for throwaway tests."
  exit 1
fi
echo "✔ Apple Development identity present"

# ---------------------------------------------------------------------------
if [[ $SKIP_BUILD -eq 0 ]]; then
  step "Building, signing, installing chronicle.app"
  ./scripts/make-app.sh --install >/dev/null
  echo "✔ built + installed"
fi

# ---------------------------------------------------------------------------
step "Ensuring Launch Services sees /Applications/chronicle.app"
if [[ ! -d "$APP_DST" ]]; then
  echo "✘ $APP_DST not found. Run scripts/make-app.sh --install first."
  exit 1
fi

LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Unregister any chronicle.app entries Launch Services may still know about
# in stale build paths — otherwise Settings may bind the toggle to one of
# them instead of /Applications/chronicle.app.
"$LSREG" -dump 2>/dev/null | awk '/^path:.*chronicle\.app/ {sub(/^path: *[ \t]*/,""); sub(/ *\([^)]*\)$/,""); print}' \
  | grep -v '^/Applications/chronicle\.app$' \
  | while IFS= read -r stale; do
      echo "  unregistering stale LS entry: $stale"
      "$LSREG" -u "$stale" 2>/dev/null || true
    done

"$LSREG" -R -f "$APP_DST" 2>/dev/null
echo "✔ installed at $APP_DST and LS is clean"

# ---------------------------------------------------------------------------
step "Showing current TCC.db state for $BUNDLE_ID"
sqlite3 -header -column "$TCC_DB" \
  "SELECT service,auth_value,length(csreq) AS cs_len FROM access WHERE client='$BUNDLE_ID';" \
  | sed 's/^/  /' || true

# ---------------------------------------------------------------------------
step "Opening Privacy & Security pane + revealing chronicle.app in Finder"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture" || true
sleep 1
open -R "$APP_DST"

cat <<'EOF'

  In the System Settings window:
    1. If chronicle is in the list and toggled ON → toggle it OFF, then ON
       again. Forces Settings to rewrite the row with the current Apple
       Development cert's csreq (previous toggle may have bound to another
       signing identity or ad-hoc cdhash).
    2. If chronicle is in the list and OFF → just toggle it ON.
    3. If chronicle is NOT in the list → click "+", pick
       /Applications/chronicle.app, toggle ON.
    4. Same flow for Microphone if testing `chronicle mic`.
  Then come back here and press ENTER.

EOF
read -r _

# ---------------------------------------------------------------------------
step "TCC.db state after your toggle"
sqlite3 -header -column "$TCC_DB" \
  "SELECT service,auth_value,length(csreq) AS cs_len FROM access WHERE client='$BUNDLE_ID';" \
  | sed 's/^/  /' || true

# ---------------------------------------------------------------------------
step "Running preflight + smoke capture (no tccd restart)"
TMPDIR_OUT=$(mktemp -d -t chronicle-grant-test)
trap 'rm -rf "$TMPDIR_OUT"' EXIT

CHRONICLE_TCC_DEBUG=1 "$APP_DST/Contents/MacOS/chronicle" sysaudio \
  --locale en-US \
  --live "$TMPDIR_OUT/live.md" \
  --append "$TMPDIR_OUT/finals.md" \
  -o "$TMPDIR_OUT/trace.jsonl" \
  --verbose 2>"$TMPDIR_OUT/stderr.log" &
P=$!

sleep 3
say -v Samantha "Chronicle system audio test. This spoken sentence should appear in the transcript if system audio capture is working. The quick brown fox jumps over the lazy dog."
sleep 4
kill "$P" 2>/dev/null || true
wait "$P" 2>/dev/null || true

# ---------------------------------------------------------------------------
step "Results"

printf '\n  TCC probes:\n'
grep '\[tcc\]' "$TMPDIR_OUT/stderr.log" | sed 's/^/    /' || true

printf '\n  Preflight outcome:\n'
grep -E 'preflight|permission|first ioproc|first converted|Error' "$TMPDIR_OUT/stderr.log" \
  | head -5 | sed 's/^/    /' || true

printf '\n  Last 3 peak measurements:\n'
grep sessionPeak "$TMPDIR_OUT/stderr.log" | tail -3 | sed 's/^/    /' || true

PEAK_MAX=$(grep -oE 'sessionPeak=[0-9]+' "$TMPDIR_OUT/stderr.log" | awk -F= '{print $2}' | sort -n | tail -1)
TRACE_LINES=$(wc -l <"$TMPDIR_OUT/trace.jsonl" 2>/dev/null || echo 0)
FINALS_BYTES=$(wc -c <"$TMPDIR_OUT/finals.md" 2>/dev/null || echo 0)
TRANSCRIPT_HIT=0
if grep -Eiq 'chronicle|system audio|quick brown fox|lazy dog' "$TMPDIR_OUT/finals.md" "$TMPDIR_OUT/live.md" "$TMPDIR_OUT/trace.jsonl" 2>/dev/null; then
  TRANSCRIPT_HIT=1
fi

printf '\n  Trace events: %s\n' "$TRACE_LINES"
printf '  Finals bytes: %s\n' "$FINALS_BYTES"
printf '  Max session peak: %s\n' "${PEAK_MAX:-0}"
printf '  Transcript hit: %s\n' "$TRANSCRIPT_HIT"

echo
if [[ "${PEAK_MAX:-0}" =~ ^[0-9]+$ ]] && (( PEAK_MAX > 0 )) && (( TRANSCRIPT_HIT == 1 )); then
  echo "✔ CAPTURE + TRANSCRIPTION WORKING — tap delivered voice audio and SpeechAnalyzer produced expected text."
  echo "  Output dir: $TMPDIR_OUT (preserved; trap cleared)"
  trap - EXIT
  exit 0
else
  echo "✘ Capture/transcription smoke failed. Inspect stderr/output:"
  echo "  $TMPDIR_OUT"
  trap - EXIT
  exit 1
fi
