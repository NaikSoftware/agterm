# Phone terminal stream M3 (zmx viewer attach, `session.attach`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the M4 relay a safe, app-resolved way to watch a Live pane: an attach that never leads and whose first burst is only the visible screen, plus phone viewers in read-back and events.

**Architecture:** A zmx patch adds two `ManageFlags` bits: `screen_only` (skip the scrollback part of the re-attach snapshot) and `follow` (never become leader, even of an unowned daemon).
A new control command `session.attach` resolves a Live pane (local, attached from another Mac, elis-server row, or the server's own socket) to a viewer attach argv; the relay never builds argv from phone input.
The relay (`elisctl mobile serve`, the app's child) will print viewer lines in M4; the app parses them now, counts viewers per pane, emits `phone.attached` / `phone.detached`, and reports `phoneViewers` on the pane node.

**Tech Stack:** Zig 0.16 (zmx patch), Swift 6 (ElisCore, elisctlKit, ElisServerKit, app target), Swift Testing / XCTest.

**Spec:** `docs/superpowers/specs/2026-11-18-phone-terminal-stream-design.md` (sections "Attach model", "Control API coverage", "Milestones" M3).

## Global Constraints

- Swift paths are under `macos/`. Run Swift tests from `macos/ElisCore` (`swift test --filter <Suite>`); app-hosted tests with `-only-testing:`. Run the full gates once, in Task 9.
- Every change must build, pass `swift test`, `make test-app`, and `make lint` (strict, zero findings).
- Known failures on older master `e23d5491` (re-baseline on `92f299a3` before Task 9 trusts them): `SessionCloseCommandsTests.anAttachedForwardParsesOnItsOriginAsItsCommand`, `SkillInstallTests.bundledSkillDescriptionFitsTheSpecLimit`, `RemoteSessionTests.controlReachesTheCliWithEveryArgumentIntactUnderAnyLoginShell` (fish), `AppDelegateCaptureTests.testConfiguredNoneClearsCapturedAndPendingSlotsOnLastWindowClose`, `AppDelegateCaptureTests.testFreshLaunchChangedToRerunCapturesAtFirstExit`, `SurfaceFactorySeedTests.testAScratchOutsideRequestedLiveForgetsTheSavedOneAndRunsAPlainShell`, `SurfaceFactorySeedTests.testPrimaryFactoryDefersItsSeedAndResolvesOnlyTheLeftSlot`, `SurfaceFactorySeedTests.testSplitFactoryDefersItsSeedAndResolvesOnlyTheRightSlot`.
- A zmx patch must build for macOS and for `aarch64-linux-musl` / `x86_64-linux-musl` (`scripts/setup-zmx-linux.sh`).
- A patch change invalidates `.zmx-build-stamp`: in this worktree remove the zmx artifact and stamp symlinks and let `scripts/setup.sh --zmx-only` build locally.
- Resolution, parsing and response shaping go in `ElisCore` with host-free tests; the app target only looks up state and calls them (`CLAUDE.md`, module boundaries).
- `ElisCore` `public` symbols may have downstream callers (the Linux app): add, do not narrow.
- New identifiers avoid the product name (`PhoneLink`, `phoneViewers`, `screenOnly`).
- Never run `elisctl` against the default socket, never launch or quit the live app. Every delegated agent receives verbatim: "never execute `elis`/`elisctl` against the default socket, never launch or quit the app, static reading only" (hosted and server tests use their own isolated state).
- `macos/CHANGELOG.md` is release-only: do not edit.
- `session.attach` never claims in M3. `--claim` is M5 (Take over).
- The viewer attach carries no ssh ControlPath. `// shortcut: each phone attach opens its own ssh connection; lease a pool channel released on phone.detached if connection count matters.` The argv leaves the app and outlives any lease the app could release.

## Spec check: server zmx has the leadership patch

elis-server's zmx is built from the same patch set: `scripts/setup-zmx-linux.sh:38-41` runs `setup.sh --zmx-only` for each musl target, and `scripts/server-package.sh:19,29` package it. So 0001 (leadership) and the new 0007 ship to the server with the next server package.
Limit: a host still running an older package ignores `ZMX_MANAGED_*`. Its viewer attach then gets full scrollback and could lead an unowned daemon. M4 checks the server's version before it opens a vt channel; M3 documents the floor (Task 8).

## Review Focus

1. A phone attach to a daemon no Mac leads (elis-server row, headless origin, the Mac's reattach gap) must not take the lead or resize the pty. → Task 1 test `followClientNeverLeadsAnUnownedDaemon`.
2. A target that is not a Live pane (plain pty pane, page row, a closed pane) must answer `ok:false` with a clear error, never an argv that creates a daemon. → Task 4 `refusesAPaneThatIsNotLive`, Task 5 `refusesAMissingPane`.
3. `--pane split` must attach the split daemon, not the primary. → Task 4 `splitPaneAttachesTheSplitDaemon`.
4. The relay exits while viewers are counted: counts drop to zero and each remaining viewer gets `phone.detached`, or `phoneViewers` outlives the relay. → Task 7 `relayExitDetachesEveryViewer`.
5. A detach line for a pane with no counted viewer (duplicate, or after a reset) must not go negative or emit an event. → Task 7 `unmatchedDetachIsIgnored`.

---

### Task 1: zmx patch 0007 — viewer attach (screen-only, follow)

**Files:**
- Create: `macos/scripts/zmx-patches/0007-managed-viewer.patch`
- Modify: `macos/scripts/zmx-patches/README.md` (one bullet after `0006`)

Locations in the tree after 0001-0006 are applied to `ZMX_REV` 8bab1f0:
- `src/ipc.zig:90` `ManageFlags = packed struct(u8) { claim: bool = false, _pad: u7 = 0 }` → add `screen_only: bool = false`, `follow: bool = false`, `_pad: u5 = 0`.
- `src/role.zig` beside `claimFromEnv()`: `screenOnlyFromEnv()` reads `ZMX_MANAGED_SCREEN_ONLY`; `followFromEnv()` reads `ZMX_MANAGED_FOLLOW`.
- `src/loop.zig` attach client (the `relay != null` block that sends `.Manage`): set both bits from env.
- `src/daemonize.zig`: `unsetenv` both variables beside `ZMX_MANAGED_CLAIM`.
- `src/loop.zig:549` Client: `screen_only_on_init: bool = false`, `follow: bool = false`; `handleManage` (`:899`) stores them.
- `src/loop.zig:1070` `handleInit`: `if ((self.leader_client_fd == null and !client.follow) or client.claim_on_init)`. `claim` wins over `follow`. The other two `setLeader` paths (`:1007` input, `:1148` resize) already skip managed clients.
- `src/util.zig:790` `serializeTerminalState(alloc, term)` → `serializeTerminalState(alloc, term, scrollback: bool)`. When false, skip the Phase 1 content but still write `\x1b[2J\x1b[H\x1b[0m` before Phase 2, so the screen boundary is the same with or without scrollback. Every caller and existing test passes `true`.
- `src/loop.zig:1097` `handleInit` passes `!client.screen_only_on_init`.

- [ ] **Step 1: Set up the trees** as `scripts/zmx-patches/README.md` says (`zmx` and `zmx-ghostty` side by side, ghostty patches, then 0001-0006). Keep a pristine copy of that patched `zmx` tree for the diff.
- [ ] **Step 2: Write failing Zig tests.**
  - In `src/util.zig`, modelled on `test "serializeTerminalState with scrollback preserves visible content"` (`:1859`): `test "serializeTerminalState without scrollback sends only the visible screen"`. Feed one line `scrollback-marker`, then enough lines to push it off the visible screen, then `visible-marker`. Assert `full` contains `scrollback-marker`, `visible` does not, `visible` contains `visible-marker` and starts with `\x1b[2J\x1b[H\x1b[0m` after any colour overrides, and a fresh terminal fed `visible` has the same active rows and cursor as `term`.
  - In the 0001 test block (`testDaemon()`, `testManaged()`): `test "followClientNeverLeadsAnUnownedDaemon"` (unowned daemon, Manage with `follow`, then Init → `leader_client_fd == null`, no `.Resize` queued for that client); `test "claimWinsOverFollow"`; `test "manageStoresScreenOnly"`.
- [ ] **Step 3: Run** `zig build test` in `zmx`. Expected: compile error (no 3-argument `serializeTerminalState`, no `follow`).
- [ ] **Step 4: Implement** the changes listed above.
- [ ] **Step 5: Run** `zig build test`. Expected: PASS. Run `scripts/zmx-patches/check.py <built zmx>`. Expected: every rule passes.
- [ ] **Step 6: Regenerate** the patch as `diff -ruN` against the pristine 0001-0006 tree, `-p1`. README bullet: both variables, a client without them behaves as before, an older zmx ignores them.
- [ ] **Step 7: Build through the repo:** remove this worktree's zmx artifact and stamp symlinks, run `macos/scripts/setup.sh --zmx-only`, then `macos/scripts/setup-zmx-linux.sh`. Expected: both succeed.
- [ ] **Step 8: Commit** `feat(zmx): viewer attach that never leads and skips scrollback`.

### Task 2: Viewer attach argv

**Files:**
- Modify: `ElisCore/Sources/ElisCore/ZmxLead.swift` (`ZmxLeadAttachment`)
- Modify: `ElisCore/Sources/ElisCore/RemoteSession.swift:139` (`attachCommand`)
- Create: `ElisCore/Sources/ElisCore/PhoneAttach.swift`
- Test: `ElisCore/Tests/ElisCoreTests/PhoneAttachTests.swift`; the existing `ZmxLead` test file

**Interfaces:**
- Produces:
  - `ZmxLeadAttachment`: `screenOnlyVariable = "ZMX_MANAGED_SCREEN_ONLY"`, `followVariable = "ZMX_MANAGED_FOLLOW"`; `init(nonce:claim:screenOnly: Bool = false, follow: Bool = false)`; `environment` / `assignments` add `=1` for each set flag; `static var viewer: ZmxLeadAttachment` = `claim: false, screenOnly: true, follow: true` with a fresh nonce.
  - `RemoteSession.zmxAttachArguments(endpoint: ControlZmxEndpoint, daemon: String, lead: ZmxLeadAttachment?) throws -> [String]`: the `/usr/bin/env ZMX_SESSION= ZMX_SESSION_PREFIX= ZMX_NO_DETACH_KEY=1 ZMX_DIR=… <lead assignments> <zmx> attach <daemon> /bin/sh -c <gone guard>` list `attachCommand` builds inline today, with the same validation. `attachCommand` uses it; its output does not change.
  - `public enum LivePaneSource: Equatable, Sendable { case local(endpoint: ControlZmxEndpoint, daemon: String); case remote(host: String, endpoint: ControlZmxEndpoint, daemon: String) }`
  - `public struct ControlAttach: Codable, Sendable, Equatable { public let argv: [String]; public let paneID: String }` with `static func viewer(_ source: LivePaneSource, paneID: String) throws -> ControlAttach`: `.local` → `zmxAttachArguments(… lead: .viewer)`; `.remote` → `attachCommand(host:endpoint:daemon:lead: .viewer)` with no ControlPath. `paneID` is the token `tree` reports as `surfaces[].paneID`.

- [ ] **Step 1: Failing tests:** `viewerLeadSetsScreenOnlyAndFollowNotClaim`; `attachCommandOutputIsUnchanged` (copy one existing expected argv from the RemoteSession tests); `localViewerArgvRunsZmxDirectly` (first word `/usr/bin/env`, contains `attach`, daemon, both variables, no `ssh`); `remoteViewerArgvUsesSshWithoutControlPath`; `invalidDaemonIsRejected`.
- [ ] **Step 2: Run** `swift test --filter 'PhoneAttach|ZmxLead'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter. Expected: PASS. Also run `swift test --filter RemoteSessionTests` and expect only the known fish failure.
- [ ] **Step 5: Commit** `feat(phone-link): viewer attach argv`.

### Task 3: `session.attach` protocol, dispatcher, policy

**Files:**
- Modify: `ElisCore/Sources/ElisCore/ControlProtocol.swift:65` (`case sessionAttach = "session.attach"`), `ControlResult` (~`:752`, add `attach: ControlAttach?`)
- Create: `ElisCore/Sources/ElisCore/ControlDispatcher+Attach.swift` (model `ControlDispatcher+Grid.swift`)
- Modify: `ControlDispatcher.swift:40` (session-surface arm), `ControlActions.swift`, `ControlActionsDefaults.swift`, `PageSessionRefusal.swift:6`, `ElisServerKit/ServerCommandPolicy.swift:6-24` (`served`), `Elis/Control/ControlServer.swift:748` (fallback list); check `HtmlBridge.swift:48`
- Test: `ElisCoreTests/ControlDispatcherAttachTests.swift`, `ElisCoreTests/MockControlActions.swift`, `ControlProtocolTests.swift`, `ElisServerTests/ServerCommandPolicyTests.swift:6`

**Interfaces:**
- Produces: `ControlActions.sessionAttach(target: String?, pane: String?, paneID: String?, window: String?) async -> ControlResponse`. `--pane` takes the `session.grid` values (`validateGridPane`); default primary.
- `session.attach` stays out of `RemoteOperation.structuralCommands`, `localOnlyCommands` and the attached-forward set, so `remoteRoute` returns nil and the local action answers for every row kind.

- [ ] **Step 1: Failing tests:** `attachRoundTripsThroughTheProtocol`; dispatcher `passesTargetPaneAndWindow`, `rejectsAnUnknownPaneValue`; policy `aServedCommandPasses` includes `.sessionAttach`; page-row refusal includes `session.attach`.
- [ ] **Step 2: Run** `swift test --filter 'ControlDispatcherAttach|ControlProtocol|ServerCommandPolicy|PageSessionRefusal'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter. Expected: PASS.
- [ ] **Step 5: Commit** `feat(control): session.attach protocol`.

### Task 4: Mac app answers `session.attach`

**Files:**
- Create: `macos/Elis/Control/ControlServer+Attach.swift`
- Test: `macos/ElisTests/ControlServerAttachTests.swift` (model `ControlServerGridTests.swift`)

**Interfaces:**
- Consumes: Task 2 `LivePaneSource`, `ControlAttach.viewer`.
- The app only maps the resolved pane to a `LivePaneSource`:
  - Local pane with `Session.zmxBacking(for:)` true → `.local(endpoint: <the app's local zmx endpoint>, daemon: ZmxSupport.daemonName(for: identity))`.
  - Row attached from another Mac → `.remote(host: binding.origin.host, endpoint: binding.origin.endpoint, daemon: binding.daemon(forLocalPane: identity))` (same lookups as `Elis/Ghostty/PaneLead.swift:117-123`).
  - Row of an elis-server window → `.remote(host:, endpoint: catalogPane.endpoint, daemon: catalogPane.daemon)` (same lookup as `ControlServer+RemoteCatalog.swift:205`).
  - Anything else → `ok:false`, `"<target> is not a Live session"`.

- [ ] **Step 1: Failing hosted tests:** `localLivePaneReturnsAViewerAttach` (paneID equals the tree's); `splitPaneAttachesTheSplitDaemon`; `refusesAPaneThatIsNotLive`; `attachedRowUsesItsOrigin`; `serverWindowRowUsesItsCatalogPane`.
- [ ] **Step 2: Run** `scripts/test-app.sh -only-testing:ElisTests/ControlServerAttachTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `ControlServer.sessionAttach(...)`.
- [ ] **Step 4: Run** the same. Expected: PASS.
- [ ] **Step 5: Commit** `feat(control): session.attach on the Mac, local and remote rows`.

### Task 5: elis-server answers `session.attach`

**Files:**
- Create: `ElisCore/Sources/ElisServerKit/ServerActions+Attach.swift` (model `ServerActions+Sessions.swift:190` `readSessionText`)
- Test: `ElisCore/Tests/ElisServerTests/ServerAttachTests.swift`

**Interfaces:**
- Consumes: `withSession`, `daemonPane(of:token:pane:)`, `panes.daemonName(for:)` (`ServerPanes.swift:60`), `ZmxRunner`'s executable and socket dir → `ControlAttach.viewer(.local(...), paneID:)`.

- [ ] **Step 1: Failing tests:** `servedAttachNamesTheServersZmxAndDaemon`; `refusesAMissingPane`; end-to-end `viewerFirstBurstHasNoScrollback` with a real daemon (as `ServerLifecycleTests`): print `scrollback-marker`, then 200 filler lines, then `visible-marker`; detach the creating client; run the returned argv on a pty and read until idle. The output must not contain `scrollback-marker` and must contain `visible-marker`. Then `zmx` reports the session with no leader (the viewer did not take it).
- [ ] **Step 2: Run** `swift test --filter ServerAttach`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same. Expected: PASS (needs Task 1's zmx staged).
- [ ] **Step 5: Commit** `feat(server): serve session.attach`.

### Task 6: `elisctl session attach`

**Files:**
- Create: `ElisCore/Sources/elisctlKit/Session+Attach.swift`; register in `SessionCommands.swift`
- Test: `ElisCore/Tests/elisctlKitTests/SessionAttachCommandsTests.swift` (model `SessionGridCommandsTests.swift`)

**Interfaces:**
- `struct Attach: RequestCommand` with `--pane`, `TargetOptions`, `ClientOptions`. `run()` sends the request with `SocketClient`, decodes `result.attach.argv`, then `execvp`s it on the caller's stdio. With `--json` it prints the response and does not exec.

- [ ] **Step 1: Failing tests:** `makeRequestCarriesTargetAndPane`; `rejectsAnUnknownPane`; `aRefusalExitsNonzeroWithTheError`.
- [ ] **Step 2: Run** `swift test --filter SessionAttachCommands`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same. Expected: PASS.
- [ ] **Step 5: Commit** `feat(cli): elisctl session attach`.

### Task 7: Phone viewers — read-back and events

**Files:**
- Create: `ElisCore/Sources/ElisCore/PhoneViewers.swift`
- Modify: `ControlEvents.swift` (kinds), `PhoneDesktop.swift:82` (`PhoneRelayLine`), `ControlPhone.swift:41` (`controlEvent`, unchanged forms), `ControlProjection.swift` (`ControlSurfaceNode`), `AppStore.swift:404-413`, `elisctlKit/EventCommands.swift:83` (`EventFormatter.human`, phone arm `:116`), `Elis/Phone/PhoneRelay.swift:203-215`, `Elis/elisApp.swift:134`
- Test: `ElisCoreTests/PhoneViewersTests.swift`, `ElisCoreTests/PhoneDesktopTests.swift`, `ControlEventProtocolTests.swift`, `elisctlKitTests/EventCommandsTests.swift`

**Interfaces:**
- `ControlEventKind.phoneAttached = "phone.attached"`, `.phoneDetached = "phone.detached"`; payload uses the existing `ip` and `paneID`.
- Relay lines (serve prints them in M4): `phone attached from <ip> pane <paneID>` / `phone detached from <ip> pane <paneID>`. `PhoneRelayLine.stderr` returns a new `case viewer(attached: Bool, ip: String, paneID: String)` for them. They do not set `lastEvent` (a phone opening panes is not relay status).
- `public struct PhoneViewers: Equatable, Sendable { mutating func attach(paneID: String); mutating func detach(paneID: String) -> Bool /* false when none counted */; mutating func reset() -> [String] /* one paneID per remaining viewer */; func count(paneID: String) -> Int }`. `PhoneRelay` owns one instance (no global).
- `ControlSurfaceNode.phoneViewers: Int?`, omitted at zero. `AppStore` reads counts through `@ObservationIgnored public var phoneViewerCount: (String) -> Int = { _ in 0 }`, which the app sets from `PhoneRelay` where it creates stores. The server projection leaves it nil: the user approved this exception on 2026-11-18 (the relay runs only on a Mac; the Mac's tree counts server rows its phone watches). Task 8 records it in `control-api.md`.
- `PhoneRelay.onEvent` becomes `((ControlEventKind, ControlEventPayload) -> Void)?`. On `.viewer` it updates the count, and emits only when the count changed (`attach` always; `detach` when it returned true). On child exit it calls `reset()` and emits `phone.detached` with `paneID` and no `ip` for each returned pane.
- `EventFormatter.human`: `phone.attached <ip> <paneID>`, `phone.detached <ip> <paneID>` (`ip` omitted when nil).

- [ ] **Step 1: Failing tests:** `attachCountsPerPane`; `unmatchedDetachIsIgnored`; `relayExitDetachesEveryViewer` (reset returns one entry per remaining viewer, counts become 0); `relayLineParsesViewerEvents`; `viewerLinesAreNotStatusEvents` (`isEvent` false); `phoneViewersOmittedAtZero`; event round trip and `human` text for both kinds.
- [ ] **Step 2: Run** `swift test --filter 'PhoneViewers|PhoneDesktop|ControlEventProtocol|EventCommands'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same. Expected: PASS.
- [ ] **Step 5: Commit** `feat(phone-link): phone viewers read-back and events`.

### Task 8: Docs and skill

**Files:**
- Modify: `.claude/rules/control-api.md:23` (terminal-output streaming is in scope through `session.attach` for the phone relay); one short `session.attach` contract paragraph: viewer attach never leads and skips scrollback, answered locally for every row kind, no ControlPath, a zmx older than 0007 ignores the variables (full scrollback, may lead an unowned daemon).
- Modify: `plugins/elis/skills/elis/SKILL.md` (description trigger for attaching a script to a Live pane's terminal stream; events list ~`:313`), `plugins/elis/skills/elis/reference.md` (phone events `:76`, `session.attach`).
- Modify: `site/commands.html` (`session.attach` near `session.grid` ~`:2110`; events ~`:747`; `phoneViewers` field), `site/docs.html` (one paragraph where the phone app is described).

- [ ] **Step 1: Edit** the files. Each fact lives in one place; the others cross-reference it.
- [ ] **Step 2: Run** `make lint`. Expected: zero findings.
- [ ] **Step 3: Commit** `docs: session.attach and phone viewers`.

### Task 9: Gates

- [ ] Re-baseline the known failures on `92f299a3` if any differ from the list above.
- [ ] Run once: `cd macos && make test`, `make test-app`, `make lint`. Expected: green except the baselined failures.
