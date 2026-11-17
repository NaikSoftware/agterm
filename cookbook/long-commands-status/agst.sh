#!/bin/sh
# agst - run a command under an elis session status indicator.
#
# Sets the current elis session's status to `active` while the command runs,
# then `completed --auto-reset` on success or `blocked --auto-reset` on any
# non-zero exit. When $ELIS_SESSION_ID is unset, just runs the command.
#
# Flags --blink, --sound, --shape, and --socket are parsed off the front;
# --blink and --sound apply to the end states only (completed/blocked),
# --shape and --socket apply to every status call including active.
# Everything after them is the command.
#
# Usage:
#   agst [--blink] [--sound <sound>] [--shape <shape>] [--socket <socket>] <command...>
#
# Environment:
#   ELIS_SESSION_ID  the session to update (set by elis).
#   ELIS_PANE        the pane role (left|right|scratch); forwarded when set.
#   ELIS_PANE_ID     stable pane token; forwarded when set, overrides a stale role.
#   ELIS_SOCKET      the control socket; an explicit --socket wins.
#   ELISCTL          override the elisctl binary (default: elisctl).

set -u

ELISCTL=${ELISCTL:-elisctl}

usage() {
  echo "usage: ${0##*/} [--blink] [--sound <sound>] [--shape <shape>] [--socket <socket>] <command...>" >&2
}

# Collect our own flags off the front; the rest is the command.
# blink and sound apply to completed/blocked only; shape and socket to every call.
blink=
sound=
shape=
socket=${ELIS_SOCKET:-}
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --blink) blink=1; shift ;;
    --sound)
      [ $# -ge 2 ] || { usage; exit 2; }
      sound=$2; shift 2 ;;
    --shape)
      [ $# -ge 2 ] || { usage; exit 2; }
      shape=$2; shift 2 ;;
    --socket)
      [ $# -ge 2 ] || { usage; exit 2; }
      socket=$2; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done

if [ $# -eq 0 ]; then
  usage
  exit 2
fi

# Not inside elis: exec the command directly, no status calls.
if [ -z "${ELIS_SESSION_ID:-}" ]; then
  exec "$@"
fi

# set -- inside the function touches only its own positional parameters, so the
# caller's $@ (the command) survives the active call. Pane markers forward only
# when the app injected them, never empty, matching the stock status wrapper.
status() {
  # $1 = state, $2 = end (nonempty for completed/blocked)
  _end=${2:-}
  set -- "$1"
  [ -n "$_end" ] && set -- "$@" --auto-reset
  set -- "$@" --target "$ELIS_SESSION_ID"
  [ -n "${ELIS_PANE:-}" ] && set -- "$@" --pane "$ELIS_PANE"
  [ -n "${ELIS_PANE_ID:-}" ] && set -- "$@" --pane-id "$ELIS_PANE_ID"
  [ -n "$shape" ] && set -- "$@" --shape "$shape"
  [ -n "$socket" ] && set -- "$@" --socket "$socket"
  [ -n "$_end" ] && [ -n "$blink" ] && set -- "$@" --blink
  [ -n "$_end" ] && [ -n "$sound" ] && set -- "$@" --sound "$sound"
  "$ELISCTL" session status "$@" >/dev/null 2>&1 || :
}

status active ''

# Capture the exit code without -e so the status still gets set on failure.
rc=0
"$@" || rc=$?

if [ "$rc" -eq 0 ]; then
  status completed end
else
  status blocked end
fi

exit "$rc"
