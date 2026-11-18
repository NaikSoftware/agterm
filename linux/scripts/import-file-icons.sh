#!/usr/bin/env bash
# Copies the Atom file-icons fonts and licenses from the Swift app into resources/file-icons.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dest="$root/resources/file-icons"
mkdir -p "$dest"
cp "$root"/../macos/Elis/Resources/file-icons/* "$dest/"
ls -l "$dest"
