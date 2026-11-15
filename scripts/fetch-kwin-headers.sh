#!/usr/bin/env bash
# Unpack the KWin and KDecoration development files into .deps/ without root, so the glass effect
# (src/kwin-glass) builds where `sudo apt install kwin-dev libkdecorations3-dev` is not an option.
# Versions are pinned to the installed compositor: KWin only loads an effect built for its exact version.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
kwin=$(dpkg-query -W -f='${Version}' kwin-wayland)
deco=$(dpkg-query -W -f='${Version}' 'libkdecorations3-6*' | head -1)
stamp="$root/.deps/kwin-$kwin"
[ -f "$stamp" ] && exit 0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
(cd "$tmp" && apt-get download "kwin-dev=$kwin" "libkdecorations3-dev=$deco" >/dev/null)
mkdir -p "$root/.deps"
for deb in "$tmp"/*.deb; do dpkg-deb -x "$deb" "$root/.deps"; done
# the CMake configs point at the versioned libraries next to them; those live in the runtime packages
lib=/usr/lib/x86_64-linux-gnu
for so in "$lib"/libkwin.so.* "$lib"/libkdecorations3*.so.*; do ln -sf "$so" "$root/.deps/usr/lib/x86_64-linux-gnu/"; done
rm -f "$root"/.deps/kwin-*
touch "$stamp"
echo "KWin $kwin headers unpacked into $root/.deps"
