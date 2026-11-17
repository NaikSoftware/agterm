# Agent Status Indicator (per-session, control-driven)

## Overview

Add a per-session **agent status** indicator to agterm, driven entirely over the control channel
(`agtermctl`), plus an installable hooks package that wires coding agents to it. Inspired by
[`oleg-koval/kitty-agent-status`](https://github.com/oleg-koval/kitty-agent-status) but adapted to
agterm's CLI/icon model — no direct agent integration, just a thin control command + a sidebar icon.

A coding agent (Claude Code / a shell agent / Codex) running inside an agterm-spawned shell calls
`agtermctl session status <state>` to set its session's status. agterm renders a small SF Symbol on
that session's sidebar row, just left of the existing OSC-notification count badge. By default the
indicator is **stored and kept** (keep-state: hidden while you view the session, restored on
switch-away); a caller-set `--auto-reset` flag makes it **clear on visit** — the indicator resets to
idle for good once that session is selected. agterm hard-codes nothing per-status; the policy lives
entirely in the flag. The indicator is always shown ONLY on sessions you are not currently looking at
— the selected session of the frontmost window hides its icon; switching away re-reveals it (for a
kept indicator).

The agent-status glyph sits right next to the red OSC notification count badge (`notify-badge`); the
two are independently controlled. The **count badge** is toggleable via Settings (General → "Show
notification badges", `AppSettings.notificationBadgeEnabled`, default on; render-only — `unseenCount`
keeps tracking so re-enabling shows the current count), while the **agent-status glyph is always on**
— there is no toggle for it. Hiding the count badge does not affect the agent-status indicator.

States: `idle | active | completed | blocked` (idle = nothing). An optional `--blink` flag makes the
icon pulse for attention; an optional `--auto-reset` flag makes it clear on visit. The whole thing is
control-native (no GUI action to set status) and cross-window aware (the hook always targets its own
`$AGTERM_SESSION_ID`, which may live in a non-frontmost window).

## Context (from discovery)

- **Project:** agterm — native macOS SwiftUI terminal on libghostty. Two build systems: `agtermCore`
  SwiftPM package (`swift test`, host-free, strict concurrency) + the app target (`xcodegen` +
  `xcodebuild`). This is a **Swift project (no `go.mod`)** — Go-specific planning rules don't apply.
- **Near-exact template:** the `unseenCount` / `BadgeView` notification-badge path.
  - `Session.unseenCount: Int` — observed, ephemeral, NOT in `SessionSnapshot` (`Session.swift:39`).
  - `BadgeView` custom `NSView`, accessibility id `notify-badge`; `RowContent`, `reloadIfChanged`,
    `snapshotBadges`, and the `updateNSView` dependency read fold `unseenCount` in
    (`agterm/Views/WorkspaceSidebar.swift`).
  - e2e precedent: `ControlAPIUITests.testUnfocusedNotificationBadgesRowAndClearsOnSelect` sends raw
    JSON over the socket and asserts `notify-badge` appears, then clears on select.
- **Control seam:** `Command` enum + `ControlArgs` in `agtermCore/ControlProtocol.swift`; dispatch in
  `agterm/Control/ControlServer.swift` via `resolveSession(target, window:) { store, id in … }`
  (already cross-window through `resolveSessionTarget` → `resolveTargetAcrossWindows`); CLI subcommands
  in `agtermCore/Sources/agtermctlKit/Commands.swift` (`Session` has `Split`/`Focus`/`Copy` siblings to
  mirror).
- **Installer pattern:** `Help ▸ Install Command Line Tool…` = `agtermApp.swift` `CommandGroup(replacing:
  .help)` → `CLIInstaller.run()` (app-side FS glue) backed by host-free `CLIInstall.swift`
  (`CLIInstallTests.swift`). Resource bundling mirrors `Resources/ghostty` in `project.yml`.
- **Env already injected:** every tree surface's shell gets `AGTERM_SESSION_ID` + `AGTERM_SOCKET`
  (`agtermApp.surfaceEnv(for:)`), so a hook needs no discovery.

## Development Approach

- **testing approach:** Regular (implement, then write tests in the same task before completing).
  The host-free `agtermCore` model/protocol/installer-logic tasks naturally go test-first within this.
- complete each task fully before moving to the next; small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for its code changes — success AND error
  scenarios. Tests are a required deliverable, listed as separate checklist items.
- **CRITICAL: all tests must pass before starting the next task.**
- `cd agtermCore && swift test` after every agtermCore change (fast, ~0.2s). The app must build.
- maintain backward compatibility (the control protocol is additive; all new args are optional).

## Swift / project conventions (HARD — verify against every task)

- `agtermCore` MUST NOT import GhosttyKit, AppKit, or Metal (host-free is what lets `swift test` run
  with no app host). New model/protocol/installer-logic types live here; AppKit/Metal glue lives in the
  app target.
- Private (lowercase) by default; only make a symbol `public` when a caller in another module needs it
  (the CLI and the app both link `agtermCore`, so protocol types are `public`).
- **Keep-in-sync (HARD):** a new control command is not done until all four exist — (1) a `Command` case
  in `agtermCore`, (2) a `ControlServer` dispatch arm, (3) an `agtermctl` subcommand, (4) round-trip +
  e2e tests. `session.status` is control-NATIVE (no GUI/`AppActions`/menu equivalent, like
  `notify`/`session.type`/`session.copy`), so it needs no `AppActions` entry.
- Comments lowercase except godoc-style doc comments on exported symbols (start with the symbol name).
- One test file per source file (`Foo.swift` → `FooTests.swift`).

## Testing Strategy

- **unit tests (agtermCore, `swift test`, host-free):** enum parse, struct defaults/Equatable, the
  `AppStore` mutation, control protocol round-trip, the installer's pure JSON-merge / shell-rc-marker
  logic. Fast; run on every agtermCore task.
- **e2e tests (`agtermUITests`, XCUITest):** in `ControlAPIUITests` — speak raw JSON over the socket
  and assert the `agent-status` accessibility element appears on a non-selected row, hides on select,
  and reappears on switch-away (mirroring the `notify-badge` test).
- **manually verified (NOT automated):** the blink `CABasicAnimation` (XCUITest can't observe a layer
  animation) and the installer's real-file FS/JSON writes (tests must never mutate `~/.claude` or
  `~/.config`; the pure merge logic is unit-tested instead).
- **test cadence:** the XCUITest suite is slow (~75s/class). Run ONLY the affected target
  (`-only-testing:agtermUITests/ControlAPIUITests`); ASK before any full UI sweep.

## Progress Tracking

- mark completed items `[x]` immediately when done.
- add newly discovered tasks with ➕ prefix; blockers with ⚠️ prefix.
- update this plan if scope changes during implementation.

## Solution Overview

- **Model (agtermCore):** an `AgentStatus` enum + an `AgentIndicator` value struct; one ephemeral
  `Session.agentIndicator` field (parallel to `unseenCount`); a single `AppStore.setAgentIndicator`
  mutation point. No workspace roll-up, no priority/ranking logic — agterm only set/resets per-session
  glyphs and never reasons about ordering.
- **Behavior:** the indicator is kept by default — only an `autoReset` indicator clears on visit
  (`selectSession` resets it to idle when `agentIndicator.autoReset` is true, right after
  `clearUnseen`; a non-auto-reset indicator is left untouched). `autoReset` is a caller-set,
  status-agnostic flag (symmetrical with `blink`); agterm hard-codes no per-status policy. The icon's
  appear/disappear is otherwise purely **render-time gating** in the sidebar: hidden iff the session is
  the selected session of the frontmost window. `NSApp.isActive` is deliberately left OUT of the gate
  (it would flicker the selected row's icon on every app-switch for no benefit).
- **Control:** `session.status <state> [--blink] [--auto-reset]`, control-native, reusing
  `resolveSession` so it is cross-window by construction (required — the hook targets its own
  `$AGTERM_SESSION_ID`).
- **Hooks package:** full kitty-parity — Claude Code hooks + a generic bash/zsh shell integration + a
  Codex notify-chain — bundled in the app and wired by `Help ▸ Install Agent Status Hooks…`
  (idempotent `~/.claude/settings.json` merge with a `.bak` backup; shell-rc `source` line; Codex
  `config.toml` line printed, not auto-edited).

## Technical Details

```swift
// agtermCore/AgentStatus.swift
public enum AgentStatus: String, Codable, Sendable, CaseIterable {
    case idle, active, completed, blocked
}
public struct AgentIndicator: Equatable, Sendable {
    public var status: AgentStatus = .idle
    public var blink: Bool = false
    public var autoReset: Bool = false   // caller-set, clear-on-visit; symmetrical with blink
    public init(status: AgentStatus = .idle, blink: Bool = false, autoReset: Bool = false) { … }
}

// Session.swift  (observed, EPHEMERAL — NOT captured by SessionSnapshot)
public var agentIndicator = AgentIndicator()

// AppStore.swift  (single mutation point; unknown id = clean no-op)
// MUST be `public` — ControlServer (app target) calls it cross-module, like the
// `public` `selectSession`/`clearUnseen` siblings.
public func setAgentIndicator(_ indicator: AgentIndicator, forSession id: UUID)

// AppStore.selectSession  (after clearUnseen): reset an auto-reset indicator on visit
//   if session(withID:)?.agentIndicator.autoReset { session.agentIndicator = AgentIndicator() }
//   a non-auto-reset indicator is left untouched (keep-state).

// ControlProtocol.swift
case sessionStatus = "session.status"      // Command
public var status: String?                 // ControlArgs (+ extend init)
public var blink: Bool?                     // ControlArgs (+ extend init)
public var autoReset: Bool?                 // ControlArgs (+ extend init, appended)

// ControlServer.swift dispatch arm
case .sessionStatus:
    return resolveSession(request.target, window: request.args?.window) { store, id in
        // parse AgentStatus(rawValue:) -> error on unknown; build
        // AgentIndicator(status:, blink:, autoReset:); setAgentIndicator; return id
    }

// agtermctl: Session.Status (mirror Session.Split/Focus)
//   agtermctl session status <state> [--blink] [--auto-reset] [--target <id>]
//   only the Claude Stop->completed hook (and codex-notify completed) passes --auto-reset

// sidebar gate (render-time, app-side reconcile)
//   showIcon = indicator.status != .idle && !(isFrontmostWindow && session.id == store.selectedSessionID)
//   effective = showIcon ? session.agentIndicator : AgentIndicator()   // carried in RowContent (Equatable)
```

SF Symbol family (consistent filled-circle silhouette): `active` = `ellipsis.circle.fill` (blue),
`blocked` = `exclamationmark.circle.fill` (amber), `completed` = `checkmark.circle.fill` (green),
`idle` = none. Blink = `CABasicAnimation` on layer `opacity` (autoreverse, repeat), added only while
visible AND `blink == true`.

## What Goes Where

- **Implementation Steps** (`[ ]`): all agtermCore + app code, hooks scripts, the installer, unit/e2e
  tests, and doc updates — everything achievable in this repo.
- **Post-Completion** (no checkboxes): the manual installer FS verification, the manual blink visual
  check, and the user-side act of actually wiring agents and watching real status flow.

## Implementation Steps

### Task 1: AgentStatus + AgentIndicator value types

**Files:**
- Create: `agtermCore/Sources/agtermCore/AgentStatus.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AgentStatusTests.swift`

- [x] create `AgentStatus: String, Codable, Sendable, CaseIterable { idle, active, completed, blocked }`
- [x] create `AgentIndicator: Equatable, Sendable { status: AgentStatus = .idle; blink: Bool = false }` with a defaulted `init`
- [x] write tests: `AgentStatus(rawValue:)` for each valid case + an unknown string → `nil`
- [x] write tests: `AgentIndicator` defaults (`.idle`, `blink == false`) and `Equatable` (equal/!equal cases)
- [x] run `cd agtermCore && swift test` — must pass before next task

### Task 2: Session field + AppStore.setAgentIndicator (ephemeral)

**Files:**
- Modify: `agtermCore/Sources/agtermCore/Session.swift`
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/SessionTests.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/AppStoreTests.swift`

- [x] add `public var agentIndicator = AgentIndicator()` to `Session` with a doc comment noting it is observed + EPHEMERAL (parallel to `unseenCount`)
- [x] confirm `Snapshot.swift` / `SessionSnapshot` does NOT capture it (no change needed — verify and note); confirm `selectSession` does NOT touch it
- [x] add `public func setAgentIndicator(_ indicator: AgentIndicator, forSession id: UUID)` to `AppStore` (single mutation point; unknown id = no-op). MUST be `public` — `ControlServer` calls it cross-module, like the `public` `selectSession`/`clearUnseen`
- [x] write tests: `setAgentIndicator` sets the field on the right session; an unknown id is a clean no-op
- [x] write tests: a snapshot round-trip does NOT carry `agentIndicator` (stays `.idle` after restore); `selectSession` leaves it unchanged
- [x] run `swift test` — must pass before next task

### Task 3: Control protocol — session.status command + args

**Files:**
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`
- Modify: `agtermCore/Tests/agtermCoreTests/ControlProtocolTests.swift`

- [x] add `case sessionStatus = "session.status"` to `Command`
- [x] add `public var status: String?` + `public var blink: Bool?` to `ControlArgs`, extend the `init` (doc-comment each: `status` for `session.status` = idle|active|completed|blocked; `blink` toggles the pulse). NOTE: the existing 19-param `init`'s parameter order already diverges from field-declaration order — APPEND `status`/`blink` to the param list and assign in the body, matching the established append convention (don't reorder)
- [x] write tests: `ControlRequest(cmd: .sessionStatus, target:, args: ControlArgs(status: "active", blink: true))` round-trips through JSON encode/decode
- [x] write tests: decoding `{"cmd":"session.status","args":{"status":"blocked"}}` yields the right command/args; an unknown `status` string is left for the server to reject (parse `AgentStatus(rawValue:)` → nil)
- [x] run `swift test` — must pass before next task

### Task 4: agtermctl `session status` subcommand

**Files:**
- Modify: `agtermCore/Sources/agtermctlKit/Commands.swift`
- Modify: `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift` (request-building assertion — this is the test file for `Commands.swift`, NOT `ControlProtocolTests`; it `@testable import agtermctlKit` and has a `request(_ argv:)` helper that runs `Agtermctl.parseAsRoot` → `makeRequest()`)

- [x] add a `Status: RequestCommand` struct under `Session.subcommands` (mirror `Split`/`Focus`): `@Argument var state: String` (help: idle|active|completed|blocked), `@Flag(name: .long) var blink = false`, `@OptionGroup var target: TargetOptions`, `@OptionGroup var options: ClientOptions`
- [x] build `ControlRequest(cmd: .sessionStatus, target: target.target, args: ControlArgs(status: state, blink: blink ? true : nil))`; `echoesResultID` stays default `false` (prints `ok`)
- [x] register `Status.self` in `Session`'s `subcommands`
- [x] write tests in `CommandsTests.swift` via the existing idiom: `request(["session","status","active","--blink"])` → assert `cmd == .sessionStatus`, `args.status == "active"`, `args.blink == true`; and a no-`--blink` case (`blink` nil/false)
- [x] run `swift test` — must pass before next task

### Task 5: ControlServer dispatch arm + cross-window resolution + control e2e

**Files:**
- Modify: `agterm/Control/ControlServer.swift`
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add a `case .sessionStatus:` arm using `resolveSession(request.target, window: request.args?.window) { store, id in … }` (cross-window for free)
- [x] parse `AgentStatus(rawValue: request.args?.status ?? "")` → on nil return a structured error (`invalid status`); build `AgentIndicator(status:, blink: request.args?.blink ?? false)`; call `store.setAgentIndicator(_, forSession: id)`; return `id` in `result.id`
- [x] write e2e: `session.status` with `target` set returns `ok` + the resolved `id`; an unknown `status` returns the LITERAL error string the arm emits (pin it, e.g. `invalid status`, the way the suite pins `"no such session"`/`"no selection"`); an unknown `target` returns not-found (mirror `testUnknownTargetErrors`)
- [x] run only `-only-testing:agtermUITests/ControlAPIUITests` (ASK before any full UI sweep) — must pass before next task

### Task 6a: StatusIconView + layout + blink (AppKit drawing)

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`

- [x] add `StatusIconView: NSView` (sibling of `BadgeView`) with an `apply(_ indicator: AgentIndicator)` method: render the state's tinted SF Symbol (active=`ellipsis.circle.fill`/blue, blocked=`exclamationmark.circle.fill`/amber, completed=`checkmark.circle.fill`/green) and hide on `.idle`; accessibility id `agent-status`, value = the state name, role `.staticText` (so XCUITest matches `app.staticTexts["agent-status"]`); position it just LEFT of the count badge in the cell
- [x] add blink: a `CABasicAnimation` on layer `opacity` (autoreverse, repeat) added when the icon is visible AND `indicator.blink`, removed otherwise (no per-frame timer)
- [x] feed the cell's `StatusIconView` from the row session's `agentIndicator` UNGATED for now (the visibility gate lands in 6b — at this stage nothing shows until a status is set)
- [x] tests: the AppKit drawing + blink are MANUALLY verified (manual - not automatable; verified app compiles; e2e in 6b). XCUITest can't observe a `CABasicAnimation`; the automated e2e is Task 6b
- [x] build the app — must compile before 6b

### Task 6b: visibility gate + RowContent reconcile + isFrontmostWindow + icon e2e

**Files:**
- Modify: `agterm/Views/WorkspaceSidebar.swift`
- Modify: `agterm/ContentView.swift` (the representable's call site is here, `WorkspaceSidebar(store:, actions:)` at ~line 260; NOT under `agterm/Views/`)
- Modify: `agtermUITests/ControlAPIUITests.swift`

- [x] add `isFrontmostWindow: Bool` as a stored property on the `WorkspaceSidebar` representable; pass it at the call site `WorkspaceSidebar(store:, actions:, isFrontmostWindow:)` from `WindowContentView`, computed from `library` (e.g. `library.frontmostWindowID == windowID`). Do NOT inject `library` into the representable — `WindowContentView` (where `library` is `@Observable`) recomputes the Bool and re-renders, which re-runs `updateNSView` (the representable currently holds only `store` + `actions`, so it has no `library` to read)
- [x] compute the gated indicator in reconcile: `effective = (isFrontmostWindow && session.id == store.selectedSessionID) ? AgentIndicator() : session.agentIndicator`; switch 6a's `StatusIconView` to render `effective`
- [x] carry `effective` in `RowContent` (extend the struct, keep `Equatable`) so a status/blink change reloads only that row via the existing `reloadIfChanged` path
- [x] fold `session.agentIndicator` and selection into the `updateNSView` dependency read so a status or selection change re-reconciles; the frontmost flip re-runs `updateNSView` automatically because the parent passes a fresh `isFrontmostWindow` Bool (no `library` read inside the representable) — no state mutation
- [x] write e2e: send `session.status active` to a NON-selected seeded session → `agent-status` appears on its row; `session.select` it → `agent-status` hides (`waitForNonExistence`); select another session → it reappears (mirror `testUnfocusedNotificationBadgesRowAndClearsOnSelect`)
- [x] run only `-only-testing:agtermUITests/ControlAPIUITests` (ASK before full sweep) — must pass before next task

### Task 7: Hooks package scripts + resource bundling

**Files:**
- Create: `agterm/Resources/agent-status/agterm-agent-status.sh`
- Create: `agterm/Resources/agent-status/shell/integration.sh`
- Create: `agterm/Resources/agent-status/codex-notify.sh`
- Modify: `project.yml` (bundle `agterm/Resources/agent-status` as a Contents/Resources folder, mirroring the `Resources/ghostty` entry)

- [x] `agterm-agent-status.sh <state> [--blink]`: guard `[ -n "$AGTERM_SESSION_ID" ] || exit 0`, then `exec ${AGTERMCTL:-agtermctl} --socket "$AGTERM_SOCKET" session status "$1" --target "$AGTERM_SESSION_ID" "${@:2}"` (no-op outside agterm). RESOLUTION ORDER for the binary, documented once here: (1) an `AGTERMCTL` env var if the caller set one, (2) the absolute bundled-binary path the installer bakes in (see Task 9), (3) `agtermctl` on `PATH`. The installer guarantees (2) so the hook fires even when the CLI tool was never symlinked into `PATH`
- [x] `shell/integration.sh`: bash/zsh `preexec`/`precmd` — `active` while a command matching `AGTERM_AGENT_RE` runs (Claude excluded; its hooks are precise), `idle` at the next prompt; all calls best-effort/no-op outside agterm
- [x] `codex-notify.sh`: set `completed`/`blocked` per turn, then forward an existing notify program via `AGTERM_NOTIFY_FORWARD` if set
- [x] add the `agent-status` resource folder to `project.yml`, `xcodegen generate`, confirm it lands in `agterm.app/Contents/Resources/agent-status`
- [x] tests: this task ships shell scripts + a build-config change (no Swift logic); verification is a build + a manual `bash agterm-agent-status.sh active` no-op-outside-agterm check (note in checklist), so no unit test — covered by Task 9's manual install verification. Verified: `env -u AGTERM_SESSION_ID bash agterm-agent-status.sh active` exits 0 without invoking agtermctl; all three scripts pass `bash -n`/`zsh -n`; `xcodebuild` BUILD SUCCEEDED; the folder bundled at `agterm.app/Contents/Resources/agent-status/` (incl. `shell/integration.sh`) with exec bits preserved

### Task 8: Installer host-free logic (JSON merge + shell-rc marker)

**Files:**
- Create: `agtermCore/Sources/agtermCore/AgentHooksInstall.swift`
- Create: `agtermCore/Tests/agtermCoreTests/AgentHooksInstallTests.swift`

- [x] add `AgentHooksInstall` (namespace of pure static funcs, mirroring `CLIInstall`): merge the three Claude Code hooks (`UserPromptSubmit`→active, `Stop`→completed, `Notification` matcher `permission_prompt`→blocked) into an existing `settings.json` string → `(json: String, changed: Bool)`; skip when already present (idempotent)
- [x] add the shell-rc helper: given an rc file's contents + the script dir, append a marker-guarded `source …/integration.sh` line → `(contents: String, changed: Bool)`; skip when the marker is already present
- [x] add backup-path derivation (`settings.json` → `settings.json.bak`) as a pure helper
- [x] write tests: merge-when-absent adds all three hooks; merge-when-present is a no-op (`changed == false`); a hooks block with OTHER unrelated hooks is preserved; malformed/empty existing JSON is handled (start fresh, don't crash)
- [x] write tests: shell-rc append adds the line once; second call is a no-op; backup-path derivation
- [x] run `swift test` — must pass before next task

### Task 9: Installer app-side (Help menu + FS/JSON glue)

**Files:**
- Create: `agterm/AgentHooksInstaller.swift`
- Modify: `agterm/agtermApp.swift` (add the Help menu button)

- [x] add `AgentHooksInstaller.run()` (app-side, mirroring `CLIInstaller`): copy bundled `agent-status/` from `Bundle.main` to `~/.config/agterm/agent-status/`
- [x] make the `AGTERMCTL` resolution CONCRETE: resolve the bundled binary via `Bundle.main.url(forAuxiliaryExecutable: "agtermctl")` (the same path `CLIInstaller` uses, `agterm.app/Contents/MacOS/agtermctl`) and bake its ABSOLUTE path into the installed wrapper at `~/.config/agterm/agent-status/` (write an `AGTERMCTL="…"` default into the copied script, or a sourced `config` file it reads). Because install is idempotent + re-runnable, this path is REFRESHED on every run, so a moved/reinstalled app bundle is healed by re-running the installer
- [x] wire the shell-rc append (zsh + bash) via `AgentHooksInstall`, and the `settings.json` merge writing a `.bak` first (only when `changed`); print the Codex `~/.codex/config.toml` line for the user (do NOT auto-edit TOML)
- [x] add `Button("Install Agent Status Hooks…") { AgentHooksInstaller.run() }` to the `CommandGroup(replacing: .help)` in `agtermApp.swift`, next to "Install Command Line Tool…"
- [x] surface success/failure to the user (alert, like `CLIInstaller`); idempotent + re-runnable
- [x] tests: app-side FS/JSON/auth glue is MANUALLY verified (manual - FS/auth glue verified by compile; pure logic unit-tested in Task 8; end-to-end install in Post-Completion) — the pure logic is already unit-tested in Task 8. Note the manual steps in Post-Completion.

### Task 10: Verify acceptance criteria

- [x] verify the Overview behaviors: set each state via socket → correct glyph/tint on a non-selected row; `--blink` pulses; `idle` clears; focus hides, switch-away re-reveals; a background window's selected session still shows its icon (manually verified live with the user; the show-on-unselected-row + hide-on-select + reappear-on-switch-away path is also automated in `ControlAPIUITests.testAgentStatusIconShowsOnUnselectedRowAndHidesOnSelect`)
- [x] verify cross-window: `session.status active --target <id-in-other-window>` lands on the right window's row (manually verified live with the user; `resolveSession` cross-window resolution is also covered by `ControlAPIUITests.testCapturedIDResolvesWhileAnotherWindowFrontmost`)
- [x] run full host-free suite: `cd agtermCore && swift test` (418 tests in 19 suites, all passed)
- [x] run the affected UI target: `-only-testing:agtermUITests/ControlAPIUITests` (ran ControlAPIUITests + SidebarUITests + ReorderUITests at the user's direction — 63 tests, 0 failures, TEST SUCCEEDED; no sidebar/reorder regression from the `StatusIconView` cell addition)
- [x] confirm the keep-in-sync four points are all present for `session.status`: (1) `Command.sessionStatus = "session.status"` in `ControlProtocol.swift`; (2) the `.sessionStatus` dispatch arm in `ControlServer.swift` (via `setSessionStatus`, parsing `status`/`blink`/`autoReset`); (3) the `Session.Status` subcommand in `agtermctlKit/Commands.swift` with `--blink`/`--auto-reset`; (4) round-trip tests in `ControlProtocolTests` + `CommandsTests` and e2e in `ControlAPIUITests`

### Task 11: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `CLAUDE.md`
- Modify: `docs/known-issues.md` (only if a libghostty/AppKit quirk surfaces)

- [x] README.md: document the feature, the `agtermctl session status` command, and the `Help ▸ Install Agent Status Hooks…` flow + manual Codex `config.toml` step
- [x] CLAUDE.md: add `session.status` to the Control API command catalog, bump the catalog count (32 → 33), and add notes for the visibility gate / `StatusIconView` rendering and the hooks/installer surface
- [x] update this plan's checkboxes; then move it to `docs/plans/completed/` (performed by the exec finalize step)

## Post-Completion

*Items requiring manual intervention or external systems — informational only.*

**Manual verification:**
- the blink `CABasicAnimation` (XCUITest can't observe a layer animation) — eyeball that a `--blink`
  status pulses on a non-selected row and stops when you focus it.
- the installer's real-file writes: run `Help ▸ Install Agent Status Hooks…` on a real machine, confirm
  scripts land in `~/.config/agterm/agent-status/`, the `source` line is appended once to `~/.zshrc`
  (and `~/.bashrc`), `~/.claude/settings.json` gains the three hooks with a `.bak` written, re-running
  is a clean no-op, and the printed Codex `config.toml` line is correct.
- end-to-end with a real agent: run Claude Code in a background session and watch `active`/`completed`/
  `blocked` flow to the sidebar icon; run an interactive Codex session to confirm the notify-chain.

**External system updates:**
- the user must add the printed `notify = ["…/codex-notify.sh"]` line to `~/.codex/config.toml`
  themselves (the installer prints it; it is not auto-edited).

---
Smells pre-check: skipped — non-Go project.
