# Phone Chat mode for Claude Code — design

Status: for planning (milestone M6 of [the stream design](2026-11-18-phone-terminal-stream-design.md)).
Tags: **[owner]** = owner decision of 2026-11-19/20; **[lead]** = the lead's call, not confirmed by the owner;
**[writer]** = a rule this document adds to close a gap, open to the lead.
Evidence tags on keystrokes: **[45]** seen at 45 columns through tmux `send-keys`/`paste-buffer -p`, **[100]** seen only at 100 columns,
**[unproven]** never seen. No key or paste has been seen through the phone → relay → zmx path yet (open checks 1-2).
"Scope call N" points to [scope calls](#scope-calls), which the lead made under the owner's delegation of 2026-11-20.
Research notes cited below sit in the session scratchpad
(`/private/tmp/claude-502/-Users-n-savchenko-IdeaProjects-elis/96123572-0e60-465e-958a-b0ed3100d48a/scratchpad/`);
`narrow-protocol.md` is authoritative over `live.md` and `design.md`.

## Intent and why

The phone shows a Claude Code session today as a terminal grid (Term).
At phone width, Claude's TUI is hard to read, to scroll and to answer.
Chat draws the same conversation as a native, full-featured chat UI, built from Claude's transcript file,
and answers Claude's prompts with native cards.
Chat is the owner's top priority, and its functionality is as complete as possible. **[owner]**

## Goals, non-goals, anti-goals

Goals:
- Chat shows every message, tool call, diff, prompt and live state the TUI shows, in a form made for a phone. **[owner]**
- Chat answers AskUserQuestion, permission prompts and plan approval with native cards. **[owner]**
- Chat works the same for a local session, a session attached from another Mac, and an elis-server session. **[owner]**
- Every capability has control API coverage: protocol, dispatcher, `elisctl`, tests, docs and skill. **[owner]**

Non-goals (v1):
- Chat in the Linux Qt app: it stays disabled there; a C++ port comes later. **[owner]**
  This is the owner-approved remote exception.
- Adapters other than Claude Code; codex comes after M6. **[owner]**
- Opening a subagent as its own chat (dropped by the owner; subagent rows stay). **[owner]**
- The items in [What is later](#what-is-later).

Anti-goals:
- A key the phone sends lands on a prompt the user did not see. The [write gate](#write-gate) narrows this per write;
  it cannot close it, and open check 3 measures what is left. **[lead]**
- A card, banner, chip or sheet stays on screen after the thing it describes is gone.
- Chat scrolls, resizes or otherwise changes Claude's view on the Mac. **[lead]**
- A phone request names a file path on the host.
- Chat computes numbers that can disagree with Claude's own display (context %, cost). **[lead]**

## Constraints

- A session can run any program. Chat is one of two modes, Chat and Term; Text is dropped. **[owner]**
- Auto-pick: a program with an adapter shows Chat, anything else shows Term. **[owner]**
- Chat is disabled, never hidden, without an adapter. A manual pick sticks until the user picks Auto. **[owner]**
- `ElisCore` holds parsing, paging and catalogs; the app target and elis-server are adapters.
- ElisCore imports no CoreGraphics, so it cannot scale images.
- A key or gesture does one thing for what the user sees.
- A control that exists elsewhere in the app looks and behaves the same.
- The relay closes a phone with more than 4 MiB of unsent answers.
- Each call times out after 15 s (`mobile/lib/link/client.dart:220`); Bluetooth carries 4096-byte chunks.
- Channel-0 lines are split into frames and joined again (`mobile/lib/link/mux.dart:109-113`, `:129`), so 64 KiB is not a reply cap.
- Transcript files only grow, one record per line; the largest file seen was 71 MB and the largest line 1.34 MB.
- Every screen anchor comes from one Claude Code build (2.1.328).
  Each classifier needs captured grid fixtures and a fallback to the live rows.
- This design supersedes two clauses of the stream design's "Session view" section:
  "Chat never interprets the screen …" and "never a guess about the program".
  New rule: content comes from the transcript; the screen only confirms which prompt is up and supplies its option rows. **[owner]**
  Editing the stream design is left to the lead.

## Approaches

### Transport

| | How | Cost | Trade-off |
|---|---|---|---|
| **A (picked) [owner]** | One read command `session.transcript`; parser in ElisCore; ~48 KiB pages, byte-offset cursor, echoed transcript id; tool output clipped to ~4 KiB inline; phone polls | ~1,500 lines | Expanded output stops at ~4 KiB ("full output in Term"); pages carry bodies nobody expands |
| B | As A, but tool items carry no body; `--tool <id> --at <offset>` fetches up to ~40 KiB on tap | ~1,900 lines | Second protocol mode; one ssh round trip per tap on remote rows |
| C | As A, plus a host file watcher and a new `transcript` event | ~2,100 lines | New event kind on three hosts, a watcher lifecycle, remote event forwarding |

B's detail fetch and C's push stay clean upgrades if clipped output or poll cost become a problem.

### Prompt answers

| | How | Verdict |
|---|---|---|
| One key per tap | Each card button sends one key | Rejected: a multi-step answer becomes a series of blind taps |
| **Collected sequence (picked) [owner]** | The user builds the whole answer on the card; the phone sends a verified keystroke sequence | Safety rules in [Prompt cards](#prompt-cards) |
| Live rows only | Show the screen rows and a key bar | Kept as the fallback: the [panel sheet](#panel-sheet) |

### Composer

| | How | Verdict |
|---|---|---|
| **Local draft (picked) [owner]** | A native field with autocorrect; text reaches Claude only on Send | Adopts Claude's existing draft on open |
| Live-linked | Every keystroke goes to Claude's `❯` row | Rejected: no autocorrect, keystroke lag over ssh, Claude's menus fight the native field |

## Data sources

| Source | What it is | Owns |
|---|---|---|
| **T** | The transcript JSONL `~/.claude/projects/<dir>/<sessionId>.jsonl` and its `<sessionId>/` sidecars, read on the host that runs Claude | History and structure: messages, tools, diffs, pending tool calls, titles, PR link, permission-mode fallback, todos, subagents, skill listing |
| **G** | The live vt grid the phone already holds through its attach | State never written to a file: statusline rows, spinner line, mode line, shell count, which dialog is open, option rows with their `❯`/`[✔]` state, the `❯` input row, panels, the reply still being written |
| **E** | The Elis tree and events | `agent` (is Claude running now), `agentSessionId` (which transcript; it outlives Claude), `status` (active/blocked/completed), `statusChangedAt`, notifications |

Rules:
- T is the only source of conversation content. G never supplies message text, except in the streaming area.
- G is the only source of "what is on screen now". A card or chip that depends on G clears itself when G stops showing its anchor.
- E's `blocked` is a hint for ordering and alerts only; it never opens or closes a card.
  There is one block per session, and a desktop key clears it while the prompt is still up.

## The Chat screen

### Layout (about 45 columns)

```
┌───────────────────────────────────────────┐
│ ‹ Run Echo Todo Checklist  [💬][◧] ● ⋮    │ app bar: title, mode button, pane button (split only), Elis status,
│   ~/elis · Opus · medium · PR #446        │ ⋮ (holds "Choose mode automatically"); subtitle: cwd, model, PR;
│                                           │ the cwd gives way first; nothing collapses on scroll
├───────────────────────────────────────────┤
│ ❯ Now write 40 short facts about squi…    │ sticky last prompt (tap: jump)
│ ☐ 2/5 · Write tests                ▾      │ todo strip (only while open items)
├───────────────────────────────────────────┤
│                    ┌───────────────────┐  │
│                    │ user message      │  │ user bubble
│                    └───────────────────┘  │
│ markdown reply …                          │ assistant text
│ ▸ Bash  Run unit tests        ✓ 3 passed  │ tool row (tap: clipped output)
│ ▸ Edit  model.dart              +12 −3    │ tool row (tap: diff)
│ ▸ Agent  title-fetch          ◯ running   │ subagent row
│ ▸ Thought for 4s                          │ collapsed thinking
│ ── Conversation compacted ──              │ divider
│ ░ Here are the facts: 1. …                │ streaming area (G rows)
│                               ( ↓ 3 new ) │ jump to bottom, above the composer
├───────────────────────────────────────────┤
│ ✶ Whirlpooling… (11s · ↓ 884 tok)  [Stop] │ working line
│ ⟳ also tell me the date      [Send now]   │ queued messages
│ Context 9% | 5h: 12% | master +2…      ▾  │ statusline: first row, tap expands all
├───────────────────────────────────────────┤
│ [⏸ manual ▾]  · 1 shell                   │ composer accessory row
│ ┌──────────────────────────────┐ [Queue]  │ composer, grows to 6 lines
│ │ /                            │          │ "/" opens the native menu
│ └──────────────────────────────┘          │
└───────────────────────────────────────────┘
```

While a card is up it is docked as a sheet directly above the composer (at most ~60% of the height, content scrolling inside),
with the option buttons stacked full-width at its bottom, the primary nearest the thumb; the list keeps a one-line record of it.
The composer stays visible and disabled. **[lead]**

```
│ ┌ Bash · needs you ─────────────────────┐ │
│ │ $ touch …/probe/x.txt                 │ │
│ │ [ Yes                               ] │ │
│ │ [ No                                ] │ │
│ │ [ Yes, and don't ask again for …    ] │ │ verbatim, outlined, second tap
│ └───────────────────────────────────────┘ │
```

### Elements

"No dialog open" below means the G classifier finds Claude's normal bottom stack: the `❯` input row between its two rules.
"Idle" means no dialog open and no working line on G.

### Write gate **[lead]**

Every write Chat sends goes through one gate: card keys, Send's paste and Enter, Send now, Stop, Cancel and both chips.
The panel sheet's key bar is the user's own keyboard and is exempt.
- One key per write; a paste is one write.
- Right before each write, re-read G and check the state the write expects: the normal bottom stack for composer and chip writes,
  the card's anchor for card keys. A mismatch, or 2 s without the expected change, stops the sequence (card rule 9).
- Enter after a paste goes only once G shows the pasted text, or Claude's `[Pasted text …]` placeholder, on the `❯` input row.
- While a sequence runs, its buttons are locked and show progress ("Sending 2/4"); a second tap does nothing.
- A tick haptic marks a finished sequence, an error buzz a stop.

The gate narrows the race between check and write; open check 3 measures what is left.
Stop and Cancel keep a residual risk: a dialog opening inside that window turns their Esc into No or Cancel.

| Element | Source | Shows / does | Enabled / visible when |
|---|---|---|---|
| Mode switcher | E | One `IconButton` (`modeButton`) first in the session `AppBar` actions: its icon is the mode shown (chat bubble or terminal), a tap picks the other mode; while Chat is unavailable it shows the terminal, disabled, with the reason in its tooltip. On a split, a pane button (`paneButton`) beside it shows the pane on view and a tap shows the other, in both modes. Auto is the `⋮` item "Choose mode automatically", checked while no manual pick holds; a manual pick lasts for that Elis session while the phone app runs **[lead]** | Chat enabled while `agent` is `claude` and `agentSessionId` is known (the pane that runs Claude: scope call 1) |
| Title | T meta | `custom-title` wins over `ai-title`; falls back to the Elis `name` | Always |
| PR link | T meta `pr-link` | `PR #N` in the app bar subtitle; a tap opens `prUrl` | A `pr-link` exists |
| Model | T last assistant `model`, `effort` | `Opus · medium` in the app bar subtitle; dimmed after a `/model` command item until the next assistant record. A tap offers "Change model…", which sends `/model` through Send and opens the panel sheet **[lead]** | Always visible; enabled when idle |
| Elis status | E | Existing `StatusShape` glyph | Always |
| Sticky last prompt | T, computed on the phone | The nearest human prompt above the viewport: `promptSource` `typed`, `queued` or `suggestion_accepted`, or `origin.kind: human`; a tap scrolls the phone list to it **[lead]** | While scrolled up past a prompt |
| Day separator | T `timestamp` | A date row between records on different days **[lead]** | Per day change |
| Jump to bottom | Phone scroll state | Button with "N new", bottom-right above the composer; auto-follow pauses while scrolled up | While not at the bottom |
| Messages | T | User bubbles; assistant `text` blocks grouped by `message.id`, markdown via `flutter_markdown_plus` 1.0.12 in the proportional font, one `MarkdownBody` per message in `ListView.builder(reverse: true)`, mono scrolling `pre` **[owner]**; long-press gives Copy, Copy code and Share, since `selectable: true` fights the list's scroll; new items fade and slide up 8 pt **[lead]** | Always |
| Tool row | T `tool_use` + `tool_result`/`toolUseResult` | One collapsed row: tool name, short argument, result mark; a tap expands the clipped output or the diff; "Full output in Term" when clipped **[owner]**. Secondary colour and a smaller size than prose; the expansion animates its size **[lead]**. Consecutive calls fold per scope call 3 | Always |
| Diff | T `toolUseResult.structuredPatch` | Native hunk view, soft-wrapped, with the file path in a sticky hunk header **[lead]**; Write create counts content lines | Inside an Edit/Write row |
| Thinking | T `thinkingDurationMs` | "Thought for Ns" row; content never shown **[owner]** | When the message had a thinking block |
| Subagent row | T Agent `tool_use`/`toolUseResult` + `subagents/*.meta.json` | Name, `subagent_type`, running or finished; teammates show `name` and `color`; an open call reads "stopped" after an interrupted marker or once Claude exits **[lead]** | Per Agent call |
| Command chip, output | T `<command-name>` tags, `<local-command-stdout>`, `system/local_command`, `<bash-input>`/`<bash-stdout>` | `/compact` chip; mono output block | Per record |
| Compaction divider | T `system/compact_boundary` | "Conversation compacted"; the `isCompactSummary` record collapses under it | Per boundary |
| Interrupted marker | T `[Request interrupted by user…]`, `isAbortedMidStream` | Divider "Interrupted" | Per record |
| Error row | T `isApiErrorMessage` | Red row with the error text | Per record |
| Hook error row | T `stop_hook_summary` with `hookErrors` or `preventedContinuation`; `hook_*` attachments with a non-zero `exitCode` | Warning row; successful hooks stay hidden | Per record |
| Notice row | T `system/informational` (warning level), `away_summary` | Info row | Per record |
| Image thumbnail | T `image` blocks | Inline thumbnail, tap to zoom; a placeholder with the byte size when over the item cap | Per block |
| Todo strip | T latest `TaskCreate`/`TaskUpdate`/`TodoWrite` inputs, folded | Count and current item; expands to the list | While any item is not complete |
| Prompt card | T pending `tool_use` + G anchor and rows | Docked above the composer; see [Prompt cards](#prompt-cards). It plays a notification haptic on appearing; in the background or on another session the existing `status` alert notifies **[lead]** | Only while T, G and the anchor agree |
| Streaming area | G | The grid's in-progress reply rows, below the last T record; cross-fades into the T message **[lead]** | While G shows the working line and reply rows newer than the last T block (not gated on E, which may be missing remotely); cleared when the next T record arrives or the working line goes **[lead]** |
| Working line | G spinner row (glyphs `✶✻✽✢·`, then `Verb… (`) | Mirrored text with a phone-drawn spinner; `Stop` sends Esc through the write gate **[lead]**. Esc interrupts and then sends queued messages (tui-facts); whether it can instead pull them into the input row is open check 13 | Visible while G shows the row; `Stop` enabled only when no dialog is open |
| Limit banner | G `Usage limit reached` / `Continuing automatically at … · Esc to cancel` | Banner; `Cancel` sends Esc through the write gate | While G shows the line; `Cancel` enabled when no dialog is open |
| Queued messages | T `queue-operation` enqueue, cleared by its dequeue, remove or popAll (2.1.329 writes `queued_command` only as the delivery); G `⎿ Queued` confirms | Gray rows; `Send now` sends Ctrl+X, then Ctrl+S, one key per write through the write gate. The keys come from a footer hint only **[unproven]**, so the button ships after open check 12 **[lead]** | While both T and G show the item |
| Statusline | G rows between the composer's bottom rule and the mode line, with SGR colours | The first mirrored row cut to one line; a tap expands all rows, wrapped by the phone. Never parsed; the only source of "context left" **[lead]** | When present; while a dialog hides them, the last rows show dimmed as stale and update when G shows them again |
| Mode chip | G mode line (`⏸ manual mode on`, `⏵⏵ accept edits on`, …); T `permission-mode` while G hides it | In the composer accessory row. A tap opens a picker that names the modes the cycle passes through; the phone sends Shift+Tab through the write gate until G shows the chosen mode, at most one full cycle, with a selection haptic per step. A target of auto or bypass needs a second tap (card rule 10) **[lead]** | Always visible; enabled only when idle: Shift+Tab approves a plan, picks "allow for session" on a file prompt, and a mode passed on the way could auto-approve a call raised mid-cycle **[lead]** |
| Shell count | G mode line `· N shell` | `1 shell` badge in the composer accessory row | While G shows it |
| Composer | Local | See [Composer](#composer-and-the--menu) | See there |

Scrolling acts only on the phone's list; Chat never sends PgUp, `{` or wheel events to Claude. **[lead]**

### States

| State | Detection | Chat shows |
|---|---|---|
| Claude not started | `agent` is not `claude`, or no `agentSessionId` (the id outlives Claude, so it alone proves nothing) | Chat disabled; Auto shows Term |
| Running | `agent` is `claude` and `agentSessionId` known **[lead]** | Full Chat |
| Host too old | `session.transcript` answers "unknown command" (an older Mac app, origin or elis-server) | Chat disabled with "Update Elis on <host>" **[lead]** |
| Transcript file switched (`/clear`, `/resume`, `/branch`) | The reply's `transcript` differs from the held id, the old file's `continued-in` names the next id, or the tree's `agentSessionId` changes | Drop the list and load the new file's tail |
| Branch switched (rewind, retry) | The reply sets `reset` | Drop the list and load the tail |
| Claude exited while Chat is shown | `agent` stops being `claude` | History stays read-only with a "Claude exited" banner and a Term button; composer, chips and Stop are disabled; once the user leaves, the mode button shows Term, disabled **[writer]** |
| Stale | No GRID for 5 s, or no poll reply for two intervals | "Reconnecting…" bar; working line, statusline and chips dimmed, the spinner stopped, every write disabled; cleared by the next GRID and reply **[lead]** |
| Empty | Running, no items yet | "Claude is ready" with 2-3 built-in commands to pick **[lead]** |
| Loading | First page or paging back | Skeleton bubbles; a "Loading earlier…" row at the top **[lead]** |
| Transcript unreadable | Command error | A full-width state with Retry and Term in place of the list; polling continues **[lead]** |

On any file switch, reset, exit or stale state, transient marks clear with what they describe:
"Closed on the computer", open subagent rows (to "stopped") and the streaming area.
"Stopped at step k of n" lasts until the panel sheet it opened closes. **[lead]**

### Lead and grid size

- Chat takes the lead at the first input, as Term does since M5b. **[lead]**
- Chat's claim passes the daemon's current grid size and Chat never sends RESIZE, so Claude keeps the Mac's layout. **[lead]**
  The Mac still shows its existing lead cover while the phone leads.
- G therefore arrives at Mac width. The phone wraps statusline rows, and every anchor and row parser is width-agnostic: join wrapped rows, ignore whitespace.
- A grid already fitted to the phone in Term stays as it is when the user switches to Chat; Chat itself never changes the size.

### Polling

- `session.transcript {after: next}` runs every 700 ms locally and every 2 s on remote rows. **[owner]**
- It also runs at once on this session's `status` event, and on `tree.changed` when `agentSessionId` changes. **[owner]**
- The poll lives in `_load` (`session.dart:361-393`); the `_termShown` early return at `:364` must not skip it.
- The attach stream keeps running under Chat, because G is required.
- On a non-Live pane (no attach stream), G comes from `session.text` polling without colours. Without SGR the current tab, dim drafts
  and the stale statusline cannot be told apart, so there: no cards and no draft adoption; prompts open the panel sheet over `session.text` rows,
  and Send uses the shipped Term path (text, then `\r` as a separate `session.type`, `session.dart:567-590`) behind the same write gate. **[lead]**

## Prompt cards

### When a card shows

All three must hold; otherwise no card shows:
1. **T:** an open `tool_use` (no `tool_result` yet) for `AskUserQuestion`, a permission-gated tool, or `ExitPlanMode`,
   on the main chain or in the subagent file of an open Agent call (`pending` in the reply).
2. **G anchor:** the grid shows that call's anchor (below).
3. **G rows:** numbered option rows parse from the screen.

- With 2 and 3 but no T match, or with a G dialog of any other kind, the [panel sheet](#panel-sheet) shows instead.
- When T arrives late, the card replaces the panel sheet. Claude Code 2.1.329 can draw a dialog before it writes the call's `tool_use`; the first dialog read polls at once, and until the call is in `pending` the panel sheet answers it.
- In a parallel batch, the call whose anchor matches wins; two matches go to the panel sheet.

### Shared rules **[owner]**

1. Send one key per write. A write holding several keys loses digits silently [45]; phone path [unproven] (open check 1).
2. Before every key, re-read G and re-check the anchor plus the expected `❯` row or tab state. On any mismatch or timeout, stop.
3. Each key waits for its expected screen change before the next one.
   The timeout is 2 s (a design figure, not measured), counted from GRID arrival on remote rows.
4. Join wrapped rows and ignore whitespace before comparing. Footer checks are substring checks.
5. Take row numbers from the `N. ` and `N. [ ] ` rows on screen, never from option counts. Submit and Next rows have no number.
6. Free text goes in as bracketed paste; Enter is its own write. A newline inside the paste does not submit [45]; phone path [unproven] (open check 2).
7. Never use Esc to leave a field: in the Other and amend fields it cancels the whole prompt [45].
   Send the row's digit (No, Review "Cancel") instead.
8. After the prompt is gone, send nothing more.
9. On a stop, show "Stopped at step k of n: <reason>. The prompt may be half answered." and open the panel sheet.
   Never resume or undo automatically.
10. Options that persist a rule or change the mode ("always allow …", "switch to auto mode", plan "Yes, and use auto mode", bypass)
    show their screen label verbatim, are never the filled primary button, and need a second tap.
11. multiSelect sends only rows whose `[ ]`/`[✔]` state differs from the wanted one.
12. While a card is up, the composer is disabled with the hint "Answer the prompt above".
    Free-text fields (Other, notes, amend, change) live inside the card. **[writer]**
13. Anchors use model-written strings (question text, labels, command, path), never Claude's UI strings: the UI can be localized.
    Expected-state checks may use UI strings ("Tab to amend", "Review your answers"); a missing one stops the sequence, the safe direction. **[lead]**
14. A step tagged [unproven] is offered on the card only after the open checks prove it; until then the panel sheet reaches it.
    Every free-text step depends on open checks 1-2. **[writer]**
15. Every key goes through the [write gate](#write-gate-lead). **[lead]**

A card turns into a one-line record in the list when its `tool_result` arrives (the item's `rejected` flag reads "Rejected"; a "Chat about this" answer reads "Discussing"), and the docked sheet collapses into it.
When the anchor has been off screen for two grid updates without a `tool_result`, the card reads "Closed on the computer" until the result arrives,
or until a file switch, reset or exit clears it.

### AskUserQuestion

Data: `input.questions[]{question, header, multiSelect, options[]{label, description, preview}}`; the result is `toolUseResult.answers` and `annotations`.
Card: one step per question (`1/2`), options with descriptions, an Other field, previews in mono, then a Review step and Send.

Anchor:
- The joined question text under the tab bar equals the current `question`; the current tab is shown only by colour.
- The labels on the numbered rows equal `options[].label`, in order.
- The header counts only when it is 10 characters or shorter, or on the Review tab.
- The Other row is the numbered row whose label matches no option.
- Descriptions and preview content are never anchors.

| Answer | Keys and expected state after each | Evidence |
|---|---|---|
| Single choice k | Digit k → dialog gone, or the next question's text, or "Review your answers" | [45] |
| Single choice Other | Other row's digit → `❯` on it and the footer contains "ctrl+g to edit in nano"; paste → the row shows the text; Enter → submitted or advanced | Steps 1-2 [45]; Enter [100] |
| multiSelect set S | Per differing row: digit → the row flips, `❯` stays; Tab → "Review your answers"; check each `→` line (labels joined in toggle order); "Submit answers" digit → gone | Toggles, Tab [45]; Submit [100] |
| multiSelect Other | Toggles first; Down, one write at a time, until `❯` is on Other; paste → `[✔] <text>`; Up → `❯` on the row above, text kept; Tab → Review | [45] |
| Several questions | Per tab: check the question text, answer; after a multiSelect question send Right and expect the next text; at the end Review, check, Submit digit | Right then digit [45]; Submit [100] |
| Preview option k | Digit k → `❯` on label k, the box changes (no submit); Enter → gone | [45] |
| Preview notes | Footer contains "n to add notes" → n, paste, Enter | [100]; [unproven] at 45 |
| Chat about this | That row's digit → rejected | [100]; no button where the row has no number (preview layout) |
| Cancel | Review "Cancel" digit, or Esc while no field is focused → "Interrupted ·" | [45] |

### Permission prompts (Bash, Write, Edit, WebFetch, MCP)

Card content comes from T: the Bash `command` and `description`; the Write content or Edit diff; the WebFetch URL and prompt; the MCP server, tool and arguments.
Option labels come from G; nothing structured lists them.

Anchor:
- Bash: the `│ ` rows joined with no separator equal `command`.
- Write and Edit: the `…`-truncated header path is a suffix of `file_path`; the question line holds `basename(file_path)`; content or diff lines are verbatim.
- MCP: the argument values verbatim; the title is a display name, not `mcp__server__tool`.
- WebFetch: the `url:` row equals `input.url`.
- Subagent: X in the header "· from the X agent" equals the pending call's `agentType` or `agentName`; none or two matches go to the panel sheet. The pending call's source is
  `subagents/agent-<id>.jsonl` for an in-process subagent, the teammate's own JSONL for a teammate pane.

| Answer | Keys and expected state | Evidence |
|---|---|---|
| Yes | Digit of the row labelled exactly "Yes" → gone | Bash, Write [45] |
| No | Digit of the "No" row → gone, "Interrupted ·" | Edit [45], Bash [100] |
| Rule or mode option | Verbatim label, second tap, then its digit | [unproven] |
| Yes with a note | Check `❯` is on the Yes row (row 1); Tab → label "Yes, and tell Claude what to do next" (MCP: "Yes, tell Claude…") and "Tab to amend" leaves the footer; paste → "Yes, <text>"; Enter → gone, the text shows as a user message | Bash [45]; Write, Edit, MCP: Tab [45], paste and Enter [unproven] |
| No with a reason | Down until `❯` is on No, checking each; Tab → "No, and tell Claude what to do differe…"; paste; Enter → "Not run · rejected" | Bash [45] |
| Abandon a note | A second Tab → the label is back to "Yes" | [45] |

Option lists vary: a teammate Bash prompt has no "always allow" row, and an MCP connector prompt showed only Yes and No.

### Plan approval (ExitPlanMode)

Card: `input.plan` as markdown (first lines, then More), the option buttons, and a Change field.
Anchor: the footer's plan basename, joined across the wrap, equals `basename(planFilePath)` when the input has one; otherwise the first heading of `input.plan` is the anchor.
The "Exit plan mode?" variant has no plan file and always goes to the panel sheet.

| Answer | Keys and expected state | Evidence |
|---|---|---|
| Yes, manually approve edits | That row's digit → gone, "⏸ manual mode on" | [45] |
| Yes with auto mode (or bypass) | Verbatim label, second tap | [unproven] |
| Change | "Tell Claude what to change" digit → a field opens; paste → the row shows the text; Enter → a new plan prompt | [45] |

### Answer bar

- In Chat the card owns the answers.
- The `_answers` bar (`session.dart:838`) shows only in Term and inside the panel sheet.
- `promptOptions` (`mobile/lib/screens/prompt.dart`) stays as it is for Term and home cards; the card parser is new and width-agnostic.

## Composer and the "/" menu

- The Chat composer is the existing component (`session.dart:913-953`) with three parameters: 6 lines, autocorrect on, and the proportional body font. **[owner]**
- Term keeps its values (4 lines, no autocorrect, mono), because Term input is terminal input. **[writer]**
- The composer is always visible in Chat. **[owner]**

Adopting a draft:
- On opening Chat, the phone copies the non-dim text of G's `❯` input row into an empty local field. **[owner]**
- Dim (SGR 2) text is a placeholder or suggestion and is never adopted; neither is "Press up to edit queued messages".
- Claude's row keeps the text until Send.

Send is enabled when the field is not empty, no dialog is open, and G shows the `❯` input row.
When disabled with text in the field, a one-line reason shows under it ("Claude shows a dialog", "Waiting for Claude's screen"). **[lead]**
It reads "Queue" while G shows the working line and "Send" otherwise. **[lead]** It runs through the write gate:
1. If Claude's row holds exactly the adopted draft, clear it and wait for an empty row.
   If it holds anything else, stop with "Claude's input changed on the computer" and offer Replace and Keep. **[writer]**
2. Bracketed paste of the field text; Enter as its own write once G shows the text or a paste placeholder on the `❯` row.
3. Clear the field once G shows the row empty or the user record arrives in T.

Sending while Claude works queues the message, as Enter does in the TUI.
The clearing key is the builder's, after an open check; it is never Esc Esc.

The "/" menu:
- Typing `/` as the first character opens a native list filtered by the typed text. **[owner]**
- Items: Claude's built-in commands (a static catalog in ElisCore, returned by `session.transcript`) plus the commands and skills in T's last `skill_listing` attachment.
- Picking an item inserts `/name ` into the field; Send sends it like any text.
- A command that opens a panel (`/model`, `/usage`, `/config`, `/rewind`, `/resume`, `/tasks`) is marked "opens in panel" in the list
  and leads to the panel sheet by itself. **[lead]**
- `/model`, `/effort`, `/fast`, `/status`, `/tasks` and `/usage` run at once instead of queueing (tui-facts).
- A leading `!` (bash mode) or `#` in pasted text may not switch Claude's mode as typing does; open check 14 decides whether Send types that
  first character as a key.

## Panel sheet

- It opens when G shows something that is neither the normal bottom stack nor a classified prompt:
  `/usage`, `/model`, `/config`, `/context`, `/resume`, `/tasks`, the Ctrl+O view, MCP elicitation, folder trust, `/login`,
  a sandbox prompt, any unclassified dialog, and every stopped card sequence. **[lead]**
- It shows G's live rows with the existing Term renderer, plus the existing key bar (`session.dart:874`, keys at `:22-42`) and the answer bar.
- It closes by itself when G shows the normal bottom stack again.
- The user can swipe it down; while the panel is still on G, the composer stays visible and disabled, with "Claude shows a panel · Open". **[lead]**
- Claude's classic (non-fullscreen) TUI runs on the main screen with its bottom stack at the end;
  the classifier reads the bottom of the visible grid and needs fixtures for both layouts.

## Transcript reader in ElisCore

`ClaudeTranscript` is new, next to `SessionLauncher.swift:48-75`: pure, host-free and Linux-safe.

Resolution:
- The input is the Claude session id, guarded by `plainSessionID` (`SessionLauncher.swift:56`), and a home directory.
- The reader finds `~/.claude/projects/*/<id>.jsonl` and caches the path per id.
- No caller passes a path. Sidecars resolve only under `<dir>/<id>/`, by names the transcript or meta files record (`agentId`, `toolUseId`, `toolu_*`).
- Every such name comes from file contents and passes the `plainSessionID` charset check before it becomes a path component;
  `/`, `..` and anything else is skipped. **[lead]**

Index:
- On the first read the reader scans the file once and keeps, per record, `uuid`, `parentUuid`, `logicalParentUuid`, byte offset and type.
  Later reads extend the index from the last offset.
- Only whole lines count; a partial trailing line waits for its newline.
- A line too long for the read window becomes one placeholder item, and the cursor moves past it.
- The index cache is keyed by path, size and a hash of the first 4 KiB; a smaller size or a changed prefix rebuilds it.

Tree walk **[lead]**:
- The current leaf is the last record in file order that has a `uuid`.
- The active chain walks `parentUuid` from the leaf, through records the reader does not emit (attachments),
  and crosses a `compact_boundary` through `logicalParentUuid`, so pre-compaction history stays.
- Records with `isSidechain: true` are dropped.
- A page lists active-chain items only, in chain order.
- `reset` is set when the new leaf's chain no longer holds the last item the caller has (rewind, retry).

Records kept as items:

| Record | Item |
|---|---|
| `user` typed content (string or `text`), not `isMeta` | `user` with `promptSource`, `origin.kind` |
| `user` `image` blocks | `image` |
| `user` command tags, local command output, bash tags | `command`, `commandOutput`, `bash` |
| `user` `[Request interrupted…]`, `interruptedMessageId` | `interrupted` |
| `user` `isCompactSummary` | `compactSummary` |
| `user` `<task-notification>` | `taskNotification` |
| `assistant` `text` | `text`, grouped by `message.id` |
| `assistant` `thinking` | `thinking`, duration only |
| `assistant` `tool_use` + its `tool_result` (by `tool_use_id`) | `tool`: name, short argument, `mark`, clipped `output` or `patch`, `isError`, `exitCode` from `/^Exit code (\d+)/` |
| `assistant` `isApiErrorMessage`, `isAbortedMidStream` | `error`, `interrupted` |
| `system` `compact_boundary`, `informational` (warning), `away_summary`, `stop_hook_summary` with errors | `compact`, `notice`, `hook` |
| `attachment` `hook_*` with a non-zero `exitCode` | `hook` |

- Everything else is dropped, including `api-request*`, wrapper tags and unknown types; the allowlist is the only way in.
- A `skipped` count reports lines that failed to decode, so one bad line never blanks the chat.
- Short argument: Bash `description` or `command`; Read, Edit and Write the `file_path` basename; Agent `description`; WebFetch host; MCP first argument.
- Result mark: Bash exit code or error; Edit and Write `+N −M` from `structuredPatch`; Agent status.

Caps:
- A page is about 48 KiB; tool output and patches are clipped to about 4 KiB with `clipped: true`. **[owner]**
- Each item is at most about 16 KiB.
- A spilled output in `tool-results/toolu_<id>.txt` contributes its first 4 KiB.
- An image is inline only below the item cap; otherwise it is a placeholder with media type and size.

Meta folding: the last record of each type wins.
The reader folds meta during the index scan and on each extension, so meta never depends on the page window.

| Meta field | From |
|---|---|
| `title` | last `custom-title` (`customTitle`), else last `ai-title` (`aiTitle`) |
| `lastPrompt` | last `last-prompt.lastPrompt` (about 200 characters, a preview only) |
| `permissionMode` | last `permission-mode` |
| `pr` | last `pr-link` `{prNumber, prRepository, prUrl}` |
| `agentName` | last `agent-name` |
| `model`, `effort` | last non-sidechain assistant record |
| `todos` | latest folded `TaskCreate`/`TaskUpdate`/`TodoWrite` state |
| `queued` | `queue-operation` enqueue records minus dequeue, remove and popAll |
| `continuedIn` | `continued-in` record |
| `skillsAt` | byte offset of the last `skill_listing` |

Pending calls: open `tool_use` records on the active chain, plus open ones in `subagents/agent-*.jsonl` whose `.meta.json` `toolUseId` matches an open Agent call.
Each carries `source` (`main` or the bare agent id), optional `agentType` and `agentName`, and the full `input`, capped at 16 KiB.

## Control API

### `session.transcript`

Copy `session.text`: the case at `ControlProtocol.swift:64`, args at `:303-331`, dispatch at `ControlDispatcher.swift:479` and `:693`,
actions at `ControlActions.swift:236-238`, the default at `ControlActionsDefaults.swift:306`.
The dispatcher resolves the pane's `agentSessionId` from the tree and passes it to the action, so the ControlActions default can call
`ClaudeTranscript` with that id under HOME and the agterm-linux fork keeps working. **[lead]**
A new case in `public enum Command` breaks any exhaustive switch in that fork, as every new command does.

Arguments:

| Arg | Meaning |
|---|---|
| target | The session, as for every session command |
| `pane` / `paneID` | Which pane's Claude; default is the active pane |
| `after` | Byte offset: items appended after it (tail poll) |
| `before` | Byte offset: older items before it (scrolling back) |
| `transcript` | The id the caller holds; a mismatch sets `reset` |
| `maxBytes` | Page budget, capped at the default (about 48 KiB) |

`pane`/`paneID` default to the session's `agentPane` (scope call 1).

Without `after` and `before` the command returns the tail page plus `commands`.

Result:

| Field | Meaning |
|---|---|
| `transcript` | The Claude session id read |
| `size` | File size at the read |
| `start`, `next` | Byte offsets covered; `next` is the next `after` |
| `reset` | The held id differs, the file shrank, or the leaf left the chain the caller holds |
| `items[]` | `{kind, uuid, at, time, …}` as listed above |
| `pending[]` | Open prompt-capable calls with `source`, `name`, `input` |
| `meta` | Folded fields |
| `commands[]` | `{name, description, source: builtin or skill}`; on the tail page and when `skillsAt` falls in the polled range |
| `skipped` | Lines that failed to decode |

Errors: `no adapter` (the pane runs no Claude, or its id is unknown) and `transcript not found`.

- Read-back: the command is a read; the tree's `agentSessionId` (`ControlProjection.swift:303`) names the transcript.
  elis-server's tree gains `agent` and `agentSessionId`.
- Events: none new. The phone uses `status` and `tree.changed`; `EventFormatter` needs no entry.
- `elisctl session transcript [<target>] [--pane left|right] [--pane-id ID] [--after N | --before N] [--transcript ID] [--max-bytes N] [--json]`,
  next to `struct Text` (`elisctlKit/SessionCommands.swift:435-458`). Human output prints meta, then one line per item (`kind  text`).

Server plumbing:
- `waitsOnNetwork` (`ControlServer.swift:640-642`) and the exhaustive not-handled list (`ControlServer.swift:749`).
- Attached Mac row: a new `AttachedForward` case (`ElisCore/AttachedForward.swift:30-72`), an entry in `forwarded`
  (`ControlServer+AttachedForward.swift:44-45`), and a pass-through follow-up, because `.none` rewrites `result` (`:248`).
  The viewer's `pane`/`paneID` map to the origin's through `originPane` (`ControlServer+AttachedForward.swift:160-178`).
  Whether the forward's ssh connection is pooled is unchecked; the 2 s poll assumes it is (open check 16).
- Attached Mac `agent`: the origin publishes the running agent as a new presentation kind `agent` next to `agent.session`
  (`AppStore+SessionState.swift:36-38`, `PresentationHub.supportedKinds`); the viewer sets the row's `runningAgent` from it.
  An origin that never sends it leaves `agent` unset, so Chat stays disabled on that row. **[lead]**
- elis-server row: an ssh read like `serverPageResult` (`ControlServer+RemoteActions.swift:139`); ssh connections are pooled (`RemoteSession.swift:272`).
- elis-server: an entry in `ServerCommandPolicy.served` (`ServerCommandPolicy.swift:7-23`), a `ServerActions` method,
  and Claude detection in `PaneObserver`: per tick, read `~/.claude/sessions/<pid>.json` for the foreground pids and call `setAgentSessionID`,
  which publishes `agent.session` through `PresentationHub` (`ServerStreams.swift:10,59`).

Tests:
- Reader fixtures: chain walk through attachments, compaction crossing, branch switch, sidechain drop, partial line, oversized line,
  unknown types, `skipped`, `continued-in`, spilled output, subagent pending calls, meta folding, page boundaries,
  sidecar names with `/` or `..`, and the built-in command catalog.
- Protocol round trip (`ControlProtocolTests.swift:472`), dispatcher (`ControlDispatcherTests.swift:801`), `MockControlActions`,
  elisctl (`CommandsTests.swift:579-620`), `ServerCommandPolicyTests`, server actions (`ServerActionsSessionsTests.swift:420`),
  the elis-server tree's `agent` and `agentSessionId`, attached forward, and the `agent` presentation kind.
- An end-to-end UI test in the style of `ClipboardPromptUITests.swift:56`.
- Phone: grid classifier fixtures captured from real grids (fullscreen and classic, 45 columns and Mac width),
  the card sequence state machine against a fake grid, and widget tests.

Docs: `site/docs.html` (Chat on the phone, by task), `site/commands.html` (command, arguments, result fields), `.claude/rules/control-api.md`,
and `plugins/elis/skills/elis/` with a `description` trigger such as "read a session's Claude conversation".

## Remote parity

| Piece | Local Mac | Attached from another Mac | elis-server row | Linux Qt app |
|---|---|---|---|---|
| `agentSessionId` | Sampler (`Elis/SessionLaunchers.swift:87-110`) | Published by the origin (`AppStore+SessionState.swift:36-38`) | New `PaneObserver` detection | Not stored: Chat disabled **[owner]** |
| `agent` (running) | Sampler | New `agent` presentation kind; missing → Chat disabled **[lead]** | New `PaneObserver` detection | — |
| T | Local reader | Forwarded to the origin's `elisctl` | ssh read on the server | — |
| E events (`status`, `tree.changed`) | Hooks → `events.read` | Mirrored by the origin | elis-server installs the hooks (`ServerHookInstall.swift`); reaching the phone's `events.read` is open check 15 | — |
| G | Attach stream | Attach stream over ssh | Attach stream over ssh | — |
| Keys: digit, Tab, arrows, Shift+Tab, Esc | Attach stream, one write each | Same, over ssh (open check 1) | Same (open check 1) | — |
| Paste | Attach stream | Same (open check 2) | Same (open check 2) | — |
| Poll interval | 700 ms | 2 s | 2 s | — |
| Older host | — | "unknown command" → Chat disabled | Same | — |

The card timeout counts from GRID arrival on remote rows, so ssh lag does not trip it.
Without E events the poll interval alone drives Chat; nothing in Chat waits on an event. **[lead]**

## Scope calls

The owner delegated these on 2026-11-20 ("work autonomously; ask only non-obvious choices"). **[lead]**
1. Claude is tracked once per Elis session, as today, but the sampler reads both panes and records which pane runs Claude
   (`agentPane`); Chat follows that pane, so focusing a shell pane on the Mac no longer reads as "Claude exited".
   Full per-pane tracking is later.
2. Open checks 1 and 2 run first. If either fails, the path is fixed (a zmx patch if needed) while history, the composer
   and the panel sheet ship; cards, Send and the mode chip stay disabled with a one-line reason until the fix lands.
3. Two or more consecutive tool calls, of any tool and MCP tools included, fold into one row as the TUI folds them:
   "Read, Grep, search and 5 other calls" names the first three distinct tools (an MCP tool by its own name) and counts the rest.
   Its mark reads running while any call runs, else ✗ with the count of failed or rejected calls, else ✓.
   A tap lists the calls, each expandable as before; the expansion survives polls that grow the run.
   An Agent call and a call whose prompt is pending keep their own row and break the run **[lead]**.

## What is later

- Rewind; history, Ctrl+R and stash; editing queued messages.
- Background shell output tail.
- "@" file completion; sending images from the phone; prompt-suggestion ghost text.
- A C++ port for the Qt app; codex.
- Approach B's full-output fetch; approach C's push event.
- Native cards for MCP elicitation; a native model picker.
- Search in the conversation.

## Open checks to run first

1. One key per write survives the phone → relay → zmx path, locally and remotely.
2. Bracketed paste markers written by the phone reach Claude as a paste.
3. The race between the anchor check and the send, measured on local and remote rows; it sets the per-step timeout.
4. A pasted `/cmd args` followed by Enter runs exactly that command, not the slash menu's highlighted match.
5. The key that clears Claude's input row for Send (Ctrl+U or another), including multi-line drafts.
6. The `skill_listing` attachment's shape; until it is known, the "/" menu shows built-ins only.
7. The todo tools' input shapes: 2.1.329 has only `TodoWrite`, and 691 local transcripts hold no task tool, so the todo strip may stay empty.
8. The transcript layout on an elis-server Linux host.
9. Whether entering Chat after a Term fit should restore the Mac's grid size.
10. Every [unproven] row in the card tables, starting with Yes-with-note on Write, Edit and MCP, and the rule and mode options.
11. Classifier fixtures for the classic TUI, the Ctrl+O view, and a tall plan at Mac width.
12. Ctrl+X then Ctrl+S sends the queue now.
13. What Esc does to queued messages: sent next, or pulled back into the input row.
14. Whether a pasted leading `!` or `#` switches Claude's input mode as a typed one does.
15. elis-server `status` events reach the phone's `events.read` stream.
16. The attached forward's ssh connection is pooled.
17. Whether `/rewind` or `/clear` ever truncates a transcript file (the tree walk and `reset` assume append-only; only tui-critic asserts rewind branches).
18. A multi-line paste on the main `❯` row: inline text or a `[Pasted text …]` placeholder, and what the write gate then checks.

## What is left to the builder

- Exact item JSON fields, the image cap, and index cache eviction.
- The look of tool rows, dividers, chips and the diff view; the `pre` builder style.
- The chat view in its own files (`session.dart` is 1037 lines).
- The G classifier's internals, within the anchors above.
- Remote poll tuning around 2 s.
- Milestone split, with the open checks first and the [lead]/[writer] calls that set scope (streaming area, mode chip, panel triggers,
  Send now) kept separable.
