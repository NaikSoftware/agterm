#!/usr/bin/env bash
# Run the host-free HangarCore unit tests (no Xcode, no libghostty, no Metal).
set -euo pipefail
cd "$(dirname "$0")/../HangarCore"
swift test
