#!/bin/bash
# One-time move from Agterm2 to Hangar. Run it once after you install Hangar and before Hangar first starts.
# It copies your sessions and config, removes what Agterm2 installed for agents, and leaves the old dirs as a backup.
# Safe to run twice.
#
#   migrate-from-agterm2.sh [--dry-run] [--home DIR]
#
# --home works on a fake home (for tests): it skips the running-app check, the old daemons and /usr/local/bin.
set -euo pipefail

home="$HOME"
isolated=0
dry=0
while [ $# -gt 0 ]; do
    case "$1" in
        --home) home="${2:?--home needs a directory}"; isolated=1; shift 2 ;;
        --dry-run) dry=1; shift ;;
        -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -d "$home" ] || { echo "no such home: $home" >&2; exit 2; }
python3 -I -c 'import json, shutil' 2>/dev/null || {
    echo "python3 is required. Install the Xcode command line tools: xcode-select --install" >&2; exit 1; }

did=""
left=""
note_did() { did="$did  - $1"$'\n'; }
note_left() { left="$left  - $1"$'\n'; }
say() { [ $dry -eq 1 ] && echo "would $1" || echo "$1"; }

if [ $isolated -eq 0 ]; then
    for id in ua.naiksoftware.agterm2 ua.naiksoftware.hangar; do
        name=$([ $id = ua.naiksoftware.hangar ] && echo Hangar || echo agterm)
        # pgrep also covers a session where lsappinfo cannot reach the window server (ssh)
        if [ -n "$(lsappinfo find "bundleid=$id" 2>/dev/null)" ] || pgrep -x "$name" >/dev/null 2>&1; then
            echo "Quit $([ $name = Hangar ] && echo Hangar || echo Agterm2) first, then run this again." >&2
            exit 1
        fi
    done

    # zmx daemons and session hosts of the old state dir listen under /tmp/agterm-zmx-<FNV-1a of the state dir>
    zdir="$(python3 -I -c '
import os, sys
h = 14695981039346656037
for b in os.path.realpath(sys.argv[1]).encode():
    h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
print("/tmp/agterm-zmx-%016x" % h)' "$home/Library/Application Support/agterm")"
    pids="$(lsof -nP -U -F pcn 2>/dev/null | awk -v a="$zdir/" -v b="/private$zdir/" '
        /^p/ { p = substr($0, 2) } /^c/ { c = substr($0, 2) }
        /^n/ { n = substr($0, 2); if ((index(n, a) == 1 || index(n, b) == 1) && (c == "zmx" || c == "agterm-session-host")) print p }' | sort -u || true)"
    if [ -n "$pids" ]; then
        count=$(echo "$pids" | wc -l | tr -d ' ')
        if [ $dry -eq 0 ]; then
            # shellcheck disable=SC2086
            kill -TERM $pids 2>/dev/null || true
            for _ in 1 2 3 4 5 6 7 8 9 10; do
                alive=""; for p in $pids; do kill -0 "$p" 2>/dev/null && alive="$alive $p"; done
                [ -z "$alive" ] && break; sleep 0.5
            done
            [ -n "$alive" ] && note_left "old session processes still running, stop them: kill$alive"
        fi
        note_did "$(say "stop $count old session processes (zmx, agterm-session-host) under $zdir")"
    fi
fi

# read first: bash 3.2 misparses a quoted heredoc inside $(...)
IFS= read -r -d '' migrate_py <<'PY' || true
import json, os, re, shutil, stat, sys

home, dry, isolated = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
env_codex, env_opencode, env_xdg = (sys.argv[4:7] if not isolated else ("", "", ""))
old_status = home + "/.config/agterm/agent-status/"

def did(msg): print("D " + ("would " + msg if dry else msg))
def left(msg): print("L " + msg)
def short(p): return "~" + p[len(home):] if p.startswith(home + "/") else p

# surrogateescape round-trips a stray Latin-1 byte in an rc file unchanged
def read(p):
    with open(p, encoding="utf-8", errors="surrogateescape") as f: return f.read()

def write(p, text):
    # in place: keeps the mode and writes through a dotfiles symlink; the first edit keeps a backup
    if dry: return
    bak = p + ".pre-hangar"
    if not os.path.lexists(bak): shutil.copy2(os.path.realpath(p), bak)
    with open(p, "w", encoding="utf-8", errors="surrogateescape") as f: f.write(text)

def step(path, fn, *args):
    # one unreadable file must not stop the cleanup of the others
    try: fn(path, *args)
    except OSError as e: left(f"could not edit {short(path)} ({e.strerror}): remove the agterm entries from it yourself.")

RENAMES = [
    (re.compile(r"agtermctl"), "hangarctl"),
    (re.compile(r"AGTERM_"), "HANGAR_"),
    (re.compile(r"(?<=\.config/)agterm(?![\w.])"), "hangar"),
    (re.compile(r"(?<=Application Support/)agterm(?![\w.])"), "hangar"),
    (re.compile(r"(?<=Application\\ Support/)agterm(?![\w.])"), "hangar"),
    (re.compile(r"(?<![\w.-])agterm\.app(?![\w])"), "Hangar.app"),
    (re.compile(r"(?<=Contents/MacOS/)agterm(?![\w.-])"), "Hangar"),
    (re.compile(r"(?<![\w.-])agterm(?=\.(?:sock|lock)\b)"), "hangar"),
    (re.compile(r"(?<![\w.-])agterm(?=://)"), "hangar"),
]
THEME_LINE = re.compile(r"^(\s*theme\s*=.*)$", re.M)
THEME_WORD = re.compile(r"(?<![\w./-])agterm(?![\w./-])")

def rename_config_text(text):
    for pattern, new in RENAMES: text = pattern.sub(new, text)
    return THEME_LINE.sub(lambda m: THEME_WORD.sub("hangar", m.group(1)), text)

OLD_CONFIG = {"~/.config/agterm", home + "/.config/agterm"}

def rename_settings(text):
    # only the theme values and a config dir set to the old default: other strings belong to the user
    text = re.sub(r'("(?:theme|darkTheme)"\s*:\s*")([^"]*)(")',
                  lambda m: m.group(1) + THEME_WORD.sub("hangar", m.group(2)) + m.group(3), text)
    return re.sub(r'("configDirectory"\s*:\s*")([^"]*)(")',
                  lambda m: m.group(1) + (m.group(2)[:-6] + "hangar" if m.group(2).replace("\\/", "/") in OLD_CONFIG
                                          else m.group(2)) + m.group(3), text)

def copy_dir(src, dst, skip_top, rewrite):
    if not os.path.isdir(src): return
    if os.path.lexists(dst):
        left(f"{short(dst)} already exists, so nothing was copied from {short(src)}. "
             "If Hangar started before this script, quit it, move that folder away and run this again.")
        return
    did(f"copy {short(src)} to {short(dst)}")
    if dry: return
    tmp = dst + ".migrating"
    if os.path.lexists(tmp): shutil.rmtree(tmp)
    def ignore(d, names):
        out = set()
        for n in names:
            mode = os.lstat(os.path.join(d, n)).st_mode
            if stat.S_ISSOCK(mode) or stat.S_ISFIFO(mode) or (d == src and n in skip_top): out.add(n)
        return out
    shutil.copytree(src, tmp, symlinks=True, ignore=ignore)
    for d, _, files in os.walk(tmp):
        for n in files:
            p = os.path.join(d, n)
            if os.path.islink(p): continue
            try:
                with open(p, encoding="utf-8") as f: text = f.read()
            except (UnicodeDecodeError, OSError): continue  # binary or unreadable: copied as is
            new = rewrite(os.path.relpath(p, tmp), text)
            if new != text:
                with open(p, "w", encoding="utf-8") as f: f.write(new)
    os.rename(tmp, dst)

state_src = home + "/Library/Application Support/agterm"
copy_dir(state_src, home + "/Library/Application Support/hangar", {"agterm.lock", "agterm.sock", "agterm.sock.lock"},
         lambda rel, t: rename_settings(t) if rel == "settings.json" else t)
copy_dir(home + "/.config/agterm", home + "/.config/hangar", {"agent-status"}, lambda rel, t: rename_config_text(t))
try:
    custom = json.loads(read(state_src + "/settings.json")).get("configDirectory")
    if custom and custom.rstrip("/") not in OLD_CONFIG: left(f"Settings name a custom config folder ({custom}). Hangar keeps using it: rename agtermctl and AGTERM_ in it yourself.")
except (OSError, ValueError, AttributeError): pass

# Claude Code: the seven hooks and the swarm-companion mod dir, matched by the old script path.
def ours(command):
    return isinstance(command, str) and any(old_status + n in command for n in ("agterm-claude-status.sh", "agterm-agent-status.sh"))

def dump_like(original, obj):
    sep = " : " if re.search(r'"\s:\s', original) else ": "
    m = re.search(r"\n( +)\S", original)
    out = json.dumps(obj, indent=len(m.group(1)) if m else 2, separators=(",", sep), ensure_ascii=False)
    if "\\/" in original: out = out.replace("/", "\\/")  # JSONSerialization escaped slashes; strings are the only place one occurs
    if sep == " : ":  # JSONSerialization also opens empty containers over a blank line; a string value never ends a line in {} or []
        out = re.sub(r"^( *)(.*)([\[{])([\]}])(,?)$", lambda m: f"{m[1]}{m[2]}{m[3]}\n\n{m[1]}{m[4]}{m[5]}", out, flags=re.M)
    return out + ("\n" if original.endswith("\n") else "")

def edit_claude(settings):
    if not os.path.isfile(settings): return
    text = read(settings)
    try: root = json.loads(text)
    except ValueError: root = None; left(f"{short(settings)} is not valid JSON: remove the agterm hooks from it yourself.")
    if isinstance(root, dict):
        removed = 0
        hooks = root.get("hooks")
        if isinstance(hooks, dict):
            for event in list(hooks):
                entries = hooks[event]
                if not isinstance(entries, list): continue
                kept = []
                for entry in entries:
                    cmds = entry.get("hooks") if isinstance(entry, dict) else None
                    if isinstance(cmds, list):
                        rest = [c for c in cmds if not (isinstance(c, dict) and ours(c.get("command")))]
                        if len(rest) != len(cmds):
                            removed += len(cmds) - len(rest)
                            if not rest: continue
                            entry["hooks"] = rest
                    kept.append(entry)
                if len(kept) != len(entries) or removed:
                    if kept: hooks[event] = kept
                    elif entries: del hooks[event]
            if removed and not hooks: del root["hooks"]
        mod = old_status + "claude-mods/swarm-companion"
        env = root.get("env")
        dropped = False
        if isinstance(env, dict) and isinstance(env.get("CLAUDE_CODE_PLUGIN_DIRS"), str):
            dirs = env["CLAUDE_CODE_PLUGIN_DIRS"].split(":")
            if mod in dirs:
                dropped = True
                rest = [d for d in dirs if d != mod]
                if rest: env["CLAUDE_CODE_PLUGIN_DIRS"] = ":".join(rest)
                else: del env["CLAUDE_CODE_PLUGIN_DIRS"]
                if not env: del root["env"]
        if removed or dropped:
            write(settings, dump_like(text, root))
            did(f"remove {removed} agterm hooks{' and the swarm-companion mod' if dropped else ''} from {short(settings)}")

step(home + "/.claude/settings.json", edit_claude)

def strip_block(path, begin, end, owned):
    if not os.path.isfile(path): return
    text = read(path)
    lines = text.split("\n")
    stripped = [l.strip() for l in lines]
    if begin not in stripped: return
    b = stripped.index(begin)
    if end not in stripped[b + 1:]: return
    e = stripped.index(end, b + 1)
    if not owned("\n".join(lines[b + 1:e])): return
    if b > 0 and not stripped[b - 1]: b -= 1
    del lines[b:e + 1]
    write(path, "\n".join(lines))
    did(f"remove the agterm block from {short(path)}")

BEGIN, END = "# >>> agterm agent-status >>>", "# <<< agterm agent-status <<<"
for rc in (".zshrc", ".bashrc", ".config/fish/config.fish"):
    step(f"{home}/{rc}", strip_block, BEGIN, END, lambda body: old_status + "shell/integration" in body)
codex = env_codex if env_codex.startswith("/") else home + "/.codex"
# the whole block goes, Codex's [hooks.state] trust records with it: a leftover `hooks` key stops Hangar adding its own
step(codex + "/config.toml", strip_block, BEGIN, END,
     lambda body: "agterm-codex-status.sh" in body or "agterm-agent-status.sh" in body)

def remove_marked(path, marker, what):
    if os.path.islink(path) or not os.path.exists(path): return
    probe = path + "/SKILL.md" if os.path.isdir(path) else path
    try: mine = marker in read(probe)
    except (OSError, UnicodeDecodeError): mine = False
    if not mine:
        left(f"{short(path)} was not installed by Agterm2, so it stays. Remove it if you do not need it.")
        return
    did(f"remove {what} {short(path)}")
    if dry: return
    if os.path.isdir(path): shutil.rmtree(path)
    else:
        os.unlink(path)
        parent = os.path.dirname(path)
        if os.path.basename(parent) == "agterm-v2" and not os.listdir(parent): os.rmdir(parent)

for base in (home + "/.claude", codex):
    step(base + "/skills/agterm", remove_marked, "<!-- agterm-skill -->", "the agterm skill")
step(home + "/.pi/agent/extensions/agterm-status.ts", remove_marked, "// agterm-pi-status-extension", "the Pi extension")
opencode = {home + "/.config/opencode"}
if env_opencode: opencode.add(env_opencode)
if env_xdg: opencode.add(env_xdg + "/opencode")
for d in sorted(opencode):
    step(d + "/plugins/agterm-status.js", remove_marked, "// agterm-opencode-status-plugin", "the OpenCode plugin")
    step(d + "/plugins/agterm-v2/tui.js", remove_marked, "// agterm-opencode-v2-status-plugin", "the OpenCode plugin")
PY
python_out="$(python3 -I -c "$migrate_py" "$home" "$dry" "$isolated" "${CODEX_HOME:-}" "${OPENCODE_CONFIG_DIR:-}" "${XDG_CONFIG_HOME:-}")" || { echo "$python_out"; echo "Migration stopped with an error. The old folders are untouched; fix the error and run this again." >&2; exit 1; }

while IFS= read -r line; do
    case "$line" in
        "D "*) note_did "${line#D }" ;;
        "L "*) note_left "${line#L }" ;;
    esac
done <<< "$python_out"

if [ $isolated -eq 0 ]; then
    link=/usr/local/bin/agtermctl
    if [ -L "$link" ]; then
        case "$(readlink "$link")" in
            */agterm.app/Contents/MacOS/agtermctl)
                if [ $dry -eq 1 ]; then note_did "would remove $link"
                elif rm -f "$link" 2>/dev/null; then note_did "remove $link"
                else note_left "remove the old command line link: sudo rm $link"; fi ;;
            *) note_left "$link does not point into agterm.app, so it stays." ;;
        esac
    fi
fi

echo "Agterm2 to Hangar migration$([ $dry -eq 1 ] && echo ' (dry run, nothing changed)')"
echo
echo "Done:"
printf '%s' "${did:-  - nothing to do; it already ran}"
[ -z "$did" ] && echo
echo
echo "Left for you:"
printf '%s' "$left"
cat <<'EOF'
  - Remove agterm.app (Agterm2) from Applications. The old folders ~/Library/Application Support/agterm
    and ~/.config/agterm stay as a backup; delete them when Hangar works.
  - Start Hangar. It installs hangarctl, the agent skill and the agent hooks itself.
  - Grant Accessibility and other macOS permissions again (System Settings > Privacy & Security).
  - Install the Hangar phone app and pair it again.
  - Sign in again to web pages you open in overlays.
  - Two Macs that attach to each other must both run Hangar.
EOF
