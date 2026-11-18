#!/usr/bin/env bash
# Copy the agent launcher logos from the Swift app's asset catalog.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/resources/launchers"
for n in claude codex opencode antigravity; do
  cp "$root/../macos/Elis/Assets.xcassets/launcher-$n.imageset/$n.svg" "$root/resources/launchers/$n.svg"
done
ls -l "$root/resources/launchers"
