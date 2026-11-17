#!/usr/bin/env bash
# Phase 1 moves the macOS app into macos/ (moves only); phase 2 imports agterm-qt with history as linux/ and mobile/.
# A one-time recipe for this branch, not a replay: later master changes arrive by `git merge origin/master`,
# which follows the renames. A re-run on the merged tree is a no-op, except that phase 1 moves root files new on master.
# The hand path fixes are in commits 958deeb1, 0dc295d1 and 32bafca2, not here.
# Each phase skips once its folder exists. Phase 2 needs a clean tree: run, commit phase 1, run again.
# Run from anywhere inside the repository; recover a run that fails partway with `git reset --hard`.
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
