# Claude row stays active while a scheduled wakeup is pending

**Intent:** a Claude Code session that runs `/loop` shows idle between wakeups. The user wants it to show in progress.

**Goal:** on `Stop`, if Claude will wake itself later, the row stays `active --blink` instead of `completed`.

**Non-goals:** telling `/loop` apart from other scheduled tasks; showing the next fire time.

**Constraint:** Claude Code 2.1.326 sends `session_crons` in the `Stop` payload: "Session-scoped cron tasks (CronCreate, ScheduleWakeup, /loop) that will wake this session later. Empty array when none are scheduled."

## Approaches

- **A (picked by the user): any session cron keeps the row active.** One rule. A job scheduled far ahead keeps the row blinking until it fires or is deleted.
- **B: only `/loop` wakeups.** The payload has no `/loop` flag, so the script would guess from the cron text. Rejected as fragile.

## Design

In `agterm/Resources/agent-status/agterm-claude-status.sh`, the main-agent `Stop` + `completed` branch posts `active --blink` when `session_crons` has at least one entry, the same rewrite a running subagent gets.
A wakeup's own `UserPromptSubmit` keeps the row active; a later `Stop` with an empty list completes it.
Remote sessions run the same installed script, so they need no separate path.
