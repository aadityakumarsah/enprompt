#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP="build/enprompt.app"
DMG="build/enprompt.dmg"
STAGE=$(mktemp -d)

echo "==> Preparing DMG staging..."
rm -f "$DMG"
mkdir -p "$STAGE/dmg"
cp -R "$APP" "$STAGE/dmg/enprompt.app"
ln -s /Applications "$STAGE/dmg/Applications"
cp Resources/icon.icns "$STAGE/dmg/.VolumeIcon.icns"

# Mark the volume as custom-iconed so Finder uses .VolumeIcon.icns.
if [ -x /usr/bin/SetFile ]; then
    SetFile -a C "$STAGE/dmg"
fi

echo "==> Creating $DMG..."
hdiutil create -volname "enprompt" -srcfolder "$STAGE/dmg" \
    -ov -format UDZO "$DMG" >/dev/null

rm -rf "$STAGE"

echo "==> Verifying $DMG..."
hdiutil verify "$DMG" | tail -1
echo "==> Done. DMG at $DMG"
