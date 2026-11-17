# elis-agent-status — shell integration for fish.
# Sets the elis session's agent-status indicator to `active` while a coding
# agent runs as a foreground command, and back to `idle` at the next prompt.
# Source this from your ~/.config/fish/config.fish.
#
# Which commands count as agents is a regex, override before sourcing to taste:
#   set -gx ELIS_AGENT_RE '^(gemini|cursor-agent|my-agent)([[:space:]]|$)'
#
# Claude Code, Codex, Pi, and OpenCode are intentionally NOT in the default list —
# their own hooks/extensions/plugins drive finer per-turn state, which the coarse
# process-level active/idle here would only fight. Add any of them here if you
# rely on the shell integration alone for it.
#
# Every entry point is best-effort and a clean no-op outside elis (guarded by
# $ELIS_SESSION_ID), so sourcing it from a non-elis shell does nothing.

if not set -q ELIS_SESSION_ID
    return 0 2>/dev/null
end

# Locate elis-agent-status.sh relative to this file
set -l _ags_dir (dirname (dirname (status filename)))
if not set -q ELIS_AGENT_BIN
    set -g ELIS_AGENT_BIN "$_ags_dir/elis-agent-status.sh"
end

# exported, unlike the shell-local state below: the Claude adapter reads an overridden value from
# its process environment, and a `set -g` would keep it invisible outside this shell. BOTH branches
# export — the one carrying an override set before sourcing (the value the adapter needs, and the
# form this file documented as `set -g` until now) as much as the default
if set -q ELIS_AGENT_RE
    set -gx ELIS_AGENT_RE $ELIS_AGENT_RE
else
    set -gx ELIS_AGENT_RE '^(gemini|cursor-agent|aider|crush|goose)([[:space:]]|$)'
end

function _ags_preexec --on-event fish_preexec
    if string match -r -q $ELIS_AGENT_RE $argv[1]
        $ELIS_AGENT_BIN active --blink
        set -g _ags_active 1
    end
end

function _ags_precmd --on-event fish_prompt
    if set -q _ags_active
        $ELIS_AGENT_BIN idle
        set -e _ags_active
    end
end
