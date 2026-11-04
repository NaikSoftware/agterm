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
fail0() { echo "FAIL: $*"; exit 1; } # before the app runs
trap 'kill $pid 2>/dev/null || true; rm -rf "$AGTERM_STATE_DIR"' EXIT

mkdir -p "$AGTERM_STATE_DIR/config" # an isolated state dir keeps keymap.conf and hooks.conf there too
mkdir -p "$AGTERM_STATE_DIR/windows" # prior state: no first-launch welcome
# the Help menu installers, run headless against a throwaway HOME
fakehome=$AGTERM_STATE_DIR/home
mkdir -p "$fakehome/.claude" "$fakehome/.codex"
HOME=$fakehome SHELL=/bin/sh "$bin/agterm-qt" --install agent-hooks --home "$fakehome" | grep -q "Agent Status Hooks Installed" || fail0 "agent hooks installer"
grep -q agterm-claude-status.sh "$fakehome/.claude/settings.json" || fail0 "claude hooks merged"
grep -q "hooks.Stop" "$fakehome/.codex/config.toml" || fail0 "codex hooks merged"
"$bin/agterm-qt" --install skill --home "$fakehome" | grep -q "Agent Skill Installed" || fail0 "skill installer"
[ -f "$fakehome/.codex/skills/agterm/SKILL.md" ] || fail0 "codex skill copy"
"$bin/agterm-qt" --install cli --home "$fakehome" >/dev/null
[ "$(readlink "$fakehome/.local/bin/agtermctl")" = "$bin/agtermctl" ] || fail0 "command line tool link"
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
ctl dashboard "$first" "$id" --font-size 9 >/dev/null
ctl tree --json | grep -qF "\"dashboardMembers\":[\"$first:left\",\"$id:left\"]" || fail "dashboard members"
ctl tree --json | grep -q '"dashboardFontMode":"fixed"' || fail "dashboard font mode"
ctl dashboard "$id:scratch" 2>/dev/null && fail "dashboard accepted a bad pane suffix"
ctl dashboard --close
ctl tree --json | grep -q dashboardMembers && fail "dashboard --close"
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
w1=$(ctl window list | awk '$1=="*"{print $2}')
w2=$(ctl window new second)
[ "$(ctl window list | grep -c ' open$')" = 2 ] || fail "window new"
inw2=$(ctl session new --name inw2 --window "$w2" --no-select)
ctl tree --window "$w2" | grep -q inw2 || fail "session in the second window"
ctl tree --window "$w1" | grep -q inw2 && fail "windows share a tree"
ctl session info --target "$inw2" | grep -q '^name  *inw2' || fail "a session id reaches its window"
ctl session type 'echo WIN=$AGTERM_WINDOW_ID'$'\n' --target "$inw2"
sleep 1
ctl session text --target "$inw2" | grep -q "WIN=$w2" || fail "AGTERM_WINDOW_ID"
r=$(ctl window resize "$w2" --width 700 --height 500); [ "$r" = 700x500 ] || fail "window resize ($r)"
ctl window rename "$w2" renamed-window
ctl window list | grep -q renamed-window || fail "window rename"
ctl window close "$w2"
ctl window list | grep -q 'renamed-window *closed' || fail "window close keeps the bundle"
ctl tree --window "$w2" 2>/dev/null && fail "a closed window answers tree"
ctl window select "$w2"
ctl tree --window "$w2" | grep -q inw2 || fail "a reopened window keeps its sessions"
w3=$(ctl window new doomed)
ctl window delete "$w3"
ctl window list | grep -q doomed && fail "window delete"
ctl window go --to next >/dev/null || fail "window go"
ctl window select "$w1"
# master's catalog: events, context, sidebar, text extents, pick/ask, messages, recent, batch targets, absent features
timeout 3 "$bin/agtermctl" events --kind session.created >"$AGTERM_STATE_DIR/events.log" &
evpid=$!
sleep 0.5
ctl session new --name evt --no-select >/dev/null
wait "$evpid" || true
grep -q 'session.created evt' "$AGTERM_STATE_DIR/events.log" || fail "events stream"
ctl session context 'PR 12' --target "$id"
ctl tree --json | grep -q '"context":"PR 12"' || fail "session context read-back"
ctl session context 2>/dev/null && fail "context without text or --clear"
[ "$(ctl sidebar width 300)" = 300.0 ] || fail "sidebar width"
ctl sidebar mode flagged
ctl tree --json | grep -q '"sidebarMode":"flagged"' || fail "sidebar mode"
ctl sidebar mode tree
[ "$(ctl sidebar flagged-layout tree)" = tree ] || fail "sidebar flagged-layout"
ctl workspace go --to next >/dev/null || fail "workspace go"
ctl session select --target "$id"
ctl session type $'seq 1 120\n' --target "$id"
sleep 1
ctl session text --all --target "$id" | grep -qx 1 || fail "session text --all reaches the scrollback"
ctl session text --target "$id" | grep -qx 1 && fail "session text is the visible screen"
ctl session text --all --lines 2 --target "$id" 2>/dev/null && fail "--all with --lines"
ctl session search 117 --target "$id" | grep -q 'match' || fail "session search"
ctl session search --close --target "$id"
pick=$(printf 'one\ntwo\n' | ctl pick --no-block | sed 's/.*"id":"\([^"]*\)".*/\1/')
ctl tree --json | grep -q "\"pickPending\":\"$pick\"" || fail "pick pending read-back"
ctl pick cancel "$pick"
rc=0; ctl pick result "$pick" >/dev/null || rc=$?
[ "$rc" = 2 ] || fail "pick result exit after cancel ($rc)"
ask=$(ctl ask 'Ship?' --button yes=Yes --button no --no-block --target "$id" | sed 's/.*"id":"\([^"]*\)".*/\1/')
ctl tree --json | grep -q "\"ask\":{\"id\":\"$ask\"" || fail "ask read-back"
ctl ask cancel "$ask"
rc=0; ctl ask result "$ask" >/dev/null || rc=$?
[ "$rc" = 2 ] || fail "ask result exit after cancel ($rc)"
ctl ask 'No buttons' 2>/dev/null && fail "ask without buttons"
ctl session type '"$AGTERMCTL" msg send ping --to "$AGTERM_SESSION_ID:left" >/dev/null; "$AGTERMCTL" msg read --ack > "'"$AGTERM_STATE_DIR"'/inbox"'$'\n' --target "$id"
for _ in $(seq 20); do grep -q ping "$AGTERM_STATE_DIR/inbox" 2>/dev/null && break; sleep 0.2; done
grep -q ping "$AGTERM_STATE_DIR/inbox" || fail "msg send/read from a pane"
b1=$(ctl session new --name batch1 --no-select)
b2=$(ctl session new --name batch2 --no-select)
[ "$(ctl session close --target "$b1" --target "$b2")" = "2 session(s)" ] || fail "batch close"
ctl recent list | grep -q batch2 || fail "recent list"
ctl recent open "$b2" >/dev/null
ctl tree | grep -q batch2 || fail "recent open by id"
err=$(ctl zmx list 2>&1) && fail "zmx list answered"
[[ $err == *'zmx.list is not supported on this platform'* ]] || fail "absent feature error"
ctl notify 2>/dev/null && fail "notify without a body"
cd /tmp
ctl session type $'cd /usr\n' --target "$id"
sleep 1
stop

start
ctl tree | grep -q 'renamed' || fail "session not restored"
ctl tree | grep renamed | grep -q idle || fail "status must not survive a restart"
ctl tree | grep renamed | grep -q '/usr' || fail "cwd not tracked"
ctl tree --json | grep -q '"tint":"red"' || fail "tint not restored"
ctl tree --json | grep -q '"context":"PR 12"' || fail "context not restored"
ctl restore mode | grep -q 'active     rerun' || fail "restore mode at launch"
[ "$(ctl window list | grep -c ' open$')" = 2 ] || fail "open windows reopen at launch"
ctl tree --window "$w2" | grep -q inw2 || fail "second window restored"
for _ in $(seq 20); do ctl session info --target src | grep -qE '^foreground +sleep' && break; sleep 0.2; done
ctl session info --target src | grep -qE '^foreground +sleep' || fail "rerun restore replays the captured command"
stop
echo "smoke OK"
