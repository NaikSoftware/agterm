#!/usr/bin/env bash
# The agent status hooks the launch installs on install or update, by hand (Claude Code, Codex, OpenCode, Pi and the shell integration), run by the
# app's own installer: scripts/install-claude-hooks.sh [--home DIR]. Idempotent; each edited config is backed up as .bak.
# HANGAR_QT picks the binary (default: the installed one, else this checkout's build). The hooks bake in the hangarctl
# beside it, so an installed binary keeps them working after the build tree goes away.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app=${HANGAR_QT:-$HOME/.local/bin/hangar}
[ -x "$app" ] || app=$root/build/hangar
exec "$app" --install agent-hooks "$@"
