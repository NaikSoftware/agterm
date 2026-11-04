#!/usr/bin/env bash
# Help ▸ Install Agent Status Hooks… from a shell (Claude Code, Codex, OpenCode, Pi and the shell integration), run by the
# app's own installer: scripts/install-claude-hooks.sh [--home DIR]. Idempotent; each edited config is backed up as .bak.
# AGTERM_QT picks the binary (default: this checkout's build, else the installed one).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app=${AGTERM_QT:-$root/build/agterm-qt}
[ -x "$app" ] || app=$HOME/.local/bin/agterm-qt
exec "$app" --install agent-hooks "$@"
