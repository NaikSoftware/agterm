#!/usr/bin/env bash
# Copy the agent launcher logos from agterm master's asset catalog.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/resources/launchers"
for n in claude codex opencode antigravity; do
  git -C "$root" show "master:agterm/Assets.xcassets/launcher-$n.imageset/$n.svg" >"$root/resources/launchers/$n.svg"
done
ls -l "$root/resources/launchers"
