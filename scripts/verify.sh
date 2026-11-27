#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "🧪 [1/2] Running PocketRackCore Swift tests..."
swift test --parallel

if [ -d "PocketRackApp/PocketRack.xcodeproj" ]; then
  echo "📱 [2/2] Building PocketRackApp for generic iOS/iPadOS..."
  xcodebuild \
    -project PocketRackApp/PocketRack.xcodeproj \
    -scheme PocketRack \
    -destination 'generic/platform=iOS' \
    CODE_SIGNING_ALLOWED=NO \
    build | tail -n 20
else
  echo "ℹ️ [2/2] PocketRackApp Xcode project not yet created; skipping iOS app build."
fi

echo "✅ Verification complete."
