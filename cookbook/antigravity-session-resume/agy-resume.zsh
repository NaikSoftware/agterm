#!/usr/bin/env zsh
# Sourced, not executed: source this file from ~/.zshrc.
# See README.md.

# Antigravity CLI (agy) wrapper for per-pane session resume in elis.
# Runs the real `agy` binary unchanged, then clears the pane's sticky restore
# pin when an interactive session returns to the shell so a closed session is
# not relaunched on the next terminal restart.
function agy {
  emulate -L zsh
  local rc
  command agy "$@" && rc=0 || rc=$?

  [[ -n ${ELIS_SESSION_ID:-} && -n ${ELIS_PANE_ID:-} && -n ${ELIS_SOCKET:-} ]] || return $rc
  [[ -z ${CLAUDECODE:-} && -z ${CLAUDE_CODE_SESSION_ID:-} ]] || return $rc
  (( rc == 129 || rc == 143 )) && return $rc

  local arg
  for arg in "$@"; do
    case $arg in
      --) break ;;
      -p|--print|--prompt|--print=*|--prompt=*|-h|--help|--version|\
      agent|agents|changelog|help|install|mcp|mic-serve|models|plugin|plugins|remote-control|update)
        return $rc ;;
    esac
  done

  local ctl=${ELISCTL:-elisctl}
  if ! command -v "$ctl" >/dev/null 2>&1; then
    if [[ -z ${ELISCTL:-} && -x $HOME/Applications/Elis.app/Contents/MacOS/elisctl ]]; then
      ctl=$HOME/Applications/Elis.app/Contents/MacOS/elisctl
    elif [[ -z ${ELISCTL:-} && -x /Applications/Elis.app/Contents/MacOS/elisctl ]]; then
      ctl=/Applications/Elis.app/Contents/MacOS/elisctl
    else
      return $rc
    fi
  fi

  "$ctl" session restore --clear \
    --target "$ELIS_SESSION_ID" \
    --pane-id "$ELIS_PANE_ID" \
    --socket "$ELIS_SOCKET" >/dev/null 2>&1 || true

  return $rc
}
