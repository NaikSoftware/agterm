# Phone Chat View (Plan B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone's session screen gains a Chat mode beside Term that draws a Claude Code session as a native chat built from `session.transcript`, mirrors Claude's live state from the vt grid, and writes to Claude only through one write gate.

**Architecture:** New code lives in `mobile/lib/chat/`: a decoder and a polling feed for plan A's `session.transcript`, a `Grid` view over the vt rows with a width-agnostic `ClaudeScreen` classifier tested against captured grids, a `WriteGate` that every Chat write (and plan C's cards) goes through, and the Chat widgets. `session.dart` only gains the Chat/Term switcher, the mode pick, the poll hook and the no-resize lead rule; the composer, key bar and answer bar move into shared widgets so Term and Chat use the same components.

**Tech Stack:** Flutter (Dart 3.13, Android), `flutter_markdown_plus` 1.0.12, the existing `elis/open` method channel, libvtshim through `TermSession`.

**Spec:** `docs/superpowers/specs/2026-11-20-phone-chat-mode-design.md` (sections The Chat screen, Composer and the "/" menu, Panel sheet, States, Polling, Lead and grid size, Remote parity, Open checks). Base: `docs/superpowers/plans/2026-11-19-phone-direct-input-m5b.md` (the lead and input paths this plan reuses).
The open-check report of 2026-11-20 on Claude Code 2.1.329 (`/private/tmp/claude-502/-Users-n-savchenko-IdeaProjects-elis/96123572-0e60-465e-958a-b0ed3100d48a/scratchpad/open-checks.md`, local rows only) takes precedence over the spec's evidence tags where they differ, as in plan C.

## Interfaces shared with other plans

Plan B consumes plan A's `session.transcript` exactly as `docs/superpowers/plans/2026-11-20-phone-chat-a-transcript-api.md` ("Interfaces shared with other plans") defines it.
The names this plan relies on, copied from there:

- Args: `pane` (`left`/`right`, omitted = the session's `agentPane`), `paneID`, `after` and `before` as **decimal strings**, `transcript`, `maxBytes`.
- Result, flat on `result`: `transcript`, `size`, `start`, `next`, `reset` (omitted when false), `items`, `pending` (omitted when empty), `meta`, `commands` (tail page, or when `skillsAt` falls in the polled range), `skipped` (omitted when 0).
- Cursor:
  - `next < size` means "poll again now".
  - A `before` page's `start` is the next `before`.
  - `reset: true` replaces everything with this tail page.
- **Upsert:** an item whose `uuid` the phone already holds replaces that item in place. This is how a tool row gets its result and a text item its later blocks.
- Every item has `kind`, `uuid`, `at`, `time` (the record's timestamp string).

| Item `kind` | Fields B reads |
|---|---|
| `user` | `text`, `promptSource`, `origin` (the `origin.kind` string), `clipped` |
| `image` | `mediaType`, `bytes`, `data` (base64, absent over the cap) |
| `command` / `commandOutput` / `bash` | `name` (no `/`), `args` / `text`, `clipped` / `text` (the `!` input) |
| `interrupted` | none |
| `compactSummary`, `taskNotification`, `error`, `hook` | `text` (`clipped` on the first two) |
| `notice` | `text`, `level` |
| `compact` | `trigger` |
| `text` | `text`, `message` (API `message.id`), `clipped` |
| `thinking` | `durationMs` |
| `tool` | `id`, `name`, `arg`, `mark`, `running`, `output`, `patch` `[{oldStart, oldLines, newStart, newLines, lines}]`, `file`, `isError`, `rejected`, `exitCode`, `readOnly`, `agentType`, `agentName`, `agentColor`, `clipped` |
| `oversized` | `bytes` |

- `mark` values: `running`; Bash `ok`, `exit N`, `error`; Edit/Write `+N −M` or `+N`; Agent `done` or `error`; other tools `error` or absent.
- `rejected` (omitted when false): the user rejected the prompt; an approved call that failed has `isError` only. B and C read it and never match Claude's wording.
- **Pending** `[{id, uuid, source, agentType, agentName, name, input, clipped}]`: `source` is `main` or the bare `agentId` (`a1`, never `agent-a1`); `agentType` and `agentName` only on subagent entries, when present; `input` is passed as Claude wrote it.
- **Meta** `{title, lastPrompt, permissionMode, pr: {prNumber, prRepository, prUrl}, agentName, model, effort, todos: [{content, status, activeForm}], queued: [string], continuedIn, skillsAt}`.
- **Commands** `[{name, description, source: builtin|skill, panel}]`.
- **Errors:** `no adapter`, `transcript not found`. Host too old: a message starting `unknown command`, one containing `too old`, or one starting `invalid request:` that contains `session.transcript`.
- **Tree:** raw `agent`, `agentSessionId`, `agentPane` (`left`/`right`, omitted when no agent), and the existing `remoteHost`.
- **Grouping:** the visual grouping of 3+ consecutive `readOnly` tool items is B's (plan A leaves it to the phone).

Plan B produces, plan C consumes (all in `mobile/lib/chat/`):
- `Grid`, `ClaudeScreen` (Task 5, 6), `WriteGate`, `GateStep`, `GateWrite`, `GateSequence`, `GateResult` and `escapeGap` (Task 7).
- `TranscriptFeed.pending` and `PendingCall` (Task 3, 4).
- `Checks.remote` and `Checks.writeBlockedOn(remote:)`, the one remote flag; plan C reads `remote` with its own card reason (Task 1).
- The card slot `PromptCardBuilder` and `ChatPromptContext`, and `openPanel(String? stopped)` (Task 18).
- `AnswerBar` (Task 8), and `checks.dart` constants (Task 1).

The report settles checks 1, 2, 4, 5, 13, 14 and 18 locally and gives check 3's local figures; Task 1 records them and runs only check 12, plus an end-to-end re-confirmation of 1 and 2 through the real relay. Task 5 covers check 11's classic and Ctrl+O fixtures.
Check 9 is settled by the spec's Lead section: the grid stays as it is. Checks 6 to 8, 15 to 17 belong to plan A; check 10 and the remote runs of checks 1 to 3 belong to plan C (Task 9), whose result sets `Checks.remote`.
Docs: plan B owns the "Chat on the phone" section of `site/docs.html`, the Chat point in `site/index.html`'s phone section, and `mobile/README.md`; plan A owns `site/commands.html`, `.claude/rules/control-api.md` and the skill.

## Global Constraints

- Work in `mobile/`; run `flutter analyze --no-pub` (0 issues) and `flutter test --no-pub test/<file>` per task, the full suites once in Task 20.
- Local Flutter 3.47.2 needs the temporary constraint `sdk: ^3.13.2` and `flutter pub get` before any flutter command. Before each commit restore only the `sdk:` line of `pubspec.yaml` (`^3.13.7`) and any `sdks:` line change in `pubspec.lock`. Task 10 adds `flutter_markdown_plus: 1.0.12`: that dependency line and its lock entries are committed.
- No new dependency besides `flutter_markdown_plus` 1.0.12. Links open and text is shared through the existing `elis/open` channel (`MainActivity.kt`).
- Chat never sends `session.grid`, a claim RESIZE, `session.scroll`, PgUp, `{` or wheel events; scrolling acts only on the phone's list.
- Every Chat write goes through `WriteGate`; the panel sheet's key bar is the only exemption.
- One key per write; a paste is one write; Enter is its own write; an Esc is followed by `escapeGap` (100 ms) before the next write (check 1).
- No Chat sequence or probe sends Ctrl+C: it arms "Press Ctrl-C again to exit" (check 5). The exempt key bar keeps its keys.
- Anchors use model-written strings; UI strings ("Queued", "mode on", "esc to interrupt") are only expected-state checks, and a missing one disables or stops, never guesses.
- Every classifier rule is width-agnostic: join wrapped rows and ignore whitespace before comparing.
- Remote rows (attached Mac, elis-server, `remoteHost` set) take the same code path, polled every 2 s instead of 700 ms.
  Send and the mode chip stay disabled there until `checks.remote` (scope call 2: checks 1 and 2 passed only locally).
- A banner, chip, row mark or sheet that depends on G clears when G stops showing its anchor, and on file switch, reset, exit and stale.
- Never execute `elis`/`elisctl` against the default socket, never launch or quit the deployed app; only the isolated Debug instance of the rig is driven.
- Never use the owner's phone or the `Pixel_5`, `Medium_Tablet`, `mf-d1`, `srpaging` AVDs.
- Every screenshot (records and docs) shows no machine name, hostname, username or `/tmp` path; the owner's preference overrides CLAUDE.md's Website rule.
- Comments one line, only for constraints the code cannot show (CLAUDE.md Working norms).

## Review Focus

1. A Chat write while the lead is still pending: `TermSession` queues it and drains later without a fresh grid check. The gate must claim and wait for `leading`, then check, then write. Test: Task 7 `gateWaitsForLeadBeforeChecking`.
2. A paste while mode 2004 is off: `encodePaste` turns newlines into CR and submits. The gate must stop with a reason. Test: Task 7 `pasteStopsWithoutBracketedPaste`.
3. Entering Chat must not resize Claude on the Mac: no fit on open, no claim on OPENED, a claim at the snapshot's grid at the first write, no RESIZE on rotation or keyboard. Test: Task 9 `chatNeverResizes`.
4. A reset or file switch arriving while a page of older items is in flight: the late `before` reply must be dropped, never spliced into the new transcript. Test: Task 4 `staleBeforeReplyIsDropped`.
5. A mode line the classifier does not recognize (a new build, another language, a vim mode suffix): the mode chip is disabled and never cycles Shift+Tab blind. Tests: Task 6 `unknownModeLineHasNoMode`, Task 17 `chipDisabledWithoutAKnownMode`.

---

## File Structure

| File | Responsibility |
|---|---|
| `lib/chat/checks.dart` | Open-check outcomes as constants, each with the reason text shown when it disables a feature |
| `lib/chat/mode.dart` | `ViewMode`, the per-session manual pick, `chatAvailable` |
| `lib/chat/transcript.dart` | Decoding a `session.transcript` reply: `TranscriptPage`, `ChatItem`, `PendingCall`, `TranscriptMeta`, `SlashCommand` |
| `lib/chat/feed.dart` | `TranscriptFeed`: tail polling, paging back, reset and switch, stale and error state |
| `lib/chat/grid.dart` | `Grid`: rows from a `VtSnapshot` or from `session.text`, text and non-dim text per row |
| `lib/chat/claude_screen.dart` | `ClaudeScreen.read(Grid)`: bottom stack, input row, working line, limit, queued, statusline rows, mode line, shells, streaming rows |
| `lib/chat/write_gate.dart` | `WriteGate` and its writers (lead channel, `session.type`) |
| `lib/chat/rows.dart` | `chatRows(items)`: day separators, read-only tool grouping, sticky prompt lookup, model label |
| `lib/chat/items.dart` | One widget per row kind (bubbles, markdown, tool rows, diff, dividers, images, thinking, subagent) |
| `lib/chat/chat_view.dart` | The list, header, states, bottom stack, composer, card slot |
| `lib/chat/bottom_stack.dart` | Working line, limit banner, queued rows, statusline, streaming area |
| `lib/chat/chat_composer.dart` | Draft adoption, Send/Queue sequence, disabled reasons, "/" menu, mode chip, shell badge |
| `lib/chat/panel_sheet.dart` | Live rows, key bar and answer bar in a sheet; the stopped-sequence message |
| `lib/screens/composer.dart`, `lib/terminal/key_bar.dart`, `lib/screens/answer_bar.dart` | The composer, key bar (with `keys` and `xtermSeq`) and answer bar moved out of `session.dart` |
| `test/support/ansi.dart` | `gridFromAnsi`: replays a `tmux capture-pane -p -e` capture into a `Grid` without libvtshim |
| `test/fixtures/grid/` | Captured grids and their README |

---

### Task 1: Open checks on the phone path

Steps 1 and 7 are for any implementer. Steps 2 to 6 run in the lead session only: they launch a Debug instance and an emulator, which CLAUDE.md forbids delegated agents.
Tasks 2 to 19 do not wait for Steps 2 to 6; they read the Step 1 outcomes, which come from the open-check report.
The emulator rig defined here is reused by Task 20.
Do not run Steps 2 to 6 while another agent edits the worktree: the probe builds from the working tree (Memroot failed_approach on shared worktrees).

**Files:**
- Create: `mobile/integration_test/open_checks_test.dart`, `mobile/lib/chat/checks.dart`
- Modify: `mobile/lib/terminal/vt.dart` (`VtKey.s(38)`, `VtKey.x(43)`: `GHOSTTY_KEY_A` is 20 and the letters run in order, as `c(22)` and `u(40)` show)
- Test: `mobile/test/vt_test.dart`

**Interfaces:**
- Produces, in `checks.dart`:
```dart
class Checks {
  const Checks({this.keys = false, this.paste = false, this.clearInput, this.sendNow = false, this.remote = false,
      this.pastedCommandRuns = false, this.pastedBangSwitches = false, this.timeout = const Duration(seconds: 2)});
  final bool keys, paste; // checks 1, 2
  final (VtKey, int)? clearInput; // check 5: the one key Send repeats to clear; null: an adopted draft is never cleared
  final bool sendNow; // check 12
  final bool remote; // checks 1-3 passed on an attached row and an elis-server row (plan C Task 9 sets it)
  final bool pastedCommandRuns, pastedBangSwitches; // checks 4, 14
  final Duration timeout; // check 3
  String? get writeBlocked; // null when keys and paste hold, else 'Sending from the phone is not verified yet'
  String? writeBlockedOn({required bool remote}); // writeBlocked, else on a remote row while !this.remote
      // 'Sending from the phone is not verified on remote sessions yet'
}
const checks = Checks(/* the recorded outcomes */);
```
- The gate, composer and bottom stack take `Checks checks = checks` as a parameter, so tests can pass other outcomes.
- `writeBlockedOn` disables Send and the mode chip. Cards are disabled by `writeBlocked`, and on a remote row while `!remote`, with plan C's own reason text "Answering is off on remote rows until checked".
  Stop and Cancel stay enabled (scope call 2 names only the first three).

- [ ] **Step 1: Commit the recorded outcomes.** Write `checks.dart` and the two `VtKey` values. `checks` takes the report's local results, with one comment line naming it, 2026-11-20 and Claude 2.1.329:
  - `keys: true`, `paste: true` (checks 1, 2; Esc is handled by `escapeGap`, Task 7);
  - `clearInput: (VtKey.u, vtCtrl)` (check 5: one row per press, count unbounded; never Ctrl+C);
  - `pastedCommandRuns: true` for the `/cmd args` form (check 4; Task 16 keeps bare names exact);
  - `pastedBangSwitches: true` (check 14: a pasted `!` equals a typed one);
  - `timeout: 2 s` (check 3 locally: slowest write 14 ms, lone Esc 63 ms; the remote figure is open);
  - `sendNow: false` and `remote: false` until measured.
  - Add to `vt_test.dart` the test `ctrlXAndCtrlSEncode`, expecting `encodeKey(VtKey.x, mods: vtCtrl)` to equal `[0x18]` and `encodeKey(VtKey.s, mods: vtCtrl)` to equal `[0x13]`.
  - Symlink `mobile/build/vtshim` from the main checkout so the test runs. A skip here counts as a failure.
  - Run `flutter test --no-pub test/vt_test.dart`, expecting PASS.
  - Commit `feat(mobile): open-check outcomes for Chat from the 2026-11-20 report`.
- [ ] **Step 2: Rig (lead session only).**
  - Create AVD `elis-chat-test` from `system-images;android-34;google_apis;arm64-v8a`.
  - Build and start an isolated Debug Mac instance per CLAUDE.md: `ELIS_STATE_DIR=/tmp/ecb`, `env -u` every inherited `CLAUDE*`/`ELIS_*`/`GHOSTTY_*`, `open -n --env ELIS_STATE_DIR=/tmp/ecb`.
  - Run `ELIS_STATE_DIR=/tmp/ecb <Debug Contents/MacOS>/elisctl mobile serve --host 10.0.2.2`, which resolves the instance's socket from the state directory.
  - Open a Live session in it running `cd ~/IdeaProjects/elis && claude --model haiku --permission-mode default`.
  - Record the Claude build (`claude --version`).
- [ ] **Step 3: Write the probe** `open_checks_test.dart`, skipped unless `--dart-define=OPEN_CHECKS=1`.
  - It pairs with `PAIR_LINK` and opens a `TermSession` on the session's pane, then claims and waits for `leading`.
  - It prompts Claude through `session.type`, then sends writes and reads `snapshot` text.
  - One test per check, each printing `CHECK n: PASS|FAIL <observed rows>`. It never sends Ctrl+C.
    - **1 (re-confirm through the relay):** ask for an AskUserQuestion multiSelect with 4 options; send `1` and `3` as two `term.text` writes with no gap; PASS when rows 1 and 3 show `[✔]`.
    - **2 (re-confirm through the relay):** ask for a single-choice question; send the Other row's digit, then `term.paste('two\nlines')`; PASS when the row shows the text and the dialog is still up.
    - **12:** while working with a queued message, Ctrl+X then Ctrl+S as two writes; PASS when the queued row leaves and the prompt runs.
- [ ] **Step 4: Run it on `elis-chat-test`**: `flutter test integration_test/open_checks_test.dart -d emulator-5554 --dart-define=OPEN_CHECKS=1 --dart-define=PAIR_LINK='elis://pair?…'`.
- [ ] **Step 5: Update `checks` from the results**, adding the relay run to the comment line:
  - Check 1 or 2 FAIL through the relay: set `keys`/`paste` false, so `writeBlocked` holds the reason, and report the gap between the relay and the report's harness.
  - Check 12 PASS: `sendNow: true`; FAIL leaves Send now hidden.
- [ ] **Step 6: Stop the rig** (SIGTERM the Debug pid and `serve`; check `lsappinfo list | grep elis.debug`).
- [ ] **Step 7: Commit** the probe and the outcomes, after restoring the pubspec lines: `feat(mobile): phone-path open checks for Chat`.

---

### Task 2: Session fields and the mode pick

**Files:**
- Modify: `mobile/lib/model.dart` (`Session`)
- Create: `mobile/lib/chat/mode.dart`
- Test: `mobile/test/unit_test.dart`, `mobile/test/wire_names_test.dart`

**Interfaces:**
- Produces:
  - `Session.liveAgent` (raw tree `agent`, `''` when absent), `Session.agentSessionId`, `Session.agentPane` (`'left'` when absent; A omits it when no agent runs), `bool Session.remote` (`remoteHost` non-empty).
  - `enum ViewMode { chat, term }`
  - `class ModePicks { static ViewMode? of(String sessionId); static void pick(String sessionId, ViewMode? mode); static final Set<String> tooOld; }`
    - null = Auto; in memory only.
    - `tooOld` holds the sessions whose host answered as too old (`TranscriptError.hostTooOld`), so Auto does not bounce to Chat on every visit.
  - `bool chatAvailable(Session s, String pane)`: false for a session in `tooOld`
  - `ViewMode shownMode(Session s, String pane)`

- [ ] **Step 1: Write the failing tests** in `unit_test.dart`:
```dart
test('chatNeedsTheTreesOwnAgentAndAnId', () {
  Session s(Map m) => Session(m, 'w', 'W');
  expect(chatAvailable(s({'agent': 'claude', 'agentSessionId': 'a1'}), 'left'), isTrue);
  expect(chatAvailable(s({'foreground': ['claude'], 'agentSessionId': 'a1'}), 'left'), isFalse); // origin sent no agent
  expect(chatAvailable(s({'agent': 'claude'}), 'left'), isFalse);
  expect(chatAvailable(s({'agent': 'claude', 'agentSessionId': 'a1', 'agentPane': 'right'}), 'left'), isFalse);
});
test('autoPicksChatAndAManualPickSticks', () {
  final c = Session({'id': 'x', 'agent': 'claude', 'agentSessionId': 'a1'}, 'w', 'W');
  ModePicks.pick('x', null);
  expect(shownMode(c, 'left'), ViewMode.chat);
  ModePicks.pick('x', ViewMode.term);
  expect(shownMode(c, 'left'), ViewMode.term);
  final gone = Session({'id': 'x'}, 'w', 'W');
  ModePicks.pick('x', ViewMode.chat);
  expect(shownMode(gone, 'left'), ViewMode.term); // a pick of an unavailable Chat shows Term
});
```
- [ ] **Step 2: Run** `flutter test --no-pub test/unit_test.dart`. Expected: FAIL, `chatAvailable` undefined.
- [ ] **Step 3: Implement.** Add `'agentSessionId'`, `'agentPane'`, `'remoteHost'` to the `ControlProjection.swift` list in `wire_names_test.dart`. `agentPane` exists only once plan A lands, so until then keep it in a separate entry whose test is skipped with reason `'plan A adds agentPane'`.
- [ ] **Step 4: Run** both tests. Expected: PASS.
- [ ] **Step 5: Commit** `feat(mobile): Session agent fields and the Chat/Term pick`.

---

### Task 3: Transcript decoding

**Files:**
- Create: `mobile/lib/chat/transcript.dart`, `mobile/test/transcript_test.dart`, `mobile/test/fixtures/transcript/tail.json`

**Interfaces:**
- Produces:
  - `TranscriptPage.fromJson(Map<String, dynamic> r)` with:
    - `String transcript`, `int size, start, next`, `bool reset`, `int skipped`
    - `List<ChatItem> items`, `List<PendingCall> pending`
    - `TranscriptMeta? meta`, `List<SlashCommand>? commands` (null when absent)
  - `ChatItem`: `String kind, uuid`, `int at`, `DateTime? time`, `Map<String, dynamic> raw`, typed getters `id`, `text`, `name`, `arg`, `mark`, `output`, `patch`, `file`, `isError`, `rejected`, `exitCode`, `clipped`, `running`, `readOnly`, `agentType`, `agentName`, `agentColor`, `message`, `durationMs`, `bytes`, `isHumanPrompt`
  - `PendingCall(String id, String uuid, String source, String name, Map<String, dynamic>? input, bool clipped, {String? agentType, String? agentName})`
  - `TranscriptMeta` with every meta field above
  - `SlashCommand(String name, String description, bool skill, bool panel)`
  - `enum TranscriptError { hostTooOld, noAdapter, notFound, other }` with `TranscriptError.of(String message)`

- [ ] **Step 1: Write `tail.json`** by hand from the Interfaces table: one item of every kind (one tool item with `rejected: true`), two pending calls (`source: 'main'`, and `source: 'a1'` with `agentType: 'general-purpose'` and `agentName: 'scout'`), full meta, two commands. If plan A has landed, use a real `elisctl session transcript --json` reply instead. Then write the failing tests:
```dart
test('decodesEveryItemKind', () {
  final p = TranscriptPage.fromJson(_load('tail.json'));
  expect(p.items.map((i) => i.kind).toSet(), {'user', 'image', 'command', 'commandOutput', 'bash', 'interrupted', 'compactSummary',
      'taskNotification', 'text', 'thinking', 'tool', 'error', 'compact', 'notice', 'hook', 'oversized'});
  expect(p.pending.map((c) => c.source), ['main', 'a1']);
  expect(p.pending.last.agentType, 'general-purpose');
  expect(p.pending.last.agentName, 'scout');
  expect(p.pending.first.agentType, isNull);
  expect(p.items.where((i) => i.rejected).length, 1);
  expect(p.meta!.pr!.prNumber, 446);
  expect(p.commands!.where((c) => c.skill).length, 1);
});
test('unknownKindsAndFieldsAreKeptNotFatal', () {
  final p = TranscriptPage.fromJson({'transcript': 't', 'size': 1, 'start': 0, 'next': 1, 'items': [{'kind': 'future', 'uuid': 'u', 'at': 0}]});
  expect(p.items.single.kind, 'future');
  expect(p.meta, isNull);
});
test('humanPromptFollowsPromptSourceOrOrigin', () {
  ChatItem u(Map<String, dynamic> m) => ChatItem.fromJson({'kind': 'user', 'uuid': 'u', 'at': 0, ...m});
  expect(u({'promptSource': 'typed'}).isHumanPrompt, isTrue);
  expect(u({'promptSource': 'suggestion_accepted'}).isHumanPrompt, isTrue);
  expect(u({'promptSource': 'system'}).isHumanPrompt, isFalse);
  expect(u({'origin': 'human'}).isHumanPrompt, isTrue);
});
test('errorsMapToStates', () {
  expect(TranscriptError.of("unknown command 'session.transcript'"), TranscriptError.hostTooOld);
  expect(TranscriptError.of('invalid request: unknown cmd session.transcript'), TranscriptError.hostTooOld);
  expect(TranscriptError.of('elis on host is too old'), TranscriptError.hostTooOld);
  expect(TranscriptError.of('no adapter'), TranscriptError.noAdapter);
  expect(TranscriptError.of('transcript not found'), TranscriptError.notFound);
});
```
- [ ] **Step 2: Run** `flutter test --no-pub test/transcript_test.dart`. Expected: FAIL, missing file.
- [ ] **Step 3: Implement** in `transcript.dart`.
  - `isHumanPrompt` is true for `promptSource` `typed`, `queued` or `suggestion_accepted`, or for `origin` `human`.
  - `after`, `before` go out as decimal strings (Task 4); `start`, `next`, `size` and `at` decode from int or string.
  - A wrongly typed field reads as absent, never throws.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(mobile): decode session.transcript`.

---

### Task 4: Transcript feed

**Files:**
- Create: `mobile/lib/chat/feed.dart`, `mobile/test/feed_test.dart`

**Interfaces:**
- Consumes: `TranscriptPage`, `TranscriptError` (Task 3).
- Produces:
  - `class TranscriptFeed extends ChangeNotifier`
  - `TranscriptFeed({required Future<Map<String, dynamic>> Function(Map<String, dynamic> args) call, required bool Function() canPoll, required bool remote})`
    - `call` adds the pane.
    - `canPoll` is `_load`'s guard (mounted, connected, not in the background, route current), so the feed's timer obeys the same rule.
  - Read state: `List<ChatItem> items` (oldest first), `List<PendingCall> pending`, `TranscriptMeta? meta`, `List<SlashCommand> commands`, `String? transcript`
  - Flags: `bool loading`, `bool loadingEarlier`, `bool atStart` (start == 0), `bool stale`
  - Errors and fresh items: `TranscriptError? error`, `Set<String> fresh` (uuids that arrived by a tail poll, for the entry animation)
  - `int switches`: bumps on reset or a file switch, so views clear their transient marks
  - Methods: `void start()`, `void stop()`, `Future<void> pollNow()`, `Future<void> loadEarlier()`, `void retry()`, `@override void dispose()`
  - Interval: `remote ? 2 s : 700 ms`

- [ ] **Step 1: Write the failing tests** with `fake_async` and a scripted `call`:
  - `firstReadIsTheTailWithoutCursor`: the first args hold no `after`, `before` or `transcript`; items, `meta` and `commands` are set; `loading` turns false.
  - `noPollWhileCanPollIsFalse`.
  - `tailPollsAfterNext`: the next call after 700 ms holds `after: '<next>'` (a decimal string) and `transcript: <held id>`; new items append; their uuids are in `fresh`.
  - `upsertReplacesInPlace`: a polled item whose uuid is held replaces it at its position (a `running` tool gets its result); it is not in `fresh`.
  - `nextBelowSizePollsAgainAtOnce`: a reply with `next < size` makes the next call without waiting for the tick.
  - `remotePollsEvery2s`: with `remote: true` no call at 700 ms, one at 2 s.
  - `resetDropsAndReloadsTail`: a reply with `reset: true` clears `items`, bumps `switches`, and the next call has no `after`.
  - `otherTranscriptIdSwitches`: a reply whose `transcript` differs from the held one does the same.
  - `staleBeforeReplyIsDropped`: `loadEarlier()` is held; a reset reply arrives; then the held `before` reply resolves. `items` holds only the new tail.
  - `oneCallInFlight`: a slow reply makes the timer tick skip; `pollNow()` during it does nothing.
  - `staleAfterTwoIntervalsWithoutReply`: after a first reply, a held call makes `stale` true once 1.4 s pass since that reply (2 s polls: 4 s), and false at the next reply. Before any reply `stale` stays false; `loading` shows instead.
  - `hostTooOldStopsPolling`: an `unknown command` error sets `error` and stops the timer; `notFound` keeps polling (spec: polling continues); `retry()` reloads the tail.
  - Stale is time-based, a 1 s check on the timer: a call can take 15 s to time out and only one is in flight, so counting missed replies would take 30 s.
- [ ] **Step 2: Run** `flutter test --no-pub test/feed_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - A generation counter ties each reply to the request that asked for it; a reply from an older generation is dropped.
  - `loadEarlier` asks `before: '<start>'`, prepends, and takes the reply's `start` as the next `before`.
  - `meta`, `pending` and `commands` come from the latest tail reply; `commands` is replaced only when present.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(mobile): poll and page the transcript`.

---

### Task 5: Grid and captured fixtures

**Files:**
- Modify: `mobile/lib/terminal/vt.dart` (public `VtRow(List<VtCell> cells)` and `const VtCell(String text, {int? fg, int? bg, int flags = 0})` beside the private constructors)
- Create: `mobile/lib/chat/grid.dart`, `mobile/test/support/ansi.dart`, `mobile/test/grid_test.dart`
- Create: `mobile/test/fixtures/grid/*.ansi` and `mobile/test/fixtures/grid/README.md`

**Interfaces:**
- Produces:
  - `class Grid`: `Grid.of(VtSnapshot s)`, `Grid.text(String screen)`, `final List<VtRow> rows`, `final bool colours`
  - Row reads: `String text(int r)` (spacers skipped, trailing blanks trimmed), `String bright(int r)` (faint cells as spaces), `bool get blank`
  - `String norm(String s)` (whitespace removed, the comparison form of every anchor)
  - In `test/support/ansi.dart`: `Grid gridFromAnsi(String capture)` (SGR 0, 1, 2, 22, 3x, 9x, 38;5;n, 38;2;r;g;b, 39; each rune one cell; an opaque fg key per colour, compared for equality only)

- [ ] **Step 1: Capture the fixtures** with `tmux capture-pane -p -e -t <pane> > <name>.ansi`.
  - Start Claude as plan A Task 1 Step 1 does: `tmux new -d -s capture /bin/zsh -fc "cd /Users/n.savchenko/IdeaProjects/elis/.claude/worktrees/phone-chat-mode && env -u <every inherited ELIS_*, GHOSTTY_*, CLAUDE*> claude --model haiku --permission-mode default"`, driven with `tmux send-keys`, never through `elisctl` or the live terminal. Claude already trusts the worktree (no trust prompt in the 2026-11-20 checks); never capture from a `/tmp` folder. If a folder-trust prompt appears, stop and report it; never answer it. Capture the fullscreen TUI unless a name says `classic`.
  - Widths: 45 columns and 100 columns (Mac width).
  - No private content: only made-up prompts that read or write nothing in the repository (the Bash prompt runs `ls /tmp`); the statusline may show a branch name, never a username or hostname.

| Fixture | State | Widths |
|---|---|---|
| `idle-placeholder` | fresh, dim `Try "…"` on `❯` | 45, 100 |
| `idle-suggestion` | after a turn, dim predicted prompt | 45 |
| `idle-draft` | typed draft `hello there`, not sent | 45 |
| `idle-draft-multiline` | two-line draft | 45 |
| `idle-no-statusline` | Claude with `--settings '{"statusLine":null}'` | 45 |
| `working` | spinner line and a reply being written | 45, 100 |
| `working-wrapped` | spinner status wrapped over 3 rows (`running PreToolUse hooks…`) | 45 |
| `queued` | `⎿  Queued` row and `Press up to edit queued messages` | 45 |
| `mode-accept`, `mode-plan`, `mode-auto` | after 1, 2, 3 Shift+Tab | 45 |
| `shell` | a background Bash: `· 1 shell` | 45 |
| `paste-placeholder` | a five-line paste on the `❯` row: `[Pasted text #N +4 lines]` (check 18: 4 lines or ~1200 chars) | 45 |
| `paste-inline` | a three-line paste on the `❯` row, shown inline (check 18) | 45 |
| `idle-draft-wrapped` | a three-line draft whose middle line wraps over 2 rows | 45 |
| `interrupted-queued` | Esc while a message is queued: `⎿ Interrupted · What should Claude do instead?` and the queued prompt working (check 13) | 45 |
| `slash-menu` | `/mo` typed: the slash menu open under the input | 45 |
| `bash-mode` | `!` typed: bash input mode | 45 |
| `dialog-bash`, `dialog-ask` | permission prompt; AskUserQuestion | 45, 100 |
| `panel-model`, `panel-usage` | `/model`, `/usage` | 45 |
| `ctrl-o` | Ctrl+O detailed view | 45 |
| `classic-idle`, `classic-working` | classic (non-fullscreen) TUI, main screen | 100 |
| `limit` | **synthetic**: `idle-placeholder` with the two usage-limit lines from the spec inserted above the composer | 45 |

  - `README.md` lists every fixture with its state, layout, width, Claude build and capture date.
  - It marks `limit` synthetic: the state cannot be produced on demand.
- [ ] **Step 2: Write the failing tests:**
```dart
test('ansiCaptureKeepsDimCells', () {
  final g = gridFromAnsi(_fx('idle-placeholder-45'));
  final r = [for (var i = 0; i < g.rows.length; i++) i].lastWhere((i) => g.text(i).startsWith('❯ '));
  expect(g.text(r), startsWith('❯ Try'));
  expect(g.bright(r).trim(), '❯');
});
test('textGridHasNoColours', () {
  final g = Grid.text('a\n❯ hi');
  expect(g.colours, isFalse);
  expect(g.bright(1), '❯ hi');
});
test('normDropsAllWhitespace', () => expect(norm(' a b\n c '), 'abc'));
```
- [ ] **Step 3: Run** `flutter test --no-pub test/grid_test.dart`. Expected: FAIL.
- [ ] **Step 4: Implement**; neither `grid.dart` nor `ansi.dart` loads libvtshim.
- [ ] **Step 5: Run.** Expected: PASS. **Commit** `feat(mobile): Grid view over vt rows, captured Claude grids`.

---

### Task 6: The live-grid classifier

**Files:**
- Create: `mobile/lib/chat/claude_screen.dart`, `mobile/test/claude_screen_test.dart`

**Interfaces:**
- Consumes: `Grid`, `norm` (Task 5).
- Produces `class ClaudeScreen` with `static ClaudeScreen read(Grid g)` and:
  - Input: `bool bottomStack`, `String? input` (joined `❯` input rows), `String draft` (their non-dim text; `''` for a placeholder, a suggestion or `Press up to edit queued messages`), `bool pastePlaceholder`
  - Working: `String? working` (spinner text joined across wraps, glyph removed), `String? limit`
  - Rows: `List<String> queued`, `List<int> statusRows`, `(int, int)? streaming` (first and last row of the reply above the spinner), `int? interrupted`
  - Mode: `ClaudeMode? mode`, `String? modeText`, `int shells`
  - Derived: `bool get dialog` (not blank and no bottom stack), `bool get idle` (bottom stack, no working line)
  - `dialog` is a single-frame reading. Callers act on it only as Task 18 says: Claude running, not stale, and held for two grid updates.
- `enum ClaudeMode { manual, acceptEdits, plan, auto, bypass }`

Rules, all width-agnostic:
- Rows and input:
  - Rules are rows of `─` only, or `─` runs around a title.
  - The bottom stack is the last `❯` row between two rule rows; the classic layout's stack is the last such group above the trailing blank rows.
  - The input row is the first `❯` row after the composer's top rule. The slash menu's highlighted `❯` rows never count, wherever the `slash-menu` fixture shows them.
  - The input is that `❯` row plus its continuation rows before the bottom rule.
- After the bottom rule:
  - Statusline rows are the rows after the bottom rule up to the mode line.
  - The mode line is the first of those rows containing `mode on`, or one starting `⏸`/`⏵`. Its mode comes from `manual`, `accept edits`, `plan mode`, `auto mode` and `bypass`; anything else has no mode.
  - `shells` comes from `· N shell` on the mode line.
- Above the composer:
  - The working line is a row starting with one of `✶✻✽✢·`, then a word ending `…`, then ` (`; it is joined with the following rows up to the closing `)`.
  - `streaming` is the rows from the last row starting `⏺ ` that is not a tool call (`⏺ Name(`) down to the row above the working line, only while working.
  - `queued` is the text of each `❯ ` row directly followed by a `⎿  Queued` row.
  - `limit` is a row containing `Usage limit reached` or `Continuing automatically at`.
  - `interrupted` is the row index of the last row above the composer starting `⎿` that contains `Interrupted`, or null. Callers compare it with the index seen before a write, because an old row stays on screen.
- Paste placeholder: `pastePlaceholder` is true when the input matches `[Pasted text #<n>( +<k> lines)?]`, `n` and `k` any digits (the counter keeps rising across pastes).

- [ ] **Step 1: Write the failing tests**, one per fixture:
  - `idleWithPlaceholderHasNoDraft` (both widths): `bottomStack`, `idle`, `draft == ''`, `statusRows.length == 1`, `mode == ClaudeMode.manual`.
  - `typedDraftIsAdoptable` and `multilineDraftJoins`: `draft` equals the typed text.
  - `suggestionIsNotADraft`.
  - `noStatuslineConfigured`: `statusRows` is empty and `mode` is still read.
  - `workingLine` (both widths) and `wrappedWorkingLineJoins`: `working` starts with the verb, `idle` is false, `streaming` is non-null.
  - `queuedRows`: `queued == ['<prompt>']`; `draft == ''`; `streaming` holds none of the queued rows.
  - `slashMenuAndBashModeKeepTheStack`: `slash-menu` and `bash-mode` have `bottomStack` true and `dialog` false.
  - `modeCycle`: accept, plan and auto fixtures map to their modes; `shell` has `shells == 1`.
  - `pastePlaceholderSeen`: `paste-placeholder` has `pastePlaceholder` true; `paste-inline` has it false and its `draft` holds the three lines.
  - `wrappedDraftJoins`: `idle-draft-wrapped` gives the typed text as `draft`.
  - `interruptedRowFound`: `interrupted-queued` has a non-null `interrupted` and a `working` line; `working` (no Esc) has `interrupted == null`.
  - `dialogsAndPanelsAreDialogs`: dialog-bash, dialog-ask, panel-model, panel-usage and ctrl-o all have `dialog` true and `bottomStack` false.
  - `classicLayout`: `classic-idle` and `classic-working` read like their fullscreen twins.
  - `limitBanner`: `limit` contains `Usage limit reached`.
  - `blankGridIsNotADialog`: `Grid.text('')` gives `dialog` false and `bottomStack` false.
  - `unknownModeLineHasNoMode`: the `idle-placeholder-45` grid with its mode line replaced by `⏸ ручний режим` reads `mode == null` and `modeText != null`.
- [ ] **Step 2: Run** `flutter test --no-pub test/claude_screen_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** `ClaudeScreen.read` per the rules above.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(mobile): classify Claude's live grid`.

---

### Task 7: The write gate

**Files:**
- Create: `mobile/lib/chat/write_gate.dart`, `mobile/test/write_gate_test.dart`
- Modify: `mobile/lib/terminal/term_session.dart`:
  - add `bool get bracketedPaste`, which reads `mode(2004)` from the emulator and is false without one;
  - `snapshot` is null while `replaying`, so no half-drawn frame after a Resync reaches the classifier.
- Modify: `mobile/test/session_term_test.dart`: `FakeVt.lines` (a settable `List<VtRow>`, default empty) passed through `FakeSnapshot.lines`, so screen tests can show grid rows.

**Interfaces:**
- Consumes: `Grid` (Task 5), `Checks` (Task 1), `TermSession.key/text/paste/leading`.
- Produces:
```dart
const escapeGap = Duration(milliseconds: 100); // Ink reads Esc + key within ~60 ms as Alt+key (check 1)

sealed class GateWrite {}
class KeyWrite extends GateWrite { KeyWrite(this.key, [this.mods = 0]); final VtKey key; final int mods; }
class TextWrite extends GateWrite { TextWrite(this.text); final String text; }
class PasteWrite extends GateWrite { PasteWrite(this.text); final String text; }

class GateStep {
  const GateStep(this.write, {required this.ready, required this.done, this.why});
  final GateWrite write;
  final String? why; // the stop reason when `ready` fails
  final bool Function(Grid g) ready; // the state the write expects, checked right before it
  final bool Function(Grid g) done; // the change that ends the step
}

enum GateOutcome { done, mismatch, timeout, writeFailed, noLead, blocked, busy }
class GateResult { final GateOutcome outcome; final int step, total; final String reason; bool get ok; } // reason is '' only when done

abstract class GateWriter {
  Future<bool> lead(); // true once writes reach the program at once (Live: claimed and leading)
  Future<bool> write(GateWrite w); // one write; false when refused
  bool pasteSafe(String text); // a newline in this paste cannot submit
}
// Live: bracketedPaste, or no newline in the text
class LeadWriter implements GateWriter { LeadWriter(TermSession? Function() term, Future<bool> Function() claim); }
// session.type, xtermSeq for keys; lead() is always true; pasteSafe only without a newline
class TypeWriter implements GateWriter { TypeWriter(Future<String?> Function(String text) type); }

class GateSequence { Grid get grid; Future<void> send(GateStep step); void addSteps(int n); } // send throws GateStop, which run() turns into a GateResult; addSteps grows total for a loop of unknown length

class WriteGate extends ChangeNotifier {
  WriteGate({required Listenable grids, required Grid? Function() grid, required GateWriter Function() writer,
      required bool Function() remote, required String? Function() blocked, Checks checks = checks});
  bool get running; int get step; int get total;
  String get progress; // "Sending 2/4"
  Future<GateResult> run(int total, Future<void> Function(GateSequence s) body);
}
```
- Semantics:
  - `blocked()` returns the stale or exited reason; non-null fails at once with `blocked`. `checks.writeBlocked` is applied by the callers it names, not by the gate, so Stop and Cancel keep working.
  - A `run` while another runs returns `busy` and writes nothing.
  - `send` first awaits `writer.lead()` (`noLead` on false), then:
    - Checks `ready(grid)` (`mismatch` on false). A `PasteWrite` whose text fails `writer.pasteSafe` stops with `mismatch` and reason "Claude is not accepting pastes".
    - Writes once (`writeFailed` on false), then waits for `done(grid)` on each `grids` notification.
  - The gate records when its last Esc write went out and delays any write until `escapeGap` after it, across runs. The delay comes before the `ready` check, so the check sees the grid after the Esc took effect.
  - The timeout is `checks.timeout`. On a remote row it counts from the first grid notification after the write, capped at 5 s.
  - Every stop carries a non-empty reason: `mismatch` the step's `why`, else "Claude's screen is not as expected"; `timeout` "Claude's screen did not change"; `noLead` "Could not take over the session"; `writeFailed` "The key did not reach the computer"; `blocked` the `blocked()` text; `busy` "Another answer is being sent". Test `everyStopHasAReason` covers each outcome.
  - Haptics: `HapticFeedback.lightImpact` when a run ends done, `HapticFeedback.vibrate` on any stop.
- `LeadWriter.lead()` first waits for a non-null `snapshot` (OPENED and not replaying), then calls `claim` when not leading, and waits up to 10 s in all for `leading`. It writes only while `leading`, so nothing queues in `TermSession` unchecked.

- [ ] **Step 1: Write the failing tests** with a fake grid notifier and a recording `GateWriter`:
  - `oneWritePerStepInOrder`: three steps whose `done` turns true after each write record exactly three writes in order.
  - `readyMismatchStopsBeforeWriting`: step 2's `ready` is false. The result is `mismatch` at step 2 and only one write was made.
  - `timeoutStops`: no grid change. The run ends `timeout` after `checks.timeout`.
  - `remoteTimeoutCountsFromGrid`: remote, the first grid arrives 3 s after the write, and `done` holds 1 s later. The run ends `done`.
  - `secondRunIsBusy`.
  - `progressCounts`: `progress` reads `Sending 1/2`, then `Sending 2/2`.
  - `blockedNeverWrites`.
  - `gateWaitsForLeadBeforeChecking`: with a real `TermSession` over the session test's fake relay, `send` claims. No bytes reach the claim channel before LEAD; after LEAD the key goes out once and `ready` was evaluated after LEAD.
  - `pasteStopsWithoutBracketedPaste`: `FakeVt.modes` lacks 2004, so a two-line `PasteWrite` stops with `mismatch` and nothing is sent.
  - `typeWriterRefusesMultilinePaste`.
  - `escapeIsFollowedByAGap`: a run of `KeyWrite(VtKey.escape)` and then `TextWrite('x')`, each `done` holding right after its write; the second write is recorded at 100 ms or later.
  - `gapSpansRuns`: a Stop run (Esc) ends, and a second run's first write still waits until 100 ms after the Esc.
  - `noGapAfterOtherKeys`: two digit writes go out 0 ms apart.
  - `leadWaitsForASnapshot`: while `replaying`, `lead()` sends no claim; the claim goes out at the snapshot's cols and rows once it arrives.
- [ ] **Step 2: Run** `flutter test --no-pub test/write_gate_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Import `FakeVt`, `Relay` and `Harness` from `session_term_test.dart`, as that file imports from `mux_test.dart`.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(mobile): write gate for Chat and prompt cards`.

---

### Task 8: Shared composer, key bar and answer bar

A pure move: Term looks and behaves the same, and existing tests and goldens pass unchanged.

**Files:**
- Create: `mobile/lib/screens/composer.dart`, `mobile/lib/terminal/key_bar.dart`, `mobile/lib/screens/answer_bar.dart`
- Modify: `mobile/lib/screens/session.dart:20-42, 553-565, 838-953`

**Interfaces:**
- Produces:
  - `Composer`:
```dart
Composer({Key? key, required TextEditingController controller, required FocusNode focus, required VoidCallback? onSend,
    int maxLines = 4, bool autocorrect = false, bool mono = true, String sendLabel = 'Send', IconData sendIcon = Icons.arrow_forward,
    String? reason, Widget? accessory, bool enabled = true})
```
  - `KeyBar({required void Function(String? seq, VtKey? key, int mods) onKey, required VoidCallback onKeyboard})`
  - `const keys` (moved) and `String xtermSeq(VtKey key, int mods)` (the old `_seq`)
  - `AnswerBar({Key? key, required List<PromptOption> options, required void Function(String key) onAnswer})`
- The keys `composer`, `send`, `softKeyboard`, `key-<name>` and `answer-<n>` stay.

- [ ] **Step 1: Move the code**; `session.dart` calls the new widgets with Term's values.
- [ ] **Step 2: Run** `flutter test --no-pub test/session_term_test.dart test/term_keyboard_test.dart`. Expected: PASS with no golden change.
- [ ] **Step 3: Commit** `refactor(mobile): share the composer, key bar and answer bar`.

---

### Task 9: Chat in the session screen

**Files:**
- Modify: `mobile/lib/screens/session.dart`, `mobile/lib/screens/actions.dart:91-115`, `mobile/lib/model.dart` (`ElisModel.events`)
- Create: `mobile/lib/chat/chat_view.dart` (the shell: list of plain item text, filled in by Tasks 10-18), `mobile/test/chat_screen_test.dart`
- Modify: `mobile/test/session_term_test.dart`; goldens `session_screen.png`, `session_toolbar_split.png`

**Interfaces:**
- Consumes: Tasks 2, 4, 5, 6, 7, 8.
- Produces:
  - `Stream<Map<String, dynamic>> ElisModel.events` (every event `_onEvent` sees)
  - `showSessionActions(..., bool? autoMode, VoidCallback? onAutoMode)`, which adds the item "Choose mode automatically" with key `autoMode`, checked while `autoMode`
  - `ChatView(...)`, given the feed, `Grid? Function() grid`, the grid `Listenable`, `WriteGate gate`, `Session s`, `bool exited`, `bool stale` and `VoidCallback onTerm`
- Behaviour:
  - Toolbar:
    - `_toolbar` always renders `Chat`/`Term` segments (keys `modeChat`, `modeTerm`), Chat disabled when `!chatAvailable(s, pane)`.
    - A tap sets `ModePicks.pick`. The pane pair follows on a split.
  - In Chat:
    - `ChatView` replaces the terminal stack, and the `TermSession` keeps running.
    - The feed's `call` is `m.call('session.transcript', target: sessionId, args: {...args, 'pane': s.agentPane})`.
    - The feed starts and stops with the screen's foreground and route, and polls on this session's `status` event and when `s.agentSessionId` changes in `_onModel`.
  - `_load` in Chat never returns at `_termShown`. It runs `session.text` only for a pane that is not Live, which is the non-Live G (`Grid.text`).
  - No resize in Chat:
    - `_syncFit` makes no call (the initState call too); a fit made in Term stays as it is.
    - `_onTerm` does not claim on OPENED; `_layoutGrid` and `_resizeLead` do nothing.
    - `_takeOver` claims at `term.snapshot`'s cols and rows without `_syncFit`.
    - `LeadWriter.claim` calls `_claim()`.
  - Leaving Chat for Term restores today's Term behaviour on the next frame (fit, claim, resize).
  - Exited: when `liveAgent` stops being `claude` while Chat is shown, Chat stays, with `exited: true`. On the next visit `shownMode` decides.
  - The screen opens on `s.agentPane` when `shownMode` for that pane is Chat, else on `left` as today.
  - A host-too-old reply (`TranscriptError.hostTooOld`) adds the session to `ModePicks.tooOld` and shows Term.
  - The panel sheet, mode picker and "/" menu are in-tree overlays, not routes: `_load` and the feed stop while the route is not current.
- `ChatComposer`, `ModeChip`, `BottomStack` and `ChatPromptContext` get `remote: s.remote`.
- Writers follow the existing `_direct` rule: `LeadWriter` on a Live pane whose claim was not refused this visit, `TypeWriter` (via `session.type`) otherwise.

- [ ] **Step 1: Write the failing tests** in `chat_screen_test.dart`. `Relay` answers `session.transcript` from a `transcript` field and records its args.
  - `autoShowsChatForClaude`: a tree session with `agent: claude` and `agentSessionId` shows `ChatView`, and the first transcript call carries `pane: left`.
  - `termAndChatSwitch`: tap `modeTerm`, then the terminal shows; tap `modeChat`, then Chat. Run it with `ComposerPref.shown` false as well (Memroot: a hidden composer's GlobalKey asserts in layout).
  - `autoItemClearsTheManualPick`: pick Term, open ⋮, tap `autoMode`, and Chat shows again.
  - `chatDisabledWithoutAgent`: `modeChat` is disabled, and Term shows.
  - `chatNeverResizes`: in Chat, after OPENED, layout changes and a rotation, `r.grids` is empty and no claim frame is sent. A gate write then claims once, at the snapshot's 80x24, and no RESIZE follows.
  - `statusEventPollsAtOnce`: a `status` event for `s1` makes a transcript call before the 700 ms tick.
  - `nonLivePanePollsText`: `live: false` gives `session.text` calls in Chat.
  - `exitKeepsChatShown`: the tree drops `agent`, and `ChatView` stays with `exited` true.
  - `refusedClaimWritesThroughSessionType`: after a refused claim, a gate write is one `session.type` call, with no 10 s wait.
  - `opensOnTheAgentPane`: with `agentPane: right` on a split, the first transcript call and the watch are on `right`.
  - `tooOldHostShowsTerm`: an `unknown command` reply shows Term, and reopening the screen makes no transcript call.
  - Update `toolbarIsEmptyWithoutASplit` to `toolbarShowsTheModeWithoutASplit`: the toolbar is present and `rightPane` is absent.
- [ ] **Step 2: Run** `flutter test --no-pub test/chat_screen_test.dart test/session_term_test.dart`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both. Regenerate `session_screen.png` and `session_toolbar_split.png` with `--update-goldens` only for these two, and look at the images: the only change is the mode segments. Expected: PASS.
- [ ] **Step 5: Commit** `feat(mobile): Chat/Term switcher and the transcript poll`.

---

### Task 10: Messages and markdown

**Files:**
- Create: `mobile/lib/chat/items.dart` (first part), `mobile/lib/chat/rows.dart` (first part), `mobile/test/chat_items_test.dart`
- Modify: `mobile/android/app/src/main/kotlin/ua/naiksoftware/elis/MainActivity.kt` (`elis/open` method `share`: `ACTION_SEND` text chooser)
- Modify: `mobile/pubspec.yaml`, `mobile/pubspec.lock`: add `flutter_markdown_plus: 1.0.12`; commit its lock entries and restore only the `sdk:` lines (Global Constraints)

**Interfaces:**
- Produces:
  - `class ChatRow { final String key; final ChatItem? item; final List<ChatItem> group; final DateTime? day; }`
  - `List<ChatRow> chatRows(List<ChatItem> items)` (newest first, for `reverse: true`)
  - `Widget chatRowWidget(BuildContext c, ChatRow r, {required bool fresh})`
  - `Future<void> shareText(String text)`

- [ ] **Step 1: Write the failing tests:**
  - `userBubbleRightAligned`: the bubble's right edge is near the list's right edge.
  - `assistantTextIsOneMarkdownBody`: a `text` item renders one `MarkdownBody` in Inter, and a fenced block renders mono inside a horizontal `SingleChildScrollView`.
  - `longPressOffersCopyCopyCodeShare`: Copy puts the text on the clipboard; Copy code puts only the fenced code; Share calls `elis/open` `share` (mock channel).
  - `freshItemsAnimateIn`: a fresh uuid wraps in a fade and an 8 pt slide; an old one does not.
  - `daySeparatorBetweenDays`: two items on different days give a date row between them.
- [ ] **Step 2: Run** `flutter test --no-pub test/chat_items_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Markdown uses `MarkdownBody` (not `selectable`) and a `pre` builder that is mono and scrolls horizontally.
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): Chat messages in markdown`.

---

### Task 11: Tool rows, diffs, grouping, subagents

**Files:**
- Modify: `mobile/lib/chat/items.dart`, `mobile/lib/chat/rows.dart`
- Test: `mobile/test/chat_items_test.dart`

**Interfaces:**
- Produces:
  - `String groupLabel(List<ChatItem> tools)`, e.g. `Read 7 files · Searched 2`
  - `enum SubagentState { running, finished, stopped }`
  - `SubagentState subagentState(ChatItem agentTool, {required bool interruptedAfter, required bool exited, required bool stale})` (`running` from the item's `running`; finished on `mark` `done` or `error`)
  - `String markText(String? mark)`: `ok` → `✓`, `exit N` → `✗ exit N`, `error` → `✗`, `done` → `✓ done`, others as given

- [ ] **Step 1: Write the failing tests:**
  - `threeReadOnlyCallsGroup`: three `readOnly` items (Read, Grep, Glob) in a row give one row labelled `Read 1 file · Searched 2`. Two in a row stay separate. A group that grows by a poll keeps its row key.
  - `editBashNeverGroup`: Read, Read, Edit, Read gives four rows.
  - `toolRowShowsNameArgMark` (`Bash`, `Run unit tests`, `✓`; `exit 1` shows `✗ exit 1`).
  - `tapExpandsClippedOutput`: the clipped output and `Full output in Term` show, and the expansion sits in an `AnimatedSize`.
  - `diffRendersHunks`: `-` and `+` lines are coloured, soft-wrapped, with the file path in each hunk header.
  - `subagentStates`:
    - open is running; finished is finished;
    - open with an `interrupted` item after it, exited, or stale is stopped;
    - a teammate shows `agentName` in its `agentColor`, with `agentType`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** Grouping reads the items' `readOnly` (scope call 3). Tool rows use the secondary colour and a smaller size than prose. The diff header shows `file`.
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): Chat tool rows, diffs and subagents`.

---

### Task 12: Dividers, errors, notices, thinking, commands, images

**Files:**
- Modify: `mobile/lib/chat/items.dart`
- Test: `mobile/test/chat_items_test.dart`

**Interfaces:**
- Consumes: `ChatItem` getters (Task 3), `chatRowWidget` and `ChatRow` (Task 10).
- Produces: `chatRowWidget` cases for `compact`, `compactSummary`, `interrupted`, `error`, `hook`, `notice`, `thinking`, `command`, `commandOutput`, `bash`, `taskNotification`, `image` and `oversized` (a placeholder with its size). A `compactSummary` directly after a `compact` folds into that divider's row in `chatRows`.

- [ ] **Step 1: Write the failing tests:**
  - `compactDividerCollapsesSummary`: a `compact` item then a `compactSummary` give the divider "Conversation compacted"; the summary shows only after a tap.
  - `interruptedDivider` reads "Interrupted".
  - `errorRowIsRed`.
  - `hookAndNoticeRows`: a warning row and an info row.
  - `thinkingShowsDurationOnly` reads "Thought for 4s", with no content.
  - `commandChipAndOutput`: `/compact` as a chip; `commandOutput` as a mono block; `bash` as `! <text>`.
  - `imageThumbnailZooms`: a tap opens an `InteractiveViewer`.
  - `imageOverCapIsPlaceholder` (no `data`, `bytes` 2411724) reads `image/png · 2.3 MB`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): Chat dividers, notices and images`.

---

### Task 13: List behaviour and header

**Files:**
- Modify: `mobile/lib/chat/chat_view.dart`, `mobile/lib/chat/rows.dart`
- Test: `mobile/test/chat_view_test.dart`

**Interfaces:**
- Produces:
  - `int? stickyPrompt(List<ChatRow> rows, int topVisible)`: the index of the newest human prompt older than the top visible row
  - `String modelLabel(String? model, String? effort)`, e.g. `Opus · medium`
- Behaviour:
  - The list is `ListView.builder(reverse: true)`.
  - Near the oldest row it calls `feed.loadEarlier()` and shows "Loading earlier…".
  - While not at the bottom, appended rows keep the user's view: in a post-frame callback, `jumpTo(pixels + Δ maxScrollExtent)`. The jump button counts them ("↓ 3 new").
  - The header row holds the cwd, the PR chip and the switcher. It collapses on scroll up and returns on scroll down.
  - The app bar holds the title (`meta.title`, else `s.name`) and the model chip:
    - dimmed after a `command` item with `name` `model` newer than the last assistant item;
    - its tap ("Change model…") arrives with the composer's `send` in Task 16.
  - The PR chip calls `elis/open` `view` with `prUrl`.
  - The todo strip shows while any todo is not `completed`: `☐ 2/5 · <in_progress content>`, expanding to the list.

- [ ] **Step 1: Write the failing tests:**
  - `stickyPromptIsNearestAbove` (pure).
  - `stickyTapScrollsToPrompt`.
  - `appendWhileScrolledUpKeepsView`: the first visible row's screen position is unchanged after 3 items arrive, and the jump button shows `3 new`.
  - `atBottomFollows`.
  - `pagingBackPrepends`: "Loading earlier…" shows while the call is held.
  - `modelLabel` (`claude-opus-4-5` with `medium` gives `Opus · medium`; an unknown id stays raw).
  - `modelChipDimsAfterModelCommand`.
  - `prChipOpensUrl`.
  - `todoStripHidesWhenAllDone`.
  - `headerCollapsesOnScrollUp`.
- [ ] **Step 2: Run** `flutter test --no-pub test/chat_view_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): Chat list, sticky prompt, header`.

---

### Task 14: States

**Files:**
- Modify: `mobile/lib/chat/chat_view.dart`, `mobile/lib/screens/session.dart` (passes `stale`)
- Test: `mobile/test/chat_view_test.dart`

**Interfaces:**
- Consumes: `TranscriptFeed.loading/error/stale/switches/retry` (Task 4), `ModePicks.tooOld` (Task 2), `ChatView(exited, stale, onTerm)` (Task 9).
- Produces: `String? ChatView.blockedReason`, which is `'Claude exited'` or `'Reconnecting…'`. The screen's `WriteGate.blocked` returns it.

**Behaviour (spec States table):**
- Empty: running with no items shows "Claude is ready" and `/help`, `/model`, `/usage` buttons (wired to the composer in Task 16).
- Loading: skeleton bubbles until the first page.
- Unreadable: `notFound` or `other` shows a full-width state with `Retry` (`feed.retry`) and `Term` in place of the list.
- Host too old: Chat is disabled with "Update Elis on <remoteHost or 'the computer'>". The screen shows Term and polling stops.
- Exited: the history stays, with the banner "Claude exited" and a `Term` button. Composer, chips, Stop and Send now are disabled.
- Stale: `feed.stale`, a disconnected link, or no running `TermSession` on a Live pane after its first OPENED this visit (before OPENED the screen is connecting, not stale).
  - It shows "Reconnecting…".
  - The working line, statusline and chips are dimmed, the spinner stops, and every write is blocked (`WriteGate.blocked`).
- File switch, reset, exit and stale clear the streaming area, set open subagent rows to stopped, and close the panel sheet's stopped message.

- [ ] **Step 1: Write the failing tests:** `emptyState`, `loadingSkeleton`, `unreadableShowsRetryAndTerm`, `hostTooOldDisablesChat`, `exitedBannerDisablesWrites`, `staleDimsAndBlocks`, `connectingIsNotStale`, `switchClearsTransientMarks`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): Chat states`.

---

### Task 15: Bottom stack

**Files:**
- Create: `mobile/lib/chat/bottom_stack.dart`
- Test: `mobile/test/bottom_stack_test.dart`

**Interfaces:**
- Consumes: `ClaudeScreen`, `WriteGate`, `Checks`.
- Produces `BottomStack({required ClaudeScreen? screen, required Grid? grid, required TranscriptFeed feed, required WriteGate gate, required bool stale, required bool remote, Checks checks = checks})`.
- Behaviour:
  - Working line: mirrored text with a phone-drawn spinner.
    - `Stop` runs one `GateStep(KeyWrite(VtKey.escape), ready: s.working != null && !s.dialog, done: working gone or s.interrupted differs from its value at ready)`.
      Check 13: Esc interrupts and then sends the queue, so the working line may never leave; a new `Interrupted` row ends the step.
    - It is enabled only when no dialog is open.
  - Limit banner: `Cancel` sends Esc the same way while `limit` shows.
  - Queued rows: a row shows while the prompt is both in `meta.queued` (strings) and in `screen.queued` (gray).
    - `Send now` sends Ctrl+X, then Ctrl+S as two gate steps.
    - It is hidden unless `checks.sendNow`, and disabled with its reason while `checks.writeBlockedOn(remote: remote)` is non-null.
  - Statusline: the first status row cut to one line, with the row's SGR colours built from its `VtRow` cells. A tap expands every row, wrapped.
    - While a dialog hides them, the last rows stay dimmed as stale.
    - On a `Grid.text` grid the statusline is plain.
  - Streaming area: the `streaming` rows, drawn plain.
    - It shows while working and while its first line is not already the start of the last `text` item (`norm` compare).
    - It cross-fades out when the next T record arrives or the working line goes.

- [ ] **Step 1: Write the failing tests** from fixtures:
  - `stopSendsOneEsc`: one Esc write.
  - `stopDoneOnInterruptedWithQueue`: `working`, then after the Esc `interrupted-queued`; the run ends `done`.
  - `oldInterruptedRowDoesNotEndStop`: starting from `interrupted-queued` with no grid change after the Esc, the run ends `timeout`.
  - `sendNowBlockedOnUnprovenRemote`: with `sendNow: true` and `remote: true`, Send now is disabled with the remote reason; Stop stays enabled.
  - `stopDisabledOnDialog`.
  - `queuedNeedsBothSources`: T only or G only shows no row.
  - `sendNowHiddenUntilProven`.
  - `statuslineFirstRowExpands`.
  - `statuslineStaleUnderDialog`.
  - `streamingHidesOnceInTranscript`.
  - `limitBannerCancel`.
- [ ] **Step 2: Run** `flutter test --no-pub test/bottom_stack_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): Chat working line, queue and statusline`.

---

### Task 16: Chat composer and the "/" menu

**Files:**
- Create: `mobile/lib/chat/chat_composer.dart`
- Modify: `mobile/lib/chat/chat_view.dart` (model chip tap, empty-state buttons)
- Test: `mobile/test/chat_composer_test.dart`, `mobile/test/chat_view_test.dart` (`modelChipSendsModel`, `emptyStateFillsTheField`)

**Interfaces:**
- Consumes: `Composer` (Task 8), `ClaudeScreen`, `WriteGate`, `checks.dart`.
- Produces:
  - `ChatComposer({required TranscriptFeed feed, required ClaudeScreen? Function() screen, required bool colours, required bool remote, required WriteGate gate, String? disabledBy, Checks checks = checks})`
  - `Future<void> ChatComposer.send(String text)`: also used by the model chip and the empty state
  - `List<SlashCommand> slashMatches(List<SlashCommand> all, String typed)`
  - `bool pasteShown(ClaudeScreen s, String text)`
- Behaviour:
  - Uses `Composer(maxLines: 6, autocorrect: true, mono: false)`, always visible in Chat.
  - Draft adoption, only when `colours`:
    - once per Chat visit, at the first grid with a bottom stack, when the field is empty, the field takes `screen.draft`;
    - again after a Stop run, when the field is empty and Claude's row shows a draft (check 13: an Esc before any output puts the prompt back);
    - never while `pastePlaceholder` (the placeholder is not the text); Send then treats the row as a changed draft.
    - The adopted text is remembered as `adopted`.
  - Send is enabled when the field is not empty, `bottomStack`, no dialog, and `disabledBy == null`. It reads `Queue` while `working`; `/model`, `/effort`, `/fast`, `/status`, `/tasks` and `/usage` read `Send`.
  - Disabled with text, one reason line: "Claude shows a dialog", "Waiting for Claude's screen", the `checks.writeBlockedOn(remote: remote)` text, or `disabledBy`.
  - Send trims trailing whitespace. A pasted bare `/cos` runs `/cost` (check 4), so the menu inserts full names.
  - The send sequence on a Live pane (`colours`), through one `gate.run`:
    `total` is 2 plus one per clear step; the clear loop calls `s.addSteps(1)` before each Ctrl+U, so progress reads `Sending k/n` with n growing while it clears.
    1. Claude's input:
       - If `draft` equals `adopted`, clear it: repeat `checks.clearInput` as one gate step at a time. Each step's `ready` is a non-empty `draft`, its `done` "the input changed". Stop when `draft == ''` (empty or a dim placeholder), with "Claude's input did not clear" after 40 steps. A null `clearInput` stops instead (check 5: one press per visual row plus one per newline, no fixed count).
       - If `draft` is non-empty and different, stop with "Claude's input changed on the computer" and offer `Replace` (clear the same way, then continue) and `Keep` (stop).
    2. Write the text per `checks.dart`:
       - a `PasteWrite`;
       - `TextWrite` for a leading `/` when `!checks.pastedCommandRuns`;
       - a split leading `!`/`#` when `!checks.pastedBangSwitches`.
       - Each write's `done` is `pasteShown`: the `norm`ed input contains the first 40 normalized characters, or `pastePlaceholder`.
    3. Enter as its own write. Its `done` is an empty input row, a new human `user` item in the feed, or a working line.
    4. Clear the field.
  - On a non-Live pane (`!colours`): no adoption, no draft check and no clear (a `Grid.text` placeholder reads as text), and the `TypeWriter` path: the text, then Enter, as two steps whose `done` is any grid change.
  - The model chip's "Change model…" (Task 13) sends `/model` through `send`, enabled only when idle.
  - The empty state's buttons (Task 14) put their command in the field.
  - The "/" menu: a `/` as the first character opens a list above the field, filtered by `slashMatches` (prefix first, then substring, case-insensitive).
    - It lists `feed.commands`; those with `panel` are marked "opens in panel".
    - A pick inserts the full name, `/name `.

- [ ] **Step 1: Write the failing tests** against a fake grid driven by fixtures. All but `leadingSlashTypedWhenPasteFails` and `sendDisabledWhileUnproven` pass `Checks(keys: true, paste: true, pastedCommandRuns: true, pastedBangSwitches: true, clearInput: (VtKey.u, vtCtrl))`:
  - `adoptsTypedDraftNotPlaceholder` (`idle-draft` and `idle-placeholder`).
  - `noAdoptionWithoutColours`.
  - `noAdoptionOfAPastePlaceholder` (`paste-placeholder`).
  - `readoptsAfterStop`: the field is empty, Stop ends, the grid shows the interrupted prompt as a draft; the field takes it.
  - `sendPastesThenEnters`: two writes; Enter only after the grid shows the text.
  - `pasteShownAcceptsInlineAndPlaceholder`: `paste-inline` and `paste-placeholder` both satisfy `pasteShown`.
  - `sendClearsAdoptedDraftFirst`: a three-line draft whose middle line wraps (`idle-draft-wrapped`), scripted to lose one row per Ctrl+U as check 5 saw; at least 5 Ctrl+U writes go out, one per step, and the paste follows only once `draft == ''`.
  - `clearStopsWhenTheInputDoesNotChange`: a Ctrl+U with no grid change ends `timeout` and nothing is pasted.
  - `changedDraftOffersReplaceKeep`.
  - `queueLabelWhileWorking`.
  - `disabledReasonOnDialog`.
  - `slashMenuFiltersAndInserts`.
  - `menuPickSendsExactName`: picking `/cost` and tapping Send pastes exactly `/cost`.
  - `panelCommandsMarked`.
  - `modelChipSendsModel`, `emptyStateFillsTheField`.
  - `nonLiveSendTypesTextThenEnter`: on a `Grid.text` grid showing `❯ Try "…"`, Send makes two `session.type` writes, the text then `\r`, with no clear and no "input changed" stop.
  - `leadingSlashTypedWhenPasteFails`: with `Checks(keys: true, paste: true)`, a `/effort low` send is one `TextWrite`.
  - `remoteRowWritesBlockedUntilProven`: with `remote: true`, Send is disabled with "Sending from the phone is not verified on remote sessions yet"; with `Checks(..., remote: true)` it is enabled.
  - `sendDisabledWhileUnproven`: with the default `Checks()`, Send is disabled with the reason line.
- [ ] **Step 2: Run** `flutter test --no-pub test/chat_composer_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): Chat composer with draft adoption and the slash menu`.

---

### Task 17: Mode chip and shell badge

**Files:**
- Modify: `mobile/lib/chat/chat_composer.dart` (accessory row)
- Test: `mobile/test/chat_composer_test.dart`

**Interfaces:**
- Consumes: `ClaudeScreen.mode/modeText/shells/idle` (Task 6), `TranscriptMeta.permissionMode` (Task 3), `WriteGate` (Task 7), `Checks.writeBlocked` (Task 1).
- Produces: `ModeChip({required ClaudeScreen? screen, required TranscriptMeta? meta, required WriteGate gate, required bool remote, Checks checks = checks})`, passed as `Composer.accessory`, and `Future<GateResult> cycleTo(ClaudeMode target)`.

**Behaviour:**
- The chip shows `modeText`'s mode, or `meta.permissionMode` dimmed while G hides the mode line.
- It is enabled only when `idle`, `mode != null` and `checks.writeBlockedOn(remote: remote) == null`.
- A tap opens a picker of the modes the cycle passes through: manual, accept edits, plan, auto; bypass only when seen.
- A pick runs Shift+Tab steps through the gate, one `KeyWrite(VtKey.tab, vtShift)` each:
  - `ready` is idle with the mode it expects; `done` is a different known mode.
  - Selection haptic per step.
  - At most 5 steps; it stops when the start mode returns.
- A target of auto or bypass shows its label verbatim and needs a second tap.
- The shell badge `N shell` shows while `shells > 0`.

- [ ] **Step 1: Write the failing tests:**
  - `chipCyclesToTarget`: three steps from manual to auto, and the second tap is required.
  - `chipStopsWhenModeUnchanged` (timeout).
  - `chipDisabledWhileWorking`.
  - `chipDisabledWithoutAKnownMode` (the Task 6 `ручний` grid).
  - `chipDisabledOnAnUnprovenRemoteRow`.
  - `shellBadge`.
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): Chat mode chip`.

---

### Task 18: Panel sheet and the card slot

**Files:**
- Create: `mobile/lib/chat/panel_sheet.dart`
- Modify: `mobile/lib/chat/chat_view.dart`
- Test: `mobile/test/panel_sheet_test.dart`

**Interfaces:**
- Produces:
```dart
class ChatPromptContext {
  const ChatPromptContext({required this.screen, required this.grid, required this.pending, required this.gate,
      required this.remote, required this.openPanel});
  final ClaudeScreen screen; final Grid grid; final List<PendingCall> pending; final WriteGate gate;
  final bool remote; final void Function(String? stopped) openPanel;
}
typedef PromptCardBuilder = Widget? Function(BuildContext context, ChatPromptContext c);
```
  - `ChatView(..., PromptCardBuilder? promptCard)`
- Behaviour:
  - A dialog counts only while Claude runs (not exited), not stale, and after `screen.dialog` held for two grid updates; never on a blank or replaying grid.
  - When it counts, ChatView first asks `promptCard`.
    - A non-null card docks above the composer at no more than 60% of the height, its content scrolling inside.
    - The composer stays visible, disabled with "Answer the prompt above".
    - Otherwise the panel sheet opens by itself.
  - The panel sheet shows the live rows with `TerminalView` (or the plain text of a `Grid.text` grid), the `KeyBar` and the `AnswerBar` (`promptOptions` of the rows).
    - Its keys go straight to the program (the exempt path: the screen's `_press`).
  - It closes by itself when `bottomStack` returns.
  - A swipe down hides it. While the dialog stays, the composer reads "Claude shows a panel · Open", and `Open` shows it again.
  - `openPanel(stopped)` opens it with the `stopped` text shown verbatim at the top, until it closes. The caller builds the sentence (plan C: "Stopped at step k of n: <reason>. The prompt may be half answered.").
  - Plan B passes `promptCard: null`; plan C passes its builder.

- [ ] **Step 1: Write the failing tests:**
  - `dialogOpensPanel` (dialog-bash fixture, two grid updates).
  - `oneFrameDialogOpensNothing`, `noPanelWhileExitedOrStale`.
  - `panelClosesWhenStackReturns`.
  - `swipedPanelLeavesOpenHint`.
  - `panelKeysBypassGate`: one write with no gate run.
  - `cardSlotDocksInsteadOfPanel`: a stub builder returns a box; no panel; the composer hint reads "Answer the prompt above".
  - `stoppedMessageUntilClose`.
- [ ] **Step 2: Run** `flutter test --no-pub test/panel_sheet_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS. **Commit** `feat(mobile): panel sheet and the prompt card slot`.

---

### Task 19: Docs

**Files:**
- Modify: `site/docs.html` (new section "Chat on the phone", by task: switch modes, read, send and queue, the "/" menu, change mode or model, panels, what Chat never does to the Mac's view, remote rows), `site/index.html` (the phone feature names Chat), `mobile/README.md` (first paragraph names Chat and Term)

- [ ] **Step 1: Write the section** in short paragraphs and a table of states. The screenshot is added in Task 20.
- [ ] **Step 2: Add Chat to `site/index.html`** if `section#phone` has no Chat point yet: one `div.pt` point beside the others, `<b>Read and reply to Claude Code as a chat.</b>` with a short sentence; plan C changes only the "Answer an agent from anywhere" point. `softwareVersion` stays (release-only).
- [ ] **Step 3: Check** relative links only, and bump `style.css?v=` only if CSS changed.
- [ ] **Step 4: Commit** `docs: Chat on the phone`.

---

### Task 20: End-to-end on the emulator, then the gates

Lead session only (it launches the Debug instance and the emulator). Requires plan A merged into this branch (`session.transcript`, `agentPane`). Run it alone in the worktree.

- [ ] **Step 0: Wire names.** Unskip the `agentPane` entry in `wire_names_test.dart` and add an entry for the transcript keys (`transcript`, `size`, `start`, `next`, `reset`, `items`, `pending`, `meta`, `commands`, `skipped`, the item fields of the Interfaces table including `rejected`, and the pending fields `source`, `agentType`, `agentName`) against `macos/ElisCore/Sources/ElisCore/ControlTranscript.swift` (plan A's wire types). Run `flutter test --no-pub test/wire_names_test.dart`; a missing key means A and B disagree: fix `transcript.dart` to A's name.

- [ ] **Step 1: The rig from Task 1** (AVD `elis-chat-test`, isolated Debug instance with `ELIS_STATE_DIR=/tmp/ecb`, `serve --host 10.0.2.2`, no installers).
  - Install with `flutter run -d emulator-5554 --release`, pair, and open the Claude session.
  - Then check `adb -s emulator-5554 shell pm list packages | grep ua.naiksoftware.elis` after any integration run.
  - Drive the Mac side only with the Debug binary's `elisctl` under `ELIS_STATE_DIR=/tmp/ecb`.
- [ ] **Step 2: Walk the checklist** and record pass or fail with a screenshot (`adb exec-out screencap -p`) for each:
  - Auto shows Chat, and Term shows on a shell session.
  - History, markdown, a tool row with a diff, a group row, a subagent row.
  - Sticky prompt and jump to bottom while Claude streams.
  - Send while idle; Queue while working.
  - Draft adoption of a draft typed on the Mac.
  - Stop; the mode chip to plan mode and back.
  - `/model` opens the panel sheet, which closes itself.
  - A Bash permission prompt opens the panel sheet, and its key bar answers it.
  - `/clear` switches the file.
  - Quit Claude: the exited banner shows.
  - Switch to Term and back: the Mac's grid size never changed. Compare `columns` from `ELIS_STATE_DIR=/tmp/ecb <Debug>/elisctl session text --json` before and after.
  - Airplane mode for 10 s: "Reconnecting…" and blocked writes.
  - Take the docs screenshot here: one Chat screen with made-up content, at most three statuses, no machine name, hostname, username or `/tmp` path (the header's cwd included; the owner's preference overrides CLAUDE.md's Website rule), `cwebp -q 82` into `site/assets/`, linked from Task 19's section.
- [ ] **Step 3: Remote rows read as remote (gap 8).** For an attached-Mac row and an elis-server row, each that is reachable: read the tree through the Debug binary's `elisctl tree --json` (isolated socket) and check the row carries `remoteHost`, then check on the phone that `Session.remote` is true and the feed polls every 2 s. A row of either kind with no `remoteHost` is a blocker for this plan and for plan C: its writes would skip the remote guard. Record each kind as passed, failed or not reachable for the owner.
- [ ] **Step 3b: Remote row run**: on each row that passed Step 3, repeat history, Send and Stop (Send needs `checks.remote`, so with it false confirm Send shows the remote reason instead). Otherwise record it as not run.
- [ ] **Step 4: Stop the rig** (SIGTERM the known pids, `lsappinfo list | grep -A4 elis.debug`, delete nothing of the owner's).
- [ ] **Step 5: Gates, each once:**
  - `cd macos/ElisCore && swift test`; `cd macos && make test-app`; `make lint`.
  - In `mobile/`: the temporary `sdk:` constraint and `flutter pub get`, `flutter analyze --no-pub` (0 issues), `flutter test --no-pub`, then restore the `sdk:` lines.
  - Run `lsappinfo list | grep -A4 elis.debug` after `make test-app`.
- [ ] **Step 6: Commit** any fixture or golden the run corrected, `test(mobile): Chat end-to-end fixes`, and separately the screenshot with its `site/docs.html` link, `docs: Chat screenshot`.

---

## Self-review

Spec coverage. Every Elements and States row maps to a task, plan C, or a check:

| Spec row | Owner |
|---|---|
| Write gate | 7 |
| Mode switcher, Auto item | 2, 9 |
| Title, PR chip, model chip, sticky prompt, day separator, jump to bottom, todo strip | 13, 10 |
| Messages, tool rows, diff, thinking, subagent, command chip and output, dividers, error, hook error, notice, image | 10, 11, 12 |
| Prompt card | plan C, through the Task 18 slot |
| Streaming area, working line, limit banner, queued messages, statusline | 15 |
| Mode chip, shell count | 17 |
| Composer, "/" menu | 16 |
| Panel sheet, answer bar inside it | 18 |
| States (all eight) and clearing transient marks | 9, 14 |
| Polling, non-Live G, lead and grid size | 4, 9 |
| Remote parity (phone side) | 2, 4, 7, 20 |
| Open checks 1, 2, 3, 4, 5, 13, 14, 18 (report), 12 (probe) | 1; consumed in 7, 15, 16 |
| Open check 9: the grid stays as it is (spec Lead section) | 9 |
| Open check 11 | 5 |
| Docs | 19 (A: commands, control-api, skill) |

Spec gaps and how this plan resolves them:
1. Item, meta and pending field names were left to the builder. This plan copies plan A's; decoding is confined to `transcript.dart`, and Task 20 Step 0 checks the names against A's Swift file.
2. "Chat takes the lead at the first input, as Term does since M5b". Term today claims on OPENED (`session.dart:208-211`), not at the first input. Chat follows the spec's words: no claim on OPENED, the claim at the first gated write at the snapshot's size (Task 9).
3. "Stale: no GRID for 5 s". The relay sends no heartbeat, and an idle Claude screen sends no bytes, so this would flag every idle session. Stale is instead a disconnected link, no running `TermSession` on a Live pane, or two missed poll replies (Task 14).
4. The spec gives "host too old" as `unknown command`; plan A adds `too old` and `invalid request: … session.transcript`. B accepts all three.
5. The usage-limit grid cannot be produced on demand. Its fixture is synthetic and marked so.
6. The spec cites `mobile/lib/link/client.dart:220`; the file is `mobile/lib/client.dart`.
7. "The poll lives in `_load`": the feed has its own timer, because its 700 ms/2 s cadence and paging differ from the text poll. It takes `_load`'s guard as `canPoll`, so it stops exactly where `_load` does (Task 4).
8. `remoteHost` marking attached and elis-server rows (2 s poll, the remote guard) is unverified: the Mac docs it for teleported sessions. Task 20 Step 3 proves it on both row kinds.
9. The open checks ran on local rows only. Send, the mode chip and plan C's cards stay disabled on remote rows behind `Checks.remote` until plan C Task 9 passes both an attached and an elis-server row; a missing remote run needs the owner's AskUserQuestion approval (CLAUDE.md).
10. The spec's Send clears with "the builder's key". Check 5 makes it Ctrl+U repeated until the row is empty, never a fixed count and never Ctrl+C (Task 16).
