#!/usr/bin/env bash
# Help ▸ Install Agent Status Hooks… from a shell (Claude Code, Codex, OpenCode, Pi and the shell integration), run by the
# app's own installer: scripts/install-claude-hooks.sh [--home DIR]. Idempotent; each edited config is backed up as .bak.
# AGTERM_QT picks the binary (default: the installed one, else this checkout's build). The hooks bake in the agtermctl
# beside it, so an installed binary keeps them working after the build tree goes away.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app=${AGTERM_QT:-$HOME/.local/bin/agterm-qt}
[ -x "$app" ] || app=$root/build/agterm-qt
exec "$app" --install agent-hooks "$@"
