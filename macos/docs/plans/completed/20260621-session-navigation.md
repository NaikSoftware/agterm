# Keyboard navigation between sessions

## Overview
- Add keyboard navigation BETWEEN sessions: step to previous/next session (⌥⌘↑ previous, ⌥⌘↓ next) and jump to the first/last session (menu + palette + control only, no hotkey). The bare-⌘ arrow cluster was rejected — it shadows text-field navigation — so previous/next use ⌥⌘ and first/last get no key.
- Distinct from the two existing session-switching affordances: the ⌃Tab MRU switcher (recency order) and the ⌃P fuzzy "Go to Session" palette (search). What's missing is *predictable spatial stepping* in the sidebar's visual order — this fills that gap.
- Exposed on all three surfaces per the project's HARD keep-in-sync rule: menu bar + action palette + control channel (`session.go`) / `agtermctl session go`.

## Context (from discovery)
- Selection + tree live in `agtermCore.AppStore` (host-free). `selectSession(_:)` (AppStore.swift:77) already pushes recency, clears the unseen badge, derives the workspace, and persists — navigation routes through it so all of that comes for free.
- The flattened tree order is `workspaces.flatMap(\.sessions)` (already the idiom used by the switcher's `begin()` and `paletteSessions()`).
- GUI seam is `AppActions` (app target, `@MainActor`); `focusActiveSession()` (AppActions.swift:298) moves first responder into the active session's focused pane after a selection change.
- Menu bar is `agtermApp.swift` `.commands`; the pane-focus items (⌘⌥←/→) sit in `CommandGroup(after: .toolbar)` (~lines 165-172) — the new session-nav items belong alongside them. Action palette entries come from `AppActions.paletteActions()` (~line 191).
- Control: `ControlProtocol.swift` holds the `Command` enum + `ControlArgs`; `ControlServer.swift` dispatches. `resolvePlacementStore(_ window:)` (ControlServer.swift:627) resolves the frontmost-or-`--window` store WITHOUT resolving a specific session — exactly what relative navigation needs (it acts on that store's current selection). `agtermctl` subcommands live in `agtermctlKit/Commands.swift`; `Session.Focus` is the closest template (sends `.sessionFocus` with `args.pane`, uses `ClientOptions` for `--window`).

## Development Approach
- **testing approach**: Regular (code first, then tests per task).
- complete each task fully before moving to the next.
- make small, focused changes; match existing file style.
- **CRITICAL: every task MUST include new/updated tests** for the code in that task.
- **CRITICAL: all tests must pass before starting next task** — `cd agtermCore && swift test` must stay green.
- keep `agtermCore` host-free (no AppKit / GhosttyKit / Metal imports).
- update this plan file's checkboxes as work completes.

## Testing Strategy
- **unit tests (agtermCore, fast ~0.2s)**: `navigateSession` (all four directions, wrap, edges), the `SessionNavigation(wire:)` mapping, the `.sessionGo`/`args.to` protocol round-trip, and the `agtermctl session go` request-building — all host-free, required every task that touches core/protocol/CLI.
- **XCUITest (slow, run FOCUSED only)**: one tty-oracle test in `agtermUITests` verifying focus follows selection when navigating. Per the project UI-test cadence convention, run ONLY the new test (`-only-testing:agtermUITests/SessionNavUITests`), never the full suite as a gate.

## Progress Tracking
- mark completed items with `[x]` immediately when done.
- add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix.
- keep plan in sync with actual work.

## Solution Overview
- One pure method in `AppStore` owns the logic; GUI and control both call it, so behavior can't drift between surfaces. The method routes through the existing `selectSession(_:)`, inheriting recency/badge/persistence/workspace-derivation.
- Keys are real menu items (not an `NSEvent` monitor like ⌃1/⌃2), so AppKit menu dispatch catches them before libghostty — ⌘ is never sent to the shell, so there's no terminal-shortcut conflict.
- Control uses ONE command with a direction arg (`session.go --to …`), mirroring the existing `session.focus --pane …` precedent, rather than four near-identical commands.

## Technical Details

### Core method (agtermCore/Sources/agtermCore/AppStore.swift)
```swift
public enum SessionNavigation: Sendable { case next, previous, first, last }

public func navigateSession(_ direction: SessionNavigation) {
    let ids = workspaces.flatMap(\.sessions).map(\.id)
    guard !ids.isEmpty else { return }                 // 0 sessions → no-op
    let target: UUID
    switch direction {
    case .first: target = ids.first!
    case .last:  target = ids.last!
    case .next, .previous:
        let n = ids.count
        if let current = selectedSessionID, let i = ids.firstIndex(of: current) {
            let step = direction == .next ? 1 : -1
            target = ids[(i + step + n) % n]           // wrap at both ends
        } else {
            target = ids.first!                        // no/invalid selection → first
        }
    }
    selectSession(target)                              // recency + badge + persist + workspace
}
```

### Wire mapping (agtermCore, alongside the enum)
```swift
extension SessionNavigation {
    init?(wire: String) {                              // CLI uses "prev"; the enum case is .previous
        switch wire {
        case "next": self = .next
        case "prev", "previous": self = .previous
        case "first": self = .first
        case "last": self = .last
        default: return nil
        }
    }
}
```

### Control protocol (agtermCore/Sources/agtermCore/ControlProtocol.swift)
- `Command`: add `case sessionGo = "session.go"`.
- `ControlArgs`: add `public var to: String?` and add `to` (defaulting nil) to the existing public `init` (ControlProtocol.swift:77).

### ControlServer arm (agterm/Control/ControlServer.swift)
```swift
case .sessionGo:
    guard let dir = (request.args?.to).flatMap(SessionNavigation.init(wire:)) else {
        return ControlResponse(ok: false, error: "session.go requires --to next|prev|first|last")
    }
    return resolvePlacementStore(request.args?.window) { store in
        store.navigateSession(dir)
        guard let id = store.selectedSessionID else {
            return ControlResponse(ok: false, error: "no session to navigate")
        }
        return ControlResponse(ok: true, result: ControlResult(id: id.uuidString))
    }
```

### agtermctl (agtermCore/Sources/agtermctlKit/Commands.swift)
- Add a `Go` subcommand to `Session.subcommands`, mirroring `Session.Focus` but with `ClientOptions` only (NO `TargetOptions` — navigation is relative to the current selection, so `--target` is meaningless; `--window` still applies):
```swift
struct Go: RequestCommand {
    static let configuration = CommandConfiguration(commandName: "go",
        abstract: "Navigate sessions: next|prev|first|last.")
    @Option(name: .long, help: "Direction: next, prev, first, or last.") var to: String
    @OptionGroup var options: ClientOptions
    func makeRequest() throws -> ControlRequest {
        ControlRequest(cmd: .sessionGo, args: options.withWindow(ControlArgs(to: to)))
    }
}
```

## What Goes Where
- **Implementation Steps** (`[ ]`): all code, tests, and doc updates below.
- **Post-Completion** (no checkboxes): manual sanity check of the four shortcuts in a running build, and the focused XCUITest run.

## Implementation Steps

### Task 1: Core navigation method in AppStore

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] add `public enum SessionNavigation { case next, previous, first, last }` to `AppStore.swift`
- [x] add `public func navigateSession(_ direction:)` per Technical Details (flatten tree, wrap next/prev, ends for first/last, no-selection→first, empty→no-op, route through `selectSession`)
- [x] write tests: `.next`/`.previous` step through a multi-workspace tree in flattened order (crossing workspace boundaries)
- [x] write tests: wrap — `.next` from the last selects the first; `.previous` from the first selects the last
- [x] write tests: `.first`/`.last` select the tree ends; no-selection→first; single-session is a stable no-op-ish; 0-session is a no-op (selection unchanged)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: GUI surfaces — AppActions, menu, palette, sidebar reveal

**Files:**
- Modify: `agterm/AppActions.swift`
- Modify: `agterm/agtermApp.swift`
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Create: `agtermUITests/SessionNavUITests.swift`

- [x] add `selectNextSession()/selectPreviousSession()/selectFirstSession()/selectLastSession()` to `AppActions`, each calling `store?.navigateSession(…)` then `focusActiveSession()`
- [x] add four `paletteActions()` entries: "Previous Session" ⌥⌘↑, "Next Session" ⌥⌘↓, "First Session" (no glyph), "Last Session" (no glyph) (keep the glyphs byte-consistent with the menu shortcuts below — `paletteActions()` carries a hand-sync comment)
- [x] add four menu Buttons in `agtermApp.swift` `.commands` (near the pane-focus items): Previous/Next with `.keyboardShortcut(.upArrow/.downArrow, modifiers: [.command, .option])`, First/Last with no shortcut
- [x] in `WorkspaceSidebar.syncSelection()` (WorkspaceSidebar.swift:394), expand the owning workspace if collapsed BEFORE the `row(forItem:)` lookup (which currently bails on `row < 0`), then `scrollRowToVisible` so an off-screen target row is brought into view
- [x] write `SessionNavUITests` tty-oracle test: two sessions, navigate between them via the shortcuts, type `tty > <file>` into the focused pane, assert which shell received the keystrokes (focus follows selection)
- [x] build the app; run ONLY `-only-testing:agtermUITests/SessionNavUITests` — must pass before next task

### Task 3: Control channel — protocol, server, agtermctl

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

- [x] add `Command.sessionGo = "session.go"`, `ControlArgs.to`, and `to` to the `ControlArgs` public init
- [x] add the `SessionNavigation(wire:)` mapping (Technical Details) alongside the enum in `agtermCore`
- [x] add the `.sessionGo` dispatch arm in `ControlServer` via `resolvePlacementStore` (unknown/missing `to` → structured error; returns the newly-selected id in `result.id`)
- [x] add the `Session.Go` agtermctl subcommand and register it in `Session.subcommands`
- [x] write protocol round-trip test (`ControlProtocolTests`): encode/decode a `.sessionGo` request with `args.to`
- [x] write wire-mapping test: `SessionNavigation(wire:)` for next/prev/previous/first/last + an unknown string → nil
- [x] write CLI request test (`CommandsTests`): `agtermctl session go --to next` (and `--to prev`, `--window …`) build the expected `ControlRequest`
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 4: Verify acceptance criteria
- [x] verify navigation works in a running build (prev/next wrap via ⌥⌘↑/⌥⌘↓; first/last jump via menu/palette; focus lands in the moved-to terminal) — verified via `SessionNavUITests.testSessionNavigationFollowsFocus` tty-oracle (asserts focus follows selection) + agtermCore `navigateNextWrapsFromLastToFirst`/`navigatePreviousWrapsFromFirstToLast`/`navigateFirstAndLastJumpToEnds` for wrap/first/last
- [x] verify cross-workspace stepping and the collapsed-workspace reveal — cross-workspace stepping covered by agtermCore `navigateNextStepsForwardCrossingWorkspaces`/`navigatePreviousStepsBackwardCrossingWorkspaces`; collapsed reveal wired in `WorkspaceSidebar.syncSelection` (`expandItem(owner)` + `scrollRowToVisible`), compile-checked (visual reveal is a manual GUI check, not headless-automatable)
- [x] verify `agtermctl session go --to next|prev|first|last` drives the frontmost window, and `--window <id>` targets a specific window — CLI request-building asserted by `CommandsTests.sessionGoNext`/`sessionGoPrev`/`sessionGoWithWindow`; protocol round-trip by `ControlProtocolTests.sessionGoRoundTripsWithDirection`; `ControlServer.sessionGo` arm (`resolvePlacementStore` + `navigateSession`) is compile-checked. Live socket round-trip is a manual GUI check — not automatable headless
- [x] run `cd agtermCore && swift test` (full host-free suite) green — 315 tests in 15 suites passed
- [x] run the focused `SessionNavUITests` green — 1 test passed (29.1s)

### Task 5: Documentation
- [x] README.md — add the four session-nav shortcuts to the keyboard-shortcuts section (if present)
- [x] CLAUDE.md — note the session-nav actions in "Menu bar and actions" (⌥⌘↑/⌥⌘↓ for previous/next, first/last menu+palette+control only, `navigateSession` ownership, focus-follows-selection, sidebar reveal); bump the Control API "Command catalog (29 commands)" → 30 and add `session.go` with its `--to` semantics
- [x] move to completed/ — deferred to exec completion step (move-plan.sh)

## Post-Completion
*Informational only — no checkboxes.*

**Manual verification:**
- Hold-and-repeat ⌥⌘↑/⌥⌘↓ to confirm wrap feels right and doesn't fight the sidebar scroll.
- Confirm ⌥⌘↑/⌥⌘↓ never leak a character into the shell on a single-session window (menu dispatch should swallow them).

Smells pre-check: skipped — non-Go project
