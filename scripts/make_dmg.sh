#!/usr/bin/env bash
# Build dist/LiquidType.dmg for a GitHub Release: the app, an Applications shortcut to drag it onto,
# and a background explaining the "Open Anyway" step (the app isn't notarized).
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build_app.sh

APP="dist/LiquidType.app"
# Users' Microphone / Accessibility grants follow the signing identity. An ad-hoc release would
# make everyone grant both again on every update, so refuse to ship one.
if [[ "$(codesign -dv "$APP" 2>&1)" == *"Signature=adhoc"* ]]; then
    echo "Refusing to package an ad-hoc signed app: set CODESIGN_IDENTITY first." >&2
    exit 1
fi

DMG="dist/LiquidType.dmg"
RW="dist/LiquidType-rw.dmg"
STAGE="dist/dmg"
VOL="LiquidType"
rm -rf "$STAGE" "$DMG" "$RW"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp Resources/dmg-background.tiff "$STAGE/.background/background.tiff"

# Finder only saves icon positions and the background into a writable image, so lay it out
# mounted read-write, then compress.
[[ -d "/Volumes/$VOL" ]] && hdiutil detach "/Volumes/$VOL" -quiet
hdiutil create -volname "$VOL" -srcfolder "$STAGE" -format UDRW -ov "$RW" >/dev/null
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet
# Coordinates match the arrow and help text drawn in Resources/dmg-background.tiff (600x380).
osascript <<EOF
tell application "Finder"
    tell disk "$VOL"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 800, 528}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 88
        set text size of opts to 12
        set background picture of opts to file ".background:background.tiff"
        set position of item "LiquidType.app" to {150, 115}
        set position of item "Applications" to {450, 115}
        update without registering applications
        delay 1
        close
    end tell
end tell
EOF
sync
hdiutil detach "/Volumes/$VOL" -quiet
hdiutil convert "$RW" -format UDZO -o "$DMG" >/dev/null
rm -rf "$STAGE" "$RW"

echo "Built $DMG"
shasum -a 256 "$DMG"
