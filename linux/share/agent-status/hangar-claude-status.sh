#!/usr/bin/env bash
# Claude Code status adapter installed by hangar's Help ▸ Install Agent Status Hooks command.
#
# A worker agent spawned from inside a session (headless `claude -p` from a tool call, a second CLI
# agent) inherits the spawner's HANGAR_* environment, so its own hooks would repaint the SPAWNER's
# row. This adapter keeps that ownership question inside the installed hook package: decide from
# process topology, not terminal state. The hook is a descendant of the agent that fired it, so
# exactly one agent between here and the pane means "I am the pane's agent"; a second one means
# another agent spawned mine, so stay silent. A consecutive run of one name counts once, because a
# launcher that runs the real binary without `exec` leaves one agent wearing several pids. A worker
# is therefore caught only when a surviving process, such as its tool call's shell, separates it
# from a same-name spawner. A direct child is accepted as reporting: a hook whose whole command is
# `claude -p ...` runs through `sh -c`, which execs it, and that worker repaints the owner's row.
# A tty test cannot answer this — a headless lane that legitimately owns its pane has none, and a
# worker under script/expect gets a fresh pty anyway.
#
# It fails OPEN (reports) whenever the chain is unreadable or severed, e.g. a detached worker whose
# spawner already exited: a missed guard is the behavior without this adapter, while a false silence
# is a bug with no symptom. The argv reaches the shared wrapper unchanged except for the two payload
# rewrites at the end.
set -u

[ -n "${HANGAR_SESSION_ID:-}" ] || exit 0

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
status_wrapper=${HANGAR_STATUS_WRAPPER:-"$script_dir/hangar-agent-status.sh"}

# exact names, not a glob: `claude*` also matches wrapper scripts such as claude-opus-worker.
# The list is the union of the hook-driven agents and shell/integration.sh's HANGAR_AGENT_RE
# default — one agent set split by detection mechanism, and the walk must count all of it: an
# integration-driven agent (say gemini) that spawns `claude -p` is a spawner too, and missing it
# here would let the worker's reset repaint the gemini pane. Keep the two lists in sync.
#
# An overridden HANGAR_AGENT_RE (integration.sh documents the export) extends the set beyond the
# literals, matched against the same argv[0] basename the literal list sees — not the typed command
# line the shell integration matched, so an override that inspects arguments won't extend the walk.
# The expression is evaluated as ERE; zsh under RE_MATCH_PCRE and fish read the same value as PCRE,
# so an override can be valid there and invalid here. `[[` then returns 2, which lands on "not an
# agent" and keeps the walk fail-open; the redirect swallows bash's complaint about the expression.
is_agent() {
  case "$1" in claude | codex | kimi | opencode | pi | gemini | cursor-agent | aider | crush | goose) return 0 ;; esac
  if [ -n "${HANGAR_AGENT_RE:-}" ]; then
    [[ $1 =~ $HANGAR_AGENT_RE ]] 2>/dev/null && return 0
  fi
  return 1
}

agents=0
prev_agent=
p=$PPID
for _ in 1 2 3 4 5 6 7 8; do
  [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null || break
  line=$(ps -o ppid=,command= -p "$p" 2>/dev/null) || break
  [ -n "$line" ] || break
  line=${line#"${line%%[![:space:]]*}"} # ltrim the ppid column's padding
  ppid=${line%% *}
  cmd=${line#* }

  base=${cmd%% *}
  base=${base##*/} # argv[0] basename
  base=${base#-}   # login shells report -/bin/zsh
  base=${base#\(}
  base=${base%\)}  # macOS renders (name) when argv is unreadable
  case "$base" in # node/bun-hosted CLIs present as `node .../cli.js`, so test argv[1] too
    node | bun | deno | python3 | python)
      rest=${cmd#* }
      hosted=${rest%% *}
      hosted=${hosted##*/}
      is_agent "$hosted" && base=$hosted
      ;;
  esac

  if is_agent "$base"; then
    [ "$base" = "$prev_agent" ] || agents=$((agents + 1))
    prev_agent=$base
  else
    prev_agent=
  fi
  [ "$agents" -gt 1 ] && exit 0        # a second agent above mine: I am a worker, not the pane's agent
  case "$base" in login | hangar | hangar) break ;; esac # reached the pane boundary
  p=$ppid
done

# master's background-subagent rewrites (#959): a subagent's active posts --if-idle so it never overwrites the
# main thread's blocked or completed, and a Stop while background_tasks lists a running subagent or workflow
# posts active --blink instead of completed. The rewrite drops the caller's flags: a carried --auto-reset would
# idle the row on the next visit while a background agent still runs. stdin is read only when it is not a
# terminal, and briefly, so an inherited open pipe never hangs a hook. python3 reads the payload where master
# uses plutil or jq; without it, or with an unreadable payload, argv posts as before.
payload=
[ -t 0 ] || IFS= read -r -d '' -t 2 payload || true

if [ -n "$payload" ]; then
  kind=$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("agent_id"):
    print("subagent")
elif d.get("hook_event_name") == "Stop" and any(
        isinstance(t, dict) and t.get("status") == "running" and t.get("type") in ("subagent", "workflow")
        for t in d.get("background_tasks") or []):
    print("background")
' 2>/dev/null)
  case "$kind:${1:-}" in
    subagent:active) set -- "$@" --if-idle ;;
    background:completed) set -- active --blink ;;
  esac
fi

exec "$status_wrapper" "$@"
