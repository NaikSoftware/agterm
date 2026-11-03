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
scheme=()
[ "${2:-}" = light ] && scheme=(-style breeze)
QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME=kde QT_STYLE_OVERRIDE=breeze AGTERM_SCREENSHOT=$out \
  "$bin/agterm-qt" "${scheme[@]}" >/dev/null 2>&1 &
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
ctl session type $'printf "\\033[1;32mnaik@station\\033[0m:\\033[1;34m/tmp\\033[0m$ claude\\n"; ls -la /usr | head -12\n' --target "$c"
for _ in $(seq 80); do [ -f "$out" ] && break; sleep 0.1; done
sleep 0.3
echo "$out"
