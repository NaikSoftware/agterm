# Phone Chat Prompt Cards (Plan C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In Chat, Claude Code's AskUserQuestion, permission and plan-approval prompts show as native cards docked above the composer. Each card is answered by a keystroke sequence that the phone verifies against the live grid, one key at a time, through plan B's write gate.

**Architecture:** Plan C's code lives in `mobile/lib/chat/`:
- `PromptDialog` parses the dialog at the bottom of the grid. It is width-agnostic and tested against captured grids.
- `matchPrompt` ties that dialog to exactly one `PendingCall` from `session.transcript` through the spec's anchors.
- `cardSteps` turns a collected answer into a fixed list of `GateStep`s. `WriteGate.run` sends them.
- The card widgets plug into plan B's `PromptCardBuilder` slot.
- `PromptLedger` follows every shown card after its dialog is gone (answered, "Closed on the computer") and marks its tool row in the list.

**Tech Stack:** Flutter (Dart 3.13, Android), `flutter_markdown_plus` 1.0.12 (added by plan B), plan B's `Grid`/`ClaudeScreen`/`WriteGate`, `tmux` for fixture capture.

**Spec:** `docs/superpowers/specs/2026-11-20-phone-chat-mode-design.md`: sections "Prompt cards" (all), "Answer bar", "Write gate", "Panel sheet", "Remote parity", and open check 10.
The open-check report of 2026-11-20 (`/private/tmp/claude-502/-Users-n-savchenko-IdeaProjects-elis/96123572-0e60-465e-958a-b0ed3100d48a/scratchpad/open-checks.md`) takes precedence over the spec's evidence tags where they differ.
The keystroke facts come from `narrow-protocol.md` in the same scratchpad.

**Prerequisite:** plan B Tasks 1-18 merged into this branch before Task 1: Task 8 edits B's `chat_view.dart`, `items.dart` and `session.dart`, and Tasks 2-8 use B's gate and fixtures. Tasks 9 and 11 also need plan A merged.

## Interfaces shared with other plans

**Consumed from plan A** (`2026-11-20-phone-chat-a-transcript-api.md`, through plan B's decoder):
- `pending[]`: `{id, uuid, source, agentType, agentName, name, input, clipped}`.
  - `source` is `main` or the bare `agentId` (`a1` for `subagents/agent-a1.jsonl`).
  - `agentType` (the `.meta.json` type) and `agentName` (the Agent call's `input.name`) only on subagent entries, when present.
  - `input` is a JSON object, passed as Claude wrote it (an `ExitPlanMode` input may lack `planFilePath`). It is absent when `clipped: true`.
  - Only open calls are listed, never `Agent`/`Task`.
- `tool` items: `id`, `name`, `running`, `isError`, `rejected`, `output`. Upsert by `uuid` turns a running call into its result. `rejected` is plan A's reading of a user rejection; plan C never matches the wording.
- Plan C adds no command, argument, result field, tree field or presentation kind. Plan A's interfaces are used unchanged.

**Consumed from plan B** (`2026-11-20-phone-chat-b-phone-view.md`), names used verbatim:
- `Grid` (`rows`, `colours`, `text(r)`, `bright(r)`) and `norm(String)` (Task 5). `gridFromAnsi(String)` lives in `test/support/ansi.dart`.
- `ClaudeScreen.read(Grid)`, using `bottomStack` and `dialog` (Task 6).
- The gate (Task 7):
  - writes: `GateWrite`, `KeyWrite(VtKey, [mods])`, `TextWrite(String)`, `PasteWrite(String)`;
  - steps: `GateStep(write, ready:, done:)`, `GateSequence.send`;
  - results: `GateResult{outcome, step, total, reason, ok}` and `GateOutcome`;
  - `WriteGate.run(total, body)`, `running`, `progress`.
- `Checks` and `checks` (Task 1): `writeBlocked`, `timeout`, and `remote`, the one remote flag (plan C Task 9 sets it).
- `escapeGap` (Task 7): the gate's 100 ms hold after an Esc, used as it is.
- `PendingCall(id, uuid, source, name, input, clipped, {agentType, agentName})` and `TranscriptFeed` (`pending`, `items`, `switches`) (Tasks 3, 4).
- The card slot (Task 18):
  - `ChatPromptContext{screen, grid, pending, gate, remote, openPanel}`;
  - `PromptCardBuilder`;
  - `ChatView(..., PromptCardBuilder? promptCard)`.
- `chatRowWidget(BuildContext, ChatRow, {required bool fresh})` (Task 10), `AnswerBar` (Task 8), `VtKey`, `vtShift`.

**Produced by plan C for plan B** (plan C edits these B files and says so in its tasks):
- `chat_view.dart` (Task 8):
  - `ChatView` takes `PromptLedger? prompts`;
  - a panel the dialog opened by itself (not a stopped one) closes when `promptCard` returns a card for the same dialog.
- `items.dart` (Task 8): `chatRowWidget(..., String? Function(String toolId)? promptMark)`. A non-null mark replaces the tool row's mark text.
- `session.dart` (Task 8) builds `PromptLedger` and passes `promptCard: promptCardBuilder(ledger)` and `prompts: ledger`.
- The text plan C passes to `openPanel` is the whole sentence: `Stopped at step k of n: <reason>. The prompt may be half answered.` B shows it verbatim.

Open checks: plan C owns check 10. It also re-runs checks 1-3 on an attached row and an elis-server row, because the 2026-11-20 run was local only, and sets B's `checks.remote` when both pass (Task 9).

## Global Constraints

- Every delegated agent receives verbatim: "never execute `elis`/`elisctl` against the default socket, never launch or quit the app, static reading only."
  Tasks 9 and 11 launch a Debug instance and an emulator, so they run in the lead session only.
- Work only in the worktree `/Users/n.savchenko/IdeaProjects/elis/.claude/worktrees/phone-chat-mode`, in `mobile/`.
  Per task, run `flutter analyze --no-pub` (0 issues) and `flutter test --no-pub test/<file>`.
- Local Flutter 3.47.2 needs a temporary `sdk: ^3.13.2` constraint and `flutter pub get` before running. Before each commit, restore `sdk: ^3.13.7` and any `sdks:` change in `pubspec.lock`.
- No new dependency.
- Every card key goes through `WriteGate`:
  - one key per write; a paste is one write; Enter is its own write;
  - each write waits for its expected grid change, within `checks.timeout`, before the next one (spec rules 1-3, 15).
- Esc is never sent to leave a field (rule 7). A card sends Esc only as the last write of a Cancel, and the gate holds 100 ms after it.
- Anchors use model-written strings only: question text, labels, command, path, URL, MCP argument values, plan basename.
  UI strings such as "Submit answers", "Tab to amend", "ctrl+g to edit in nano", "press n to add notes", "· from the" and "Review your answers" are expected-state checks only. When one is missing, the sequence stops, or no card matches and the panel sheet shows.
- Width-agnostic: join wrapped rows and compare `norm`ed text. Row numbers come only from the `N. ` prefix on screen.
- Chat never resizes, so G arrives at Mac width (spec "Lead and grid size"). Every fixture-driven test in Tasks 2-5 runs at 100 columns and at 45, the width a Term fit leaves.
- A step the open checks have not proven is never a card button (rule 14). The card shows "Answer in panel" (`openPanel(null)`) for it.
- A non-Live pane's grid (`Grid.text`, `colours` false) never gets a card: without SGR the current tab and dim text cannot be told apart, so the panel sheet shows (spec "Polling").
- A matched card always shows. Its buttons are disabled with a one-line reason and an `Answer in panel` button in two cases (scope call 2):
  - `checks.writeBlocked` is non-null;
  - on a remote row (`Session.remote`) while B's `checks.remote` is false, with the reason `Answering is off on remote rows until checked`.
- Fixtures contain no private content: the worktree cwd, made-up prompts, and no username, hostname, home path or session id outside the dialog under test.
- Every screenshot shows no machine name, hostname, username or `/tmp` path; the owner's preference overrides CLAUDE.md's Website rule.
- Comments are one line and only for a non-obvious constraint. A known limit is written as `shortcut: <limit>, <when to upgrade>`.

## Review Focus

1. **A dialog field is focused when the next key goes out.** A digit typed into the Other or amend field becomes text, and Tab or → does nothing on a filled Other row or on Next.
   Every digit, Tab and → step's `ready` checks that `❯` is on a list option row and that the footer lacks "ctrl+g to edit in nano".
   Tests: Task 4 `tabWaitsUntilCursorLeavesOther`, `digitRefusedWhileOtherFocused`.
2. **The question, labels or command are echoed above the dialog** (`s1_single`, `f`): an anchor found in the conversation instead of the dialog would send keys to the wrong prompt.
   Test: Task 2 `anchorsReadOnlyTheDialogRegion`.
3. **Labels that look like row numbers** (`7`, `42`): digits come from the `N. ` prefix.
   Test: Task 4 `numericLabelsUseRowNumbers`.
4. **Someone answers on the Mac while the phone sends.** The next `ready` fails and the sequence stops at that step, never resumes.
   Tests: Task 4 `macAnswerMidSequenceStops`, Task 8 `closedOnTheComputerAfterTwoGrids`.
5. **A plan dialog's `❯` sits on "Yes, and use auto mode"** (`h.txt`). A bare Enter would approve auto mode, so a plan card never sends Enter except after its own paste.
   Test: Task 5 `planNeverSendsBareEnter`.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/chat/card_checks.dart` | `CardChecks`: which card steps the open checks proved |
| `lib/chat/prompt_dialog.dart` | `PromptDialog.read(Grid)`: the bottom dialog's regions, option rows, cursor, ticks, tabs, review lines |
| `lib/chat/prompt_match.dart` | `matchPrompt`: the anchors tying a dialog to one pending call |
| `lib/chat/card_steps.dart` | `CardAnswer` types and `cardSteps(PromptMatch, CardAnswer)`, the spec's keystroke tables |
| `lib/chat/prompt_cards.dart` | `CardFrame` and the AskUserQuestion, permission and plan cards |
| `lib/chat/prompt_ledger.dart` | `PromptLedger` (shown, answered, closed, stopped per call id) and `promptCardBuilder` |
| `test/fixtures/grid/card-*.ansi`, `card-*.pending.json` | Captured dialog grids and the matching pending calls |
| `test/support/fake_claude.dart` | `ScriptedGrids`: a grid notifier that advances to the next fixture when the expected write arrives |

---

### Task 1: Card check defaults

The 100 ms hold after Esc (open check 1) is plan B's: B Task 7 owns `escapeGap` and its tests `escapeIsFollowedByAGap`, `gapSpansRuns` and `noGapAfterOtherKeys`. Cards use that gate as it is.
The remote flag is plan B's `Checks.remote`; this task adds only the card-step flags.

**Files:**
- Create: `mobile/lib/chat/card_checks.dart`

**Interfaces:**
- Produces:
```dart
class CardChecks {
  const CardChecks({this.fileAndMcpNotes = false, this.persistOptions = false, this.previewNotes = false,
      this.webFetch = false, this.singleOther = false});
  final bool fileAndMcpNotes; // Yes/No with a note on Write, Edit, MCP: paste and Enter
  final bool persistOptions; // rule and mode rows: "always allow", "don't ask again", "switch to auto mode", plan auto, bypass
  final bool previewNotes; // n, paste, Enter on a preview option (at Mac width and at 45 columns)
  final bool webFetch; // every WebFetch answer; its No row reads "No, and tell Claude what to do differently (esc)"
  final bool singleOther; // Enter after pasting into a single-choice Other field at 45 columns (seen only at 100)
}
const cardChecks = CardChecks(); // all unproven until Task 9
```

- [ ] **Step 1: Write `card_checks.dart`** as above. Run `flutter analyze --no-pub`. Expected: 0 issues.
- [ ] **Step 2: Commit** `feat(mobile): card checks, all unproven`.

---

### Task 2: Captured dialog fixtures and the dialog parser

**Files:**
- Create: `mobile/test/fixtures/grid/card-*.ansi`, `card-*.pending.json`, and rows in that directory's `README.md` (plan B Task 5 creates it)
- Create: `mobile/lib/chat/prompt_dialog.dart`, `mobile/test/prompt_dialog_test.dart`

**Interfaces:**
- Consumes: `Grid`, `norm`, `gridFromAnsi` (B Task 5).
- Produces:
```dart
class DialogOption {
  final int? number; // from the "N. " prefix; null for Submit, Next and an unnumbered "Chat about this"
  final String label; // joined across wraps, without the preview box and the "[ ]" mark
  final bool? checked; // "[ ]" false, "[✔]" true, null without a box
  final bool cursor; // "❯" on this row
  final bool belowRule; // under the list's closing rule ("Chat about this")
  final int row, lastRow; // grid rows this option and its description span
}
class PromptDialog {
  static PromptDialog? read(Grid g); // null when the grid has no numbered option row below the conversation
  final int top; // first grid row of the dialog: the rule above the tab bar or title
  final String header; // joined rows from top to the first body row (title, "· from the <x> agent", tab bar)
  final String body; // joined rows between header and question (│ command rows, content, diff, url:, MCP args, plan)
  final String boxed; // the body's "│ " rows joined with no separator, bars removed (the Bash command)
  final String question; // joined question rows right above the options (AskUserQuestion: under the tab bar)
  final List<DialogOption> options;
  final String footer; // joined rows after the options, to the bottom title rule
  final bool review; // the Review tab: "Review your answers" rows
  final List<String> answers; // review "→ " lines, joined across wraps, in screen order
  final List<String> reviewQuestions; // review "● " lines, joined across wraps, in screen order
  final bool preview; // a box beside the options
  DialogOption? get cursorOption;
  DialogOption? numbered(String label); // the numbered row whose norm(label) equals norm(label)
}
```
The internals are the builder's (spec "left to the builder"). What fixes them is that `top` is found by scanning upward from the bottom of the grid, so text echoed in the conversation above the dialog is never inside any region.

- [ ] **Step 1: Capture the fixtures.**
  - Use the plan B Task 5 method: a detached tmux session started as `tmux new -d -s capture /bin/zsh -fc "cd /Users/n.savchenko/IdeaProjects/elis/.claude/worktrees/phone-chat-mode && env -u <every inherited ELIS_*, GHOSTTY_*, CLAUDE*> claude --model haiku --permission-mode default"`, `tmux capture-pane -p -e`, and made-up prompts. Never capture from a `/tmp` folder; Claude already trusts the worktree. If a folder-trust prompt appears, stop and report it; never answer it.
  - The scratchpad captures (`narrow/`, `probe/`) show which states to reach. They are not copied: they hold the home path and session ids, and `narrow/` has no colours.
  - Each prompt names the question, labels or command verbatim, so the dialog's text also shows above it (the echo trap).
  - For each fixture, also write `<name>.pending.json`, the `pending` array as plan A would emit it. Take it from the capture session's transcript: the open `tool_use` id, its `uuid`, `name` and `input`, with `source: "main"`; for the subagent fixture `source` is the bare `agentId` of `subagents/agent-<id>.jsonl`, with `agentType` from its `.meta.json` and `agentName` from the Agent call's `input.name` when set.
  - Record a real `ExitPlanMode` input: `card-plan.pending.json` keeps the captured `input` verbatim, and the README row names its keys (whether `planFilePath` is present). Nothing in Tasks 3-7 assumes `planFilePath` exists.
  - For the subagent fixture, start Claude with `--settings '{"teammateMode":"in-process"}'` and with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=0` set after the `env -u` list, or the Agent call opens a tmux teammate pane (Memroot root cause).

| Fixture | State | Widths |
|---|---|---|
| `card-ask-single` | one single-choice question with descriptions | 45, 100 |
| `card-ask-numbers` | labels `7` and `42` | 45, 100 |
| `card-ask-other-open` | after the Other row's digit: `❯` on it, footer has `ctrl+g to edit in nano` | 45, 100 |
| `card-ask-other-filled` | after pasting `two\nlines` into Other | 45, 100 |
| `card-ask-multi` | one multiSelect question, nothing ticked | 45, 100 |
| `card-ask-multi-ticked` | rows 1 and 3 ticked, `❯` on row 1 | 45, 100 |
| `card-ask-multi-other` | Other filled, `❯` on it | 45, 100 |
| `card-ask-two` | two questions, headers over 10 characters (`Environmen…`) | 45, 100 |
| `card-ask-two-second` | the second question shown | 45, 100 |
| `card-ask-review` | Review with `→` lines, Submit answers and Cancel | 45, 100 |
| `card-ask-preview` | preview layout, the box beside the options, unnumbered "Chat about this" | 45, 100 |
| `card-ask-preview-notes` | after `n` | 100 |
| `card-bash` | Bash with 4 options, the command wrapping mid-word at 45 | 45, 100 |
| `card-bash-amend` | after Tab on Yes: "Yes, and tell Claude what to do next" | 45, 100 |
| `card-bash-no-amend` | after Down ×3 and Tab | 45, 100 |
| `card-bash-classic` | Bash in the classic (non-fullscreen) TUI | 100 |
| `card-write`, `card-edit` | file prompts; the header path `…`-truncated at 45 | 45, 100 |
| `card-mcp` | `mcp__claude_ai_Claude_Docs__guide` with `items: ["topic.index"]` (no private argument) | 45, 100 |
| `card-webfetch` | WebFetch, `url:` row, "No, and tell Claude…" | 45, 100 |
| `card-subagent-bash` | in-process subagent: `· from the general-purpose agent` | 45, 100 |
| `card-plan` | plan approval, `❯` on "Yes, and use auto mode", basename wrapped in the footer at 45 | 45, 100 |
| `card-plan-change` | after "Tell Claude what to change" | 45, 100 |
| `card-plan-nofile` | **synthetic**: `card-plan-45` with the dialog replaced by the "Exit plan mode?" rows from `narrow-p.md` and an empty `input` | 45 |

  - Each README row gives the state, the layout, the width, the Claude build and the date. `card-plan-nofile` is marked synthetic.
  - Colour-dependent rules (the current tab) need `-e` captures, so all of these are `-e`.
- [ ] **Step 2: Write the failing tests**, one per rule, from the fixtures:
  - `optionsAndNumbers`: `card-ask-single` at both widths gives labels in order, numbers 1-5, and "Chat about this" with `belowRule`. `card-ask-numbers` gives labels `7` and `42` with numbers 1 and 2.
  - `multiSelectTicks`: `card-ask-multi-ticked` gives `checked` `[true, false, true, false]` for the list rows, and an unnumbered `Submit` row.
  - `cursorRow`: `cursorOption` is row 1 in `card-ask-multi-ticked` and the Other row in `card-ask-other-open`.
  - `reviewLines`: `card-ask-review` has `review` set, one `answers` and one `reviewQuestions` line per question, and numbered `Submit answers` and `Cancel` rows.
  - `previewLabelsWithoutTheBox`: `card-ask-preview` labels hold no `│`, `preview` is set, and "Chat about this" has no number.
  - `bashRegions`: at both widths, `card-bash` `norm(boxed)` equals the `norm`ed command, and `question` contains `Do you want to proceed`.
  - `wrappedLabelsJoin`: option 2 of `card-bash-45` is one option, not two.
  - `anchorsReadOnlyTheDialogRegion`: in `card-ask-single-45` and `card-bash-45`, `top` lies below every conversation row that echoes the question or command.
  - `classicLayout`: `card-bash-classic` reads like `card-bash-100`.
  - `noDialogOnIdle`: B's `idle-placeholder-45` and `working-45` read null.
- [ ] **Step 3: Run** `flutter test --no-pub test/prompt_dialog_test.dart`. Expected: FAIL.
- [ ] **Step 4: Implement** `PromptDialog.read`.
- [ ] **Step 5: Run.** Expected: PASS. **Commit** `feat(mobile): parse Claude's prompt dialogs from captured grids`.

---

### Task 3: Anchors

**Files:**
- Create: `mobile/lib/chat/prompt_match.dart`, `mobile/test/prompt_match_test.dart`

**Interfaces:**
- Consumes: `PromptDialog` (Task 2), `PendingCall` (B Task 3).
- Produces:
```dart
enum PromptKind { ask, permission, plan }
class PromptMatch { final PendingCall call; final PromptKind kind; final PromptDialog dialog; final int? question; } // question: shown index, null on Review
PromptKind? promptKind(PendingCall c); // AskUserQuestion, ExitPlanMode, Bash, Write, Edit, WebFetch, mcp__*
bool anchored(PromptDialog d, PendingCall c);
PromptMatch? matchPrompt(PromptDialog? d, List<PendingCall> pending); // null with no match, two or more, or clipped input
```

Anchor rules (spec, plus the resolutions in the Self-review):
- **Ask:**
  - One of `input.questions` matches: `norm(d.question)` equals its `question`, and the list's numbered labels start with its `options[].label` in order.
  - On Review, the `norm`ed `d.reviewQuestions` equal the input's questions, in order (`question: null`).
  - The header is used only when 10 characters or shorter.
- **Bash:** `norm(d.boxed)` equals `norm(command)` (spec). Containment would match both `npm test` and `npm test --watch` in a parallel batch.
- **Write, Edit:**
  - the `…`-cut path in `d.header` is a suffix of `file_path`;
  - `d.question` contains `basename(file_path)`.
- **WebFetch:** the `url:` value equals `input.url`, comparing without one trailing `/`. The probe showed `https://example.org/`.
- **MCP:**
  - the input has at least one argument, and every top-level argument value is in `norm(d.body)`: strings raw, other values as `jsonEncode`. With no argument nothing model-written is on screen, so there is no anchor and the panel sheet shows;
  - `name` starts with `mcp__`.
- **Plan:**
  - with `planFilePath` in the input: `norm(d.footer)` contains `basename(planFilePath)`;
  - without it: the first markdown heading of `input.plan` (its text after the `#`s) is in `norm(d.body)`;
  - with neither (the "Exit plan mode?" variant, empty input, or a heading off screen) there is no anchor and the panel sheet shows.
- **Source:**
  - `source == 'main'` needs `· from the` absent from `d.header`.
  - `source != 'main'` needs the header's `· from the <X> agent`, with `norm(X)` equal to `norm` of the call's `agentType` or `agentName`. A call with neither field, or an X that names neither, does not anchor.
  - A dialog that anchors to no pending call or to two goes to the panel sheet (`matchPrompt` returns null).
- Any other tool name has no kind (panel sheet).

- [ ] **Step 1: Write the failing tests**, each loading a fixture and its `.pending.json`:
  - `eachFixtureMatchesItsCall`: every `card-*` fixture except `card-plan-nofile`, at each captured width, matches its own call and kind.
  - `askQuestionIndex`: `card-ask-two` gives `question: 0`, `card-ask-two-second` gives 1, and `card-ask-review` gives null.
  - `otherCallDoesNotMatch`: swapping the Bash fixture's `command` for another one gives null.
  - `twoMatchesGoToPanel`: two pending calls with the same command give null.
  - `parallelBatchPicksTheShownCall`: the pending list of `card-bash` plus `card-write`'s call matches the Bash call on `card-bash-45`.
  - `bashPrefixCommandDoesNotMatch`: a running pending call whose command is a prefix of the shown one (`npm test` beside `npm test --watch`) does not match, so the shown call still wins alone.
  - `mcpWithoutArgumentsHasNoCard`: `card-mcp` with an empty `input` gives null.
  - `subagentSourceNeedsTheHeader`: `card-subagent-bash` with `source: 'main'` gives null; `card-bash-45` with `source: 'a1'` gives null.
  - `subagentHeaderNamesTypeOrName`: `card-subagent-bash` matches with only `agentType: 'general-purpose'`, and with only `agentName` equal to the header's X; with `agentType: 'Explore'` and no `agentName` it gives null; two subagent calls with the same command and type give null.
  - `clippedInputHasNoCard`: `clipped: true` with no input gives null.
  - `planAnchorsOnHeadingWithoutFile`: `card-plan` with `planFilePath` removed from its input still matches, on the plan's first heading.
  - `exitPlanWithoutPlanHasNoCard`: `card-plan-nofile` (empty input) gives null.
  - `webFetchTrailingSlash`: `input.url` `https://example.org` matches the row `https://example.org/`.
  - `unknownToolHasNoKind`: `NotebookEdit` gives null.
- [ ] **Step 2: Run** `flutter test --no-pub test/prompt_match_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): anchor prompt dialogs to pending calls`.

---

### Task 4: AskUserQuestion keystrokes

**Files:**
- Create: `mobile/lib/chat/card_steps.dart`, `mobile/test/support/fake_claude.dart`, `mobile/test/card_steps_test.dart`

**Interfaces:**
- Consumes: `PromptMatch`, `matchPrompt`, `anchored` (Task 3), `PromptDialog` (Task 2), `GateStep`, the `GateWrite` types and `WriteGate` (B Task 7).
- Produces:
```dart
sealed class CardAnswer {}
class QuestionAnswer { const QuestionAnswer({this.labels = const [], this.other, this.notes});
  final List<String> labels; final String? other; final String? notes; } // single choice: one label, or only other
class AskAnswer extends CardAnswer { AskAnswer(this.questions); final List<QuestionAnswer> questions; }
class AskDiscuss extends CardAnswer {} // "Chat about this"
class AskCancel extends CardAnswer {}
class OptionAnswer extends CardAnswer { OptionAnswer(this.label); final String label; } // a row by its verbatim screen label
class NoteAnswer extends CardAnswer { NoteAnswer({required this.yes, required this.text}); final bool yes; final String text; }
class PlanChange extends CardAnswer { PlanChange(this.text); final String text; }
List<GateStep> cardSteps(PromptMatch m, CardAnswer a); // the whole sequence, fixed before the first write
bool fieldShows(PromptDialog d, String text); // the cursor option's text contains norm of text's first line, first 40 chars, or "[Pasted text"
```
  - In `fake_claude.dart`: `ScriptedGrids(List<(Matcher write, Grid next)> script, Grid first)`. It implements B's `GateWriter` and the gate's `grids`/`grid`, recording writes and advancing to `next` when the write matches.
  - An unscripted write leaves the grid as it is, so the step times out.
- Every step's `ready` re-reads the dialog and requires `anchored(d, m.call)` plus the expected state. The `done` of the last step is that the dialog is gone or no longer anchored to the call.
- `cardSteps` reads the current grid's dialog once, for the current tab's ticks and cursor. Tabs not yet shown are expected to be untouched (nothing ticked, `❯` on row 1), and their first `ready` checks that.

Keystrokes (spec AskUserQuestion table, plus the report's check 1 rule on Tab and →):

| Answer | Steps (write → `done`) |
|---|---|
| Single choice | digit of `numbered(label)` → gone, the next question's text, or Review |
| Single Other | Other digit → `❯` on Other and footer has `ctrl+g to edit in nano`; `PasteWrite(other)` → `fieldShows`; `KeyWrite(enter)` → as single choice |
| multiSelect | per list row whose `checked` differs from `labels.contains(label)`: digit → that row flips and the cursor stays; then Other if wanted; then leave the tab |
| multiSelect Other | `KeyWrite(arrowDown)` per row until `❯` is on Other (`done`: cursor one row lower); `PasteWrite(other)` → Other `[✔]` and `fieldShows`; `KeyWrite(arrowUp)` → `❯` on the row above with the text kept |
| Leave a multiSelect tab | `ready`: `❯` on a list option that is not Other, Submit or Next. One question: `KeyWrite(tab)` → Review. Several: `KeyWrite(arrowRight)` → the next question's text or Review |
| Review | `ready`: for each question, its `→` line `norm`ed has the length of its wanted labels and Other text `norm`ed plus `n−1` commas, and contains each of them. Then the `Submit answers` digit → gone |
| Preview k | digit k → `❯` on label k, no submit; with notes: `ready` footer has `n to add notes`, `TextWrite('n')` → that text gone from the dialog; `PasteWrite(notes)` → the dialog contains the note; `KeyWrite(enter)` → gone |
| Discuss | the numbered `belowRule` row's digit → gone; no steps when it has no number |
| Cancel | on Review: the `Cancel` digit → gone; elsewhere: `ready` footer lacks `ctrl+g to edit in nano`, `KeyWrite(escape)` → gone (the only Esc a card sends, and always the last write) |

- A digit, Tab or → step's `ready` also requires the footer to lack `ctrl+g to edit in nano`, except the Other paste and its Up, which expect the field.
- A pre-ticked Other row that `other` does not want stops: that step's `why` is "Other is filled on the computer".

- [ ] **Step 1: Write the failing tests** with `fake_async`, a `WriteGate` over `ScriptedGrids`, and `Checks(keys: true, paste: true)`. Each sequence test runs over the `-45` and the `-100` fixtures (and `idle-placeholder-45`/`-100`); the names below give the 45 one:
  - `singleChoiceIsOneDigit`: `card-ask-single-45` and label `Production cluster` give one write, `TextWrite('2')`, and the run ends `done` when the script shows `idle-placeholder-45`.
  - `numericLabelsUseRowNumbers`: label `42` in `card-ask-numbers` gives `TextWrite('2')`.
  - `otherIsDigitPasteEnter`: three writes in order. The Enter goes out only after `card-ask-other-filled` shows.
  - `multiSelectSendsOnlyDifferingRows`: from `card-ask-multi-ticked`, wanting rows 1 and 2 gives `TextWrite('2')`, then `TextWrite('3')`, then Tab, then the Submit digit.
  - `twoQuestionsUseRight`: `card-ask-two` → `card-ask-two-second` → `card-ask-review`. A → step sits between the tabs, and Review is checked before the Submit digit.
  - `reviewMismatchStops`: a review line missing a label stops `mismatch` before the Submit digit.
  - `tabWaitsUntilCursorLeavesOther`: multiSelect with Other sends Up before Tab. Starting at `card-ask-multi-other` with no Up scripted, it stops `timeout` and no Tab is written.
  - `digitRefusedWhileOtherFocused`: a single-choice digit step on `card-ask-other-open` stops `mismatch` with no write.
  - `previewDigitThenEnter`, and `previewNotesSteps` (n, paste, Enter).
  - `discussNeedsANumber`: `card-ask-preview` gives no Discuss steps; `card-ask-single` gives one digit.
  - `cancelUsesReviewRowOrLastEsc`: on `card-ask-review` it is the Cancel digit. On `card-ask-single` it is one Esc and nothing after it.
  - `macAnswerMidSequenceStops`: in the multiSelect run, the grid turns to `idle-placeholder-45` after the first toggle, and the run stops `mismatch` at step 2.
- [ ] **Step 2: Run** `flutter test --no-pub test/card_steps_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the AskUserQuestion branch of `cardSteps`, and `fieldShows`.
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): AskUserQuestion answers as verified keystrokes`.

---

### Task 5: Permission and plan keystrokes

**Files:**
- Modify: `mobile/lib/chat/card_steps.dart`
- Test: `mobile/test/card_steps_test.dart`

**Interfaces:**
- Consumes: the Task 4 types.
- Produces: the permission and plan branches of `cardSteps`, and `bool needsSecondTap(PromptKind k, String label)`.
  - Permission: true for every row except the ones labelled exactly `Yes` and `No`.
  - Plan: true for every row except `Yes, manually approve edits` and `Tell Claude what to change`.
  - A label the card does not know therefore always needs the second tap, the safe direction under localization.

| Answer | Steps (write → `done`) |
|---|---|
| `OptionAnswer(label)` | digit of `numbered(label)` → gone |
| `NoteAnswer(yes: true)` | `ready`: `❯` on the `Yes` row. `KeyWrite(tab)` → the cursor label starts `Yes,` and the footer lacks `Tab to amend`; `PasteWrite(text)` → `fieldShows`; `KeyWrite(enter)` → gone |
| `NoteAnswer(yes: false)` | `KeyWrite(arrowDown)` per row until `❯` is on `No` (each `done`: cursor one row lower); `KeyWrite(tab)` → the cursor label starts `No,`; paste; Enter → gone |
| Plan `OptionAnswer` | the row's digit → gone |
| `PlanChange(text)` | the `Tell Claude what to change` digit → `❯` on it, still anchored; `PasteWrite(text)` → `fieldShows`; `KeyWrite(enter)` → the dialog is gone or no longer anchored to this call (a new plan) |

- A permission or plan sequence never sends Esc. The only bare Enter is the one after the card's own paste.

- [ ] **Step 1: Write the failing tests**, each over both widths as in Task 4:
  - `yesIsOneDigit`: `card-bash-45` → `TextWrite('1')`.
  - `noFindsItsRow`: `card-bash-45` → `TextWrite('4')`; `card-write` → `TextWrite('3')`.
  - `yesWithNote`: `card-bash-45` → `card-bash-amend` → (a scripted grid with the text) → idle gives Tab, paste, Enter.
  - `noWithReasonWalksDown`: three Downs, each after its `done`, then Tab, paste, Enter.
  - `noteNeedsCursorOnYes`: the cursor on row 2 stops `mismatch` with no write.
  - `secondTapRows`: in `card-bash`, rows 2 and 3 need it and `Yes`/`No` do not. In `card-plan`, `Yes, and use auto mode` needs it. An unknown label needs it.
  - `planNeverSendsBareEnter`: no answer to `card-plan` produces a `KeyWrite(enter)` except right after a `PasteWrite`.
  - `planChange`: `card-plan-45` → `card-plan-change` gives the digit, paste, Enter.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): permission and plan answers as verified keystrokes`.

---

### Task 6: Card frame and the AskUserQuestion card

**Files:**
- Create: `mobile/lib/chat/prompt_cards.dart`, `mobile/test/prompt_cards_test.dart`

**Interfaces:**
- Consumes: `cardSteps`, `CardAnswer`, `needsSecondTap` (Tasks 4, 5), `ChatPromptContext` (B Task 18), `Checks`, `CardChecks` (Task 1).
- Produces:
```dart
class CardFrame extends StatelessWidget { // title row "<Tool> · needs you", scrolling content, stacked full-width buttons, progress, reason line
  const CardFrame({super.key, required this.title, required this.content, required this.buttons, this.reason, this.onPanel}); ...
}
String stopMessage(GateResult r); // "Stopped at step k of n: <reason>. The prompt may be half answered."
Future<void> sendAnswer(ChatPromptContext c, PromptMatch m, CardAnswer a,
    {required VoidCallback onDone, required VoidCallback onStop}); // ok → onDone; stop → onStop, then c.openPanel(stopMessage(r)); busy → nothing
class AskCard extends StatefulWidget { const AskCard({super.key, required this.c, required this.m, required this.onDone,
    required this.onStop, this.checks = checks, this.cards = cardChecks}); ... }
```
- Buttons:
  - The primary (filled) button sits nearest the thumb. A second-tap button is outlined and shows its label verbatim. Its first tap shows `Tap again to confirm` for 3 s.
  - While `gate.running`, every button is locked and the primary shows `gate.progress`.
  - In the two Global Constraints cases (`checks.writeBlocked` non-null, or `c.remote` while `!checks.remote`), the buttons are disabled with that case's reason, and `Answer in panel` (`openPanel(null)`) shows.
- AskCard:
  - One step per question (`1/2`). Each step shows the header, the question, and one button per option with its description.
  - Previews show in mono in a horizontal scroll. Other is a text field that collects the text. On a single-choice step it shows only when `cards.singleOther`.
  - A single-choice step advances on tap; a multiSelect step has toggles and `Next`.
  - With two or more questions, a Review step lists the answers, then `Send`. With one question, a single-choice tap sends at once and a multiSelect question sends from `Send` (Self-review gap 9).
  - `Chat about this` shows only when its row has a number. `Cancel` sends `AskCancel`. `Notes` shows on a preview step only when `cards.previewNotes`.
  - The collected answers are state keyed by `call.id`, so a rebuild with a new grid keeps them.

- [ ] **Step 1: Write the failing widget tests** with a `ChatPromptContext` over `ScriptedGrids`:
  - `singleQuestionTapSends`: tapping `Production cluster` writes `2`, and `onDone` fires.
  - `multiQuestionCollectsThenReviews`: answer both steps, and the Review step lists them. `Send` runs one gate sequence.
  - `otherFieldCollectsText`.
  - `previewIsMono`.
  - `progressLocksButtons`: during a held write, a second tap writes nothing and the primary reads `Sending 1/3`.
  - `remoteRowDisabledUntilProven`: `remote: true` disables the buttons with `Answering is off on remote rows until checked`; `Checks(keys: true, paste: true, remote: true)` enables them.
  - `stopOpensPanelWithMessage`: a timeout calls `onStop`, then `openPanel` with `Stopped at step 1 of 3: …. The prompt may be half answered.`.
  - `blockedShowsReasonAndPanelButton`: with the default `Checks()`, the reason `Sending from the phone is not verified yet` and `Answer in panel` show.
  - `notesHiddenUntilProven`.
  - `answersSurviveRebuild`.
- [ ] **Step 2: Run** `flutter test --no-pub test/prompt_cards_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): AskUserQuestion card`.

---

### Task 7: Permission and plan cards

**Files:**
- Modify: `mobile/lib/chat/prompt_cards.dart`
- Test: `mobile/test/prompt_cards_test.dart`

**Interfaces:**
- Produces: `PermissionCard({required ChatPromptContext c, required PromptMatch m, required VoidCallback onDone, required VoidCallback onStop, Checks checks, CardChecks cards})` and `PlanCard(...)`, with the same parameters.
- PermissionCard:
  - Content from T:
    - Bash: `$ command` mono and the `description`.
    - Write: the content, mono, first 20 lines and then `More`.
    - Edit: the `old_string`/`new_string` as `-`/`+` lines.
    - WebFetch: the URL and the prompt.
    - MCP: the server and tool from `name`, then `key: value` per argument.
    - A subagent call says `from a subagent`.
  - Buttons: the dialog's option rows in screen order.
    - `Yes` is the primary.
    - Rows where `needsSecondTap` is true are outlined. They show only when `cards.persistOptions`; otherwise one `More options in panel` button stands in for them.
    - `Yes with a note` and `No with a reason` each open a field inside the card. They show for Bash always, and for Write, Edit and MCP when `cards.fileAndMcpNotes`.
    - WebFetch shows no answer button until `cards.webFetch`.
- PlanCard:
  - `input.plan` as markdown: the first 12 lines, then `More`.
  - `Yes, manually approve edits` is the primary.
  - `Change` opens a field and sends `PlanChange`.
  - The auto and bypass rows are outlined, need the second tap, and show only when `cards.persistOptions`.

- [ ] **Step 1: Write the failing widget tests:**
  - `bashCardYesNo`: the command and description show; `Yes` is filled and `No` is plain. Tapping `Yes` writes `1`.
  - `persistRowsAbsentUntilProven`: `card-bash` shows Yes, No and `More options in panel`. With `CardChecks(persistOptions: true)`, rows 2 and 3 show outlined, and one tap writes nothing.
  - `noteOnBashOnly`: `card-write` has no note buttons; with `fileAndMcpNotes`, it has both.
  - `webFetchPanelOnly`.
  - `planCardMarkdownAndChange`: the plan heading renders. `Change` with text writes digit 3, the paste, then Enter.
  - `planAutoAbsentUntilProven`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): permission and plan cards`.

---

### Task 8: Card lifecycle, the slot wiring, records

**Files:**
- Create: `mobile/lib/chat/prompt_ledger.dart`, `mobile/test/prompt_ledger_test.dart`
- Modify: `mobile/lib/chat/chat_view.dart`, `mobile/lib/chat/items.dart`, `mobile/lib/screens/session.dart`
- Test: `mobile/test/chat_screen_test.dart`

**Interfaces:**
- Consumes: everything above; `TranscriptFeed`, `ChatView`, `chatRowWidget`, `ChatPromptContext` (B).
- Produces:
```dart
class PromptLedger extends ChangeNotifier {
  PromptLedger({required Listenable grids, required Grid? Function() grid, required TranscriptFeed feed,
      required String? Function() blocked}); // blocked: the screen's WriteGate.blocked, B's ChatView.blockedReason
  void shown(String id); // first time: HapticFeedback.heavyImpact
  void answered(String id); // the phone's sequence ended done
  void stopped(String id); // no card for this id until the dialog is gone
  bool suppressed(String id);
  String? mark(String toolId); // "Closed on the computer", or null
}
PromptCardBuilder promptCardBuilder(PromptLedger ledger, {Checks checks = checks, CardChecks cards = cardChecks});
```
- The builder:
  - Reads `PromptDialog.read(c.grid)` and `matchPrompt(dialog, c.pending)`.
  - Returns null (B then opens the panel sheet) when `!c.grid.colours` (a non-Live pane), there is no match, or `ledger.suppressed(id)`.
  - Otherwise it returns the card for `m.kind`, keyed by `m.call.id`, and calls `ledger.shown`.
    - It passes `onDone: () => ledger.answered(id)` and `onStop: () => ledger.stopped(id)`.
  - A blocked or remote-unproven card is still returned; the card disables its own buttons (Task 6).
- The ledger:
  - On each grid while it holds shown ids still in `feed.pending`, it counts the grids whose dialog is not anchored to that id. At two, and when the id was not `answered`, it marks it `Closed on the computer`.
    - A null grid (replaying after a Resync) or a `blank` one is skipped, never counted.
  - An id leaving `feed.pending` (the `tool_result` arrived) clears its entries.
  - A `feed.switches` bump (file switch or reset) clears everything.
  - While `blocked()` is non-null (exited or stale), every mark clears and no grid is counted.
  - A stop clears when `ClaudeScreen.read(grid).bottomStack` returns.
- `chatRowWidget` takes `promptMark`. A main-chain tool row shows `ledger.mark(id)` while it is non-null.
  - A subagent's call has no row in the main list, so its closed state shows nothing; the subagent row stays as B draws it.
- A tool row whose item has plan A's `rejected` shows `Rejected` instead of B's mark, whether or not it had a card. Plan C never reads the result wording.
- `ChatView`:
  - passes `prompts?.mark` to every row;
  - closes a panel that the dialog opened by itself when `promptCard` returns a card (T arrived late);
  - keeps a panel opened by `openPanel(stopped)` open.
- Chat never shows `AnswerBar` outside the panel sheet. `promptOptions` and the Term and home answer bars stay as they are (spec "Answer bar").

- [ ] **Step 1: Write the failing tests:**
  - `prompt_ledger_test.dart`, with `fake_async` and scripted grids:
    - `closedOnTheComputerAfterTwoGrids`: shown, then two idle grids with the call still pending, gives the mark. One idle grid gives no mark.
    - `answeredIsNeverClosed`.
    - `resultClearsMark`.
    - `switchClearsAll`.
    - `resyncDoesNotClose`: shown, then two null grids and a blank one, with the call pending, give no mark.
    - `exitClearsMark`: a marked id loses its mark when `blocked()` turns non-null, and stays unmarked while it is.
    - `stoppedSuppressesUntilStack`.
  - `chat_screen_test.dart`, in B's harness:
    - `cardDocksForAMatchedCall`: the `card-bash-45` grid and its pending, held two grid updates, show `PermissionCard`, and no panel opens.
    - `unmatchedDialogOpensPanel`: the same grid with an empty `pending`.
    - `noCardWithoutColours`: the `card-bash-45` rows as a `Grid.text` grid, with the matching pending, give no card and open the panel.
    - `lateTranscriptReplacesPanel`: the panel opens; the next poll adds the pending call; the card shows and the panel closes.
    - `stopKeepsPanelAndNoCard`: after a stopped run, the panel stays with the message, and no card shows while the dialog stays.
    - `remoteRowGetsDisabledCard`: with `remoteHost` set and B's default `checks.remote` false, the card docks with `Answering is off on remote rows until checked` and `Answer in panel`.
    - `toolRowShowsClosedMark`.
    - `toolRowShowsRejected`: a Bash tool item with `isError: true, rejected: true` reads `Rejected`; one with `isError: true` and no `rejected` keeps B's mark.
    - `chatShowsNoAnswerBarOutsidePanel`: no `answer-1` key in Chat with a dialog card up.
- [ ] **Step 2: Run** `flutter test --no-pub test/prompt_ledger_test.dart test/chat_screen_test.dart`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** In `session.dart`, create the ledger beside the feed, dispose it with the screen, and pass `promptCard: promptCardBuilder(ledger)` and `prompts: ledger` to `ChatView`. The ledger's `blocked` is the function the screen gives `WriteGate.blocked`.
- [ ] **Step 4: Run** both, then `flutter test --no-pub test/panel_sheet_test.dart`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(mobile): prompt cards in Chat, with answered and closed states`.

---

### Task 9: Open check 10 and remote card checks (lead session only)

This task launches claude, a Debug Mac instance and the emulator. It needs plans A and B merged into this branch. Do not run it while another agent edits the worktree.

**Files:**
- Create: `mobile/integration_test/card_checks_test.dart`
- Modify: `mobile/lib/chat/card_checks.dart`, `mobile/lib/chat/checks.dart` (B's `remote` only)

- [ ] **Step 1: Rig.** Use plan B Task 1's rig: AVD `elis-chat-test`, an isolated Debug instance with `ELIS_STATE_DIR=/tmp/ecb`, and `elisctl mobile serve --host 10.0.2.2` from the Debug binary. Open a Live session running `cd /Users/n.savchenko/IdeaProjects/elis/.claude/worktrees/phone-chat-mode && claude --model haiku --permission-mode default`. Record `claude --version`.
  - The worktree is the cwd because Claude already trusts it: the 2026-11-20 checks saw no trust prompt there. Never use the main checkout, because check 10.3 writes rules into the cwd.
  - Before the run, copy the worktree's `.claude/settings.local.json` aside, if it exists.
- [ ] **Step 2: Write the probe** `card_checks_test.dart`, skipped unless `--dart-define=CARD_CHECKS=1`.
  - It pairs, opens Chat on the session, and has Claude raise each prompt through `session.type` with a plain request (Memroot: no tool instructions), aimed at files under `/tmp/ecb-cards/`.
  - It answers through the real card widgets, by tapping, and prints `CHECK 10.<n>: PASS|FAIL <rows>`.
  - A check PASSes when the gate run ends `done` and the transcript's `tool_result` shows the intended answer.
  - The checks:
    - **10.1** Yes with a note on Write, Edit and MCP. The note shows as a user message.
    - **10.2** No with a reason on Write.
    - **10.3** Each persist or mode row: Bash row 2 (the rule lands in the worktree's `.claude/settings.local.json`), Bash `switch to auto mode`, Write row 2, and plan `Yes, and use auto mode`. Restore the mode with the chip afterwards.
    - **10.4** Preview notes at 45 columns: start the session at 45 columns, the only case that changes the grid size.
    - **10.5** WebFetch: Yes, then its `No, and tell Claude…` row, recording whether the digit opens a field.
    - **10.6** The never-seen rows:
      - a single-choice Other Enter at 45 columns, which sets `singleOther`;
      - multiSelect with previews: FAIL only when a card matched and its run then stopped (a Task 2/3 parser bug, fixed with a new fixture); a card answering it or the panel opening is PASS;
      - a tall plan at Mac width, with the same FAIL condition.
- [ ] **Step 3: Run** `flutter test integration_test/card_checks_test.dart -d emulator-5554 --dart-define=CARD_CHECKS=1 --dart-define=PAIR_LINK='elis://pair?…'`.
  - Before running it, set the flag under test to `true` in a local, uncommitted `card_checks.dart` (and B's `checks.remote` in `checks.dart` for the Step 4 rows), so each step is reachable.
- [ ] **Step 4: Remote.** For each kind, an attached-Mac row and an elis-server row, that is reachable: attach the row, check that the phone reads `Session.remote` true on it, then re-run plan B's `open_checks_test.dart` checks 1 and 2, recording the slowest write-to-change time (check 3), then 10.1, on that row.
  - A row of either kind that reads `remote` false would get enabled cards on an unproven path: file it as a blocker on plan B (its gap 8, proven in B Task 20 Step 3), and do not ship plan C until it is fixed.
  - Set B's `checks.remote: true` in `checks.dart` only when both kinds passed. One kind alone leaves it false.
  - Record the slowest write-to-change time. If it exceeds `checks.timeout`'s 5 s remote cap, file that as a blocker on plan B.
  - With no host reachable, leave `remote: false`. Remote cards then stay disabled with their reason (scope call 2).
  - That is an open blocker, not a finished plan. CLAUDE.md accepts a missing remote path only with the owner's approval in a direct AskUserQuestion that explains what does not work remotely, why, and what supporting it would cost. Ask for that, or schedule the remote run.
- [ ] **Step 5: Set `cardChecks`** (and B's `checks.remote`) from the results, with one comment line naming the date and the Claude build. A FAIL leaves its flag false; that step stays in the panel sheet.
  - If a rejected answer's tool row does not read `Rejected`, report it against plan A's rejection prefixes.
  - A 10.5 field-opening No row gets `webFetch: false` and a note in the Self-review gaps.
- [ ] **Step 6: Stop the rig.** SIGTERM the known pids. Run `lsappinfo list | grep -A4 elis.debug`. Remove `/tmp/ecb-cards`.
  - Restore the worktree's `.claude/settings.local.json` from the copy, or delete it if none existed. `git status` shows no change outside `mobile/`.
- [ ] **Step 7: Commit**, after restoring the pubspec lines: `test(mobile): card open checks, outcomes recorded`.

---

### Task 10: Docs

**Files:**
- Modify: `site/docs.html`, adding the subsection "Answering Claude's prompts" inside plan B's "Chat on the phone".

- [ ] **Step 1: Write it by task**, in short paragraphs:
  - what a card shows;
  - answering a question with several steps;
  - Other and notes;
  - Yes or No with a note;
  - why some options need a second tap;
  - what "Sending 2/4" and "Stopped at step k of n" mean, and what to do next (the panel sheet);
  - "Closed on the computer";
  - when the panel sheet shows instead: unknown dialogs, subagent teammates in their own pane, and steps not yet verified;
  - a disabled card on a remote row until remote answering is verified.
  - The card screenshot is added in Task 11 Step 5.
- [ ] **Step 2: `site/index.html`:** the phone section's "Answer an agent from anywhere" point names questions, permission prompts and plan approvals as cards in Chat. Change only that point.
- [ ] **Step 3: Check** that every link is relative. Bump `style.css?v=` only if CSS changed.
- [ ] **Step 4: Commit** `docs: prompt cards on the phone`.

---

### Task 11: End-to-end on the emulator, then the gates (lead session only)

This needs plans A and B merged into this branch. Run it alone in the worktree.

- [ ] **Step 1: Rig** as in Task 9 Step 1, with the same worktree cwd and settings copy. Install with `flutter run -d emulator-5554 --release`, pair, and open the Claude session in Chat.
- [ ] **Step 2: Walk the checklist.** Record pass or fail with `adb exec-out screencap -p` for each:
  - AskUserQuestion:
    - single choice;
    - two questions with Review;
    - multiSelect with Other;
    - a preview option;
    - Chat about this;
    - Cancel.
  - Permissions:
    - Bash Yes;
    - Bash No with a reason;
    - Write Yes;
    - Edit No;
    - an MCP Yes;
    - a subagent Bash Yes, with the in-process teammate settings.
  - Plans:
    - approve manually;
    - Change, then approve the new plan.
  - A proven persist row, with its second tap.
  - Answer one prompt on the Mac with `ELIS_STATE_DIR=/tmp/ecb <Debug>/elisctl session type` while the card is up. The card turns into "Closed on the computer", then into the record.
  - A dialog with no pending call (`/model`) opens the panel sheet, never a card.
  - Every answered card collapses into its tool row, and a rejected one reads `Rejected`.
- [ ] **Step 3: Remote rows:** on an attached row and on an elis-server row, each reachable one, first confirm the phone reads `Session.remote` true; one that reads false is the Task 9 Step 4 blocker. If Task 9 proved `remote`, repeat Bash Yes and a single choice on both. Otherwise confirm that the card shows disabled with its reason, and report the remote blocker as still open.
- [ ] **Step 4: Stop the rig**, and restore `.claude/settings.local.json` as in Task 9 Step 6. SIGTERM the known pids, run `lsappinfo list | grep -A4 elis.debug`, and check `adb -s emulator-5554 shell pm list packages | grep ua.naiksoftware.elis`.
- [ ] **Step 5: Docs screenshot.** Add one card screenshot from Step 2 to `site/docs.html`'s "Answering Claude's prompts" (`cwebp -q 82` into `site/assets/`). It shows no machine name, hostname, username or `/tmp` path (the owner's preference overrides CLAUDE.md's Website rule).
- [ ] **Step 6: Gates, each once:**
  - `cd macos/ElisCore && swift test`;
  - `cd macos && make test-app`, then `lsappinfo list | grep -A4 elis.debug`;
  - `make lint`;
  - in `mobile/`: the temporary `sdk:` constraint, `flutter pub get`, `flutter analyze --no-pub` (0 issues) and `flutter test --no-pub`, then restore the `sdk:` lines.
- [ ] **Step 7: Commit** any fixture the run corrected and the screenshot, `test(mobile): prompt cards end-to-end fixes`.

---

## Self-review

Spec coverage:

| Spec item | Task |
|---|---|
| When a card shows: T pending, G anchor, G rows; panel otherwise; late T; parallel batch | 3, 8 |
| Shared rules 1-3, 15 (one key, re-check, wait, gate) | B 7, 4, 5 |
| Rules 4-5 (join, row numbers) | 2, 4 |
| Rules 6-8 (paste, no Esc in fields, nothing after) | 4, 5 |
| Rule 9 (stop message, no resume) | 6, 8 |
| Rule 10 (second tap) | 5, 7 |
| Rule 11 (multiSelect diff) | 4 |
| Rule 12 (composer disabled, fields in the card) | B 18, 6, 7 |
| Rule 13 (model-string anchors) | 3 |
| Rule 14 (unproven steps in the panel) | 1, 6, 7, 9 |
| Record, "Rejected", "Closed on the computer" | 8 |
| AskUserQuestion table | 4, 6 |
| Permission table, subagent anchor | 3, 5, 7 |
| Plan table, the no-file variant | 3, 5, 7 |
| Answer bar | 8 |
| Non-Live pane: no cards (Polling) | 8 |
| Mac-width grids (Lead and grid size) | 2-5 |
| Notification haptic | 8 |
| Open check 10; remote checks 1-3 | 9 |
| Fixtures from real grids | 2 |

Spec gaps and how this plan resolves them:
1. **Esc merges with the next key** (open check 1 FAIL). Plan B's gate holds `escapeGap` (100 ms) after any Esc (B Task 7). A card sends Esc only as the last write of a Cancel.
2. **The phone path was checked locally only.** On remote rows, cards show disabled with `Answering is off on remote rows until checked` behind B's `checks.remote` until Task 9 measures both an attached and an elis-server row, and the panel sheet answers meanwhile. The guard rests on B's `Session.remote`, so Tasks 9 and 11 check it reads true on both row kinds. This applies scope call 2 to the unproven remote path. Leaving it unmeasured needs the owner's AskUserQuestion approval.
3. **The subagent header names the agent** ("· from the X agent"). Plan A's pending entries carry `agentType` and `agentName`, and X must equal one of them; no match or two matches go to the panel sheet (Task 3).
4. **Teammate-pane prompts are not in plan A's pending**, and a `clipped` pending has no input. Both get the panel sheet (Task 3 tests).
5. **Tab and → do nothing while `❯` is on a filled Other row or on Next** (report, check 1). Those steps' `ready` requires a list option, and multiSelect Other sends Up first.
6. **WebFetch** has no row labelled exactly "No" and no "Tab to amend", and its `url:` row adds a trailing `/`. The URL compare drops one trailing `/`, and every WebFetch answer waits for check 10.5.
7. **Answered and closed states outlive the dialog**, but B asks the slot only while a dialog counts. `PromptLedger` marks the main-list tool row instead, through a `promptMark` parameter added to B's `chatRowWidget`. A subagent's call has no such row, so its closed state is not shown.
8. **Paste placeholders in dialog fields were measured only on the main row.** `fieldShows` accepts the text or `[Pasted text`.
9. **"Then a Review step and Send" for every AskUserQuestion card.** A single question skips the card's Review, as Claude's own dialog does: one tap sends a single choice. Two or more questions keep the Review.
10. **No 45-column permission grids exist on disk**, and the scratchpad captures hold private paths. Task 2 recaptures every fixture; only `card-plan-nofile` is synthetic.
11. **`planFilePath` is not assumed.** The plan card anchors on the footer's `basename(planFilePath)` when the input has it, else on the plan's first heading; the "Exit plan mode?" variant (empty input) has neither and falls back to the panel sheet, as the spec says. Task 2 records a real `ExitPlanMode` input (Task 3).
12. **"Rejected" for any `is_error`** (spec) would also mark an approved Bash call that failed. Plan C reads plan A's `rejected` field, which A tests against captured rejections and an approved failing Bash call.
13. **Resolved in plan B:** open check 5 found that Ctrl+U clears one wrapped row per press with no fixed limit; plan B Task 16 repeats it one step at a time until the input is empty, stopping after 40.
