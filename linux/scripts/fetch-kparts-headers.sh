#!/usr/bin/env bash
# Unpack the KParts development headers into .deps/ without root, for machines where
# `sudo apt install libkf6parts-dev` is not an option. CMake prefers the real package when present.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$root/.deps/usr/include/KF6/KParts/kparts/readonlypart.h" ] && exit 0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && apt-get download kf6-kparts-dev >/dev/null)
mkdir -p "$root/.deps"
dpkg-deb -x "$tmp"/kf6-kparts-dev_*.deb "$root/.deps"
echo "KParts headers unpacked into $root/.deps"
