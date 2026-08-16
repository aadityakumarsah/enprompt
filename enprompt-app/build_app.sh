#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

CERT_NAME="Treki Dev"

# Prefer an existing Apple Development identity (stable requirement, grants
# survive rebuilds). Fall back to a one-time self-signed identity.
pick_identity() {
    local apple_hash
    apple_hash=$(security find-identity -v -p codesigning 2>/dev/null | awk '/Apple Development/ {print $2; exit}')
    if [ -n "$apple_hash" ]; then
        echo "$apple_hash"
        return 0
    fi
    ensure_cert
    local self_hash
    self_hash=$(security find-identity -v -p codesigning 2>/dev/null | awk -v n="$CERT_NAME" '$0 ~ n {print $2; exit}')
    echo "$self_hash"
}

ensure_cert() {
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
        return 0
    fi
    echo "==> Creating self-signed code-signing identity '$CERT_NAME' (one-time)..."
    TMP=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
        -days 3650 -nodes -subj "/CN=$CERT_NAME" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" 2>/dev/null
    openssl pkcs12 -export -legacy -out "$TMP/treki-dev.p12" \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:treki 2>/dev/null
    security import "$TMP/treki-dev.p12" \
        -k "$HOME/Library/Keychains/login.keychain-db" \
        -P treki -A -T /usr/bin/codesign
    rm -rf "$TMP"
    echo "==> Done."
}

echo "==> Building enprompt (release)..."
swift build -c release

APP="build/enprompt.app"
STAGE=$(mktemp -d)
STAGE_APP="$STAGE/enprompt.app"

echo "==> Assembling $APP..."
rm -rf "$APP" "$STAGE_APP"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp .build/release/enprompt "$STAGE_APP/Contents/MacOS/enprompt"
cp Resources/Info.plist "$STAGE_APP/Contents/Info.plist"
cp Resources/icon.icns "$STAGE_APP/Contents/Resources/icon.icns"

# The Desktop is iCloud-synced, which stamps FinderInfo/provenance xattrs on
# files; codesign rejects those. Stage + sign outside the sync location.
IDENTITY=$(pick_identity)
echo "==> Signing with identity $IDENTITY (stable - Accessibility grant survives rebuilds)..."
xattr -cr "$STAGE_APP" 2>/dev/null || true
codesign --force --sign "$IDENTITY" "$STAGE_APP"
cp -R "$STAGE_APP" "$APP"
rm -rf "$STAGE"

echo "==> Done. Launch with: open $APP"