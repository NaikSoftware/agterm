# Phone relay mux (M4a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a phone sends `{"mux":1}`, the Mac relay speaks PhoneLink frames: control requests, pushed events, and one live terminal stream per open pane, bounded, resynced on overflow and safe against a slow phone.

**Architecture:** `PhoneSession` keeps auth, revoke, ordering and grid bookkeeping, and hands the byte stream to a new `PhoneLinkSession` on the upgrade. Channel 0 goes through `PhoneSession`'s existing serial `forward`. A vt channel asks the app for `session.attach`, runs the returned argv on a pty, filters zmx role titles, queues bytes in the M2 scheduler (bounded) and sends them by credit; overflow restarts the viewer attach (at most once a second) and sends RESYNC. The grid comes from a `zmx screen` argv the app returns beside the attach argv.

**Tech Stack:** Swift 6 (ElisCore, elisctlKit, app target), Swift Testing, XCTest (hosted), Darwin pty APIs.

**Spec:** `docs/superpowers/specs/2026-11-18-phone-terminal-stream-design.md` ("Protocol model", "Attach model", "Notes for the M4 relay", "Session view"). The phone's Term view is a separate plan (M4b). Order: M4a → M4b → M6 (Text and the switcher) → M7 (Chat): the phone cannot draw anything until the relay streams it.

## Global Constraints

- Paths are under `macos/`. Run tests from `macos/ElisCore` (`swift test --filter <Suite>`); swiftlint from `macos/` (`swiftlint lint --strict <files>`). Hosted tests: `./scripts/setup.sh && xcodegen generate && xcodebuild test -project Elis.xcodeproj -scheme ElisTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:ElisTests/<Class>` (`test-app.sh` ignores arguments). Gates once at the end.
- Every new `elisctlKit` source and test file is wrapped in `#if os(macOS)`, as `PhoneSession.swift` is: the pty APIs do not exist in Swift's Glibc module (the PR #43 break). Pure value types go in `ElisCore/PhoneLink/` and stay Linux-safe. The Linux CI job must be green before merge.
- Frame: `u8 kind | u32 channel | u32 len | payload`, big endian, `len` <= 64 KiB (M2 `PhoneLinkFrame`).
- Channels: 0 = control (`{id,cmd,target,args}` lines, answers matched by `id`), 1 = events, n >= 2 = one per open vt pane. Channels 0 and 1 carry newline-separated JSON; a line may span frames.
- vt credit window: 16 KiB on Bluetooth, 256 KiB on TLS. Relay buffer per vt channel: 512 KiB (scheduler `bufferLimit`). Send chunk: 16 KiB.
- The relay never builds argv or a host from phone input: every argv comes from the app's `session.attach` answer.
- A phone's own `session.attach` and `phone.*` requests are refused on channel 0 and on the line protocol.
- A pty master is read on every poll; blocking reads run on a plain `Thread`, never in a `Task` (`.claude/rules/tests.md`). Timers and deadlines take an injected clock.
- Delegated agents receive verbatim: "never execute `elis`/`elisctl` against the default socket, never launch or quit the app, static reading only." Tests use stub sockets and fake attach programs.
- Stage by explicit path; `.superpowers/` is not ignored.

## Decisions taken in this plan (rulings beyond the spec)

Superseded during execution: old-daemon, resync and watchdog rules — see the spec's M4 notes and control-api.md.

- **Grid source:** `ControlAttach` gains `screen: [String]` (an argv for `zmx screen <daemon>` with the attach's env and ssh) and `remote: Bool`. The relay runs `screen` on OPEN, after each RESYNC, and on a poll: every 2 s for local panes, every 10 s for remote ones (each remote poll is a fresh ssh connection, M3's no-ControlPath shortcut). One poll in flight per channel, 5 s timeout. Parsed with `ZmxScreen(output:)`.
- **Keepalive:** the remote viewer and screen argvs use the existing `keepAliveCheck` wrapper (`RemoteSession.swift:90` pattern), so a dead link ends ssh.
- **Control channel:** channel-0 requests go through `PhoneSession.forward` (serial per phone, as today), so typed input keeps its order and Fit-to-phone grids are still released on disconnect. Answers carry the phone's `id`.
- **Old daemons:** a local pane whose daemon started before this launch's zmx build (`zmxOutdatedBefore`) answers `session.attach` with `ok:false`, `"session predates this version; restart it to watch it on the phone"`. For remote rows the relay cannot see the daemon's age: if a viewer attach overflows within 2 s of starting twice in a row, the channel closes with `CLOSE {"reason":"session too old for the phone view"}` instead of looping.
- **Resync:** overflow terminates the attach. A fresh viewer attach starts at most once per second; the channel stays quiet until then. A resync prints no viewer lines. A failed re-attach sends `CLOSE {"reason":<the app's error>}` and one detach line.
- **Credit across RESYNC:** both sides reset the channel's credit to the full window at RESYNC (`scheduler.open(channel:)` does this already); M4b's phone does the same. Task 7 writes this into the spec.
- **Watchdog:** no CREDIT from the phone for 30 s while the channel has bytes waiting (queued, or a resync pending) closes it with `CLOSE {"reason":"stalled"}`.
- **Take over:** `OPEN` with `claim: true` answers `OPENED {"error":"take over is not available yet"}` (M5).
- **Open channel cap:** 8 vt channels per phone; more answer `OPENED {"error":"too many open panes"}`.
- **Unrealized panes:** a pane the Mac has not shown since launch answers `session not realized` (M3), and the relay passes it as `OPENED {"error":…}`. Watching a never-shown pane is out of scope for M4.
- **Events:** the poller keeps its own line queue, bounded at 256 KiB, and hands lines to the scheduler only while channel 1 has less than 64 KiB pending there (`PhoneLinkScheduler.pendingBytes(channel:)`, added in Task 4). Past the bound it drops the oldest lines and queues one `{"dropped":N}` line.

## Review Focus

1. The phone disconnects with panes open: every attach and every screen poll stops; one `phone detached` line per open channel before `phone disconnected`. → Task 5 `disconnectEndsEveryAttach`.
2. A phone that never sends CREDIT while the program floods: memory stays bounded, re-attaches happen at most once a second, the channel closes `stalled` after 30 s. → Task 6 `floodResyncsAtMostOncePerSecond`, `noCreditCloses`.
3. Late bytes from a replaced attach after RESYNC. → Task 6 `noOldBytesAfterResync`.
4. A malformed frame, an unknown kind or a len over 64 KiB: the link closes cleanly, attaches stop. → Task 3 `badFrameClosesTheLink`.
5. An old daemon that sends full scrollback: no resync loop. → Task 1b `outdatedLocalDaemonIsRefused`, Task 6 `repeatedEarlyOverflowCloses`.

---

### Task 1: Attach answer carries screen argv and remote flag; keepalive; role-title filter

**Files:**
- Modify: `ElisCore/Sources/ElisCore/PhoneAttach.swift`, `ElisCore/Sources/ElisCore/RemoteSession.swift`
- Create: `ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkTitleFilter.swift`
- Test: `ElisCore/Tests/ElisCoreTests/PhoneAttachTests.swift`, `ElisCore/Tests/ElisCoreTests/PhoneLinkTitleFilterTests.swift`, hosted `ElisTests/ControlServerAttachTests.swift` (its remote-argv assertions follow the new shape), `ElisCore/Tests/ElisServerTests/ServerAttachTests.swift` (screen field present)

**Interfaces:**
- Produces:
  - `ControlAttach { argv: [String]; paneID: String; screen: [String]; remote: Bool }` (Codable; `screen` decodes as `[]` and `remote` as `false` when absent).
  - `RemoteSession.zmxScreenArguments(endpoint:daemon:) throws -> [String]` (local: `/usr/bin/env ZMX_DIR=… <zmx> screen <daemon>`, same validation as `zmxAttachArguments`); the remote form goes through ssh with the `keepAliveCheck` wrapper.
  - `ControlAttach.viewer(_:paneID:)` fills all four; for `.remote` both argvs use the keepalive wrapper.
  - `struct PhoneLinkTitleFilter { mutating func filter(_ bytes: Data) -> Data }`: drops every `ESC ] 2 ; zmx-role;… (BEL | ESC \)`, also split across calls; other bytes pass unchanged and in order; it never holds more than 512 bytes.

- [ ] **Step 1: Failing tests:** `screenArgvForLocalPane` (contains `screen` and the daemon, no `ssh`, `remote == false`); `remoteViewerUsesKeepAlive` (`/bin/sh -c`, `ServerAliveInterval=5`, `remote == true`); `attachCommandOutputIsUnchanged` keeps `attachCommand` itself unchanged and pins the new viewer literal; `oldAnswerDecodesWithDefaults`. Filter: `dropsARoleTitle`, `dropsATitleSplitAcrossChunks` (split at every byte), `keepsOtherTitles`, `capsPendingBytes`.
- [ ] **Step 2: Run** `swift test --filter 'PhoneAttach|PhoneLinkTitleFilter|ServerAttach'`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same, then the hosted `ControlServerAttachTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(phone-link): screen argv, keepalive viewer, role-title filter`.

### Task 1b: Refuse an attach to an outdated local daemon

**Files:**
- Modify: `Elis/Control/ControlServer+Attach.swift` (and wherever the app keeps `zmxOutdatedBefore`, see `Elis/elisApp.swift:131,406`, `ElisCore/Sources/ElisCore/ZmxBuildRecord.swift`)
- Test: hosted `ElisTests/ControlServerAttachTests.swift`

**Interfaces:** the local branch refuses when the pane's daemon started before the cutoff, with the exact error from "Decisions". Remote rows are unchanged (the relay handles them, Task 6).

- [ ] **Step 1: Failing hosted test** `outdatedLocalDaemonIsRefused` (pane with a daemon start before the cutoff → `ok:false`, the exact text); `currentLocalDaemonIsServed`.
- [ ] **Step 2–4:** hosted run of `ControlServerAttachTests`: FAIL, implement (reuse how the app already decides a daemon is outdated), PASS.
- [ ] **Step 5: Commit** `feat(control): session.attach refuses an outdated daemon`.

### Task 2: Pty runner

**Files:**
- Create: `ElisCore/Sources/elisctlKit/PhoneLinkPty.swift`
- Test: `ElisCore/Tests/elisctlKitTests/PhoneLinkPtyTests.swift`

**Interfaces:**
- Produces: `final class PhoneLinkPty: @unchecked Sendable { static func spawn(_ argv: [String], cols: UInt16, rows: UInt16, onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws -> PhoneLinkPty; func terminate() }`. Pty via `posix_openpt`/`grantpt`/`unlockpt`/`ptsname`; child in its own process group with the slave as stdin/stdout/stderr and `TERM=xterm-256color`; the master read on a dedicated `Thread` until EOF; then the child is reaped and `onExit` fires once. `terminate()` stops output delivery, sends SIGTERM to the process group, SIGKILL after 2 s, and closes the master.

- [ ] **Step 1: Failing tests:** `deliversOutput`; `reportsExitStatus`; `terminateEndsAChildThatIgnoresTerm`; `terminateEndsAPipelineThatHoldsTheSlave` (`printf hi; cat` ends, reader thread ends); `badExecutableThrows`; `noOutputAfterTerminate`.
- [ ] **Step 2–4:** `swift test --filter PhoneLinkPty`: FAIL, implement, PASS.
- [ ] **Step 5: Commit** `feat(phone-link): pty runner for the relay`.

### Task 3: Upgrade and the control channel

**Files:**
- Create: `ElisCore/Sources/elisctlKit/PhoneLinkSession.swift`
- Modify: `ElisCore/Sources/elisctlKit/PhoneSession.swift` (upgrade hook after auth, before `forward`; refuse `session.attach` in `forward`)
- Test: `ElisCore/Tests/elisctlKitTests/PhoneLinkSessionTests.swift` (reuse `MemoryPhone`, `RawStubServer`, `MobileFixture` from `MobileCommandsTests.swift`; move shared fixtures to a support file if needed)

**Interfaces:**
- Consumes: M2 `PhoneLinkDecoder`, `PhoneLinkScheduler`, `PhoneLinkFrame`, `PhoneLinkUpgrade`; `PhoneSession`'s connection, `queue`, `log`, `forward`, revoke check.
- Produces: `final class PhoneLinkSession { init(send: …, forward: @escaping (Data, @escaping (Data) -> Void) -> Void, socketPath: String, peer: String, window: UInt32, log: @escaping (String) -> Void, clock: @escaping () -> Date); func receive(_ bytes: Data); func close(reason: String) }`. Window 16 KiB for `BlePhoneLink`, 256 KiB for TLS. It drains `scheduler.next(maxChunk: 16384)` with one transport send in flight.
- Behaviour: `{"mux":1}` after auth → `PhoneLinkUpgrade.answer` after all earlier answers, then frames only; leftover bytes go to the decoder. Channel 0 lines go to `forward` in order; each answer is DATA on channel 0. A decoder error closes the link. Revoke still closes it.

- [ ] **Step 1: Failing tests:** `upgradeAnswersThenSpeaksFrames`; `leftoverBytesAfterUpgradeAreDecoded`; `aLineMaySpanFrames`; `controlAnswersKeepRequestOrder` (`session.type` "a" then "b" reach the stub in that order); `gridSetOverMuxIsResetOnDisconnect`; `refusesPhoneAndAttachCommands` (on both protocols); `badFrameClosesTheLink` (kind 99 → closed, `phone disconnected` logged); `revokeClosesAMuxLink`.
- [ ] **Step 2–4:** `swift test --filter 'PhoneLinkSession|MobileCommands'`: FAIL, implement, PASS.
- [ ] **Step 5: Commit** `feat(phone-link): relay upgrade and control channel`.

### Task 4: Events channel

**Files:**
- Create: `ElisCore/Sources/elisctlKit/PhoneLinkEvents.swift`
- Modify: `ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkScheduler.swift` (add `func pendingBytes(channel: UInt32) -> Int`), `PhoneLinkSession.swift`
- Test: `PhoneLinkSessionTests.swift`, `ElisCore/Tests/ElisCoreTests/PhoneLinkSchedulerTests.swift`

**Interfaces:** a poller on its own `Thread` reads `events.read` (model `EventCommands.swift` 51-71, 179-184; 0.25 s sleep on an empty batch), starting after the latest event at upgrade time, into the bounded queue from "Decisions"; it stops when the link closes.

- [ ] **Step 1: Failing tests:** `pendingBytesPerChannel` (scheduler); `eventsArriveOnChannelOne`; `startsAfterTheLatestEvent`; `aSlowPhoneDropsOldEvents` (no transport progress, 300 KiB of rows → at most 256 KiB queued plus one `dropped` line); `pollerStopsOnClose`.
- [ ] **Step 2–5:** filters `PhoneLinkScheduler|PhoneLinkSession`, FAIL, implement, PASS, commit `feat(phone-link): events channel`.

### Task 5: vt channels: open, stream, close

**Files:**
- Create: `ElisCore/Sources/elisctlKit/PhoneLinkTerminal.swift`
- Modify: `PhoneLinkSession.swift`
- Test: `ElisCore/Tests/elisctlKitTests/PhoneLinkTerminalTests.swift`

**Interfaces:**
- Consumes: Task 1 `ControlAttach.screen`/`remote`, `PhoneLinkTitleFilter`; Task 2 `PhoneLinkPty`; M2 `PhoneLinkOpen`, `PhoneLinkOpened`, `PhoneLinkClose`, `PhoneLinkFrame.grid`.
- Behaviour:
  - OPEN on channel n: refuse n < 2, a duplicate n, a ninth channel, `type != "vt"`, `claim == true` (texts in "Decisions"). Otherwise ask `session.attach` (`target`, `pane`) on the app socket (not through `forward`, so it does not queue behind typed input), run `screen` once, `scheduler.open(channel:)`, send `OPENED {"cols","rows"}`, spawn the attach on a pty of cols×rows, log `phone attached from <peer> pane <paneID>`.
  - Attach output → title filter → `scheduler.enqueue`. CREDIT → `scheduler.grant`.
  - Phone CLOSE, attach exit (`CLOSE {"reason":"session ended"}`), or link close: terminate the attach, stop the poll, `scheduler.close`, log `phone detached from <peer> pane <paneID>` once.
  - On link close every channel detaches before `PhoneSession` logs `phone disconnected`.
- Test fake: the stub app answers `session.attach` with `argv = ["/bin/sh","-c","printf 'hi'; cat"]`, `screen = ["/bin/sh","-c","printf '1 80 24 0 0 0\\n'"]`, `remote = false`.

- [ ] **Step 1: Failing tests:** `openStreamsTheAttach` (OPENED 80×24, DATA "hi", attached line); `attachRefusalAnswersOpenedError` (no process started); `refusesControlChannelsAndDuplicates`; `refusesClaimAndTooManyPanes`; `roleTitlesNeverReachThePhone`; `phoneCloseEndsTheAttach`; `attachExitClosesTheChannel`; `disconnectEndsEveryAttach` (two open → two detach lines before `phone disconnected`).
- [ ] **Step 2–5:** filters `PhoneLinkTerminal|PhoneLinkSession`, FAIL, implement, PASS, commit `feat(phone-link): vt channels`.

### Task 6: Overflow resync, grid poll, stall watchdog

**Files:**
- Modify: `PhoneLinkTerminal.swift`
- Test: `PhoneLinkTerminalTests.swift`

**Interfaces:** `PhoneLinkTerminal` takes the injected clock and a timer source; all rules below come from "Decisions".
- Overflow: stop delivery from the old attach first, terminate it, wait until a re-attach is allowed (1 per second), call `session.attach` again, run `screen`, `scheduler.open(channel:)` (credit back to the window), send RESYNC then GRID, spawn. No viewer lines. A failed re-attach closes the channel with the app's error and one detach line. Two overflows each within 2 s of their attach start → `CLOSE {"reason":"session too old for the phone view"}`.
- Grid poll: 2 s local / 10 s remote, one in flight, 5 s timeout; a cols/rows change sends GRID.
- Stall: 30 s without CREDIT while bytes wait → `CLOSE {"reason":"stalled"}`.

- [ ] **Step 1: Failing tests:** `overflowResyncs` (600 KiB burst then quiet fake → RESYNC, GRID, fresh output); `floodResyncsAtMostOncePerSecond` (`yes`-style fake, clock-driven → re-attach count ≤ elapsed seconds + 1); `noOldBytesAfterResync`; `repeatedEarlyOverflowCloses`; `gridChangeSendsGrid` (local 2 s, remote 10 s with `remote = true`); `noCreditCloses` (clock +31 s); `creditKeepsTheChannelOpen`.
- [ ] **Step 2–5:** filter `PhoneLinkTerminal`, FAIL, implement, PASS, commit `feat(phone-link): resync, grid poll and stall watchdog`.

### Task 7: Docs

**Files:** `.claude/rules/control-api.md` (relay mux contract: upgrade, channels, caps, refusals, the `screen`/`remote` fields, the outdated-daemon refusal; one paragraph that points at the spec), `docs/superpowers/specs/2026-11-18-phone-terminal-stream-design.md` (credit resets to the window at RESYNC on both sides; mark the M4 relay notes this plan settled), `site/commands.html` (`session.attach` answer fields and the new refusal).

- [ ] **Step 1:** edit; `make lint`; commit `docs: phone relay mux`.

### Task 8: Gates

- [ ] Run once: `make test`, `make test-app`, `make lint`. Compare any failure with `origin/master`. Push and confirm the Linux core tests job is green before merge.
