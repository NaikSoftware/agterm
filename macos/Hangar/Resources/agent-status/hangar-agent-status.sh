#!/usr/bin/env bash
# hangar-agent-status — set the current hangar session's agent-status indicator.
#
#   hangar-agent-status.sh active            # agent is busy
#   hangar-agent-status.sh completed         # agent finished a turn
#   hangar-agent-status.sh blocked           # agent is waiting on you
#   hangar-agent-status.sh idle              # clear the indicator
#
# States: idle | active | completed | blocked. An optional --blink / --auto-reset
# (and any further args) is forwarded verbatim to `hangarctl session status`.
#
# Outside hangar this is a silent no-op, so it is safe to call from any hook.
#
# As a hook it must never interfere with the agent: stdout/stderr are suppressed
# (Claude Code injects a UserPromptSubmit/SessionStart hook's stdout into the
# prompt context) and it always exits 0 (a non-zero exit can block the turn).
#
# hangarctl resolution order (the binary that talks to the control socket):
#   1. $HANGARCTL — an explicit override the caller set.
#   2. the absolute bundled-binary path the installer bakes in: the installer
#      rewrites the HANGARCTL default below to Hangar.app's Contents/MacOS/hangarctl,
#      so the hook fires even when the CLI was never symlinked into PATH.
#   3. `hangarctl` on PATH — the fallback when no override was set and the baked
#      path no longer exists, which is what a bundle moved since the install leaves
#      behind (installing from the mounted DMG bakes a /Volumes path, dead on eject).
set -u

[ -n "${HANGAR_SESSION_ID:-}" ] || exit 0   # not inside hangar: nothing to do

# --socket is a SUBCOMMAND option, so it must come AFTER `session status`, not before
# it. Pass it only when HANGAR_SOCKET is set (the app injects it alongside the id).
state=$1
shift

# forward the pane discriminators when the app injected them: each session surface
# (main/split/scratch) sets its own HANGAR_PANE (the role) plus HANGAR_PANE_ID (a stable
# per-surface token). the role can go stale — a split survivor promoted into the main pane
# keeps its baked `right` — so we also forward the token as --pane-id, which the app resolves
# to the surface's CURRENT slot and lets override the stale role (#199). both are validated
# hangarctl-side, so pass them through verbatim. the ${arr[@]+..} guard keeps the empty-array
# expansion safe under `set -u` on bash 3.2.
pane_args=()
[ -n "${HANGAR_PANE:-}" ] && pane_args+=(--pane "$HANGAR_PANE")
[ -n "${HANGAR_PANE_ID:-}" ] && pane_args+=(--pane-id "$HANGAR_PANE_ID")

if [ -n "${HANGAR_SOCKET:-}" ]; then
  "${HANGARCTL:-hangarctl}" session status "$state" \
    --target "$HANGAR_SESSION_ID" --socket "$HANGAR_SOCKET" \
    "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
else
  "${HANGARCTL:-hangarctl}" session status "$state" \
    --target "$HANGAR_SESSION_ID" "${pane_args[@]+"${pane_args[@]}"}" "$@" >/dev/null 2>&1 || true
fi
exit 0
