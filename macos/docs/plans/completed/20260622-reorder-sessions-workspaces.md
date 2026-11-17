# Reorder Sessions and Workspaces (drag-and-drop + control API/CLI)

## Overview

Today a session can be moved to a *different* workspace (sidebar drag-and-drop, or `session.move --workspace`), but it always lands at the end, and there is no way to:

- reorder a session *within* its own workspace,
- reorder a workspace among its siblings.

This plan adds both, over two surfaces: sidebar drag-and-drop (precise, drop-between-rows) and the control API/CLI (relative `up|down|top|bottom`). Ordering is already pure array position end-to-end, so this is array-mutation plus `save()` with no schema change and no migration. The model already has the session primitive (`moveSession(_:toWorkspace:at:)` with a clamped index); the work is wiring it up, adding the workspace equivalent, a shared relative-step resolver, the drag-drop index handling, and the control/CLI surface.

## Context (from discovery)

- **Ordering is pure array position** in the model (`Workspace.sessions`, `AppStore.workspaces`), the snapshot (`WorkspaceSnapshot.sessions`, `Snapshot.workspaces`), and on-disk JSON. No order/rank field anywhere. Reorder = mutate the array + `save()`.
- `AppStore.moveSession(_ sessionID: UUID, toWorkspace targetID: UUID, at index: Int? = nil)` exists (`HangarCore/Sources/HangarCore/AppStore.swift` ~291). It removes the session, clamps `index` to the POST-removal count, inserts, saves. Intra-workspace reorder is "move to the same workspace at index" — already supported at the model level, just unwired. There is a `location(ofSession:)` helper returning `(workspaceIndex, sessionIndex)`.
- `AppStore.workspaces` is a plain array; `addWorkspace` appends; **no `moveWorkspace` exists**.
- Sidebar: `Hangar/Views/WorkspaceSidebar.swift` Coordinator. `pasteboardWriterForItem` (~817) returns `nil` for workspace nodes (only sessions draggable); session pasteboard type `ua.naiksoftware.hangar.session` (~7). `validateDrop` (~824) rejects same-workspace drops and force-retargets every drop to `NSOutlineViewDropOnItemIndex` (ignores `proposedChildIndex`). `acceptDrop` (~838) calls `moveSession(...)` with no `at:` (append). `SidebarNode` cached by UUID; `roots`/`children` rebuilt from store order each reload via the `TreeShape` reconcile (preserves expansion/selection). `targetWorkspace(forDropOn:)` ~859.
- Control: `case sessionMove = "session.move"` (`ControlProtocol.swift` ~17). `ControlArgs.to: String?` already exists, used by `session.go` for `next|prev|first|last` — reuse it for `up|down|top|bottom`. Dispatch arm `case .sessionMove` in `Hangar/Control/ControlServer.swift` (~384) uses `resolveSession` then a workspace `resolve(...)`. CLI `session move` (`HangarCore/Sources/hangarctlKit/Commands.swift` ~237) takes a required positional `workspace` + `--target`.
- Test suites (host-free): `HangarCore/Tests/HangarCoreTests/` has `AppStoreTests.swift`, `WorkspaceTests.swift`, `ControlProtocolTests.swift`, `ControlResolveTests.swift`. CLI parse tests live in the hangarctlKit test target. XCUITests in `HangarUITests/`.

## Locked design decisions (from brainstorm — do not relitigate)

1. **Position model (CLI/API):** relative `up|down|top|bottom`, mirroring `session.go --to next|prev|first|last`. Drag-and-drop stays precise (drop between rows). The asymmetry (CLI relative, drag absolute) is intentional.
2. **API shape:** fold reorder into `move`. `session.move` gains `--to`; new `workspace.move --to`. No separate `reorder` verb.
3. **GUI scope:** drag-and-drop + CLI only. No action-palette, menu, or keyboard-shortcut entries for reorder.

## Development Approach

- **Testing approach:** Regular (code, then tests in the same task). The pure resolver and the `AppStore` methods are host-free and fast to test; the sidebar drag behavior is verified by a focused XCUITest.
- Complete each task fully before the next. Make small, focused changes. Maintain backward compatibility (existing `session.move --workspace` and cross-workspace drag must behave exactly as before).
- **CRITICAL: every task includes new/updated tests** (success + error/edge cases), listed as separate checklist items.
- **CRITICAL: `cd HangarCore && swift test` must pass and the app must build before starting the next task.**
- **CRITICAL: update this plan file if scope changes during implementation.**

## Testing Strategy

- **Unit (primary gate):** `cd HangarCore && swift test` — host-free, fast. Covers the resolver, the `AppStore` reorder methods, snapshot→restore order preservation, the protocol round-trip, and CLI parse-validation.
- **XCUITest (focused only):** a new `ReorderUITests.swift` (session-within-workspace + workspace reorder, asserted via `session-row` / `workspace-row` order), updated `ControlAPIUITests.swift` (the control surface changed: new reorder dispatch/error arms + positive reorder e2e), and `SidebarUITests.testDragSessionToWorkspace` as the cross-workspace regression guard. The suite is slow; run ONLY the affected cases (`-only-testing:HangarUITests/ReorderUITests`, `-only-testing:HangarUITests/ControlAPIUITests`, `-only-testing:HangarUITests/SidebarUITests/testDragSessionToWorkspace`), never the full suite, per the project test-cadence convention.
- App must build (`xcodebuild` Debug) after the sidebar tasks.

## Progress Tracking

- Mark completed items `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix.
- Keep this plan in sync with the actual work.

## Solution Overview

A shared, host-free `ReorderDirection` enum and a pure index resolver own the relative-step arithmetic, so the model, the control server, and (indirectly) the CLI agree on semantics. `AppStore` gets `reorderSession` (reuses the existing `moveSession` primitive), a new `moveWorkspace` primitive, and `reorderWorkspace`. The sidebar starts honoring `proposedChildIndex` (enabling intra-workspace session reorder and precise cross-workspace placement for free) and gains a second pasteboard type so workspace rows become draggable. The control channel makes `session.move` mode-bearing (`--to` reorder vs `--workspace` relocate) and adds `workspace.move`. The CLI mirrors that. Docs (CLAUDE.md catalog + Sidebar section, README Features + Scripting) are updated last.

## Technical Details

### Two distinct index spaces (the core subtlety)

`moveSession`/`moveWorkspace` **remove the element first, then insert**, so their `at:` is a POST-removal index. Two callers feed them from different spaces:

- **Relative / CLI path** — the resolver returns post-removal insert indices directly:
  - `up` → `current - 1`, `down` → `current + 1`, `top` → `0`, `bottom` → `count - 1` (where `count` is the pre-removal length). For a same-array move, `down = current + 1` is already correct post-removal (the element formerly at `current+1` shifts down to `current` after removal, so inserting at `current+1` lands our element after it). Returns `nil` when it would be a no-op (`up`/`top` at index 0, `down`/`bottom` at the last index).
- **Drag-drop path** — AppKit's `proposedChildIndex` is a PRE-removal absolute index in the displayed array. For a **same-parent downward** move (`sourceIndex < childIndex`) the caller subtracts 1 before passing to `moveSession`/`moveWorkspace`; cross-parent and upward moves pass the index unchanged. This adjustment lives in `acceptDrop` so the model contract is untouched.

### New file `HangarCore/Sources/HangarCore/Reorder.swift`

```swift
public enum ReorderDirection: String, Sendable {
    case up, down, top, bottom
}

extension ReorderDirection {
    /// destinationIndex returns the post-removal insert index for a relative reorder
    /// within a list of `count` elements, or nil when the move is a no-op
    /// (already at the end in this direction). No wraparound.
    public func destinationIndex(from current: Int, count: Int) -> Int? {
        switch self {
        case .up:     return current > 0 ? current - 1 : nil
        case .down:   return current < count - 1 ? current + 1 : nil
        case .top:    return current > 0 ? 0 : nil
        case .bottom: return current < count - 1 ? count - 1 : nil
        }
    }
}
```

### `AppStore` additions (`HangarCore/Sources/HangarCore/AppStore.swift`)

```swift
public func reorderSession(_ id: UUID, _ direction: ReorderDirection) {
    guard let loc = location(ofSession: id) else { return }
    let count = workspaces[loc.workspaceIndex].sessions.count
    guard let dest = direction.destinationIndex(from: loc.sessionIndex, count: count) else { return }
    moveSession(id, toWorkspace: workspaces[loc.workspaceIndex].id, at: dest)
}

public func moveWorkspace(_ id: UUID, at index: Int) {
    guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
    let workspace = workspaces.remove(at: current)
    let dest = max(0, min(index, workspaces.count))
    workspaces.insert(workspace, at: dest)
    save()
}

public func reorderWorkspace(_ id: UUID, _ direction: ReorderDirection) {
    guard let current = workspaces.firstIndex(where: { $0.id == id }) else { return }
    guard let dest = direction.destinationIndex(from: current, count: workspaces.count) else { return }
    moveWorkspace(id, at: dest)
}
```

`reorderSession` reuses the existing `moveSession` (same workspace id → in-place reorder). `moveWorkspace` mirrors `moveSession`'s remove/clamp/insert/save shape. All no-op on `nil`/unknown id (no redundant `save()`).

### Control server (`Hangar/Control/ControlServer.swift`)

`session.move` becomes mode-bearing:
- `args.to` AND `args.workspace` both set → error (`session.move takes either --to or a workspace, not both`).
- neither set → error (`session.move requires --to or a workspace`).
- `args.to` set → parse `ReorderDirection(rawValue:)` (invalid → error), `resolveSession`, `store.reorderSession(id, dir)`, return the session id.
- `args.workspace` set → existing relocate path, unchanged.

New `case .workspaceMove`: require `args.to`, parse `ReorderDirection` (invalid → error), resolve the workspace target via the existing workspace resolver (active/exact/prefix) honoring the global `--window` selector like other workspace commands, `store.reorderWorkspace(id, dir)`, return the workspace id.

### Protocol (`HangarCore/Sources/HangarCore/ControlProtocol.swift`)

Add `case workspaceMove = "workspace.move"`. Reuse `ControlArgs.to`. No new `ControlArgs` field.

### CLI (`HangarCore/Sources/hangarctlKit/Commands.swift`)

`session move`: make `workspace` positional optional, add `@Option var to: String?`, add `validate()` rejecting neither/both (the `overlay open --block/--wait` precedent). `makeRequest` builds `ControlArgs(workspace:)` or `ControlArgs(to:)`. New `workspace move` subcommand: required `--to`, `--target` defaulting to `active`, builds `ControlRequest(cmd: .workspaceMove, ...)`. Human (non-`--json`) output prints `ok` (reorder is not a create — no id echo). Direction-string validity is enforced server-side (matching `session.go`'s string `--to`).

## What Goes Where

- **Implementation Steps** (`[ ]`): all code, tests, and docs — entirely in this repo.
- **Post-Completion** (no checkboxes): manual drag-UX verification in the real app, and the focused XCUITest run command.

## Implementation Steps

### Task 1: ReorderDirection enum + pure index resolver

**Files:**
- Create: `HangarCore/Sources/HangarCore/Reorder.swift`
- Create: `HangarCore/Tests/HangarCoreTests/ReorderTests.swift`

- [x] create `Reorder.swift` with the `ReorderDirection` enum and `destinationIndex(from:count:)` exactly as in Technical Details
- [x] write tests for each direction at a middle index (up/down/top/bottom return the expected post-removal index)
- [x] write edge-case tests: `up`/`top` at index 0 → nil; `down`/`bottom` at last index → nil; single-element list (count 1) → all nil; verify behavior for a 2-element list both directions
- [x] run `cd HangarCore && swift test` — must pass before Task 2

### Task 2: AppStore reorderSession + moveWorkspace + reorderWorkspace

**Files:**
- Modify: `HangarCore/Sources/HangarCore/AppStore.swift`
- Modify: `HangarCore/Tests/HangarCoreTests/AppStoreTests.swift`

- [x] add `reorderSession`, `moveWorkspace`, `reorderWorkspace` exactly as in Technical Details
- [x] write tests for `reorderSession`: move up/down/top/bottom within a multi-session workspace; no-op at the ends; unknown id is a no-op; selection (`selectedSessionID`) is unaffected
- [x] write tests for `moveWorkspace`: reorder within bounds; index clamped at both ends; unknown id is a no-op
- [x] write tests for `reorderWorkspace`: up/down/top/bottom; no-op at the ends
- [x] write a test that order survives `snapshot()` → `restore(from:)` after a session reorder AND a workspace reorder (positional persistence)
- [x] run `cd HangarCore && swift test` — must pass before Task 3

### Task 3: Control protocol + server dispatch (session.move mode-bearing + workspace.move)

**Files:**
- Modify: `HangarCore/Sources/HangarCore/ControlProtocol.swift`
- Modify: `Hangar/Control/ControlServer.swift`
- Modify: `HangarCore/Tests/HangarCoreTests/ControlProtocolTests.swift`
- Modify: `HangarUITests/ControlAPIUITests.swift`

- [x] add `case workspaceMove = "workspace.move"` to the `Command` enum
- [x] make the `.sessionMove` arm mode-bearing (to vs workspace; both→error; neither→error; invalid direction→error) per Technical Details. The neither-set error string changes from `"session.move requires a workspace"` to one covering both forms (e.g. `"session.move requires --to or a workspace"`)
- [x] add the `.workspaceMove` arm (require `to`, resolve the workspace target via the existing `resolveWorkspace` honoring `--window`, `reorderWorkspace`, return id)
- [x] write HOST-FREE round-trip tests in `ControlProtocolTests.swift` (encode/decode only): `session.move` with `to`, `workspace.move` with `to`, and confirm the `workspace.move` raw string maps to `.workspaceMove`
- [x] update the existing `ControlAPIUITests.testSessionMoveRequiresWorkspace` for the new neither-set error string
- [x] add `ControlAPIUITests` dispatch/error cases (driven through the real socket, where the dispatcher actually runs): `session.move` with both `to` and `workspace` → error; invalid direction string → error; `workspace.move` without `to` → error
- [x] add `ControlAPIUITests` positive e2e (the keep-in-sync "end-to-end" half for both new modes): create ≥3 sessions, send `session.move --to up`/`--to top`, poll the tree order; create ≥3 workspaces, send `workspace.move --to top`/`--to up`, poll order
- [x] run `cd HangarCore && swift test` (host-free) AND focused `-only-testing:HangarUITests/ControlAPIUITests`; app must build — must pass before Task 4. NOTE: host-free `swift test` passes (362/362, incl. the 3 new round-trip tests). The app BUILDS clean and the UITest bundle COMPILES clean (`xcodebuild build-for-testing` → TEST BUILD SUCCEEDED, so the new ControlAPIUITests methods are valid Swift). ⚠️ The focused XCUITest could NOT be executed in this autonomous env: the runner fails at init with "Timed out while enabling automation mode" before ANY test method runs — an environmental harness/TCC block, NOT a test/code failure (reproduced identically across two runs of the whole `ControlAPIUITests` target). The new dispatch/error + e2e cases are authored and compile; verify manually with a re-run once the runner's automation-mode grant is available.

### Task 4: hangarctl CLI (session move --to + workspace move)

**Files:**
- Modify: `HangarCore/Sources/hangarctlKit/Commands.swift`
- Modify: `HangarCore/Tests/hangarctlKitTests/CommandsTests.swift`

- [x] make `session move`'s `workspace` positional optional and add `--to`; add `validate()` rejecting neither/both
- [x] update `session move`'s `makeRequest` to send `ControlArgs(workspace:)` or `ControlArgs(to:)`
- [x] add the `workspace move` subcommand (required `--to`, `--target` default `active`) and register it under the `workspace` command group
- [x] write host-free CLI parse tests in `CommandsTests.swift`: `session move --to up` (no workspace) builds a `to` request; `session move <ws>` still builds a workspace request; `session move` with neither and with both → `validate()` error; `workspace move --to top` builds a `.workspaceMove` request (the reorder-actually-happens e2e lives in Task 3's `ControlAPIUITests`)
- [x] confirm the existing `CommandsTests` `sessionMove`/`sessionMoveWithWindow` cases still pass (workspace-only stays valid)
- [x] run `cd HangarCore && swift test` — must pass before Task 5

### Task 5: Sidebar — session intra-workspace reorder + precise cross-workspace placement

**Files:**
- Modify: `Hangar/Views/WorkspaceSidebar.swift`
- Create: `HangarUITests/ReorderUITests.swift`

- [x] in `validateDrop`: stop rejecting same-workspace session drops; stop force-retargeting to `NSOutlineViewDropOnItemIndex`; compute the target workspace + insert index from `proposedItem`/`proposedChildIndex` (drop on a session row → redirect to its parent workspace at that child index; drop on a workspace row with `NSOutlineViewDropOnItemIndex` → append). Implemented as a shared `resolveSessionMove(...)` helper so `validateDrop` and `acceptDrop` agree exactly (target + index + no-op detection in one place); a drop ON a session row (`index == NSOutlineViewDropOnItemIndex`) inserts just AFTER it (`sessionIdx + 1`)
- [x] in `acceptDrop`: call `moveSession(id, toWorkspace: target, at: index)`, applying the downward same-parent `childIndex - 1` adjustment (only when `sourceWorkspace == target && sourceIndex < childIndex`) per Technical Details
- [x] confirm cross-workspace drag still works and now honors the drop position (precise placement, no longer always-append) — `SidebarUITests.testDragSessionToWorkspace` green
- [x] add `HangarUITests/ReorderUITests.swift` — drag a session above/below a sibling, assert the new order via the persisted `customName` order. SCOPE NOTE: split into TWO methods `testReorderSessionUp` (drag ccc up onto aaa → [aaa,ccc,bbb]) + `testReorderSessionDown` (drag bbb down onto ccc → [aaa,ccc,bbb], exercising the downward `childIndex - 1` adjustment), each a fresh launch with ONE real drag through the full `validateDrop`→`acceptDrop`→`moveSession` path. A second chained XCUITest drag in one method does not reliably re-start a drag session (tests XCTest's injector, not the reorder), so directions are split rather than chained. The `dragRow` helper selects the source row first (the outline only drags the SELECTED row), drags via `coordinate(withNormalizedOffset:)`, and uses mouse-native `click(forDuration:thenDragTo:withVelocity:thenHoldForDuration:)` — see the UI tests section in CLAUDE.md
- [x] confirm `SidebarUITests.testDragSessionToWorkspace` still passes — it is the cross-workspace regression guard for the `validateDrop` rewrite (a drop on a workspace row must still append)
- [x] run the focused UI tests (`-only-testing:HangarUITests/ReorderUITests/testReorderSessionUp`, `…/testReorderSessionDown`, and `-only-testing:HangarUITests/SidebarUITests/testDragSessionToWorkspace`) and `cd HangarCore && swift test`; app must build — all green (host-free 367/367; all three UI tests passed; app builds clean)

### Task 6: Sidebar — workspace reorder (second pasteboard type)

**Files:**
- Modify: `Hangar/Views/WorkspaceSidebar.swift`
- Modify: `HangarUITests/ReorderUITests.swift`

- [x] update `outline.registerForDraggedTypes` (WorkspaceSidebar.swift ~170) to `[sessionPasteboardType, workspacePasteboardType]` — LOAD-BEARING: without it AppKit never delivers validate/accept for workspace drags and the branch code is dead
- [x] add a `workspacePasteboardType = "ua.naiksoftware.hangar.workspace"` and make `pasteboardWriterForItem` emit it (carrying the workspace UUID) for workspace nodes
- [x] branch `validateDrop` on pasteboard type: session drag → Task 5 logic; workspace drag → valid only at top level (`proposedItem == nil`) between root rows, reject dropping a workspace onto a session or into a workspace's children. Implemented as a shared `resolveWorkspaceMove(...)` helper so `validateDrop` and `acceptDrop` agree exactly (target index + downward off-by-one + no-op detection in one place)
- [x] branch `acceptDrop`: workspace drag → `moveWorkspace(id, at: adjustedIndex)` with the same downward off-by-one adjustment (`sourceIndex < dropChildIndex` → `dropChildIndex - 1`)
- [x] add `testReorderWorkspace` to `ReorderUITests.swift`: drag a workspace above/below a sibling, assert the new `workspace-row` order. Drags "workspace 3" to the TOP edge of "workspace 1" (a top-level between-rows drop, `proposedItem == nil`), asserting [workspace 3, workspace 1, workspace 2] via the persisted `name` order
- [x] run the focused UI test (`-only-testing:HangarUITests/ReorderUITests`) and `cd HangarCore && swift test`; app must build — must pass before Task 7. Host-free 367/367 pass; the WHOLE ReorderUITests class ran in the foreground and all 3 methods passed (testReorderSessionUp, testReorderSessionDown, testReorderWorkspace) — `Executed 3 tests, with 0 failures`; app + UITest bundle build clean (TEST SUCCEEDED)

### Task 7: Verify acceptance criteria

- [x] session reorder within a workspace works via drag AND `hangarctl session move --to up|down|top|bottom` — drag verified by `ReorderUITests.testReorderSessionUp`/`testReorderSessionDown` (green); CLI/control by `ControlAPIUITests.testSessionMoveReorderWithinWorkspace` (positive e2e), `testSessionMoveInvalidDirectionErrors`, host-free `ReorderTests`/`AppStoreTests.reorderSession*`/`CommandsTests` (`session move --to`)
- [x] workspace reorder works via drag AND `hangarctl workspace move --to up|down|top|bottom` — drag verified by `ReorderUITests.testReorderWorkspace` (green); CLI/control by `ControlAPIUITests.testWorkspaceMoveReorder` (positive e2e), `testWorkspaceMoveRequiresTo`/`testWorkspaceMoveInvalidDirectionErrors`, host-free `AppStoreTests.reorderWorkspace*`/`moveWorkspace*`/`CommandsTests` (`workspace move --to`)
- [x] cross-workspace drag still works and now honors drop position; `session.move --workspace` unchanged (appends) — `SidebarUITests.testDragSessionToWorkspace` (regression guard, green) + `ControlAPIUITests.testSessionMoveToAnotherWorkspace` (relocate path) + `testSessionMoveBothToAndWorkspaceErrors`/`testSessionMoveRequiresWorkspace` (mode-bearing guards)
- [x] order persists across an app restart (snapshot/restore) for both sessions and workspaces — host-free `AppStoreTests` snapshot()→restore(from:) order-preservation test (the "persists across restart" guarantee)
- [x] run full host-free suite: `cd HangarCore && swift test` — 367 tests in 16 suites, all green
- [x] run the focused UI tests for the changed surfaces: `xcodebuild test -project Hangar.xcodeproj -scheme hangar -destination 'platform=macOS' -only-testing:HangarUITests/ReorderUITests -only-testing:HangarUITests/ControlAPIUITests -only-testing:HangarUITests/SidebarUITests/testDragSessionToWorkspace` — 52 tests, 0 failures (TEST SUCCEEDED). Two pre-existing reorder-UNRELATED ControlAPIUITests flaked on initial runs (`testCapturedIDResolvesWhileAnotherWindowFrontmost` — macOS key-window activation race; `testOverlayCloseReturnsFocusToSession` — async focus-return-after-overlay-teardown race); both FIXED test-side with the file's existing retry idiom (re-issue `window.select` while polling the active flag + `app.activate()`; keyboard-type-until-marker after overlay close) rather than dismissed. All reorder tests green throughout.

### Task 8: [Final] Documentation

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [x] CLAUDE.md Control API: bump the command count (31 → 32), add `workspace.move`, note `session.move` is now mode-bearing (`--to` reorder vs `--workspace` relocate), and record the four-point keep-in-sync audit for `workspace.move`
- [x] CLAUDE.md Sidebar section: note intra-workspace session reorder, workspace reorder, the second pasteboard type, and that drops now honor `proposedChildIndex`
- [x] README Features bullet: update the "Move a session between workspaces…" line to also mention reordering sessions within a workspace and reordering workspaces by drag
- [x] README "Scripting Hangar": add a reorder example (`hangarctl session move --to up`, `hangarctl workspace move --to top`)
- [x] move this plan to `docs/plans/completed/` (deferred to exec finalize — orchestrator moves the plan via move-plan.sh after the review/finalize phases)

## Post-Completion
*Items requiring manual intervention — no checkboxes, informational only*

**Manual verification:**
- Drag-reorder UX in the real app (XCUITest drag is finicky and may not fully exercise the drop-between-rows feel): drag a session up/down within a workspace, across workspaces to a precise slot, and reorder workspaces; confirm selection/expansion are preserved and the order persists after quit+relaunch.
- Confirm a workspace cannot be dropped into a workspace's children or onto a session (rejected, not a crash).
- Drag a workspace onto its own row → no-op (no crash, order unchanged).

Plan-review (auto, 2026-06-22): 3 critical + 2 important + 2 minor findings applied — Task 3 dispatch/error tests relocated to `ControlAPIUITests` (host-free keeps round-trips only), the broken `testSessionMoveRequiresWorkspace` string update added, Task 6 `registerForDraggedTypes` step added, CLI e2e folded into Task 3, `SidebarUITests` named as the cross-workspace guard, `Codable` dropped from `ReorderDirection`, workspace-onto-self no-op noted.

Smells pre-check: skipped — non-Go project
