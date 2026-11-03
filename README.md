# agterm-qt

A Qt/KDE port of [agterm](https://github.com/umputun/agterm): a terminal organised as named workspaces of
sessions, with a control API so coding agents (and scripts) can drive it and report whether they are working,
blocked, or done.

Each session is a real Konsole terminal (the Konsole KPart), so profiles, colour schemes, scrollback, search and
copy/paste behave exactly as in Konsole. The window follows the Plasma colour scheme, light or dark.

## Build and install

Needs Qt 6, KDE Frameworks 6 (CoreAddons, XmlGui, Notifications, ColorScheme, Config) and the Konsole KPart
(`konsole-kpart`).

```sh
sudo apt install libkf6parts-dev   # or, without root: scripts/fetch-kparts-headers.sh
cmake -S . -B build
cmake --build build -j
ctest --test-dir build              # core + offscreen UI tests
scripts/smoke.sh                    # end-to-end over the control socket
cmake --install build --prefix ~/.local
```

The install adds `agterm-qt` and `agtermctl` to `~/.local/bin` and an `agterm` launcher entry.

## Agent status

```sh
scripts/install-claude-hooks.sh     # adds Claude Code hooks to ~/.claude/settings.json (backed up first)
```

The hooks run agterm's own status adapter, which does nothing outside agterm-qt. A session then shows:

- a spinner while Claude works;
- an orange mark when it waits for you;
- a check when it finishes.

A desktop notification fires when a session that isn't in front of you needs attention.
Typing into the session clears "blocked" or "done". Ctrl+Alt+↓ / ↑ jumps between sessions that need you.

## Control API

Every pane exports `AGTERM_SESSION_ID`, `AGTERM_WORKSPACE_ID`, `AGTERM_SOCKET` and `AGTERMCTL`, so `agtermctl` run
inside a pane addresses its own session by default. Targets are an id, a unique id prefix, an exact name, or `active`.

```sh
agtermctl tree
agtermctl session new --name api --cwd ~/src/api --workspace-name backend --create-workspace
agtermctl session type $'make test\n' --target api
agtermctl session text --target api --lines 40
agtermctl session status blocked
agtermctl session go --to next-attention
agtermctl --help
```

The wire format is agterm's: one JSON request line, `{"cmd","target","args"}`, then one response line,
`{"ok","result"|"error"}`, on `<state dir>/agterm.sock`.
The state dir is `~/.local/share/agterm-qt`; `AGTERM_STATE_DIR` overrides it, for example to run an isolated
second instance.

## Keys

| Key | Action |
| --- | --- |
| Ctrl+Shift+T | New session (in the current session's directory) |
| Ctrl+Shift+N | New workspace |
| Ctrl+Shift+R | Rename session |
| Ctrl+Shift+W | Close session (asks if a program is still running) |
| Ctrl+PgDown / Ctrl+PgUp | Next / previous session |
| Ctrl+Alt+↓ / Ctrl+Alt+↑ | Next / previous session needing attention |
| Ctrl+Shift+B | Toggle sidebar |
| Ctrl+Shift+M | Toggle menu bar (also behind the ☰ button) |

Konsole's own keys (Ctrl+Shift+C/V, Ctrl+Shift+F, …) work as usual.
The app's terminal profile is `agterm-qt` in Konsole's profile list. Change it, or pick another one, from
Settings ▸ Manage Profiles.

## Not ported (yet)

Split panes, overlays and HUDs, live sessions surviving an app restart (zmx), the file panel, flags and tints,
the keymap and custom commands, ask/pick dialogs, messages, multiple windows, the quick terminal, and most of
the ~140 control commands. Sessions restore as fresh shells in their last directory.
