#!/usr/bin/env bash
# Render a staged window offscreen with the desktop's Breeze theme: scripts/screenshot.sh out.png [light]
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/build
out=$(realpath -m "${1:-screenshot.png}")
export AGTERM_STATE_DIR=$(mktemp -d /tmp/agq.XXXX)
mkdir -p "$AGTERM_STATE_DIR"
trap 'kill $pid 2>/dev/null || true; rm -rf "$AGTERM_STATE_DIR"' EXIT
unset AGTERM_SESSION_ID AGTERM_SOCKET
theme=kde # "light" drops the Plasma scheme for Qt's default light palette
[ "${2:-}" = light ] && theme=none
QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=$theme QT_STYLE_OVERRIDE=breeze AGTERM_SCREENSHOT=$out \
  "$bin/agterm-qt" >/dev/null 2>&1 &
pid=$!
ctl() { "$bin/agtermctl" "$@"; }
for _ in $(seq 30); do ctl tree >/dev/null 2>&1 && break; sleep 0.1; done
first=$(ctl tree --json | grep -o '"id":"[0-9a-f]*"' | sed -n 2p | cut -d'"' -f4)
ctl workspace rename agterm --target active
ctl session rename "claude · refactor" --target "$first"
ctl session status active --target "$first"
ctl session new --name server --cwd "$root" --no-select >/dev/null
t=$(ctl session new --name tests --cwd "$root/tests" --no-select)
ctl session status completed --target "$t"
c=$(ctl session new --name "claude · copy" --cwd /tmp --workspace-name website --create-workspace)
ctl session status blocked --target "$c"
ctl session new --name "dev server" --cwd /usr --workspace-name website --no-select >/dev/null
ctl session new --name nvim --cwd "$HOME" --workspace-name dotfiles --create-workspace --no-select >/dev/null
ctl session type $'ls -la /usr | head -12\n' --target "$c"
# a stand-in agent: the sidebar only reads the foreground argv's name
mkdir -p "$AGTERM_STATE_DIR/fake" && ln -sf "$(command -v sleep)" "$AGTERM_STATE_DIR/fake/claude"
ctl session type "$AGTERM_STATE_DIR/fake/claude 30"$'\n' --target "$first"
ctl session flag on --target "$t"
ctl session split on --target "$c"
ctl filepanel show >/dev/null
for _ in $(seq 80); do [ -f "$out" ] && break; sleep 0.1; done
sleep 0.3
echo "$out"
