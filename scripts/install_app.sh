#!/usr/bin/env bash
# Build, copy to /Applications, relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build_app.sh
INSTALLED="/Applications/LiquidType.app"
pkill -x LiquidType 2>/dev/null || true
sleep 0.3
rm -rf "$INSTALLED"
cp -R dist/LiquidType.app "$INSTALLED"
open "$INSTALLED"
echo "Installed $INSTALLED"
