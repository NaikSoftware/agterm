#!/usr/bin/env bash
# End-to-end check of the built app over its control socket, offscreen and on an isolated state dir.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=$root/build
export AGTERM_STATE_DIR=$(mktemp -d /tmp/agq.XXXX)
unset AGTERM_SESSION_ID AGTERM_SOCKET
ctl() { "$bin/agtermctl" "$@"; }
pid=
start() {
  QT_QPA_PLATFORM=offscreen "$bin/agterm-qt" >"$AGTERM_STATE_DIR/app.log" 2>&1 &
  pid=$!
  for _ in $(seq 50); do ctl tree >/dev/null 2>&1 && return; sleep 0.2; done
  echo "socket never came up"; cat "$AGTERM_STATE_DIR/app.log"; exit 1
}
stop() { kill "$pid"; wait "$pid" 2>/dev/null || true; }
fail() { echo "FAIL: $*"; ctl tree || true; stop; exit 1; }
trap 'kill $pid 2>/dev/null || true; rm -rf "$AGTERM_STATE_DIR"' EXIT

mkdir -p "$AGTERM_STATE_DIR/config" # an isolated state dir keeps keymap.conf and hooks.conf there too
cat >"$AGTERM_STATE_DIR/config/keymap.conf" <<EOF
map ctrl+alt+l toggle_split
command "Mark" ctrl+a>m echo "{AGT_SESSION_ID}" > "$AGTERM_STATE_DIR/mark"
map bogus toggle_split
EOF
cat >"$AGTERM_STATE_DIR/config/hooks.conf" <<EOF
on app.launched touch "$AGTERM_STATE_DIR/launched"
on session.created cat >> "$AGTERM_STATE_DIR/created"
EOF
start
ctl version
for _ in $(seq 20); do [ -f "$AGTERM_STATE_DIR/launched" ] && break; sleep 0.1; done
[ -f "$AGTERM_STATE_DIR/launched" ] || fail "app.launched hook"
ctl keymap list | grep -qE '^  toggle_split +Ctrl\+Alt\+L  \(mapped\)' || fail "keymap list read-back"
ctl keymap list | grep -q "line 3: invalid chord 'bogus'" || fail "keymap diagnostics"
[ "$(ctl keymap reload)" = "1 diagnostic(s)" ] || fail "keymap reload count"
first=$(ctl tree | awk 'NR==2{print $2}')
ctl keymap run Mark --target "$first" >/dev/null
for _ in $(seq 20); do [ -s "$AGTERM_STATE_DIR/mark" ] && break; sleep 0.1; done
[ "$(cat "$AGTERM_STATE_DIR/mark")" = "$first" ] || fail "keymap run with {AGT_SESSION_ID}"
ctl keymap run Nope 2>/dev/null && fail "unknown custom command accepted"
ctl hooks list | grep -q 'on session.created' || fail "hooks list"
ctl theme list | grep -q ' DarkPastels' || fail "theme list"
ctl theme set DarkPastels >/dev/null
ctl theme list | grep -q '^\* DarkPastels' || fail "theme set read-back"
ctl theme set NoSuchScheme 2>/dev/null && fail "unknown theme accepted"
ctl theme set >/dev/null
[ "$(ctl tree | grep -c '^  ')" = 1 ] || fail "first launch should open one session"
id=$(ctl session new --name probe --cwd /tmp --workspace-name agents --create-workspace)
sleep 1
ctl session type 'echo MARK=$AGTERM_SESSION_ID' --target "$id"
ctl session type $'\n' --target "$id"
sleep 1
ctl session text --target "$id" --lines 5 | grep -q "MARK=$id" || fail "pane env or text read-back"
ctl session status blocked --target "$id" --blink --pane main
ctl tree | grep probe | grep -q blocked || fail "status not set"
ctl session status bogus --target "$id" 2>/dev/null && fail "bogus status accepted"
AGTERM_SESSION_ID=$id ctl session info | grep -q '^pid' || fail "info by env target"
ctl session type "$root/share/agent-status/agterm-claude-status.sh completed --auto-reset"$'\n' --target "$id"
sleep 1
ctl tree | grep probe | grep -q completed || fail "Claude hook adapter from a pane"
ctl session split on --axis horizontal --target "$id"
sleep 1
ctl session info --target "$id" | grep -qE '^hasSplit +true' || fail "split not created"
ctl session info --target "$id" | grep -qE '^splitAxis +horizontal' || fail "split axis"
ctl session swap --target "$id"
ctl session split close --target "$id"
ctl session info --target "$id" | grep -qE '^hasSplit +false' || fail "split not closed"
rc=0; ctl session overlay open 'exit 4' --block --target "$id" || rc=$?
[ "$rc" = 4 ] || fail "overlay --block exits with the program's status ($rc)"
[ "$(ctl session overlay result --target "$id")" = 4 ] || fail "overlay result"
ctl session overlay open 'sleep 30' --size-percent 60 --target "$id"
ctl tree --json | grep -q '"overlaySizePercent":60' || fail "floating overlay read-back"
[ "$(ctl session overlay toggle --target "$id")" = hidden ] || fail "overlay toggle hides"
ctl tree --json | grep -q '"hiddenOverlays":\["session"\]' || fail "hidden overlay read-back"
ctl session hud 'hi' --target "$id" 2>/dev/null && fail "a hud over a running program"
ctl session overlay close --target "$id"
ctl session hud 'building' --position top --spinner --target "$id"
ctl tree --json | grep -q '"position":"top-center"' || fail "hud read-back"
ctl session hud close --target "$id"
ctl session hud close --target "$id" 2>/dev/null && fail "hud close is not idempotent"
bg=$(ctl session new --name bg --no-select) # a notification for the session in front of you is not a badge
ctl notify --title smoke --body hi --target "$bg"
ctl session info --target "$bg" | grep -qE '^unseen +1' || fail "unseen badge"
ctl session seen --target "$bg"
ctl session info --target "$bg" | grep -qE '^unseen +0' || fail "session seen"
sleep 0.5
ctl session type $'printf "\\033]9;from osc\\007"\n' --target "$bg"
for _ in $(seq 20); do ctl session info --target "$bg" | grep -qE '^unseen +1' && break; sleep 0.1; done
ctl session info --target "$bg" | grep -qE '^unseen +1' || fail "OSC 9 from a pane raises the badge"
grep -q "\"session\":\"$bg\"" "$AGTERM_STATE_DIR/created" || fail "session.created hook got the event on stdin"
ctl filepanel show >/dev/null
ctl tree --json | grep -q '"filePanel":{"visible":true' || fail "file panel show"
ctl filepanel width 260 >/dev/null
ctl filepanel hide >/dev/null
ctl session new --parent "$id" --name logs --no-select >/dev/null
ctl tree --json | grep -q "\"parent\":\"$id\"" || fail "companion"
named=$(ctl session new --no-select)
sleep 1.5
ctl tree | grep "$named" | grep -q 'New session' || fail "a plain shell is a New session (its prompt title is not a name)"
ctl session type "sh -c 'printf \"\\033]0;Agent task\\007\"; sleep 3'"$'\n' --target "$named"
sleep 2
ctl tree | grep "$named" | grep -q 'Agent task' || fail "a running program's title names the session"
ctl session rename renamed --target probe
ctl session go --to next >/dev/null
gone=$(ctl session new --name exits --no-select)
sleep 1
ctl session type $'echo BG_OK\n' --target "$gone"
sleep 1
ctl session text --target "$gone" | grep -q BG_OK || fail "background session text"
ctl session type $'exit\n' --target "$gone"
sleep 1.5
ctl tree | grep -q exits && fail "exited shell should end its session"
doomed=$(ctl session new --name doomed --no-select)
sleep 1
dpid=$(ctl session info --target "$doomed" | awk '/^pid /{print $2}')
kill -0 "$dpid" || fail "no shell pid for doomed"
ctl session close --target "$doomed"
for _ in $(seq 20); do kill -0 "$dpid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$dpid" 2>/dev/null && fail "closing a session left its shell running"
ctl session tint red --on icon,name --target "$id"
ctl tree --json | grep -q '"tint":"red","tintOn":\["icon","name"\]' || fail "session tint read-back"
ctl session tint pink --target "$id" 2>/dev/null && fail "unknown tint accepted"
ctl workspace new --name tinted --tint green >/dev/null
ctl tree --json | grep -q '"name":"tinted","rememberedFolder":"","sessions":\[\],"tint":"green"' || ctl tree --json | grep -q '"tint":"green"' || fail "workspace new --tint"
ctl workspace focus on --target agents
ctl tree --json | grep -q '"workspaceFilter":true' || fail "workspace focus on"
ctl workspace filter off
ctl tree --json | grep -q '"workspaceFilter":false' || fail "workspace filter off"
ctl tree --json | grep -q '"focused":true' || fail "filter off keeps the marked set"
ctl font inc --target "$id"
ctl session info --target "$id" | grep -qE '^fontSize +[1-9]' || fail "font inc read-back"
ctl font reset --target "$id"
ctl session info --target "$id" | grep -qE '^fontSize +0' || fail "font reset"
src=$(ctl session new --name src --no-select)
sleep 1
ctl session type $'sleep 300\n' --target "$src"
sleep 1
dup=$(ctl session duplicate --companion --no-select --target "$src")
sleep 1
ctl session info --target "$dup" | grep -qE "^parent +$src" || fail "duplicate as companion parent"
dupid=$(ctl session info --target "$dup" | awk '/^pid /{print $2}') # exec'd: the program is the pane's process itself
grep -qx sleep "/proc/$dupid/comm" || fail "duplicate as companion runs the pane's program"
undo=$(ctl session new --name undo --no-select)
[ "$(ctl session close --undoable --target "$undo")" = "ok (undoable)" ] || fail "close --undoable"
ctl tree | grep -q undo && fail "an undoable close leaves the tree"
ctl restore capture 2>/dev/null && fail "restore capture outside rerun mode"
ctl restore mode rerun | grep -q '(restart required)' || fail "restore mode read-back"
ctl restore capture | grep -q 'captured [1-9]' || fail "restore capture"
cd /tmp
ctl session type $'cd /usr\n' --target "$id"
sleep 1
stop

start
ctl tree | grep -q 'renamed' || fail "session not restored"
ctl tree | grep renamed | grep -q idle || fail "status must not survive a restart"
ctl tree | grep renamed | grep -q '/usr' || fail "cwd not tracked"
ctl tree --json | grep -q '"tint":"red"' || fail "tint not restored"
ctl restore mode | grep -q 'active     rerun' || fail "restore mode at launch"
for _ in $(seq 20); do ctl session info --target src | grep -qE '^foreground +sleep' && break; sleep 0.2; done
ctl session info --target src | grep -qE '^foreground +sleep' || fail "rerun restore replays the captured command"
stop
echo "smoke OK"
