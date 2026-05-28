#!/usr/bin/env bash
# Build chronicle as a proper .app bundle with codesign-bound Info.plist.
#
# Why: macOS Sequoia/Tahoe attributes audio capture TCC to a stable bundle
# identity derived from the Info.plist binding. The bare `swift build` artifact
# has the plist embedded in __TEXT __info_plist, but app-level TCC behaves more
# reliably with a real bundle that is signed with a stable identity.
#
# Default local-dev behavior:
#   - prefer an Apple Development signing identity
#   - filter by CHRONICLE_TEAM_ID / --team-id when set
#   - fail rather than silently falling back to ad-hoc signing
#   - use --ad-hoc only for CI or throwaway tests
#
# Usage:
#   scripts/make-app.sh [--team-id TEAMID] [--sign IDENTITY] [--install]
#   CHRONICLE_TEAM_ID=CXLYTY8DMR scripts/make-app.sh --install
#   scripts/make-app.sh --ad-hoc
#
# Output:
#   .build/<configuration>/chronicle.app/
#   optionally /Applications/chronicle.app with Launch Services registration

set -euo pipefail

CONFIGURATION="release"
SIGN_IDENTITY="${CHRONICLE_SIGN_IDENTITY:-}"
TEAM_ID="${CHRONICLE_TEAM_ID:-}"
ADHOC=0
INSTALL=0
INSTALL_PATH="/Applications/chronicle.app"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      CONFIGURATION="$2"; shift 2 ;;
    -s|--sign)
      SIGN_IDENTITY="$2"; shift 2 ;;
    --team-id)
      TEAM_ID="$2"; shift 2 ;;
    --ad-hoc)
      ADHOC=1; SIGN_IDENTITY="-"; shift ;;
    --install)
      INSTALL=1; shift ;;
    --install-path)
      INSTALL_PATH="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,34p' "$0"; exit 0 ;;
    *)
      echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

select_signing_identity() {
  if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "$SIGN_IDENTITY"
    return 0
  fi

  local identities
  identities="$({ security find-identity -v -p codesigning 2>/dev/null || true; } | sed -n 's/^ *[0-9]*) [A-F0-9]* "\(Apple Development:[^"]*\)".*/\1/p')"

  if [[ -n "$TEAM_ID" ]]; then
    local filtered=""
    while IFS= read -r identity; do
      [[ -z "$identity" ]] && continue
      if security find-certificate -c "$identity" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | grep -q "OU *= *${TEAM_ID}"; then
        filtered+="${identity}"$'\n'
      fi
    done <<<"$identities"
    identities="${filtered%$'\n'}"
  fi

  local count
  count=$(grep -c . <<<"$identities" || true)
  if [[ "$count" -eq 1 ]]; then
    grep -m1 . <<<"$identities"
    return 0
  fi

  if [[ "$count" -gt 1 ]]; then
    echo "[make-app] multiple Apple Development identities found. Set --team-id TEAMID or --sign IDENTITY." >&2
    echo "$identities" | sed 's/^/[make-app]   /' >&2
  else
    echo "[make-app] no Apple Development signing identity found." >&2
  fi
  echo "[make-app] Use --ad-hoc only for CI/throwaway builds; ad-hoc TCC grants do not survive rebuilds." >&2
  return 1
}

signing_team_id() {
  local identity="$1"
  [[ "$identity" == "-" ]] && return 0
  security find-certificate -c "$identity" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU *= *\([^,]*\).*/\1/p' \
    | head -1
}

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

if [[ "$ADHOC" -eq 0 ]]; then
  SIGN_IDENTITY="$(select_signing_identity)"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "[make-app] ad-hoc signing the bundle (explicit --ad-hoc)..."
  echo "[make-app] WARNING: ad-hoc CDHash changes per build → TCC grants invalidate."
else
  SELECTED_TEAM_ID="$(signing_team_id "$SIGN_IDENTITY")"
  echo "[make-app] signing with '${SIGN_IDENTITY}' (TeamIdentifier=${SELECTED_TEAM_ID:-unknown})..."
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)"
ENTITLEMENTS_ARGS=()
if [[ -f "chronicle.entitlements" ]]; then
  ENTITLEMENTS_ARGS+=(--entitlements chronicle.entitlements)
  echo "[make-app] embedding entitlements from chronicle.entitlements"
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" \
  "${ENTITLEMENTS_ARGS[@]}" "$APP_DIR" >/dev/null

if [[ "$INSTALL" -eq 1 ]]; then
  echo "[make-app] installing stable TCC target at ${INSTALL_PATH}..."
  rm -rf "$INSTALL_PATH"
  mkdir -p "$(dirname "$INSTALL_PATH")"
  cp -R "$APP_DIR" "$INSTALL_PATH"
  LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  "$LSREG" -R -f "$INSTALL_PATH" 2>/dev/null || true
fi

echo
echo "[make-app] verifying bundle signature..."
codesign -dvv "$APP_DIR" 2>&1 | grep -E '^Identifier|^Format|^Info\.plist|^TeamIdentifier|^Authority'
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

if [[ "$INSTALL" -eq 1 ]]; then
  echo
  echo "[make-app] verifying installed bundle signature..."
  codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
fi

echo
echo "[make-app] done. Bundle: ${APP_DIR}"
if [[ "$INSTALL" -eq 1 ]]; then
  echo "[make-app] Installed bundle: ${INSTALL_PATH}"
fi
echo "[make-app] First run requires TCC grants (one-time per signing identity):"
echo "  System Settings → Privacy & Security → Screen & System Audio Recording → add ${INSTALL_PATH}"
echo "  System Settings → Privacy & Security → Microphone → add ${INSTALL_PATH} (for chronicle mic)"
echo
echo "[make-app] Verify with:"
if [[ "$INSTALL" -eq 1 ]]; then
  echo "  ${INSTALL_PATH}/Contents/MacOS/chronicle sysaudio --help"
else
  echo "  ${APP_DIR}/Contents/MacOS/chronicle sysaudio --help"
fi
