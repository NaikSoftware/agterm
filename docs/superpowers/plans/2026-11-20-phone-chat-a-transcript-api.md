# Phone Chat A: Transcript API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every host that runs Claude Code (local Mac, a Mac a row is attached from, elis-server) answers `session.transcript`, a paged, clipped read of the pane's Claude conversation, and every tree tells the phone which pane runs Claude.

**Architecture:** A pure, Linux-safe `ClaudeTranscript` reader in `ElisCore` indexes `~/.claude/projects/*/<id>.jsonl` once and extends the index per poll; `ControlDispatcher` parses the arguments, asks the host for the pane's Claude session id through one new `ControlActions` method, and runs the reader off the main actor.
The Mac app routes attached and elis-server rows over pooled ssh to the remote `elisctl session transcript`; elis-server detects Claude itself and serves the command through the same dispatcher.
A new `agent` presentation kind carries the running agent and its pane to viewer rows.

**Tech Stack:** Swift 6 (`ElisCore`, `ElisServerKit`, `elisctlKit`, swift-testing), the macOS app target (XCTest hosted tests, XCUITest), ArgumentParser, static HTML docs.

**Spec:** `docs/superpowers/specs/2026-11-20-phone-chat-mode-design.md` (sections "Transcript reader in ElisCore", "Control API", "Remote parity", scope calls 1 and 3).

## Global Constraints

- Run every command in `macos/`; all `macos` paths below are relative to it, the docs paths to the repo root.
- `ElisCore` imports no GhosttyKit, AppKit, Metal or CoreGraphics; the reader also compiles and runs on Linux (no CryptoKit, no Darwin-only API).
- Page budget 48 KiB (`49152` bytes); tool output and patches clipped at 4 KiB (`4096`) with `clipped: true`; every item at most 16 KiB (`16384`); a spilled `tool-results/toolu_<id>.txt` contributes its first 4 KiB.
- No caller passes a path. Every file name taken from file contents (`agentId`, `toolUseId`, `toolu_*`) and the session id pass `SessionLauncher.plainSessionID` before becoming a path component; anything else is skipped.
- Only whole lines count; a partial trailing line waits for its newline.
- The allowlist in the spec's "Records kept as items" table is the only way into `items`; unknown types and `api-request*` are dropped; undecodable lines count in `skipped`.
- Errors verbatim: `no adapter` and `transcript not found`.
- `session.transcript` is a read: no new event kind, no `EventFormatter` entry (spec "Events: none new"); `tree.changed` still fires when `agentSessionId` changes.
- Breaking public additions for the agterm-linux fork, as every new command is: the `Command` case and the `PresentationFrame.Body.agent` case break its exhaustive switches. The `ControlActions` default refuses so the fork still compiles, and `ControlSessionNode.init` gains `agentPane: String? = nil`, so no call site changes.
- The `ControlActions` default answers `the Elis on this host is too old for session.transcript`, so the phone reads that host as too old (Plan B's `too old` match) and disables Chat.
- Never execute `elis`/`elisctl` against the default socket, never launch or quit the deployed app; manual runs use an isolated Debug instance (`/tmp` `ELIS_STATE_DIR`, `open -n --env ...`, stop by PID with SIGTERM).
- CI's `linux` job runs `ElisCore`'s `swift test` (reader and `ElisServerTests` included) in `swift:6.3.2-noble`; that is the Linux gate.
- Gates, once, at the end: `cd ElisCore && swift test`, `make test-app`, `make lint` (zero findings). Mobile gates do not apply: this plan changes nothing in `mobile/`.
- New code goes in new files where the touched file is near the limit: `SessionCommands.swift` is 957 lines, `ControlProtocol.swift` 915, `ControlDispatcher.swift` 762.
- Comments: one line, only for a non-obvious constraint. A shortcut with a known limit says `shortcut: <limit>, <when to upgrade>`.

## Interfaces shared with other plans

Plan A produces everything below; Plans B (phone view) and C (prompt cards) consume it and produce nothing for A.

**Command** `session.transcript`, `target` = the session as for every session command.

| Arg (JSON) | Type on the wire | Meaning |
|---|---|---|
| `pane` | string `left`/`right` (and `session.text`'s aliases `primary`/`top`, `split`/`bottom`) | Which pane's Claude; omitted = the session's `agentPane`; `scratch` is refused |
| `paneID` | string | Stable pane token; overrides `pane` when known |
| `after` | **decimal string** (as `events.read` sends it), e.g. `"18234"` | Items appended at or after this byte offset |
| `before` | decimal string | Older items before this offset; exclusive with `after` |
| `transcript` | string | The Claude session id the caller holds; only compared, never a path |
| `maxBytes` | integer | Page budget, clamped to 49152; `<= 0` is an error |

**Result** fields sit flat on `result` (no wrapper object), named as the spec's table:
`transcript` (string), `size` (int), `start` (int), `next` (int), `reset` (bool, omitted when false), `items` (array), `pending` (array, omitted when empty), `meta` (object), `commands` (array, only on a tail page or when `meta.skillsAt` falls in `[after, next)`), `skipped` (int, omitted when 0).

Cursor contract:
- Tail page (no `after`/`before`, or any `reset`): the newest items within the budget; `start` = offset of the oldest record in it, `next` = end of the last whole line indexed.
- `after` page: items of records at offsets `>= after`; when the budget stops it early, `next` is the end of the last included record, so `next < size` means "poll again now".
- `before` page: items before `before`, newest first filled back from it; `start` is the next `before`; `next` echoes `before` (callers ignore it).
- **Upsert:** an item whose `uuid` the caller already holds replaces that item in place. The reader re-emits an item when a later record completes it: a tool item when its `tool_result` arrives, a text item when another block of the same `message` arrives.
- `reset: true` means drop everything and keep this page (it is a tail page).

**Item** `{kind, uuid, at, time, ...}`; `at` = byte offset of the item's first record, `time` = that record's `timestamp` string. Kinds and their extra fields (all optional unless named):

| kind | fields |
|---|---|
| `user` | `text`, `promptSource`, `origin` (the `origin.kind` string), `clipped` |
| `image` | `mediaType`, `bytes` (decoded size), `data` (base64, only when the item stays under 16 KiB) |
| `command` | `name` (without `/`), `args` |
| `commandOutput` | `text`, `clipped` |
| `bash` | `text` (the `!` input) |
| `interrupted` | — |
| `compactSummary` | `text`, `clipped` |
| `taskNotification` | `text`, `clipped` |
| `text` | `text`, `message` (the API `message.id`), `clipped` |
| `thinking` | `durationMs` |
| `tool` | `id` (`tool_use.id`), `name`, `arg` (short argument), `mark`, `running` (true until a result), `output`, `patch` (`[{oldStart, oldLines, newStart, newLines, lines}]`), `file` (`file_path`), `isError`, `rejected`, `exitCode`, `readOnly`, `agentType`, `agentName`, `agentColor`, `clipped` |
| `error` | `text` |
| `compact` | `trigger` |
| `notice` | `text`, `level` |
| `hook` | `text` |
| `oversized` | `bytes` (a line longer than the 4 MiB read window) |

`mark` strings: `running` while no result; Bash `ok`, `exit N` or `error`; Edit/Write/MultiEdit `+N −M` (U+2212), Write create `+N`; Agent `done` or `error`; any other tool `error` on `is_error`, else omitted.
`rejected` is true when the `tool_result` is the user's rejection of the prompt (`is_error` and the text starts with one of Claude's rejection prefixes, captured in Task 2 Step 1), omitted when false like `readOnly`; an approved call that failed is `isError` without `rejected`. Plans B and C read this field and never match the wording themselves.
`readOnly` is true for `Read`, `Grep`, `Glob`, `LS`, `WebSearch`; **the visual grouping of 3+ consecutive `readOnly` items (scope call 3) is Plan B's**, because a run grows across polls and a page boundary would split a host-side group.
Multiple blocks in one record get `uuid` = record uuid plus `#n` for n > 0.

**Pending** `[{id, uuid, source, agentType, agentName, name, input, clipped}]`: open `tool_use` calls on the active chain (not `Agent`/`Task`), plus open calls in the subagent file of an open Agent call; `source` = `main` or the bare `agentId` (`a1` for `subagents/agent-a1.jsonl`, never `agent-a1`); `agentType` (the `.meta.json` `agentType`, which the prompt header names as "· from the general-purpose agent") and `agentName` (the Agent call's `input.name`) only on subagent entries, when present; `input` = the tool input as a **JSON object**, passed as written (no key is added or assumed, e.g. `ExitPlanMode`'s `planFilePath` may be absent), omitted with `clipped: true` when it encodes over 16 KiB.

**Meta** `{title, lastPrompt, permissionMode, pr: {prNumber, prRepository, prUrl}, agentName, model, effort, todos: [{content, status, activeForm}], queued: [string], continuedIn, skillsAt}`, all optional.

**Commands** `[{name, description, source: "builtin"|"skill", panel}]`, each `description` clipped to 160 characters; `panel: true` marks the built-ins that open a panel (`model`, `usage`, `config`, `rewind`, `resume`, `tasks`).

**Size:** `maxBytes` bounds the encoded `items`; the rest of a reply is bounded separately (each pending input at most 16 KiB, `commands` about 100 short entries, `meta` small), so a reply can exceed `maxBytes`. Channel 0 frames long lines, so no hard reply cap applies (spec constraints).

**Errors:** `no adapter`, `transcript not found`. "Host too old" (spec state table) is an error that starts with `unknown command`, contains `too old` (the routed reply and the refusing default), or starts with `invalid request:` and contains `session.transcript`.

**Tree** (`ControlSessionNode`): existing `agent`, `agentSessionId`, plus new `agentPane` (`left`/`right`, omitted when no agent). The sampler now looks at both panes (scope call 1), so `agent` stays `claude` while the user focuses the other pane.
Attached and elis-server rows carry all three through the new `agent` presentation kind and the existing `agent.session` kind.

**CLI** `elisctl session transcript [--target T] [--pane left|right] [--pane-id ID] [--after N | --before N] [--transcript ID] [--max-bytes N] [--json]`.

## Review Focus

1. A first read of a 70 MB transcript runs while Mac windows stay responsive: the index scan never runs on the main actor (Task 5 pins the reader call off the main thread).
2. Claude writing a line mid-poll: a page never contains half a record and the next poll picks the line up whole (Task 1 partial-line test, Task 3 append-between-polls test).
3. A 1.3 MB image line and a 6 MB pasted line: the image becomes a placeholder, the oversized line one `oversized` item, and later records still page (Task 2 and Task 1 tests).
4. `/rewind` or retry while the phone holds the old branch: the next `after` poll answers `reset` with the new tail, not a mix of branches (Task 3 branch-switch test).
5. A transcript id or sidecar name carrying `../` from a hostile or corrupt file never reads outside `<dir>/<id>/` (Task 3 sidecar test; the `transcript` argument is compared only, Task 5 test).

---

## File Structure

| File | Responsibility |
|---|---|
| `ElisCore/Sources/ElisCore/ClaudeHome.swift` (new) | `$CLAUDE_CONFIG_DIR` or `~/.claude`; `sessions/<pid>.json` read |
| `ElisCore/Sources/ElisCore/ClaudeTranscriptIndex.swift` (new) | Line scan, record index, active chain, open calls, meta folding |
| `ElisCore/Sources/ElisCore/ClaudeTranscriptItems.swift` (new) | One record (decoded JSON) to items; clipping, marks, tags |
| `ElisCore/Sources/ElisCore/ClaudeTranscript.swift` (new) | Id → path, index cache, pages, reset, pending, sidecars, commands |
| `ElisCore/Sources/ElisCore/ClaudeCommandCatalog.swift` (new) | Built-in slash commands; `skill_listing` folding |
| `ElisCore/Sources/ElisCore/ControlTranscript.swift` (new) | Wire types: item, pending, meta, command, hunk, `JSONValue`, source/lookup |
| `ElisCore/Sources/ElisCore/ControlDispatcher+Transcript.swift` (new) | Argument parsing, lookup, off-main read, response |
| `ElisCore/Sources/ElisCore/AppStore+Agent.swift` (new) | `applyAgentSamples`, `setRunningAgent`, `applyRemoteAgent`, `Session.transcriptSource` |
| `ElisCore/Sources/elisctlKit/Session+Transcript.swift` (new) | `elisctl session transcript` and its human output |
| `Elis/Control/ControlServer+Transcript.swift` (new) | App lookup, attached/server-row route, pooled ssh read |
| Modified | `ControlProtocol.swift`, `ControlActions.swift`, `ControlActionsDefaults.swift`, `ControlDispatcher.swift`, `PageSessionRefusal.swift`, `ControlProjection.swift`, `AppStore.swift`, `Session.swift`, `PresentationFrames.swift`, `PresentationFrame+Codable.swift`, `PresentationHub.swift`, `RemotePresentationClient.swift`, `AppStore+Presentation.swift`, `SessionCommands.swift` (subcommand list), `Elis/SessionLaunchers.swift`, `Elis/Control/ControlServer.swift`, `ControlServer+RemoteActions.swift`, `ControlServer+RemotePresentation.swift`, `ElisServerKit/ServerCommandPolicy.swift`, `ServerActions+Sessions.swift`, `PaneObserver.swift` |

---

### Task 1: Transcript index (scan, chain, meta)

**Files:**
- Create: `ElisCore/Sources/ElisCore/ClaudeHome.swift`, `ElisCore/Sources/ElisCore/ClaudeTranscriptIndex.swift`, `ElisCore/Sources/ElisCore/ControlTranscript.swift` (all wire types listed in Task 2's Produces, so the meta fold has its type)
- Test: `ElisCore/Tests/ElisCoreTests/ClaudeTranscriptIndexTests.swift`

**Interfaces:**
- Produces:
  - `public enum ClaudeHome { static func directory(environment: [String: String] = ProcessInfo.processInfo.environment, home: String = NSHomeDirectory()) -> String; static func sessionJSON(pid: Int32, directory: String) -> Data? }` (`CLAUDE_CONFIG_DIR` when absolute, else `<home>/.claude`).
  - `final class ClaudeTranscriptIndex` (internal): `init(path: String)`, `func extend() -> Bool` (false = file shrank or its first `min(4096, size)` bytes changed, caller rebuilds), `var end: Int` (offset after the last whole line), `var size: Int`, `var records: [TranscriptRecord]`, `var skipped: Int`, `func activeChain() -> [Int]` (record indices, ascending offset), `func resultIndex(forToolUse id: String) -> Int?`, `var openCalls: [String: Int]` (tool_use id → record index, no result yet), `var meta: ControlTranscriptMeta`.
  - `struct TranscriptRecord { uuid: String?; parent: String?; logicalParent: String?; offset: Int; length: Int; type: String; subtype: String?; sidechain: Bool; messageID: String?; oversized: Bool }`.

- [ ] **Step 1: Capture todo and queue fixtures.** Start `claude --model haiku` in a detached tmux session as the open-check report's "Method" does: `tmux new -d -s capture /bin/zsh -fc "cd <this worktree> && env -u <every inherited ELIS_*, GHOSTTY_*, CLAUDE*> claude --model haiku"`, so the installed status hooks (which exit without `ELIS_SESSION_ID`) never post to the live socket; that run saw no folder-trust prompt in the worktree; never through `elisctl` or the live terminal, and never from a `/tmp` folder. If a folder-trust prompt appears, stop and report it; never answer it. Drive it with `tmux send-keys`, and ask it to plan 3 steps with its todo tool and to queue a message while busy; copy the `TaskCreate`/`TaskUpdate`/`TodoWrite` `tool_use` inputs and the `queued_command`/`queue-operation` records into `ClaudeTranscriptIndexTests` as literals (strip paths). If no todo tool fires, fold only `TodoWrite` `{todos: [{content, status, activeForm}]}` and leave `TaskCreate`/`TaskUpdate` out (open check 7).

- [ ] **Step 2: Write the failing tests** (each writes JSONL into a temp dir; one record per line):

```swift
@Test func chainWalksThroughAttachmentsAndAcrossCompaction()   // u1 <- att <- a1; compact_boundary(parent nil, logicalParent a1) <- u2: chain == [u1, att, a1, boundary, u2]
@Test func sidechainRecordsAreDropped()                         // isSidechain:true record never in activeChain()
@Test func leafIsLastRecordWithUUID()                           // trailing custom-title (no uuid) does not move the leaf
@Test func branchSwitchMovesTheChain()                          // a2 then retry a2' with parent u1: chain ends at a2', a2 absent
@Test func partialTrailingLineWaitsForItsNewline()              // write half a line: end excludes it; append the rest + "\n": extend() adds it
@Test func lineOverReadWindowBecomesOneOversizedRecord()       // 5 MiB line: one record with oversized == true, next record indexed
@Test func undecodableLineCountsAsSkipped()                     // "{not json\n": skipped == 1, later lines indexed
@Test func shrinkOrChangedPrefixAsksForRebuild()                // truncate file: extend() == false; rewrite first byte: false
@Test func openCallsCloseOnToolResult()                         // tool_use id t1 open; tool_result t1 appended: openCalls empty, resultIndex("t1") set
@Test func metaFoldsLastOfEachType()                            // ai-title then custom-title then ai-title: title == custom; permission-mode, pr-link, agent-name, last-prompt, model/effort from last non-sidechain assistant
@Test func queuedCommandsFoldWithQueueOperations()              // values from Step 1's fixture
@Test func todosFoldToLatestState()                             // values from Step 1's fixture
@Test func continuedInIsRecorded()                              // continued-in record: meta.continuedIn == its id
@Test func claudeHomeHonorsAbsoluteConfigDir()                  // ["CLAUDE_CONFIG_DIR": "/x"] -> "/x"; "rel" or unset -> "<home>/.claude"
```

- [ ] **Step 3: Run to verify they fail.** Run: `cd ElisCore && swift test --filter ClaudeTranscriptIndexTests` — Expected: build error, types missing.

- [ ] **Step 4: Implement.** Read in 1 MiB chunks with `FileHandle` from `end`; the read window for one line is 4 MiB (`lineWindow`), past which the line is skipped to its newline and recorded `oversized`. Decode each line once with `JSONSerialization` for the index fields and the meta fold; keep no record bodies. Chain: walk `parentUuid` from the leaf (last non-sidechain record with a uuid), and on a record whose `parentUuid` is null follow `logicalParentUuid`. Cache the chain until `records.count` changes.

- [ ] **Step 5: Run to verify they pass.** Same command — Expected: PASS.

- [ ] **Step 6: Commit** `feat(core): Claude transcript index`.

### Task 2: Records to items

**Files:**
- Create: `ElisCore/Sources/ElisCore/ClaudeTranscriptItems.swift` (wire types already exist from Task 1)
- Test: `ElisCore/Tests/ElisCoreTests/ClaudeTranscriptItemsTests.swift`

**Interfaces:**
- Consumes: `TranscriptRecord` (Task 1).
- Produces:
  - (in `ControlTranscript.swift`, written in Task 1) `public struct ControlTranscriptItem: Codable, Sendable, Equatable` with every field of the shared item table (all optional except `kind`, `uuid`, `at`).
  - `public struct ControlTranscriptHunk: Codable, Sendable, Equatable { oldStart, oldLines, newStart, newLines: Int; lines: [String] }`.
  - `public struct ControlTranscriptPending`, `ControlTranscriptMeta` (+ `ControlTranscriptPR`, `ControlTranscriptTodo`), `ControlTranscriptCommand` as in the shared tables.
  - `public indirect enum JSONValue: Codable, Sendable, Equatable { case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue]) }` with `init?(any: Any)` from `JSONSerialization` output.
  - `enum ClaudeTranscriptItems { static func items(record: [String: Any], at offset: Int, result: [String: Any]?, spilled: (String) -> Data?) -> [ControlTranscriptItem] }` — `result` is the decoded `tool_result` record for a `tool_use`, `spilled` reads `tool-results/<id>.txt` (Task 3 supplies it).
  - `static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "WebSearch"]`.

- [ ] **Step 1: Capture rejection results.** In a detached tmux `claude --model haiku --permission-mode default` session started exactly as Task 1 Step 1 (worktree cwd, `env -u`, stop and report on a trust prompt), with made-up prompts: answer a Bash permission `No`; answer another `No` with a reason; reject a plan (`Tell Claude what to change`); pick "Chat about this" on an AskUserQuestion; and approve a Bash command that fails (`exit 3`). Copy each `tool_result` record into `ClaudeTranscriptItemsTests` as a literal (strip paths and ids), and take the rejection prefixes from the first four, never from memory. Record which of them start with a shared prefix; a variant with its own wording gets its own prefix.

- [ ] **Step 2: Write the failing tests** (records as JSON literals):

```swift
@Test func userRejectionSetsRejected()                  // each captured rejection from Step 1 -> rejected true, isError true
@Test func failedApprovedBashIsNotRejected()            // the captured approved `exit 3` -> isError true, exitCode 3, rejected absent from the encoded JSON
@Test func typedUserPromptKeepsSourceAndOrigin()        // kind user, promptSource "typed", origin "human"
@Test func metaAndToolResultOnlyUserRecordsYieldNothing()
@Test func wrapperTagsBecomeCommandOutputBash()          // <command-name>/compact</command-name><command-args>x</command-args> -> command name "compact" args "x"; <local-command-stdout> -> commandOutput; <bash-input> -> bash; <system-reminder> alone -> []
@Test func interruptMarkerAndAbortedMidStream()          // "[Request interrupted by user]" -> interrupted; isAbortedMidStream assistant -> its text item then interrupted
@Test func compactSummaryAndTaskNotification()
@Test func assistantTextCarriesMessageID()               // text item message == "msg_1"
@Test func thinkingShowsDurationOnly()                   // no text field present in the encoded JSON
@Test func bashToolMarksExitCode()                       // is_error, content "Exit code 2\n..." -> exitCode 2, mark "exit 2", isError true
@Test func editToolCarriesPatchAndCounts()               // structuredPatch 2 '+' 1 '-' -> mark "+2 −1", file "/a/b.swift", arg "b.swift"
@Test func writeCreateCountsContentLines()               // toolUseResult.type "create", 3 lines -> "+3"
@Test func openToolIsRunning()                           // result nil -> running true, mark "running"
@Test func outputClipsAt4KiB()                           // 10 KiB output -> output.utf8.count <= 4096, clipped true
@Test func spilledOutputContributesItsHead()             // spilled returns 10 KiB -> first 4096 bytes, clipped true
@Test func readOnlyToolsAreFlagged()                     // Grep -> readOnly true; Bash -> nil
@Test func agentToolCarriesTypeAndName()                 // input subagent_type "Explore", name "scout"
@Test func smallImageInlineLargeImagePlaceholder()       // 2 KiB png -> data set; 40 KiB -> data nil, bytes 40960, mediaType "image/png"
@Test func systemAndHookRecords()                        // compact_boundary -> compact trigger "auto"; informational warning -> notice; away_summary -> notice; stop_hook_summary with hookErrors -> hook; without -> []; hook_* attachment exitCode 1 -> hook, 0 -> []
@Test func apiErrorBecomesError()
@Test func itemNeverExceeds16KiB()                       // 40 KiB assistant text -> encoded item <= 16384, clipped true
@Test func secondBlockInARecordGetsSuffixedUUID()       // two image blocks -> "u1", "u1#1"
```

- [ ] **Step 3: Run to verify they fail.** `swift test --filter ClaudeTranscriptItemsTests` — Expected: build error.

- [ ] **Step 4: Implement** the mapping per the spec's "Records kept as items" table and the shared item table. Short argument: Bash `description` else `command`; Read/Edit/Write/MultiEdit `file_path` basename; Agent `description`; WebFetch URL host; `mcp__*` the first input value as a string. Output text: `tool_result.content` string, or its `text` blocks joined with `\n`. Clip by UTF-8 bytes on a character boundary. `rejected` compares the result text with the Step 1 prefixes.

- [ ] **Step 5: Run to verify they pass.** Expected: PASS.

- [ ] **Step 6: Commit** `feat(core): transcript records to items`.

### Task 3: Pages, reset, pending, sidecars, commands

**Files:**
- Create: `ElisCore/Sources/ElisCore/ClaudeTranscript.swift`, `ElisCore/Sources/ElisCore/ClaudeCommandCatalog.swift`
- Test: `ElisCore/Tests/ElisCoreTests/ClaudeTranscriptTests.swift`

**Interfaces:**
- Consumes: Tasks 1-2.
- Produces:
  - `public struct ClaudeTranscriptRequest: Sendable, Equatable { sessionID: String; after: Int?; before: Int?; held: String?; maxBytes: Int }`
  - `public struct ClaudeTranscriptPage: Sendable, Equatable { transcript: String; size, start, next: Int; reset: Bool; items: [ControlTranscriptItem]; pending: [ControlTranscriptPending]; meta: ControlTranscriptMeta; commands: [ControlTranscriptCommand]?; skipped: Int }`
  - `public enum ClaudeTranscriptError: Error, Equatable { case notFound }` (message `transcript not found`).
  - `public final class ClaudeTranscript: @unchecked Sendable` (the id → path map and the LRU behind one short `Locked`; each cached index behind its own `Locked`, so one session's first scan never stalls another session's poll): `public static func instance(directory: String) -> ClaudeTranscript` (one per directory); `public init(claudeDirectory: String, cacheLimit: Int = 8)`; `public static let pageBudget = 49152, clipBytes = 4096, itemCap = 16384`; `public func page(_ request: ClaudeTranscriptRequest) -> Result<ClaudeTranscriptPage, ClaudeTranscriptError>` (blocking; it starts with `dispatchPrecondition(condition: .notOnQueue(.main))`, so a main-actor caller fails every test that reaches it).
  - `enum ClaudeCommandCatalog { static let builtins: [ControlTranscriptCommand]; static func skills(listings: [(isInitial: Bool, names: [String], content: String)]) -> [ControlTranscriptCommand] }`.
    The `skill_listing` shape (open check 6) is read from real transcripts of Claude Code 2.1.316, 2.1.318 and 2.1.327: `{"type":"attachment","attachment":{"type":"skill_listing","isInitial":true,"names":["a","p:b"],"content":"- a: A\n- p:b: B","skillCount":2,"digests":[…]}}`. Names come from `names` (they may hold `:`); a description is the rest of the content line that starts `- <name>: `, empty when none matches. Fixtures stay synthetic.

- [ ] **Step 1: Capture the built-in list.** In a detached tmux `claude` session started exactly as Task 1 Step 1 (`env -u`, worktree directory, stop and report on a trust prompt), type `/`, `tmux capture-pane` the list, and copy the built-in names and one-line descriptions into `ClaudeCommandCatalog.builtins`, sorted by name; `panel: true` exactly for `model`, `usage`, `config`, `rewind`, `resume`, `tasks`.

- [ ] **Step 2: Write the failing tests:**

```swift
@Test func tailPageFitsTheBudgetAndCarriesCommands()    // 200 user records: encoded items <= 49152, start == first included at, next == file end, commands != nil
@Test func afterPageReturnsOnlyNewRecords()             // poll(after: page.next) after appending 1 record -> 1 item
@Test func appendBetweenPollsIsNeverHalfRead()           // append half a line, poll -> 0 items, next unchanged; finish line -> 1 item
@Test func afterPageStopsAtBudgetAndNextIsBehindSize()   // 100 KiB appended -> next < size; second poll from next continues with no gap or duplicate
@Test func beforePageWalksBackAndEchoesBefore()          // items all at < before, start == first at, next == before
@Test func toolResultReEmitsTheToolItem()                // poll 1 has tool running; poll 2 (only tool_result appended) re-emits same uuid with mark set
@Test func laterTextBlockReEmitsTheMessage()             // same message.id in two records across polls -> second poll item uuid == first record's uuid, text has both
@Test func heldIDMismatchResets()                        // held "other" -> reset true, tail page
@Test func shrunkFileResets()                            // after > size -> reset
@Test func branchSwitchResets()                          // caller held through a2; retry appends a2' off u1 -> reset true, items end with a2'
@Test func compactionKeepsPreBoundaryHistory()           // tail with small budget then before pages reach records before the boundary
@Test func unknownTypesAndApiRequestsNeverAppear()
@Test func skippedCountsBadLines()
@Test func pendingListsOpenMainCalls()                   // open AskUserQuestion -> pending [{id, source "main", name, input.object["questions"]}]
@Test func pendingIncludesOpenSubagentCalls()            // open Agent t9; subagents/agent-abc.meta.json {toolUseId: t9}; agent-abc.jsonl open Bash -> pending source "abc", agentType from meta, agentName from the Agent input's name
@Test func pendingInputOverCapIsClipped()                // 20 KiB input -> input nil, clipped true
@Test func sidecarNamesWithSlashOrDotsAreSkipped()       // meta.json toolUseId fine but file named agent-..%2F / agentId "../x"; tool_use id "../../etc" -> no read outside <dir>/<id>/, no crash
@Test func idWithSlashIsNotFound()                       // sessionID "../x" -> .failure(.notFound)
@Test func missingTranscriptIsNotFound()
@Test func skillListingsFoldSinceLastInitial()           // initial names [a, p:b] "- a: A\n- p:b: B", later non-initial [c] "- c: C" -> a "A", p:b "B", c "C"; a later initial [d] -> only d
@Test func commandsRideAnAfterPageOnlyWhenSkillsAtIsInIt()
@Test func builtinCatalogPinsPanelSetAndUniqueNames()  // names unique and sorted; the panel == true names == ["config","model","resume","rewind","tasks","usage"]
@Test func skillDescriptionsAreClipped()               // 500-char description -> 160
@Test func indexIsReusedAcrossPolls()                    // second page() on unchanged file does not rescan (expose an internal scan counter)
```

- [ ] **Step 3: Run to verify they fail.** `swift test --filter ClaudeTranscriptTests` — Expected: build error.

- [ ] **Step 4: Implement.** Path: list `<claudeDir>/projects/*/` for `<id>.jsonl`, cache id → path, drop the cache entry when the file is gone. Index cache keyed by path, LRU of `cacheLimit`; rebuild when `extend()` returns false. Paging follows the shared cursor contract. `reset` when `held` differs, `after > size`, or the last item-bearing record before `after` is not on the active chain. Re-emission: on an `after` page also emit the tool items whose result record is at `>= after` while the `tool_use` is earlier, and the text group whose later record is at `>= after`. Pending via `openCalls` ∩ active chain; a subagent entry takes `agentType` from its `.meta.json` and `agentName` from the open Agent call's `input.name`; subagent files are indexed through the same cache with no sidechain filter or chain walk.

- [ ] **Step 5: Run to verify they pass.** Expected: PASS.

- [ ] **Step 6: Commit** `feat(core): paged Claude transcript reader`.

### Task 4: Agent pane sampling, read-back and the `agent` presentation kind

**Files:**
- Create: `ElisCore/Sources/ElisCore/AppStore+Agent.swift`
- Modify: `Session.swift:48-53` (add `@ObservationIgnored public var agentPane: StatusPane?`; doc of `runningAgent` becomes "in either pane"), `ControlProjection.swift:303,444,500` (`agentPane: String?`), `AppStore.swift:448` and `AppStore+RecentClosed.swift:250` (project it), `PresentationFrames.swift:699-712,783,854` (`PresentationAgent`, body `.agent(PresentationAgent?)`, snapshot `agent`), `PresentationFrame+Codable.swift`, `PresentationHub.swift:73` (`"agent"` in `supportedKinds`), `AppStore+Presentation.swift:22`, `RemotePresentationClient.swift:29,66,94,273,279` (effect `agent`; nil at stream end), `Elis/SessionLaunchers.swift:87-110`, `Elis/Control/ControlServer+RemotePresentation.swift:97`
- Test: `ElisCore/Tests/ElisCoreTests/AppStoreAgentTests.swift`, `PresentationFramesTests.swift`, `RemotePresentationClientTests.swift`, `ControlProtocolTests.swift`

**Interfaces:**
- Produces:
  - `public struct AgentPaneSample: Sendable, Equatable { pane: StatusPane; agent: SessionLauncher?; claudeSessionJSON: Data? }`
  - `AppStore.applyAgentSamples(_ samples: [AgentPaneSample], focused: StatusPane, forSession: UUID)` — the focused pane's agent wins, else the other pane's; then `setRunningAgent`; then today's id rules (another agent clears the id; claude with a parseable json sets `resumeLine` and `setAgentSessionID`).
  - `AppStore.setRunningAgent(_ agent: SessionLauncher?, pane: StatusPane?, forSession: UUID)` — no-op when unchanged; else sets both, publishes `.agent(...)`, `scheduleTreeChanged()`.
  - `AppStore.applyRemoteAgent(_ agent: PresentationAgent?, forSession: UUID)` — viewer side; unknown names read as none. shortcut: the origin's pane role is taken as the local one, wrong only after a swap on one Mac.
  - `public struct PresentationAgent: Codable, Sendable, Equatable { name: String; pane: String }` — wire `{"kind":"agent","agent":{"name":"claude","pane":"left"}}`, `agent` absent = none.
  - `ControlSessionNode.agentPane: String?`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func focusedPaneAgentWins()                 // left claude, right codex, focused right -> runningAgent .codex, agentPane .right
@Test func otherPaneAgentKeepsClaude()            // left claude, right shell, focused right -> .claude, .left
@Test func noAgentClearsPaneButKeepsID()          // id stays after claude exits (today's rule)
@Test func otherAgentClearsID()
@Test func runningAgentChangePublishesAndSchedulesTree()  // hub records .agent(PresentationAgent(name: "claude", pane: "left")); tree.changed scheduled once
@Test func treeCarriesAgentPaneAndOmitsNil()      // JSON has "agentPane":"left"; with none, key absent
@Test func agentFrameRoundTripsAndSnapshotCarriesIt()     // PresentationFramesTests
@Test func viewerAppliesAgentAndClearsAtStreamEnd()       // RemotePresentationClientTests: frame sets row runningAgent/agentPane; stream end -> nil
@Test func originWithoutAgentKindLeavesAgentUnset()
```

- [ ] **Step 2: Run to verify they fail.** `swift test --filter "AppStoreAgentTests|PresentationFramesTests|RemotePresentationClientTests"` — Expected: build error.

- [ ] **Step 3: Implement** the ElisCore half, then the app sampler: for each local session build one `AgentPaneSample` per existing pane (`session.surface` → `.left`, `session.splitSurface` → `.right`) with `ForegroundProcess.groupPIDs`, `SessionLauncher.agent(group:)` and `ClaudeHome.sessionJSON(pid:directory:)` for the first pid that parses; pass `focused: session.focusedPane == .right ? .right : .left`. The viewer's `agent` effect calls `applyRemoteAgent`.

- [ ] **Step 4: Run to verify they pass.** Expected: PASS.

- [ ] **Step 5: Commit** `feat: track which pane runs the agent; agent presentation kind`.

### Task 5: `session.transcript` protocol, dispatcher and host lookup

**Files:**
- Create: `ElisCore/Sources/ElisCore/ControlDispatcher+Transcript.swift`
- Modify: `ControlProtocol.swift:64` (`case sessionTranscript = "session.transcript"`), `ControlArgs` (`transcript: String?`, `maxBytes: Int?`, vars only, no init parameters), `ControlResult` (flat result fields, vars only, as `headless` and `versions`), `ControlActions.swift:236-238`, `ControlActionsDefaults.swift:306`, `ControlDispatcher.swift:40` (route the case), `PageSessionRefusal.swift:6` (add the case), `Elis/Control/ControlServer.swift:749` (the app's exhaustive not-handled list, so the app builds after this task), `AppStore+Agent.swift` (`Session.transcriptSource`), `Tests/ElisCoreTests/MockControlActions.swift`
- Test: `ControlProtocolTests.swift` (near `:472`), `ControlDispatcherTests.swift` (near `:801`), `AppStoreAgentTests.swift`

**Interfaces:**
- Consumes: `ClaudeTranscript.page` (Task 3), `Session.agentPane` (Task 4).
- Produces:
  - `public struct ControlTranscriptSource: Sendable, Equatable { claudeSessionID: String; pane: StatusPane; claudeDirectory: String }` — the host names its Claude directory, so a test points one host at a temp dir without sharing a cache: the app's `ControlServer.claudeDirectory` and `ServerActions.claudeDirectory` default to `ClaudeHome.directory()` and tests set them.
  - `public enum ControlTranscriptLookup: Sendable { case source(ControlTranscriptSource), refused(ControlResponse) }`
  - `ControlActions.transcriptSource(_ target: String?, window: String?, pane: StatusPane?, paneID: String?) -> ControlTranscriptLookup`; default `.refused("the Elis on this host is too old for session.transcript")` (Global Constraints).
  - `public struct ControlTranscriptRefusal: Error, Equatable { let message: String }`
  - `Session.transcriptSource(token: String?, pane: StatusPane?) -> Result<ControlTranscriptSource, ControlTranscriptRefusal>` — pane from `paneAddress`, else `agentPane ?? .left`; `no adapter` unless `runningAgent == .claude`, `agentSessionID` is set and the pane is `agentPane`; an unknown token answers `unknown pane id: X`.
  - The dispatcher reads through `ClaudeTranscript.instance(directory: source.claudeDirectory)` (one cached reader per directory) on `DispatchQueue.global(qos: .userInitiated)` through `withCheckedContinuation`, never in a `Task`: a 70 MB first scan or a wait on a per-path lock would park a cooperative-pool thread (three on CI, `.claude/rules/tests.md`); `ControlDispatcher` keeps its `init(actions:bus:)`, since every host builds one per request.
  - `public static func transcriptArguments(_ args: ControlArgs?) -> Result<ClaudeTranscriptArguments, ControlResponse>` (pure, reused by the app route in Task 6) with `ClaudeTranscriptArguments { pane: StatusPane?; paneID: String?; after: Int?; before: Int?; held: String?; maxBytes: Int }`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func transcriptRequestRoundTrips()               // ControlRequest with after "12", transcript "abc", maxBytes 100 encodes/decodes equal
@Test func transcriptResultOmitsNilFields()            // ControlResult with items only: no "reset", "pending", "skipped", "commands" keys
@Test func afterAndBeforeAreExclusive()                // error "use either --after or --before, not both"
@Test func offsetMustBeADecimal()                      // after "x" -> "after must be a byte offset"; before "-1" -> "before must be a byte offset"
@Test func maxBytesClampsAndRejectsNonPositive()       // 1_000_000 -> reader saw 49152; 0 -> "max-bytes must be greater than 0"
@Test func paneAliasesResolveAsInSessionText()         // "top" -> .left, "bottom" -> .right reach transcriptSource; "x" -> "invalid pane: x"
@Test func scratchPaneIsRefused()                      // pane "scratch" -> "session.transcript reads --pane left or right"
@Test func lookupRefusalPassesThrough()                // mock returns refused("no adapter") -> same error
@Test func defaultRefusalReadsAsTooOld()               // a ControlActions without the method -> exactly "the Elis on this host is too old for session.transcript"
@Test func readerRunsOffTheMainThread()                // a MainActor dispatch of a valid request over a temp-dir fixture succeeds; a regression traps the test process (the reader's precondition) rather than failing one test, which is accepted
@Test func missingFileIsTranscriptNotFound()
@Test func heldTranscriptIsOnlyCompared()              // decoy <dir>/projects/x.jsonl with a distinct prompt; transcript "../x" -> reset true, items from the real file, the decoy's prompt absent
@Test func pageFieldsLandFlatOnResult()                // result.transcript, size, start, next, items match the stub page
@Test func pageRowRefusesTranscript()                  // PageSessionRefusal
@Test func transcriptSourceNeedsRunningClaudeInThatPane()  // AppStoreAgentTests: agent nil -> no adapter; claude on left, ask right -> no adapter; ask nothing -> left source
```

- [ ] **Step 2: Run to verify they fail.** `swift test --filter "ControlProtocolTests|ControlDispatcherTests|AppStoreAgentTests"` — Expected: build error.

- [ ] **Step 3: Implement.** The dispatcher validates first (so identical flags give identical first errors on every host), parsing `pane` with `parseSurfacePane` (`ControlDispatcher+Panes.swift:29`, `session.text`'s selector) and then refusing `.scratch`, then calls `transcriptSource`, then the reader off-main, then maps the page onto `ControlResult`. Add `.sessionTranscript` to the app's not-handled list at `ControlServer.swift:749`; Task 6 moves it into the routed path.

- [ ] **Step 4: Run to verify they pass.** Expected: PASS. Also `swift build` in `ElisCore` and `xcodegen generate && xcodebuild build -scheme Elis` so every exhaustive switch over `Command` and `Body` compiles before the commit.

- [ ] **Step 5: Commit** `feat(control): session.transcript command`.

### Task 6: Mac app adapter and remote routing

**Files:**
- Create: `Elis/Control/ControlServer+Transcript.swift`
- Modify: `Elis/Control/ControlServer.swift:640-648` (`waitsOnNetwork` and `leavesWindowsUnchanged` gain `.sessionTranscript`), `:749` (drop the case Task 5 parked there), `Elis/Control/ControlServer+RemoteActions.swift:5-15,24` (route case and its runner), `ElisCore/Sources/ElisCore/ControlTranscript.swift` (pure words builder)
- Test: `ElisTests/ControlServerTranscriptTests.swift` (new), `ElisCore/Tests/ElisCoreTests/AttachedForwardTests.swift`

**Interfaces:**
- Consumes: `ControlDispatcher.transcriptArguments`, `Session.transcriptSource`, `AttachedOrigin`, `catalogPool(forSession:)`, `SshConnectionPool`.
- Produces:
  - `ControlServer.transcriptSource(...)` (the `ControlActions` method) through `resolver.resolveSession` and `Session.transcriptSource`.
  - `public enum TranscriptForward { static func words(session: String, paneID: String?, pane: StatusPane?, arguments: ClaudeTranscriptArguments) -> [String] }` → `["session", "transcript", "--target", session]` + `--pane-id=…` or `--pane …` + `--after=N`/`--before=N` + `--transcript=…` + `--max-bytes=N` (values joined to their flags).
  - `RemoteRoute.transcript(host: String, row: UUID, words: [String])`, decided in `remoteRoute` before the structural check for an attached row (`AttachedOrigin(row)`: `--target` = `origin.session`, pane token mapped with `AttachedOrigin.originPaneID`, a role passed as is) and for a server row (`binding.catalogOwned`: `--target` = the row id, `--pane-id` unchanged, since the catalog shares pane identities).
  - The runner leases from `catalogPool(forSession: row)` for server rows and from `attachedTranscriptPools[host]` (`SshConnectionPool(host:, root: Self.sshPoolRoot, key: "\(socketPath)|transcript|\(host)")` with the same runner closure as `ControlServer+RemoteCatalog.swift:29`; never closed, since an idle master exits after `ControlPersist=60`) for attached rows, user `"transcript:\(row)"`, awaits `pool.ready`, releases in `defer`, runs `RemoteSession.controlCommand(... controlPath:)` with `remoteTreeDeadline`, and returns the decoded reply unchanged. No `refreshWindowCache()`. A reply that does not decode, or `refusesUnknown(.sessionTranscript)`, answers `the Elis on <host> is too old for session.transcript`.

- [ ] **Step 1: Write the failing tests:**

```swift
// AttachedForwardTests (ElisCore)
@Test func transcriptWordsJoinValuesToFlags()     // ["session","transcript","--target","s1","--pane-id=p1","--after=10","--transcript=-x","--max-bytes=100"]

// ControlServerTranscriptTests (hosted)
func testLocalRowReadsThroughTheDispatcher()       // claudeDirectory = temp dir with projects/x/c1.jsonl; claude on left with id "c1" -> items from the fixture
func testLocalRowWithoutClaudeAnswersNoAdapter()
func testAttachedRowForwardsToOriginWithItsPaneToken()  // stub remoteRunner gets ssh argv containing "session transcript --target <origin>" and the origin pane id; reply passed through byte for byte
func testServerRowForwardsWithRowIDAndPooledPath()      // argv contains "ControlPath=" and "--target <row id>"
func testOriginTooOldIsNamed()                     // stub replies "invalid request: ... session.transcript" -> "the Elis on host is too old for session.transcript"
func testUndecodableOriginReplyIsTooOld()          // stub replies "not json" -> the same too-old text
func testTranscriptLeavesWindowCacheAlone()        // no window-cache rebuild counted for the call
```

- [ ] **Step 2: Run to verify they fail.** `xcodebuild test -project Elis.xcodeproj -scheme ElisTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:ElisTests/ControlServerTranscriptTests` (after `xcodegen generate`; `scripts/test-app.sh` takes no filter) and `cd ElisCore && swift test --filter AttachedForwardTests` — Expected: FAIL/build error.

- [ ] **Step 3: Implement** per the Interfaces block; reuse `remoteRunner` and `remoteTreeDeadline`.

- [ ] **Step 4: Run to verify they pass.** Same commands — Expected: PASS. Then `lsappinfo list | grep -A4 elis.debug` per CLAUDE.md.

- [ ] **Step 5: Commit** `feat(app): route session.transcript for attached and server rows`.

### Task 7: elis-server detects Claude and serves the command

**Files:**
- Modify: `ElisCore/Sources/ElisServerKit/ServerCommandPolicy.swift:7-23` (`.sessionTranscript`), `ServerActions+Sessions.swift` (`transcriptSource` via `withSession`/`resolveSession` and `Session.transcriptSource`), `PaneObserver.swift` (agent detection per tick)
- Test: `ElisCore/Tests/ElisServerTests/ServerCommandPolicyTests.swift`, `ServerActionsSessionsTests.swift` (near `:420`), `PaneObserverTests.swift`

**Interfaces:**
- Consumes: `AppStore.applyAgentSamples` (Task 4), `ClaudeHome` (Task 1), `ControlActions.transcriptSource` and `Session.transcriptSource` (Task 5).
- Produces: `PaneObserver.init(..., agentProbe: @escaping (Int32) -> AgentPaneProbe? = ProcAgent.probe)` with `struct AgentPaneProbe { pid: Int32; argv: [String] }`; `ProcAgent.probe(leader:)` = the foreground group from `ProcCwd.foregroundGroup` and its `/proc/<pid>/cmdline`. shortcut: the group leader only, so a script-started claude without job control is missed; read the group members when that matters.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func transcriptIsServed()                          // ServerCommandPolicy.refusal(.sessionTranscript) == nil
@Test func observerRecordsClaudeAndItsSession()           // probe -> (pid 42, ["claude"]); claudeDir/sessions/42.json {"sessionId":"s1"} -> session.runningAgent .claude, agentPane .left, agentSessionID "s1"
@Test func observerClearsAgentWhenProbeShowsAShell()
@Test func serverTreeCarriesAgentFields()                 // tree JSON has agent "claude", agentSessionId "s1", agentPane "left"
@Test func serverAnswersTranscriptFromItsClaudeDir()      // ServerActionsSessionsTests: actions.claudeDirectory = temp dir with a fixture -> items
@Test func serverPublishesAgentToPresenters()             // hub records .agent and .agentSession frames
```

- [ ] **Step 2: Run to verify they fail.** `swift test --filter "ServerCommandPolicyTests|PaneObserverTests|ServerActionsSessionsTests"` — Expected: FAIL.

- [ ] **Step 3: Implement.** In `apply`, after the leaders are known, build per pane `AgentPaneSample(pane:, agent: SessionLauncher.agent(argv:), claudeSessionJSON: ClaudeHome.sessionJSON(pid:directory:))` and call `store.applyAgentSamples(_, focused: session.focusedPane == .right ? .right : .left, forSession:)`. The `claudeDirectory` is injectable for tests.

- [ ] **Step 4: Run to verify they pass.** Expected: PASS.

- [ ] **Step 5: Commit** `feat(server): detect Claude and serve session.transcript`.

### Task 8: `elisctl session transcript`

**Files:**
- Create: `ElisCore/Sources/elisctlKit/Session+Transcript.swift`
- Modify: `SessionCommands.swift:21` (add `Transcript.self` after `Text.self`), the response formatter that `SocketClient.formatResponse` uses
- Test: `ElisCore/Tests/elisctlKitTests/CommandsTests.swift` (near `:579-620`)

**Interfaces:**
- Consumes: `ControlArgs.transcript`, `maxBytes`, `after`, `before`, `pane`, `paneID`; result fields (Task 5).
- Produces: `Session.Transcript: RequestCommand` with `--pane`, `--pane-id`, `--after`, `--before`, `--transcript`, `--max-bytes`; human output: `title`, `model`, `permissionMode` lines when set, then one line per item `kind  text` (tool items `tool  <name> <arg> <mark>`), then `next <N>`.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func transcriptBuildsRequest()            // ["session","transcript","--pane","right","--after","10","--transcript","c1","--max-bytes","500"] -> cmd .sessionTranscript, args.after "10", pane "right", transcript "c1", maxBytes 500
@Test func afterAndBeforeAreExclusiveAtParse()  // ValidationError "use either --after or --before, not both"
@Test func offsetsMustBeNonNegative()           // --after -1 -> ValidationError
@Test func humanOutputListsItems()              // formatted result: contains "user  hello", "tool  Bash Run tests ok", "next 42"
```

- [ ] **Step 2: Run to verify they fail.** `swift test --filter CommandsTests` — Expected: FAIL.

- [ ] **Step 3: Implement** with `Int` options turned into decimal strings for `after`/`before`, and `--pane` checked by `validatePaneArgument` as `session text` does (the dispatcher refuses `scratch`).

- [ ] **Step 4: Run to verify they pass.** Expected: PASS.

- [ ] **Step 5: Commit** `feat(cli): elisctl session transcript`.

### Task 9: End-to-end UI test

**Files:**
- Create: `ElisUITests/TranscriptUITests.swift` (a `ControlAPITestCase` subclass)
- Test: same

**Interfaces:**
- Consumes: the whole stack; `launchEnvironmentOverrides` (`ControlAPITestCase.swift:79`).

- [ ] **Step 1: Write the test** `testTranscriptFollowsAFakeClaude`: override `launchEnvironmentOverrides` with `CLAUDE_CONFIG_DIR = <stateDir>/claude`; write `<stateDir>/claude/projects/-e2e/e2e-1.jsonl` with a user and an assistant record; type into the active session `zsh -c 'mkdir -p "$CLAUDE_CONFIG_DIR/sessions"; print -r -- "{\"sessionId\":\"e2e-1\"}" > "$CLAUDE_CONFIG_DIR/sessions/$$.json"; exec -a claude sleep 90'` and Enter; poll `tree` (bound 15 s) until the node shows `agent == "claude"`, `agentSessionId == "e2e-1"`, `agentPane == "left"`; send `{"cmd":"session.transcript","target":<id>}` and assert `items` kinds `["user","text"]` and `transcript == "e2e-1"`; append a Bash `tool_use` and its `tool_result` (`Exit code 1`), send with `"after": "<next>"` and assert one `tool` item with `mark == "exit 1"`. Assert by name beside each wait which state is missing. End by typing Ctrl-C (`\u{3}`) into the pane, so the fake never outlives the run; `sleep 90` bounds it if the test dies first.

- [ ] **Step 2: Run it.** `xcodebuild test -project Elis.xcodeproj -scheme Elis -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:ElisUITests/TranscriptUITests/testTranscriptFollowsAFakeClaude` (ask the owner before an XCUITest run, per `.claude/rules/ui-tests.md`) — Expected: PASS (it fails before Tasks 4-6 land). Read `.claude/rules/ui-tests.md` first if the runner times out at init.

- [ ] **Step 3: Commit** `test(ui): session.transcript end to end`.

### Task 10: Docs, skill and rules

**Files:**
- Modify: `site/commands.html` (a `session transcript` entry beside `session text` at `:1569`: invocation, arguments, result fields, cursor and upsert contract, `rejected`, errors; `agentPane` beside `agentSessionId` at `:555`; `docs.html` lists no tree fields, so it gets none), `site/docs.html` (a short "Read Claude's conversation" paragraph in the agents section, and the remote note that an older host answers "too old"), `plugins/elis/skills/elis/SKILL.md` (`description` trigger "read a session's Claude conversation" plus a pointer section), `plugins/elis/skills/elis/reference.md` (command entry), `.claude/rules/control-api.md` (new "Claude transcript" section: reader in ElisCore, host lookup through `transcriptSource` and why not the tree, cursor/upsert/reset, routing and pooling, too-old text, page-row refusal; under "Remote sessions" the `agent` kind and its stream-end clear; under "elis-server" the detection and the served command)
- Test: `ElisCore/Tests/ElisCoreTests/SkillInstallTests.swift` if it pins skill content

- [ ] **Step 1: Write the docs**, short paragraphs, one fact per surface; the Chat UI itself is documented by Plan B.
- [ ] **Step 2: Run** `swift test --filter SkillInstallTests` — Expected: PASS.
- [ ] **Step 3: Commit** `docs: session.transcript and agentPane`.

### Task 11: Final verification

**Files:** none changed unless a check fails.

- [ ] **Step 1: Gates, once.** `cd ElisCore && swift test`; `make test-app`; `make lint` — Expected: all green, zero lint findings.
- [ ] **Step 2: Isolated Debug instance.** Build Debug, launch with `env -u` for every inherited `CLAUDE*`/`ELIS_*`/`GHOSTTY_*` and `open -n --env ELIS_STATE_DIR=/tmp/elis-tA`; confirm the socket within 10 s. In its pane send `cd ~/IdeaProjects/elis && claude`, ask one question that runs a Bash tool. Then, with the Debug binary's full path and `--socket /tmp/elis-tA/elis.sock`: `elisctl session transcript --json` (tail, commands present), again with `--after <next>` (no duplicates), and `tree --json` shows `agent`, `agentSessionId`, `agentPane`. Split the pane, focus the shell side: `agent` stays `claude`.
  Open check 17: note the transcript file's size, run `/rewind` to an earlier prompt, then `/clear`; record whether the size ever dropped and that the next `--after <next>` read answers `reset` with the new tail (a shrunk file already answers `reset`, Task 3 `shrunkFileResets`; `/clear` starts a new id, which the tree's `agentSessionId` change covers).
- [ ] **Step 3: Remote rows (if a second Mac or an elis-server host is reachable).** Attach a row or open the server window in the Debug instance and repeat Step 2's reads against that row; on the Linux host check open check 8 (the transcript layout under `~/.claude/projects`) and open check 15: with `elisctl events --kind status --json` (the Debug binary, isolated socket; it reads through `events.read`) running, Claude on the server row going busy and idle shows `status` events for that row. Record the result for the owner; skip with a note when no host is reachable.
- [ ] **Step 4: Cross-plan phone run.** Hand the running instance's details to Plan B's final task: an agent-owned Android emulator (never the owner's phone, never the `Pixel_5` AVD) paired with this isolated instance exercises Chat end to end over these APIs.
- [ ] **Step 5: Clean up.** SIGTERM the Debug PID, check `lsappinfo list | grep -A4 elis.debug`, remove `/tmp/elis-tA`.

---

## Self-review notes

- Spec coverage: reader (Tasks 1-3), command and CLI (5, 8), scope call 1 and tree fields (4), attached and server rows (4, 6, 7), tests incl. e2e (every task, 9), docs and skill (10). Scope call 3's visual grouping is assigned to Plan B; A ships `readOnly`.
- Deviation: the spec has the dispatcher read `agentSessionId` from the tree. `controlTree(window:)` projects one placement store (`ControlServer+AppCommands.swift:10-13`), so a session in another window would answer `no adapter`; the host resolves the target instead (`transcriptSource`), as every session command does. The fork compiles through the refusing default.
- Deviation: attached rows use one `RemoteRoute.transcript` with server rows instead of a new `AttachedForward` case plus a pass-through follow-up; the result is the origin's reply unchanged either way.
- Deviation: tool items add `rejected` (decision for plans B and C); the spec reads "Rejected" from `is_error`, which would also mark an approved call that failed.
- Deviation: the CLI takes `--target T` (`TargetOptions`, as `session text`) where the spec shows a positional `[<target>]`.
- Open checks owned here: 6 answered from real transcripts (Task 3 Interfaces), 7 in Task 1, 8 and 15 in Task 11 Step 3, 17 in Task 11 Step 2.
- Open check 16 answered by reading code: `runOnOrigin` and `serverPageResult` pass no `controlPath`, so forwards were not pooled; Task 6 pools transcript reads.
