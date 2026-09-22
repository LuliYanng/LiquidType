#!/usr/bin/env bash
# `swift build` only produces a bare binary; microphone / accessibility (TCC) permissions
# need a real .app bundle. This assembles dist/LiquidType.app and signs it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP="dist/LiquidType.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/LiquidType "$APP/Contents/MacOS/LiquidType"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundle (site icons): Bundle.module looks for it under the app's Resources/
cp -R .build/release/LiquidType_LiquidType.bundle "$APP/Contents/Resources/"

# macOS ties Microphone / Accessibility grants to the app's signing identity, not its path.
# Ad-hoc signatures differ on every build, so each install looks like a brand new app and
# you have to grant both again. Signing with a stable identity keeps them.
#
# Identity comes from $CODESIGN_IDENTITY, else CODESIGN_IDENTITY in ~/.liquidtype.env
# (same file the app reads its keys from — machine-local config, deliberately not in the repo).
ENV_FILE="$HOME/.liquidtype.env"
if [[ -z "${CODESIGN_IDENTITY:-}" && -f "$ENV_FILE" ]]; then
    # Pull just this one key out; the file holds API keys, so never source it.
    CODESIGN_IDENTITY=$(sed -n 's/^[[:space:]]*CODESIGN_IDENTITY[[:space:]]*=[[:space:]]*//p' "$ENV_FILE" \
        | tail -1 | sed 's/^"//; s/"$//')
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    # Named but missing is a mistake worth stopping for: falling back to ad-hoc here would
    # silently wipe the very permissions the identity exists to preserve.
    if ! security find-identity -p codesigning -v | grep -qF "$CODESIGN_IDENTITY"; then
        echo "Signing identity \"$CODESIGN_IDENTITY\" not found in the keychain." >&2
        echo "Fix the name, or unset CODESIGN_IDENTITY to sign ad-hoc." >&2
        exit 1
    fi
    codesign --force --sign "$CODESIGN_IDENTITY" "$APP"
    echo "Signed as $CODESIGN_IDENTITY"
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc: macOS will treat every rebuild as a new app, so Microphone and"
    echo "Accessibility must be granted again after each install. To keep them, make a"
    echo "self-signed code-signing certificate in Keychain Access once, then put"
    echo "CODESIGN_IDENTITY=<its name> in ~/.liquidtype.env."
fi
echo "Built $APP"
