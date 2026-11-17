#!/bin/bash
# Runs migrate-from-agterm2.sh against a fake HOME holding what Agterm2's installers wrote.
set -u
script="$(cd "$(dirname "$0")/.." && pwd)/migrate-from-agterm2.sh"
# a short /tmp root keeps the fixture socket path under the 104-byte limit
root="$(mktemp -d /tmp/migtest.XXXXXX)"
trap '[ -n "${KEEP:-}" ] || rm -rf "$root"' EXIT
H="$root/home"
HE="${H//\//\\/}"
fails=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

snap() {
    (cd "$1" && find . -print0 | sort -z | while IFS= read -r -d '' f; do
        if [ -L "$f" ]; then echo "L $f -> $(readlink "$f")"
        elif [ -S "$f" ]; then echo "S $f"
        elif [ -f "$f" ]; then echo "F $f $(shasum < "$f" | cut -c1-40) $(stat -f %Lp "$f")"
        else echo "D $f"; fi
    done)
}

state="$H/Library/Application Support/agterm"
conf="$H/.config/agterm"
status="$conf/agent-status"
mkdir -p "$state/windows" "$conf/hooks" "$status/shell" "$H/.claude/skills/agterm" "$H/.claude/skills/mine" \
    "$H/.codex/skills/agterm" "$H/.pi/agent/extensions" "$H/.config/opencode/plugins/agterm-v2" "$H/.config/fish" "$H/dotfiles"

printf '{"workspaces":[{"name":"agterm","sessions":[{"cwd":"/Users/me/agterm"}]}]}' > "$state/workspaces.json"
printf '{"id":"w1"}' > "$state/windows/w1.json"
printf '{\n  "configDirectory" : null,\n  "darkTheme" : "agterm",\n  "fontSize" : 13,\n  "theme" : "agterm"\n}' > "$state/settings.json"
: > "$state/agterm.lock"
python3 -I -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$state/agterm.sock"

cat > "$conf/keymap.conf" <<'EOF'
map cmd+shift+k toggle_sidebar
command cmd+shift+j "Jump" agtermctl session focus "$AGTERM_SESSION_ID" --socket ~/Library/Application\ Support/agterm/agterm.sock
command cmd+shift+p "Proj" cd ~/IdeaProjects/agterm && open -a agterm.app
EOF
printf 'theme = light:agterm,dark:agterm\nfont-size = 13\n' > "$conf/ghostty.conf"
printf 'vim\nhtop\n' > "$conf/restore-denylist.conf"
printf 'on status ~/.config/agterm/hooks/status.sh\n' > "$conf/hooks.conf"
printf '#!/bin/sh\nagtermctl notify "$AGT_EVENT_STATUS"\n' > "$conf/hooks/status.sh"
chmod 755 "$conf/hooks/status.sh"
printf '#!/bin/sh\n' > "$status/agterm-agent-status.sh"
printf '# agterm shell integration\n' > "$status/shell/integration.sh"

cmd() { printf "'%s\\\\/.config\\\\/agterm\\\\/agent-status\\\\/%s' %s" "$HE" "$1" "$2"; }
ours() {
    cat <<EOF
      {
        "hooks" : [
          {
            "command" : "$(cmd "${3:-agterm-claude-status.sh}" "$2")",
            "type" : "command"
          }
        ]$1
      }
EOF
}
cat > "$H/.claude/settings.json" <<EOF
{
  "env" : {
    "CLAUDE_CODE_PLUGIN_DIRS" : "\\/opt\\/mods\\/mine:$HE\\/.config\\/agterm\\/agent-status\\/claude-mods\\/swarm-companion"
  },
  "hooks" : {
    "Notification" : [
$(ours ',
        "matcher" : "permission_prompt"' blocked)
    ],
    "PermissionRequest" : [
$(ours '' blocked)
    ],
    "PostToolUse" : [
$(ours '' 'active --blink')
    ],
    "PreToolUse" : [
      {
        "hooks" : [
          {
            "command" : "\\/usr\\/local\\/bin\\/my-guard.sh",
            "type" : "command"
          }
        ],
        "matcher" : "Bash"
      }
    ],
    "Stop" : [
      {
        "hooks" : [
          {
            "command" : "\\/usr\\/local\\/bin\\/notify-done.sh",
            "type" : "command"
          },
          {
            "command" : "$(cmd agterm-claude-status.sh 'completed --auto-reset')",
            "type" : "command"
          }
        ]
      }
    ],
    "SubagentStart" : [
$(ours '' 'active --blink')
    ],
    "SubagentStop" : [
$(ours '' 'active --blink')
    ],
    "UserPromptSubmit" : [
$(ours '' active agterm-agent-status.sh)
    ]
  },
  "model" : "opus"
}
EOF
chmod 600 "$H/.claude/settings.json"
cat > "$root/expected-settings.json" <<'EOF'
{
  "env" : {
    "CLAUDE_CODE_PLUGIN_DIRS" : "\/opt\/mods\/mine"
  },
  "hooks" : {
    "PreToolUse" : [
      {
        "hooks" : [
          {
            "command" : "\/usr\/local\/bin\/my-guard.sh",
            "type" : "command"
          }
        ],
        "matcher" : "Bash"
      }
    ],
    "Stop" : [
      {
        "hooks" : [
          {
            "command" : "\/usr\/local\/bin\/notify-done.sh",
            "type" : "command"
          }
        ]
      }
    ]
  },
  "model" : "opus"
}
EOF

printf '<!-- agterm-skill -->\n# agterm\n' > "$H/.claude/skills/agterm/SKILL.md"
printf '# mine\n' > "$H/.claude/skills/mine/SKILL.md"
printf '# my own skill that happens to be named agterm\n' > "$H/.codex/skills/agterm/SKILL.md"

codex_user='model = "gpt-5"

[profiles.fast]
model = "gpt-5-mini"
'
{
    printf '%s\n' "$codex_user"
    echo '# >>> agterm agent-status >>>'
    for pair in SessionStart:session-start Stop:stop; do
        printf '[[hooks.%s]]\n[[hooks.%s.hooks]]\ntype = "command"\ncommand = "'"'"'%s/agent-status/agterm-codex-status.sh'"'"' %s"\n\n' \
            "${pair%%:*}" "${pair%%:*}" "$conf" "${pair#*:}"
    done
    printf '[hooks.state]\n\n[hooks.state."%s/.codex/config.toml:session_start:0:0"]\ntrusted_hash = "sha256:abc"\n' "$H"
    echo '# <<< agterm agent-status <<<'
} > "$H/.codex/config.toml"

rc_user='export PATH="$HOME/bin:$PATH"
alias ll="ls -l"
'
block() { printf '\n# >>> agterm agent-status >>>\nsource '"'"'%s/%s'"'"'\n# <<< agterm agent-status <<<\n' "$status" "$1"; }
{ printf '%s' "$rc_user"; block shell/integration.sh; } > "$H/.zshrc"
{ printf '%s' "$rc_user"; block shell/integration.sh; } > "$H/dotfiles/bashrc"
ln -s dotfiles/bashrc "$H/.bashrc"
{ printf 'set -x EDITOR vim\n'; block shell/integration.fish; } > "$H/.config/fish/config.fish"

printf '// agterm-pi-status-extension\n' > "$H/.pi/agent/extensions/agterm-status.ts"
printf '// agterm-opencode-status-plugin\n' > "$H/.config/opencode/plugins/agterm-status.js"
printf '// agterm-opencode-v2-status-plugin\n' > "$H/.config/opencode/plugins/agterm-v2/tui.js"
printf '// my plugin\n' > "$H/.config/opencode/plugins/mine.js"

old_state_snap="$(snap "$state")"
old_conf_snap="$(snap "$conf")"
before="$(snap "$H")"

# Never let a live-pane environment steer the run at the real Codex or OpenCode config.
run() { env -u CODEX_HOME -u OPENCODE_CONFIG_DIR -u XDG_CONFIG_HOME /bin/bash "$script" --home "$H" "$@"; }

run --dry-run > "$root/dry.out" 2>&1
check "dry run exits 0" '[ $? -eq 0 ]'
check "dry run changes nothing" '[ "$(snap "$H")" = "$before" ]'

run > "$root/run1.out" 2>&1
code=$?
check "first run exits 0" '[ $code -eq 0 ]'
[ $code -eq 0 ] || cat "$root/run1.out"

nstate="$H/Library/Application Support/hangar"
nconf="$H/.config/hangar"
check "sessions file byte-identical" 'cmp -s "$state/workspaces.json" "$nstate/workspaces.json"'
check "window file byte-identical" 'cmp -s "$state/windows/w1.json" "$nstate/windows/w1.json"'
check "socket and lock not copied" '[ ! -e "$nstate/agterm.sock" ] && [ ! -e "$nstate/agterm.lock" ]'
printf '{\n  "configDirectory" : null,\n  "darkTheme" : "hangar",\n  "fontSize" : 13,\n  "theme" : "hangar"\n}' > "$root/expected-app-settings.json"
check "settings theme is hangar" 'cmp -s "$root/expected-app-settings.json" "$nstate/settings.json"'
check "keymap calls hangarctl" 'grep -q "\"Jump\" hangarctl session focus \"\$HANGAR_SESSION_ID\" --socket ~/Library/Application\\\\ Support/hangar/hangar.sock" "$nconf/keymap.conf"'
check "keymap keeps user path, renames app" 'grep -qF "cd ~/IdeaProjects/agterm && open -a Hangar.app" "$nconf/keymap.conf"'
check "keymap has no agtermctl" '! grep -q agtermctl "$nconf/keymap.conf"'
check "ghostty theme is hangar" '[ "$(head -1 "$nconf/ghostty.conf")" = "theme = light:hangar,dark:hangar" ]'
check "denylist byte-identical" 'cmp -s "$conf/restore-denylist.conf" "$nconf/restore-denylist.conf"'
check "hooks.conf path renamed" 'grep -qx "on status ~/.config/hangar/hooks/status.sh" "$nconf/hooks.conf"'
check "hook script renamed, mode kept" 'grep -q "^hangarctl notify \"\$AGT_EVENT_STATUS\"" "$nconf/hooks/status.sh" && [ "$(stat -f %Lp "$nconf/hooks/status.sh")" = 755 ]'
check "agent-status scripts not copied" '[ ! -e "$nconf/agent-status" ]'
check "no temp dirs left" '[ -z "$(ls -a "$H/.config" "$H/Library/Application Support" | grep migrating)" ]'

check "claude settings: only agterm hooks and mod dir removed" 'cmp -s "$root/expected-settings.json" "$H/.claude/settings.json" || diff "$root/expected-settings.json" "$H/.claude/settings.json"'
check "claude settings mode kept" '[ "$(stat -f %Lp "$H/.claude/settings.json")" = 600 ]'
check "agterm skill removed" '[ ! -e "$H/.claude/skills/agterm" ]'
check "other skill kept" '[ -f "$H/.claude/skills/mine/SKILL.md" ]'
check "unmarked codex skill kept" '[ -f "$H/.codex/skills/agterm/SKILL.md" ]'
check "codex block removed" '[ "$(cat "$H/.codex/config.toml"; echo x)" = "$(printf "%sx" "$codex_user")" ]'
check "zshrc block removed" '[ "$(cat "$H/.zshrc"; echo x)" = "$(printf "%sx" "$rc_user")" ]'
check "bashrc edited through its symlink" '[ -L "$H/.bashrc" ] && [ "$(cat "$H/dotfiles/bashrc"; echo x)" = "$(printf "%sx" "$rc_user")" ]'
check "fish block removed" '[ "$(cat "$H/.config/fish/config.fish")" = "set -x EDITOR vim" ]'
check "pi extension removed" '[ ! -e "$H/.pi/agent/extensions/agterm-status.ts" ]'
check "opencode plugins removed" '[ ! -e "$H/.config/opencode/plugins/agterm-status.js" ] && [ ! -e "$H/.config/opencode/plugins/agterm-v2" ]'
check "user opencode plugin kept" '[ -f "$H/.config/opencode/plugins/mine.js" ]'
check "old state dir unchanged" '[ "$(snap "$state")" = "$old_state_snap" ]'
check "old config dir unchanged" '[ "$(snap "$conf")" = "$old_conf_snap" ]'
check "summary lists what is left" 'grep -q "Accessibility" "$root/run1.out" && grep -q "pair" "$root/run1.out"'

after="$(snap "$H")"
run > "$root/run2.out" 2>&1
code=$?
check "second run exits 0" '[ $code -eq 0 ]'
check "second run changes nothing" '[ "$(snap "$H")" = "$after" ]'

echo
[ $fails -eq 0 ] && echo "PASS" || { echo "FAILED: $fails"; exit 1; }
