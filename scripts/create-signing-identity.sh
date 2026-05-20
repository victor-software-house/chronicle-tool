#!/usr/bin/env bash
# Create a self-signed code-signing identity in the user's login Keychain.
#
# Why: adhoc-signed binaries (`codesign --sign -`) bind TCC grants to the
# CDHash, which changes every time the binary is rebuilt. With a stable
# signing identity, `codesign` writes a Designated Requirement (DR) that
# references the cert's identity hash instead. TCC then matches the DR
# across rebuilds, so the System Audio Recording grant (and any other TCC
# grants) survive `swift build` cycles.
#
# Usage:
#   scripts/create-signing-identity.sh <identity-name>
# Example:
#   scripts/create-signing-identity.sh chronicle-dev
#
# After running:
#   scripts/make-app.sh --sign <identity-name>
#
# Notes:
# - One-time setup per machine. Re-running with the same name fails on
#   duplicate; pick a fresh name or delete the existing entry first with:
#     security delete-certificate -c "<identity-name>" \
#       "$HOME/Library/Keychains/login.keychain-db"
# - The cert is self-signed (free, no Apple Developer account needed).
#   macOS will warn about untrusted publisher if the app is distributed,
#   but TCC binding is purely local and unaffected.
# - For production distribution use a real Apple Developer ID cert
#   instead. The chezmoi-managed dotfiles already document that flow.

set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then
  echo "usage: $0 <identity-name>" >&2
  exit 2
fi

KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

KEY="${WORK_DIR}/key.pem"
CERT="${WORK_DIR}/cert.pem"
P12="${WORK_DIR}/identity.p12"
CONFIG="${WORK_DIR}/csr.cnf"

cat >"$CONFIG" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_req

[ dn ]
CN = ${NAME}
O  = chronicle
C  = US

[ v3_req ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning,1.2.840.113635.100.6.1.13
EOF

echo "[create-identity] generating self-signed code-signing cert..."
openssl req -new -newkey rsa:2048 -nodes -keyout "$KEY" -x509 -days 3650 \
  -config "$CONFIG" -out "$CERT" >/dev/null 2>&1

echo "[create-identity] bundling into PKCS#12 (legacy format for macOS security import)..."
# OpenSSL 3 defaults to AES-256-CBC + SHA-256 in PKCS#12, which macOS
# Keychain's `security import` cannot decrypt. `-legacy` switches to the
# RC2-40 / 3DES encoding macOS still accepts.
openssl pkcs12 -export -legacy -inkey "$KEY" -in "$CERT" -out "$P12" \
  -name "$NAME" -passout pass:chronicle >/dev/null 2>&1

echo "[create-identity] importing into login Keychain (may prompt for unlock)..."
security import "$P12" -k "$KEYCHAIN" -P chronicle -A \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

echo "[create-identity] trusting cert for code signing (user keychain)..."
security add-trusted-cert -r trustRoot -p codeSign \
  -k "$KEYCHAIN" "$CERT" 2>/dev/null || true

echo "[create-identity] trusting cert in System keychain (required for TCC)..."
echo "[create-identity] sudo prompt incoming: TCC daemon evaluates cert trust"
echo "[create-identity] in the system context, not user context. Skipping this"
echo "[create-identity] step means TCC will reject grants bound to this cert."
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
  -k /Library/Keychains/System.keychain "$CERT" || {
  echo "[create-identity] WARNING: system-keychain trust failed. TCC grants"
  echo "                  bound to this cert will not validate. Re-run with"
  echo "                  sudo, or grant TCC permissions per-build manually."
}

echo
echo "[create-identity] verifying..."
security find-identity -v -p codesigning "$KEYCHAIN" | grep -F "$NAME" || {
  echo "[create-identity] identity not found after import. Check Keychain Access." >&2
  exit 1
}

echo
echo "[create-identity] done."
echo "  Now run: scripts/make-app.sh --sign ${NAME}"
echo "  TCC grants for the resulting .app will survive rebuilds."
