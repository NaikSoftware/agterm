#!/usr/bin/env bash
# Phase 1 moves the macOS app into macos/ (moves only); phase 2 imports agterm-qt with history as linux/ and mobile/.
# Each phase is idempotent: it skips once its folder exists.
# Run from anywhere inside the repository. The tree must be clean; recover a run that fails partway with `git reset --hard`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
if [[ -e macos ]]; then
  echo "macos/ exists; skipping phase 1"
else
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
fi

if [[ -e linux ]]; then
  echo "linux/ exists; skipping phase 2"
else
  # git subtree add refuses a dirty tree: commit phase 1 first.
  git diff --quiet HEAD || { echo "commit phase 1 before phase 2" >&2; exit 1; }
  # No --squash: the merge keeps agterm-qt's commits. The PR must land as a merge commit, not squash or rebase.
  git subtree add --prefix=linux -m "chore: merge agterm-qt main into linux/" \
    https://github.com/NaikSoftware/agterm-qt.git main
  git mv linux/mobile mobile
  # the root .gitignore owns linux/'s rules; mobile/ keeps Flutter's nested .gitignore files
  git rm -q linux/.gitignore
  printf '\n# linux/ (Qt app) build outputs\nlinux/build/\nlinux/.deps/\n' >> .gitignore
  git add .gitignore
fi
