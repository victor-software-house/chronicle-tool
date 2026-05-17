#!/usr/bin/env bash
# Build chronicle as a proper .app bundle with codesign-bound Info.plist.
#
# Why: macOS Sequoia/Tahoe attributes audio capture TCC to a
# stable bundle identity derived from the Info.plist binding. The bare
# `swift build` artefact has the plist embedded in __TEXT __info_plist
# but `codesign -dvv` reports `Info.plist=not bound`. A real .app bundle
# with `codesign --force --sign -` rebinds the plist into the signature so
# TCC can resolve a stable identity for Microphone and System Audio Recording.
#
# Usage:
#   scripts/make-app.sh [-c|--configuration debug|release]
#
# Output:
#   .build/<configuration>/chronicle.app/
#     Contents/MacOS/chronicle
#     Contents/Info.plist
#
# First-run TCC setup:
#   1. Build the app:   `scripts/make-app.sh`
#   2. Open System Settings → Privacy & Security → Screen & System
#      Audio Recording. Click "+" and add `.build/release/chronicle.app`.
#   3. (Mic capture only) Same flow under Privacy & Security → Microphone.
#   4. macOS will prompt to relaunch the parent app. Approve.
#   5. Run via the bundle path:
#        `.build/release/chronicle.app/Contents/MacOS/chronicle sysaudio ...`

set -euo pipefail

CONFIGURATION="release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      CONFIGURATION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

echo "[make-app] building chronicle (configuration=$CONFIGURATION)..."
swift build -c "$CONFIGURATION"

BUILD_DIR=".build/${CONFIGURATION}"
BINARY="${BUILD_DIR}/chronicle"
APP_DIR="${BUILD_DIR}/chronicle.app"

if [[ ! -x "$BINARY" ]]; then
  echo "[make-app] expected ${BINARY} after swift build but it was not produced" >&2
  exit 1
fi
if [[ ! -f "Info.plist" ]]; then
  echo "[make-app] Info.plist not found at repo root" >&2
  exit 1
fi

echo "[make-app] assembling bundle at ${APP_DIR}..."
rm -rf "$APP_DIR"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp "$BINARY" "${APP_DIR}/Contents/MacOS/chronicle"
cp Info.plist "${APP_DIR}/Contents/Info.plist"
touch "$APP_DIR"

echo "[make-app] adhoc-signing the bundle (binds Info.plist to identity)..."
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP_DIR" >/dev/null

echo
echo "[make-app] verifying bundle signature..."
codesign -dvv "$APP_DIR" 2>&1 | grep -E '^Identifier|^Format|^Info\.plist'

echo
echo "[make-app] done. Bundle: ${APP_DIR}"
echo "[make-app] First run requires TCC grants (one-time):"
echo "  System Settings → Privacy & Security → Screen & System Audio Recording → add ${APP_DIR}"
echo "  System Settings → Privacy & Security → Microphone → add ${APP_DIR} (for chronicle mic)"
echo
echo "[make-app] Verify with:"
echo "  ${APP_DIR}/Contents/MacOS/chronicle sysaudio --help"
