# hangar-agent-status — shell integration for fish.
# Sets the hangar session's agent-status indicator to `active` while a coding
# agent runs as a foreground command, and back to `idle` at the next prompt.
# Source this from your ~/.config/fish/config.fish.
#
# Which commands count as agents is a regex, override before sourcing to taste:
#   set -gx HANGAR_AGENT_RE '^(gemini|cursor-agent|my-agent)([[:space:]]|$)'
#
# Claude Code, Codex, Pi, and OpenCode are intentionally NOT in the default list —
# their own hooks/extensions/plugins drive finer per-turn state, which the coarse
# process-level active/idle here would only fight. Add any of them here if you
# rely on the shell integration alone for it.
#
# Every entry point is best-effort and a clean no-op outside hangar (guarded by
# $HANGAR_SESSION_ID), so sourcing it from a non-hangar shell does nothing.

if not set -q HANGAR_SESSION_ID
    return 0 2>/dev/null
end

# Locate hangar-agent-status.sh relative to this file
set -l _ags_dir (dirname (dirname (status filename)))
if not set -q HANGAR_AGENT_BIN
    set -g HANGAR_AGENT_BIN "$_ags_dir/hangar-agent-status.sh"
end

# exported, unlike the shell-local state below: the Claude adapter reads an overridden value from
# its process environment, and a `set -g` would keep it invisible outside this shell. BOTH branches
# export — the one carrying an override set before sourcing (the value the adapter needs, and the
# form this file documented as `set -g` until now) as much as the default
if set -q HANGAR_AGENT_RE
    set -gx HANGAR_AGENT_RE $HANGAR_AGENT_RE
else
    set -gx HANGAR_AGENT_RE '^(gemini|cursor-agent|aider|crush|goose)([[:space:]]|$)'
end

function _ags_preexec --on-event fish_preexec
    if string match -r -q $HANGAR_AGENT_RE $argv[1]
        $HANGAR_AGENT_BIN active --blink
        set -g _ags_active 1
    end
end

function _ags_precmd --on-event fish_prompt
    if set -q _ags_active
        $HANGAR_AGENT_BIN idle
        set -e _ags_active
    end
end
