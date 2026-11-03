#!/usr/bin/env bash
# Copies the Atom file-icons fonts and licenses from the Swift app on master into resources/file-icons.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
dest="$root/resources/file-icons"
mkdir -p "$dest"
for f in $(git -C "$root" ls-tree --name-only master agterm/Resources/file-icons/); do
  git -C "$root" show "master:$f" > "$dest/$(basename "$f")"
done
ls -l "$dest"
