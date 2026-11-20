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

## Prompt dialogs (`card-*`)

Claude Code 2.1.329, captured 2026-11-20 the same way, with made-up prompts that quote the question, labels or command (the echo above the dialog).
Each 100-column grid is the same dialog as its 45-column twin, after a resize.
`<name>.pending.json` is the `pending` array plan A emits for it, from the capture session's transcript; states reached by keys share their dialog's call.

| Fixture | State | Layout | Widths |
|---|---|---|---|
| `card-ask-single` | one single-choice question with descriptions; label 2 wraps at 45 | fullscreen | 45, 100 |
| `card-ask-numbers` | labels `7` and `42` | fullscreen | 45, 100 |
| `card-ask-other-open` | after digit 4: `❯` on Other, footer has `ctrl+g to edit in nano` | fullscreen | 45, 100 |
| `card-ask-other-filled` | after pasting `two\nlines` into Other | fullscreen | 45, 100 |
| `card-ask-multi` | one multiSelect question, nothing ticked | fullscreen | 45, 100 |
| `card-ask-multi-ticked` | digits 1 and 3: rows 1 and 3 ticked, `❯` on row 1 | fullscreen | 45, 100 |
| `card-ask-multi-other` | Down ×3, `a spare lens` pasted: Other ticked, `❯` on it | fullscreen | 45, 100 |
| `card-ask-two` | two questions; the 14-character header is cut to `Watch sched…` at 45 (`Environment` fits) | fullscreen | 45, 100 |
| `card-ask-two-second` | digit 1: the second question shown | fullscreen | 45, 100 |
| `card-ask-review` | digit 1 again: Review with `→` lines, `Submit answers` and `Cancel` | fullscreen | 45, 100 |
| `card-ask-preview` | preview layout: the box beside the options, unnumbered "Chat about this", no Other row | fullscreen | 45, 100 |
| `card-ask-preview-notes` | after `n`: the notes field | fullscreen | 100 |
| `card-bash` | Bash with 4 options; the command breaks mid-word at 45 and has no `│` bars at either width | fullscreen | 45, 100 |
| `card-bash-amend` | Tab on Yes: "Yes, and tell Claude what to do next" | fullscreen | 45, 100 |
| `card-bash-no-amend` | Down ×3 and Tab | fullscreen | 45, 100 |
| `card-bash-classic` | `card-bash` in the classic TUI (`tui: default`) | classic | 100 |
| `card-write`, `card-edit` | file prompts; the header path is `…`-truncated at 45 and relative at 100 | fullscreen | 45, 100 |
| `card-mcp` | `mcp__claude_ai_Claude_Docs__guide`, `items: ["topic.index"]`; Yes and No at 45, a "don't ask again" row added at 100 | fullscreen | 45, 100 |
| `card-webfetch` | WebFetch, `url:` row, "No, and tell Claude…"; asked by an in-process general-purpose subagent, because the main session had no WebFetch tool | fullscreen | 45, 100 |
| `card-subagent-bash` | in-process subagent (`teammateMode: in-process`, agent teams off): `· from the general-purpose agent`; no `agentName`, the Agent call set none | fullscreen | 45, 100 |
| `card-plan` | plan approval, `❯` on "Yes, and use auto mode", basename wrapped in the footer at 45 | fullscreen | 45, 100 |
| `card-plan-change` | digit 3: "Tell Claude what to change" focused | fullscreen | 45, 100 |
| `card-plan-nofile` | "Exit plan mode?" with no plan, `input: {}`; captured, not synthetic: a hook denied the plan-file Write | fullscreen | 45 |

`card-plan.pending.json` keeps the captured `ExitPlanMode` input: keys `plan` and `planFilePath`, the home folder's user name replaced with `keeper`.
`card-webfetch` and `card-subagent-bash` carry `source` (the bare `agentId`) and `agentType` from `.meta.json`.

`panel-usage-45` is redacted by hand: the reset time, usage figures, counts and skill and subagent names are neutral text in the captured layout.
The 100-column grids carry an OSC 8 `/rc` link whose session id is replaced with `session_REDACTED`.
Claude writes U+00A0, not a space, after the input row's `❯`.
Every grid carries rows from the capturing setup, not from Claude itself: the `● full …` band above the composer (a plugin), the custom statusline, and `← 2 agents` on the mode line; never anchor on them.
