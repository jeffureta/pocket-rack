#!/usr/bin/env bash
set -euo pipefail

# 1-command $0 Free Personal Team wireless/USB build, install, and launch helper
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJ="$ROOT_DIR/PocketRackApp/PocketRack.xcodeproj"
SCHEME="PocketRack"
DERIVED_DATA="$ROOT_DIR/PocketRackApp/build/DerivedData"

if [ ! -d "$PROJ" ]; then
  echo "❌ PocketRack.xcodeproj not found at $PROJ"
  exit 1
fi

DEVICE_ID="${1:-}"
if [ -z "$DEVICE_ID" ]; then
  echo "🔍 Looking for paired iPad..."
  DEVICE_ID="$(xcrun devicectl list devices 2>/dev/null | awk '/iPad/ {print $3; exit}')"
fi

if [ -z "$DEVICE_ID" ]; then
  echo "❌ No iPad found via devicectl. Connect your iPad via USB-C or Wi-Fi and pass its UDID:"
  echo "   ./scripts/deploy-ipad.sh <DEVICE_UDID>"
  xcrun devicectl list devices || true
  exit 1
fi

echo "🔨 Building PocketRack ($0 Free Personal Team signing)..."
xcodebuild \
  -project "$PROJ" \
  -scheme "$SCHEME" \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  -allowProvisioningUpdates \
  build

APP_PATH="$(find "$DERIVED_DATA/Build/Products" -name "PocketRack.app" -maxdepth 4 | head -n 1)"
if [ -z "$APP_PATH" ]; then
  echo "❌ Could not locate built PocketRack.app"
  exit 1
fi

echo "📲 Installing $APP_PATH onto device $DEVICE_ID..."
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "🚀 Launching PocketRack on iPad..."
xcrun devicectl device process launch --device "$DEVICE_ID" com.jeffureta.PocketRack || true

echo "✅ Done! Your 7-day free Personal Team signature is refreshed without losing any files or SQLite data."
