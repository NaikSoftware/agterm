# Captured Claude Code grids

`tmux capture-pane -p -e` captures of Claude Code 2.1.329 (`--model haiku --permission-mode default`), taken 2026-11-20
in a private tmux server with the worktree as cwd and every inherited `ELIS_*`, `GHOSTTY_*` and `CLAUDE*` variable unset.
`test/support/ansi.dart` replays them into a `Grid`. The name ends in the width; 45-column grids are 40 rows, 100-column grids 30.
Layout is the fullscreen TUI (alternate screen) unless the name starts with `classic`.

| Fixture | State | Layout | Widths |
|---|---|---|---|
| `idle-placeholder` | fresh session, dim `Try "…"` on `❯` | fullscreen | 45, 100 |
| `idle-suggestion` | after a turn, dim predicted prompt on `❯` | fullscreen | 45 |
| `idle-draft` | typed draft `hello there`, not sent | fullscreen | 45 |
| `idle-draft-multiline` | two-line draft | fullscreen | 45 |
| `idle-draft-wrapped` | three-line draft, the middle line wrapped over 2 rows | fullscreen | 45 |
| `idle-no-statusline` | statusline command printing nothing (`statusLine: null` is rejected as invalid settings) | fullscreen | 45 |
| `working` | a reply being written, `esc to interrupt`; this build drops the spinner row while text streams | fullscreen | 45, 100 |
| `working-thinking` | spinner row before the reply starts (`✽ Wrangling… (2s · ↓ 40 tokens · thinking)`) | fullscreen | 45 |
| `working-wrapped` | spinner status `running PreToolUse hooks…` wrapped over 2 rows | fullscreen | 45 |
| `queued` | `⎿  Queued` row and `Press up to edit queued messages` | fullscreen | 45 |
| `interrupted-queued` | Esc while queued: `⎿  Interrupted · What should Claude do ins…`, the queued prompt working | fullscreen | 45 |
| `mode-accept`, `mode-plan`, `mode-auto` | after 1, 2, 3 Shift+Tab from manual mode | fullscreen | 45 |
| `shell` | a background `sleep`: `· 1 shell` | fullscreen | 45 |
| `paste-placeholder` | five-line bracketed paste: `[Pasted text #1 +4 lines]` | fullscreen | 45 |
| `paste-inline` | three-line bracketed paste, shown inline | fullscreen | 45 |
| `slash-menu` | `/mo` typed, the menu open | fullscreen | 45 |
| `bash-mode` | `!` typed: shell input mode | fullscreen | 45 |
| `dialog-bash` | Bash permission prompt for `ls /tmp` (declined afterwards) | fullscreen | 45, 100 |
| `dialog-ask` | AskUserQuestion, Apple or Banana | fullscreen | 45, 100 |
| `panel-model`, `panel-usage` | `/model`, `/usage` | fullscreen | 45 |
| `ctrl-o` | Ctrl+O detailed transcript | fullscreen | 45 |
| `classic-idle`, `classic-working` | classic TUI (`tui: default`), main screen | classic | 100 |
| `limit` | **synthetic**: `idle-placeholder-45` with the usage-limit lines inserted above the composer; the state cannot be produced on demand | fullscreen | 45 |

`panel-usage-45` is redacted by hand: the reset time, usage figures, counts and skill and subagent names are neutral text in the captured layout.
The 100-column grids carry an OSC 8 `/rc` link whose session id is replaced with `session_REDACTED`.
Claude writes U+00A0, not a space, after the input row's `❯`.
Every grid carries rows from the capturing setup, not from Claude itself: the `● full …` band above the composer (a plugin), the custom statusline, and `← 2 agents` on the mode line; never anchor on them.
