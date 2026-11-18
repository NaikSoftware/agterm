#!/usr/bin/env bash
# Run the host-free ElisCore unit tests (no Xcode, no libghostty, no Metal).
set -euo pipefail
cd "$(dirname "$0")/../ElisCore"
swift test
