#!/usr/bin/env bash
# Moves the macOS app into macos/ (phase 1, moves only). Idempotent: does nothing once macos/ exists.
# Run from anywhere inside the repository. The tree must be clean; recover a run that fails partway with `git reset --hard`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
[[ -e macos ]] && { echo "macos/ exists; nothing to do"; exit 0; }

mkdir -p macos/docs
for path in agterm agtermCore agtermTests agtermUITests scripts packaging Makefile project.yml \
  .swiftlint.yml ARCHITECTURE.md CHANGELOG.md; do
  git mv "$path" "macos/$path"
done
for path in docs/*; do
  [[ "$path" == docs/screenshots || "$path" == docs/superpowers ]] || git mv "$path" "macos/$path"
done

# git mv leaves ignored root files behind: carry the staged libghostty/zmx artifacts and build caches along.
for path in GhosttyKit.xcframework .ghostty-build-stamp .zmx-build-stamp agterm.xcodeproj build; do
  if [[ -e "$path" || -L "$path" ]]; then mv "$path" "macos/$path"; fi
done

# anchored ignore patterns follow the resources they name
sed -i '' -E 's#^agterm/Resources/#macos/agterm/Resources/#' .gitignore
git add .gitignore
