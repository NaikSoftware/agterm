#!/usr/bin/env bash
# Point Claude Code's status hooks at agterm-qt's adapter: scripts/install-claude-hooks.sh [prefix] (default ~/.local).
# Idempotent; backs settings.json up first. Outside agterm-qt the adapter is a silent no-op.
set -euo pipefail
prefix=${1:-$HOME/.local}
adapter=$prefix/share/agterm-qt/agent-status/agterm-claude-status.sh
[ -x "$adapter" ] || { echo "missing $adapter: run cmake --install first" >&2; exit 1; }
settings=$HOME/.claude/settings.json
mkdir -p "$(dirname "$settings")"
[ -f "$settings" ] && cp "$settings" "$settings.agterm-qt.bak"
python3 -I - "$settings" "$adapter" <<'PY'
import json, os, sys
path, adapter = sys.argv[1], sys.argv[2]
data = json.load(open(path)) if os.path.exists(path) else {}
hooks = data.setdefault("hooks", {})
# event, matcher, state: the mapping agterm's macOS installer uses
wanted = [("UserPromptSubmit", None, "active --blink"), ("PostToolUse", None, "active --blink"),
          ("Stop", None, "completed --auto-reset"), ("PermissionRequest", None, "blocked"),
          ("Notification", "permission_prompt", "blocked")]
for event in list(hooks):
    kept = []
    for entry in hooks[event]:
        entry["hooks"] = [h for h in entry.get("hooks", []) if "agterm-claude-status.sh" not in h.get("command", "")]
        if entry["hooks"]:
            kept.append(entry)
    hooks[event] = kept
for event, matcher, state in wanted:
    entry = {"hooks": [{"type": "command", "command": f"{adapter} {state}"}]}
    if matcher:
        entry["matcher"] = matcher
    hooks.setdefault(event, []).append(entry)
json.dump(data, open(path, "w"), indent=2)
print(f"installed agterm-qt status hooks into {path}")
PY
