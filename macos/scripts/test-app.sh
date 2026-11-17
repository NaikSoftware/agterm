#!/usr/bin/env bash
# Run the application-hosted AppKit unit tests with scheme launch isolation.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/setup.sh
xcodegen generate
xcodebuild test \
  -project Elis.xcodeproj \
  -scheme ElisTests \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData
