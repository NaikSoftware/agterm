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

start
ctl version
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
bg=$(ctl session new --name bg --no-select) # a notification for the session in front of you is not a badge
ctl notify --title smoke --body hi --target "$bg"
ctl session info --target "$bg" | grep -qE '^unseen +1' || fail "unseen badge"
ctl session seen --target "$bg"
ctl session info --target "$bg" | grep -qE '^unseen +0' || fail "session seen"
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
cd /tmp
ctl session type $'cd /usr\n' --target "$id"
sleep 1
stop

start
ctl tree | grep -q 'renamed' || fail "session not restored"
ctl tree | grep renamed | grep -q idle || fail "status must not survive a restart"
ctl tree | grep renamed | grep -q '/usr' || fail "cwd not tracked"
ctl tree --json | grep -q '"tint":"red"' || fail "tint not restored"
stop
echo "smoke OK"
