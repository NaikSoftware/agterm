# agterm-qt

A Qt/KDE port of [agterm](https://github.com/umputun/agterm) (NaikSoftware fork): a terminal organised as named
workspaces of sessions, with a control API so coding agents and scripts can drive it and report whether they are
working, blocked, or done. The target is feature parity with agterm `master`; [docs/PARITY.md](docs/PARITY.md)
tracks what is ported and what is not yet.

Each terminal is a Konsole KPart, so Konsole's profiles, colour schemes, scrollback, search and copy/paste work as
in Konsole.

## Build and install

Needs Qt 6 (Widgets, Network, DBus, Svg), KDE Frameworks 6 (CoreAddons, XmlGui, Config, Notifications, KParts) and
`konsole-kpart`.

```sh
sudo apt install libkf6parts-dev   # or, without root: scripts/fetch-kparts-headers.sh
cmake -S . -B build
cmake --build build -j
ctest --test-dir build              # core, file panel, offscreen UI tests
scripts/smoke.sh                    # end-to-end over the control socket
cmake --install build --prefix ~/.local
```

## What it does

- Workspaces of sessions in a sidebar. A workspace remembers the folder its sessions last worked in, and new
  sessions open there. Its "+" (on hover) starts Terminal, Claude Code, Codex, OpenCode or Antigravity (whichever
  your login shell finds), and the button beside it repeats the last choice.
- A session row shows the logo of the agent running in it, its status dot (active, blocked, completed), an unseen
  notification count, and a filled icon when flagged. Companions sit indented under their parent.
- Rename inline (double-click), multi-select, drag to reorder or move between workspaces, and drop folders from the
  file manager to open sessions there. The footer has New Session, New Workspace and the flagged view.
- Splits, terminal zoom, full screen.
- Session (Ctrl+P) and action (Ctrl+Shift+P) palettes, a Ctrl-Tab recent-session switcher, and reopen-closed.
- A file panel (the session folder as a tree with file-type icons, a built-in viewer, clipboard, drag and drop).

## Keys

agterm's ⌘ is Ctrl+Shift here (Konsole's convention); ⌘⇧ and ⌘⌃ are Ctrl+Alt+Shift; ⌃ stays Ctrl; ⌥ is Alt.

| Key | Action |
| --- | --- |
| Ctrl+Shift+N / Ctrl+Alt+Shift+N | New session / new workspace |
| Ctrl+Shift+O | Open directory as a session |
| Ctrl+Shift+W | Close session (leaves terminal zoom first) |
| Ctrl+Alt+Shift+T | Reopen closed session |
| Ctrl+Shift+D / Ctrl+Alt+Shift+D | Split side by side / top and bottom (again: hide; the other: transpose) |
| Ctrl+Alt+Shift+← / → | Focus left / right pane |
| Ctrl+Alt+Shift+Return | Terminal zoom |
| F11 | Full screen |
| Ctrl+Alt+Shift+S / Ctrl+Alt+Shift+E | Toggle sidebar / file panel |
| Ctrl+Alt+Shift+↑ / ↓ | Previous / next session |
| Ctrl+Alt+↑ / ↓ | Previous / next session needing attention |
| Ctrl+P / Ctrl+Shift+P / Ctrl+Tab | Session palette / action palette / recent sessions |
| Ctrl+Alt+Shift+F | Flag session |

## Agent status

```sh
scripts/install-claude-hooks.sh     # adds Claude Code hooks to ~/.claude/settings.json (backed up first)
```

The hooks run agterm's own status adapter (a no-op outside agterm-qt). Typing into a blocked or completed session
clears its dot (Settings sets on the first key, on Enter, or never).

## Control API

Every pane exports `AGTERM_SESSION_ID`, `AGTERM_WORKSPACE_ID`, `AGTERM_PANE`, `AGTERM_SOCKET` and `AGTERMCTL`, so
`agtermctl` inside a pane addresses its own session. Targets are an id, a unique id prefix, an exact name, or
`active`. `agtermctl --help` lists the commands; the wire format is agterm's (one JSON request line, one response
line) on `<state dir>/agterm.sock`. The state dir is `~/.local/share/agterm-qt`, or `AGTERM_STATE_DIR`.
