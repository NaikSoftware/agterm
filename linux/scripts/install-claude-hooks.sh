#!/usr/bin/env bash
# The agent status hooks the launch installs on install or update, by hand (Claude Code, Codex, OpenCode, Pi and the shell integration), run by the
# app's own installer: scripts/install-claude-hooks.sh [--home DIR]. Idempotent; each edited config is backed up as .bak.
# ELIS_QT picks the binary (default: the installed one, else this checkout's build). The hooks bake in the elisctl
# beside it, so an installed binary keeps them working after the build tree goes away.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
app=${ELIS_QT:-$HOME/.local/bin/elis}
[ -x "$app" ] || app=$root/build/elis
exec "$app" --install agent-hooks "$@"
