# Session id drop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Dragging a sidebar session or workspace row onto a terminal inserts the session ids (Claude conversation id, else agterm id), comma-separated.

**Architecture:** The sidebar drag adds a plain `.string` to its pasteboard item; the terminal already inserts strings as a bracketed paste. `Session.agentSessionID` holds the Claude id: the local monitor sets it, an origin mirrors it to attached rows through a new presentation frame, and `tree` reads it back.

**Tech Stack:** Swift 6, AppKit `NSOutlineView`, `agtermCore` (swift test), hosted XCTest (`make test-app`).

**Spec:** `docs/superpowers/specs/2026-11-17-session-id-drop-design.md`

## Global Constraints

- Ids are joined by `,` with no space.
- A session's id: `agentSessionID ?? remoteSessionID ?? id.uuidString`.
- `agtermCore` imports no AppKit; the formatter and frame live there.
- Every change builds, passes `swift test`, `make test-app`, `make lint` (each gate once, at the end).
- Never run `agterm`/`agtermctl` against the default socket; manual checks use an isolated Debug instance.
- PRs go to `NaikSoftware/agterm` (`gh pr create --repo NaikSoftware/agterm`); the gh default repo is upstream.

## Review Focus

- A workspace with no sessions: the drag writes no `.string`, so a terminal drop is refused (no empty paste).
- A workspace with companions: parent then its companions, in `workspace.sessions` order.
- A Claude session that exits: the id stays until a new one replaces it (same rule as `resumeLine`).
- An origin that predates the new frame: the attached row keeps `agentSessionID == nil` and falls back to `remoteSessionID`.
- A `sessionId` with shell-unsafe characters in `~/.claude/sessions/<pid>.json` is rejected, as `claudeResumeLine` rejects it today.

---

### Task 1: Core id field, formatter and tree read-back

**Files:**
- Modify: `agtermCore/Sources/agtermCore/SessionLauncher.swift` (extract id parsing)
- Modify: `agtermCore/Sources/agtermCore/Session.swift` (field)
- Modify: `agtermCore/Sources/agtermCore/ControlProjection.swift`, `AppStore.swift:444` (read-back)
- Test: `agtermCore/Tests/agtermCoreTests/SessionLauncherTests.swift`, `AppStoreTreeProjectionTests.swift`
- Docs: `site/commands.html` (after the `agent` field, ~line 562), `plugins/agterm/skills/agterm/reference.md` (next to `agent`)

**Interfaces:**
- Produces: `SessionLauncher.claudeSessionID(json: Data) -> String?`; `Session.agentSessionID: String?` (`@ObservationIgnored public var`, not persisted); `Session.dropID: String`; `static Session.dropText(_ sessions: [Session]) -> String?`; `ControlSessionNode.agentSessionId: String?` (JSON key `agentSessionId`).

- [ ] **Step 1: Write failing tests**
  - `claudeSessionIDReadsAPlainToken`: `{"sessionId":"abc-1_2","cwd":"/x"}` → `"abc-1_2"`; `{"sessionId":"a b"}` → nil; `{}` → nil.
  - `claudeResumeLine` existing tests still pass unchanged.
  - `dropTextJoinsIdsWithCommas`: three sessions, one with `agentSessionID = "c1"`, one remote with `remoteSessionID = "R"`, one plain → `"c1,R,<uuid>"`; `[]` → nil.
  - Tree projection test: a session with `agentSessionID = "c1"` reports `agentSessionId == "c1"`; one without omits the key.
- [ ] **Step 2:** `cd agtermCore && swift test --filter SessionLauncherTests` → FAIL (symbols missing).
- [ ] **Step 3: Implement.** `claudeResumeLine(json:)` calls `claudeSessionID(json:)` for the id and keeps its cwd checks. `dropText` returns nil for an empty list.
- [ ] **Step 4:** run the two test files → PASS.
- [ ] **Step 5:** Docs: `agentSessionId` (Claude Code's conversation id for the session, also mirrored from an origin; omitted when unknown). Commit `feat: sessions record their Claude conversation id`.

### Task 2: Set the id locally and mirror it to attached rows

**Files:**
- Modify: `agterm/SessionLaunchers.swift:104` (monitor)
- Modify: `agtermCore/Sources/agtermCore/AppStore+SessionState.swift` (setter, next to `setContext`)
- Modify: `agtermCore/Sources/agtermCore/PresentationFrames.swift`, `PresentationFrame+Codable.swift`, `PresentationHub.swift:73` (`supportedKinds`), `AppStore+Presentation.swift:20` (snapshot)
- Modify: `agtermCore/Sources/agtermCore/RemotePresentationClient.swift:262-274`, `AppStore+RemotePresentation.swift`, `agterm/Control/ControlServer+RemotePresentation.swift:94` (effects wiring)
- Test: `PresentationFramesTests.swift`, `RemotePresentationClientTests.swift`, `AppStorePresentationTests.swift`

**Interfaces:**
- Consumes: Task 1's `Session.agentSessionID`, `SessionLauncher.claudeSessionID(json:)`.
- Produces: `AppStore.setAgentSessionID(_ id: String?, forSession: UUID)`; frame body `.agentSession(String?)`, kind `"agent.session"`, key `agentSession`; `PresentationSnapshot.agentSession: String?`; effect `agentSession: (String?) -> Void`; `AppStore.applyRemoteAgentSessionID(_:forSession:)`.

- [ ] **Step 1: Write failing tests**
  - Frame round-trip: `.agentSession("c1")` encodes kind `agent.session` and decodes back; `.agentSession(nil)` too.
  - Snapshot with `agentSession: "c1"` round-trips; a snapshot JSON without the key decodes to nil.
  - `setAgentSessionID` publishes one frame on change and none on an unchanged value, and calls `scheduleTreeChanged`.
  - Client: a snapshot and a later `agent.session` frame each reach the `agentSession` effect.
  - `applyRemoteAgentSessionID` sets the field only on a row with `remotePresentation`.
- [ ] **Step 2:** `swift test --filter Presentation` → FAIL.
- [ ] **Step 3: Implement**, modeled on `context` at each site. The monitor calls `store.setAgentSessionID` with the id it reads from the same pid file as `resumeLine`, only when it finds one (no clear on exit). Local rows only; the monitor already skips remote rows. agterm-server needs no change: an unknown kind decodes to `.unknown`.
- [ ] **Step 4:** tests → PASS.
- [ ] **Step 5:** Commit `feat: an origin mirrors the Claude conversation id to attached rows`.

### Task 3: The sidebar drag writes the ids

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar+DragDrop.swift:10-27`
- Modify: `agterm/Ghostty/GhosttySurfaceView+Input.swift:10-11` (comment only: a sidebar drag now carries the ids as text)
- Test: `agtermTests/WorkspaceSidebarCompanionsTests.swift` (has the coordinator/outline fixtures)
- Docs: `site/docs.html:500` paragraph, plus `plugins/agterm/skills/agterm/SKILL.md` one line if it lists drag behavior

**Interfaces:**
- Consumes: Task 1's `Session.dropText(_:)`.

- [ ] **Step 1: Write failing hosted tests**
  - `testSessionDragWritesItsIdAsText`: `pasteboardWriterForItem` for an unselected session row → `string(forType: .string) == session.dropID`.
  - `testWorkspaceDragWritesAllSessionIdsAsText`: a workspace with a parent and companion → `"<parent>,<companion>"`.
  - `testEmptyWorkspaceDragWritesNoText`: `.string` is nil.
- [ ] **Step 2:** `xcodebuild test ... -only-testing:agtermTests/WorkspaceSidebarCompanionsTests` → FAIL.
- [ ] **Step 3a: Rename the private pasteboard types** in `agterm/Views/WorkspaceSidebar.swift:6,9` to the fork's bundle id: `ua.naiksoftware.agterm2.session` and `ua.naiksoftware.agterm2.workspace` (user request). Grep the repo (tests, docs, `.claude/rules`) for `com.umputun.agterm.session`/`.workspace` and update every hit.
- [ ] **Step 3: Implement.** Resolve the dragged ids to `Session`s through `store.session(withID:)` (session case) or the workspace's `sessions` (workspace case), and set `.string` when `dropText` is non-nil. The private types stay first and unchanged.
- [ ] **Step 4:** targeted run → PASS.
- [ ] **Step 5:** docs.html: "Drop a session or workspace row on a terminal to type its ids, comma-separated: Claude Code's conversation id when known, else the agterm session id." Commit `feat: dropping a sidebar row on a terminal types its session ids`.

### Task 4: Gates and manual check

- [ ] `cd agtermCore && swift test`, `make test-app`, `make lint` → all green, zero lint findings.
- [ ] Isolated Debug instance: drag a Claude session onto another pane (UUID-like Claude id appears), a plain one (agterm UUID), a workspace (comma list).
- [ ] `lsappinfo list | grep -A4 agterm.debug` after the hosted run.
