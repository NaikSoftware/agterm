# Phone Take over (M5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone can take the lead of a Live pane (the program runs at the phone's size and takes the phone's keys, paste, wheel and focus), give it back or lose it to the Mac, zoom and pan the Term view, and scroll a full-screen program in Watch; all of it works over Bluetooth and for remote rows.

**Architecture:** Take over is a second mux channel beside the watch channel: `OPEN {claim:true, cols, rows}` makes the relay ask the app for a claiming attach (`session.attach` with `claim`), run it on a pty at the phone's size, and scan its output only for the zmx role report. That channel carries input DATA and RESIZE phone→relay and LEAD, CREDIT and CLOSE relay→phone; output stays on the watch channel, which the relay resyncs at each lead change so the phone gets a clean screen at the new grid. The phone encodes input in `libvtshim` with libghostty-vt's encoders against its emulator's modes.

**Tech Stack:** Swift 6 (ElisCore, elisctlKit, app target), Swift Testing, XCTest (hosted); Flutter (Dart 3.13, Android), `dart:ffi`, C shim over libghostty-vt.

**Spec:** `docs/superpowers/specs/2026-11-18-phone-terminal-stream-design.md` ("Modes: Watch and Take over", "Protocol model", "Attach model", "Phone terminal engine"). Relay contract: `.claude/rules/control-api.md` (Relay mux, Pane lead). Style: the M4a and M4b plans beside this file.

**Blockers:** none. **Owner question:** elis-server's own tree will omit the new `phoneLead` field, as it omits `phoneViewers`; the approved exception (2026-11-18) names only `phoneViewers`, so the owner confirms it before Task 2 merges. zmx needs no new patch: 0001 already gives a claiming attach the lead (test "a claiming attach takes the lead from a live leader and both are told"), applies only the leader's input and resize, and reports the role ahead of any output.

**Superseded spec lines (Task 9 edits them):** the M5 line's "Fit to phone on the terminal view" is done (M4b); "Bluetooth end-to-end on the emulator" becomes the owner's physical phone (emulators are forbidden).

## Global Constraints

- Mac paths are under `macos/`. Targeted tests: `cd macos/ElisCore && swift test --filter <Suite>`; hosted: `xcodebuild test -project Elis.xcodeproj -scheme ElisTests -destination 'platform=macOS' -derivedDataPath build/DerivedData -only-testing:ElisTests/<Class>` after `./scripts/setup.sh && xcodegen generate`. Each gate runs once, in Task 10.
- New `elisctlKit` sources and tests are wrapped in `#if os(macOS)`; pure types go in `ElisCore/PhoneLink/` and stay Linux-safe. `ElisCore` `public` symbols are added, never narrowed.
- Phone code under `mobile/`: `flutter test --no-pub test/<file>`, `flutter analyze --no-pub` (0 issues). Never `flutter test integration_test` (it uninstalls the owner's app), never adb or an emulator from a subagent.
- After a `vtshim.c` change run `mobile/tool/build-vtshim.sh` (host dylib for tests, `.so` for the APK); add every new export to its `FUNCS` list.
- Frame format and the shared vectors (`PhoneLinkFrame`, `mobile/test/fixtures/phone-link-vectors.json`) do not change: RESIZE, LEAD and CREDIT are already in them.
- The relay never builds argv from phone input; a phone's own `session.attach` stays refused on channel 0 and the line protocol.
- Blocking pty work runs on a plain `Thread`, timers take the injected clock (`.claude/rules/tests.md`).
- Delegated agents receive verbatim: "never execute `elis`/`elisctl` against the default socket, never launch or quit the app, static reading only."
- Stage by explicit path; do not edit `macos/CHANGELOG.md`.

## Decisions taken in this plan (planner's calls)

1. **Take over is its own channel.** The watch channel stays open and untouched; leaving Take over is a CLOSE of the claim channel. Reason: no flicker, and `PhoneLinkTerminal` keeps its resync logic unchanged.
2. **Claim argv comes from the app:** `session.attach` gains `args.claim`; the answer adds `attach.nonce`. `ZmxLeadAttachment(claim: true, screenOnly: true)`: the claim's own output is discarded, so it skips scrollback. Reason: the relay must check the role report's nonce, since pane output on the same stream can forge the title.
3. **Unpatched or old zmx:** no role report for the nonce within 10 s of the spawn → the claim is killed and refused with `this host's zmx cannot hand over the lead; update Elis there`. Reason: a zmx without 0001 never reports; no version probe exists and none is needed.
4. **Lead changes resync the watch channel** (fresh viewer attach, RESYNC, GRID, screen) when the claim becomes leader and when it loses the lead. After a phone-side release or a RESIZE the relay only polls the grid within 1 s. Reason: the daemon has already resized when the report arrives, so the resync is the one point where old-grid bytes cannot follow.
5. **Lead lost:** the relay sends LEAD `{role}`, ends the claiming attach and sends CLOSE `the computer took the lead back`. Reason: a follower's input is dropped by the daemon, so the attach has no use.
6. **Receive window 16 KiB on both transports.** The relay sends CREDIT for bytes once they are written to the pty; more than a window unacknowledged closes the channel `input overflow`. The phone queues at most 1 MiB of unsent input. Reason: input is small; paste is the only bulk.
7. **Sizes** in OPEN and RESIZE must be 1...1000 each way; OPEN outside is refused `bad size`, RESIZE outside is ignored.
8. **Read-back and events:** pane node `phoneLead: true` (omitted otherwise), events `phone.claimed` / `phone.released` (`ip`, `paneID`), from relay lines `phone leads from <ip> pane <id>` / `phone released from <ip> pane <id>`. The Mac's cover reads `In use on your phone`. `elisctl session attach --claim` runs the claiming argv on stdio.
9. **Gestures on Term, one rule in both modes:** one finger scrolls the program, two fingers zoom (1x to 6x) and pan, double tap resets the zoom. One-finger scroll is `session.scroll` in Watch and encoded wheel in Take over. Reason: no exception depends on fit or zoom state.
10. **Wheel with mouse tracking off:** on the alternate screen with mode 1007 it sends arrow keys (xterm alternate scroll, as Ghostty does); on the main screen nothing, because Scrollback already shows there.
11. **Composer text goes as typed text** (key event with `utf8`), then Enter as a key; the new `paste` key uses the paste encoder (bracketed when mode 2004). In Watch `paste` types the clipboard through `session.type`. No unsafe-paste confirmation.
12. **Take over ends** on app pause, pane switch, leaving the screen and link loss; a reconnect starts in Watch. Reason: a phone in a pocket must not keep the Mac's pane covered.
13. **Fit after Take over stays off** until the owner taps Fit to phone. Entering awaits the `session.grid` reset answer before OPEN (OPEN is not on channel 0's serial path).
14. **Still-open M4 notes:** receive window in (Task 3); GRID overtaking DATA in for lead changes (call 4), the poll race stays; `phone.attached` session id out; never-shown pane out (Take over is refused with the same `session not realized`).

## Review Focus

1. The link drops (Wi-Fi, Bluetooth range, app killed) while the phone leads: the claiming attach ends, the Mac takes the lead back by itself, `phoneLead` clears. → Task 3 `linkCloseEndsTheClaim`, Task 2 `relayStopReleasesEveryLead`.
2. The Mac presses a key on the cover: the phone returns to Watch with one message, input typed after it is not sent, the Term view shows the Mac's grid. → Task 3 `leadLostSendsLeadThenClose`, Task 7 `leadLostReturnsToWatch`.
3. A large paste (1 MiB) or a program that stops reading: relay memory stays at one window, nothing blocks the relay queue, the phone refuses past its cap. → Task 3 `inputBeyondTheWindowCloses`, `creditFollowsPtyWrites`; Task 6 `pasteIsSentByCredit`, `queueCapRefuses`.
4. A pane output that prints a forged `zmx-role` title, or a report split across reads: the role does not change on the forgery, and the split report is parsed. → Task 3 `forgedRoleIsIgnored`, `splitRoleReportIsParsed`.
5. Take over on a host whose zmx has no leadership patch (old elis-server): a clear refusal within 10 s, no lead change, the Watch view goes on. → Task 3 `noRoleReportRefuses`, Task 7 `refusalStaysInWatch`.

---

### Task 1: Term view scrolls the program in Watch

**Files:** Modify `mobile/lib/screens/session.dart` (`_termView`, `_drag`); Test `mobile/test/session_term_test.dart`

**Interfaces:** Produces `void _drag(DragUpdateDetails d, double rowHeight)` (the text view passes `_fit * 1.3`, Term passes `CellMetrics.fit(width, cols).h`).

- [ ] **Step 1: failing tests:** `termDragScrollsTheProgram` (a 3-row drag down on `Key('term')` sends `session.scroll` with `lines: -3`, the text view's sign); `termDragErrorIsReportedOnce` (a refusal shows one message and drops the pending rows).
- [ ] **Step 2:** `flutter test --no-pub test/session_term_test.dart`: FAIL.
- [ ] **Step 3:** wrap the Term scroll view in `GestureDetector(onVerticalDragUpdate:)` with `NeverScrollableScrollPhysics`, as `_textView` does when `_remoteScroll`; on a `session.scroll` error set `_dragRows = 0`.
- [ ] **Step 4:** PASS. **Step 5:** commit `feat(mobile): drag scrolls the program in the Term view`.

### Task 2: App side: claiming attach, read-back, events, CLI

**Files:**
- Modify: `ElisCore/Sources/ElisCore/PhoneAttach.swift`, `ControlProtocol.swift` (`ControlArgs.claim: Bool?`), `ControlDispatcher+Attach.swift`, `ControlActions.swift` + `ControlActionsDefaults.swift`, `ControlEvents.swift`, `ControlProjection.swift`, `AppStore.swift`, `WindowLibrary.swift`, `PhoneDesktop.swift`, `ElisServerKit/ServerActions+Attach.swift`, `elisctlKit/Session+Attach.swift`, `elisctlKit/EventCommands.swift`, `Elis/Control/ControlServer+Attach.swift`, `Elis/Phone/PhoneRelay.swift`, `Elis/elisApp.swift`, `Elis/Views/PaneLeadCover.swift`
- Test: `ElisCoreTests/PhoneAttachTests.swift`, `PhoneDesktopTests.swift`, the `EventFormatter` and dispatcher suites, `ElisServerTests/ServerAttachTests.swift`, `elisctlKitTests` (session attach), hosted `ElisTests/ControlServerAttachTests.swift`

**Interfaces (Produces):**
- `ControlAttach.nonce: String?` (decoded with `decodeIfPresent`); `static func claimer(_ source: LivePaneSource, paneID: String) throws -> ControlAttach` (same argv shape as `viewer`, lead `ZmxLeadAttachment(claim: true, screenOnly: true)`, `nonce` set, `screen` and `remote` as `viewer`).
- `ControlActions.sessionAttach(target:pane:paneID:claim:window:)`, a NEW requirement beside the old one (a downstream conformer must keep compiling): its default in `ControlActionsDefaults` calls the old method when `claim` is false and answers `take over is not supported here` when true. The app and elis-server implement it.
- `ControlEventKind.phoneClaimed = "phone.claimed"`, `.phoneReleased = "phone.released"`; `ControlSurfaceNode.phoneLead: Bool?`; `AppStore.phoneLeads: (String) -> Bool` and the same on `WindowLibrary`, wired as `phoneViewerCount` is.
- `PhoneRelayLine.lead(leading: Bool, ip: String, paneID: String)`; `PhoneRelay.leads` (a second `PhoneViewers`).
- CLI: `elisctl session attach <target> --claim`.

- [ ] **Step 1: failing tests:** `claimerSetsClaimAndScreenOnlyAndNonce` (argv contains `ZMX_MANAGED_CLAIM=1`, `ZMX_MANAGED_SCREEN_ONLY=1`, no `ZMX_MANAGED_FOLLOW`, and `ZMX_MANAGED=<nonce>` equals `attach.nonce`); `remoteClaimerKeepsTheKeepalive`; `attachWithoutNonceDecodes`; `claimArgReachesTheAction`; `parsesLeadLines` (`phone leads from 10.0.0.2 pane P1` → `.lead(leading: true, …)`, `phone released from - pane P1`); `humanLineForPhoneClaimed` (`HH:MM:SS phone.claimed ip=IP pane-id=TOKEN`); `serverAnswersAClaimingAttach`; `claimFlagSendsClaim` (CLI request has `args.claim == true`; the "cannot attach a pane to itself" refusal stays); hosted `claimingAttachForALivePane`, `claimRefusedForAPaneThatIsNotLive`, `treeShowsPhoneLead`, `relayStopReleasesEveryLead` (each remaining lead emits `phone.released` with `ip` nil).
- [ ] **Step 2:** run the targeted suites: FAIL.
- [ ] **Step 3:** implement. `PhoneRelay.stderr` handles `.lead` as it handles `.viewer` (ignore a release that was not counted; `tree.changed` on each change, as a viewer change does); `exited` and the relay restart release every lead. `PaneLeadCover` shows `In use on your phone` when `phoneLeads(token)` is true. The CLI help for `--claim` says the pane on the Mac is covered until the command ends.
- [ ] **Step 4:** PASS. **Step 5:** commit `feat: session.attach --claim, phoneLead read-back and phone.claimed/released`.

### Task 3: Relay: claim channel, receive window, RESIZE, LEAD

**Files:**
- Create: `ElisCore/Sources/elisctlKit/PhoneLinkClaim.swift`
- Modify: `ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkTitleFilter.swift`, `elisctlKit/PhoneLinkPty.swift`, `elisctlKit/PhoneLinkSession.swift`, `elisctlKit/PhoneLinkTerminal.swift`
- Test: `ElisCoreTests/PhoneLinkTitleFilterTests.swift`, `elisctlKitTests/PhoneLinkPtyTests.swift`, new `elisctlKitTests/PhoneLinkClaimTests.swift`, `PhoneLinkSessionTests.swift`, `PhoneLinkTerminalResyncTests.swift`

**Interfaces:**
- Consumes: Task 2 `ControlAttach.nonce`, `args.claim`.
- Produces:
  - `PhoneLinkTitleFilter.filter(_:notices:)`: `mutating func filter(_ bytes: Data, notices: inout [ZmxLeadNotice]) -> Data` (the existing `filter(_:)` calls it and drops the notices).
  - `PhoneLinkPty.write(_ bytes: Data, done: @escaping @Sendable (Int) -> Void)` and `func resize(cols: UInt16, rows: UInt16)`. The controller becomes `O_NONBLOCK`; writes run in order on one writer thread, each `write` under the pty's lock and skipped once stopping, `EAGAIN` waits on `poll(POLLOUT, 100 ms)`; `done` gets the bytes written (0 after stop). The reader sets a `closed` flag under the lock before it closes the controller, and `write` and `resize` check it there: the fd number can be reused by another pane's pty.
  - `PhoneLinkTerminal.resync()` (drop the attach, re-attach at once, RESYNC and GRID as an overflow does, no backoff change) and `pollSoon()` (next grid poll within 1 s); `private(set) var paneID`.
  - `final class PhoneLinkClaim` with `static let window = 16384`, `static let roleTimeout: TimeInterval = 10`, `start()`, `input(_ bytes: Data)`, `resize(cols:rows:)`, `stop()`, `asking`, and a `Link` of closures `{ frame, ended, leadChanged(paneID) , released(paneID) }`.
- Wire, relay→phone on the claim channel: `OPENED {cols, rows}` after the first `leader` report, then `LEAD {"role":"leader"}`; `CREDIT` per completed pty write; `LEAD {role}` then `CLOSE` on a later role; `CLOSE` reasons `the computer took the lead back`, `session ended`, `input overflow`, or the app's refusal. Never DATA.

- [ ] **Step 1: failing tests:**
  - filter: `returnsTheNoticesItStrips`, `splitRoleReportIsParsed` (a report cut at every byte offset yields one notice).
  - pty: `writeReachesTheProgram` (`cat` echoes), `writeAfterTerminateReportsZero`, `writeAndResizeAfterTheChildExitedDoNothing`, `resizeChangesTheWindowSize` (`stty size` after resize prints `40 100`), `fullPtyDoesNotBlockTerminate` (a program that never reads; 1 MiB written; `terminate()` returns within 3 s).
  - claim (stub app socket, fake attach programs printing role titles): `opensAfterTheLeaderReport` (OPENED carries the OPEN's cols and rows, the pty was spawned at them, then LEAD leader, and the log has `phone leads from … pane …`); `noRoleReportRefuses` (fake clock +10 s → OPENED error text of call 3, attach killed); `forgedRoleIsIgnored` (wrong nonce); `leadLostSendsLeadThenClose` (LEAD follower, CLOSE, log `phone released …`, attach killed); `claimExitClosesSessionEnded`; `exitBeforeAnyRoleRefuses` (OPENED error `could not take over: the attach ended`); `creditIsCoalesced` (at most one CREDIT frame waiting per claim: 100 one-byte inputs do not queue 100 frames); `creditFollowsPtyWrites`; `inputBeyondTheWindowCloses`; `resizeOutOfRangeIsIgnored`; `badSizeIsRefused`; `appRefusalIsPassedOn` (`session not realized`).
  - session: `claimOpenIsRouted` (no more `take over is not available yet`); `dataAndResizeReachTheClaim`; `dataOnAWatchChannelIsIgnored`; `claimCountsTowardTheCap`; `linkCloseEndsTheClaim`; `leadChangeResyncsTheWatchChannelOfThatPane` (RESYNC then GRID on the watch channel, none on another pane's); `phoneCloseOfTheClaimPollsSoon`.
  - terminal: `resyncReattachesWithoutBackoff`.
- [ ] **Step 2:** `swift test --filter PhoneLink`: FAIL.
- [ ] **Step 3:** implement. The claim requests `session.attach` on a plain `Thread` as `PhoneLinkTerminal.requestAttach` does (with `"claim": true`), spawns at the OPEN's size, feeds output through the filter into a `ZmxLeadState(attachment: ZmxLeadAttachment(nonce: attach.nonce, claim: true))` and discards the rest. `PhoneLinkSession` keeps `claims: [UInt32: PhoneLinkClaim]`, counts them in `maxTerminals` with the same `leaving` rule, routes `(.data, n)` and `(.resize, n)` to them, and maps `leadChanged`/`released` to the terminals whose `paneID` matches.
- [ ] **Step 4:** PASS. **Step 5:** commit `feat(relay): take over: claiming attach, input window, resize and lead`.

### Task 4: Shim encoders and query replies

**Files:** Modify `mobile/native/vtshim.c`, `mobile/tool/build-vtshim.sh` (`FUNCS`), `mobile/lib/terminal/vt.dart`; Test `mobile/test/vt_test.dart`; update `FakeVt` in `mobile/test/session_term_test.dart`

**Interfaces (Produces):**
- C, each returns bytes written, 0 for "nothing to send", `-needed` when `cap` is short:
  `vts_encode_key(Vt*, uint32_t key, uint32_t mods, uint32_t unshifted, const char* utf8, size_t utf8_len, uint8_t* out, int32_t cap)` (`unshifted` is the key's unshifted codepoint, 0 for none),
  `vts_encode_paste(Vt*, char* data, size_t len, uint8_t* out, int32_t cap)` (bracketed when mode 2004),
  `vts_encode_wheel(Vt*, int32_t up, uint16_t col, uint16_t row, uint8_t* out, int32_t cap)` (0 when the program does not track the mouse),
  `vts_encode_focus(Vt*, int32_t gained, uint8_t* out, int32_t cap)` (0 unless mode 1004),
  `vts_take_replies(Vt*, uint8_t* out, int32_t cap)` (drains what `WRITE_PTY` collected during `vts_write`; the buffer holds 4 KiB and drops past it).
- Callbacks registered in `vts_new`: `WRITE_PTY` (append to the buffer), `DEVICE_ATTRIBUTES` (the values Ghostty's own surface reports, read from `src/termio` at `GHOSTTY_REV`; conformance `GHOSTTY_DA_CONFORMANCE_LEVEL_2`), `SIZE` (the grid, cells 8×16 as `vts_resize` uses). `vts_write` stays a leaf call: callbacks only touch C state.
- Dart: `enum VtKey` (values copied from `ghostty/vt/key/event.h`: `escape, tab, enter, backspace, arrowUp, arrowDown, arrowLeft, arrowRight, home, end, pageUp, pageDown, c, d, l, r, z, u, unidentified`), `const vtShift = 1, vtCtrl = 2, vtAlt = 4`; on `Vt`: `Uint8List encodeKey(VtKey key, {int mods = 0, String text = ''})` (letter keys pass their lowercase codepoint as `unshifted`), `Uint8List encodeText(String text)`, `Uint8List encodePaste(String text)`, `Uint8List encodeWheel({required bool up, required int col, required int row})`, `Uint8List encodeFocus(bool gained)`, `Uint8List takeReplies()`.

- [ ] **Step 1: failing tests:** `arrowUpFollowsCursorKeyMode` (`ESC[A`, then `ESCOA` after writing `ESC[?1h`); `ctrlCIsEtx`; `shiftTabIsBacktab` (`ESC[Z`); `kittyModeEncodesEscape` (after `ESC[>1u`, escape is `ESC[27u`); `textIsUtf8`; `pasteIsBracketedOnlyUnderMode2004`; `wheelIsEmptyWithoutTracking`; `wheelUnderSgrTracking` (after `ESC[?1000h ESC[?1006h`, up at col 2 row 3 is `ESC[<64;3;4M`); `focusOnlyUnderMode1004` (`ESC[I` / `ESC[O`); `repliesAreCollected` (write `ESC[c` → `takeReplies()` starts with `ESC[?62` and ends with `c`, a second take is empty); `cursorPositionReportIsCollected` (`ESC[6n`).
- [ ] **Step 2:** `tool/build-vtshim.sh && flutter test --no-pub test/vt_test.dart`: FAIL. **Step 3:** implement (one key encoder and one mouse encoder per `Vt`, `setopt_from_terminal` before each encode; mouse size struct with 1-pixel cells so the position is the cell). **Step 4:** PASS; `tool/build-vtshim.sh --check` lists the new exports.
- [ ] **Step 5:** commit `feat(mobile): input encoders and query replies in the shim`.

### Task 5: Mux client: claim channel

**Files:** Modify `mobile/lib/link/mux.dart`; Test `mobile/test/mux_test.dart` (extend `FakeRelay`)

**Interfaces (Produces):** `Future<ClaimChannel> claim(String target, {String? pane, required int cols, required int rows})` on `Mux` (refusal throws `ElisError`, as `open`); `class ClaimChannel { Stream<ClaimEvent> get events; bool send(Uint8List bytes); void resize(int cols, int rows); Future<void> close(); }`; `sealed class ClaimEvent` = `Lead(String role)` | `ClaimClosed(String reason)`. `send` returns false when more than 1 MiB would wait.

- [ ] **Step 1: failing tests:** `claimOpenCarriesClaimAndSize` (OPEN JSON `{"claim":true,"cols":50,"rows":30,"pane":…,"target":…,"type":"vt"}`); `claimRefusalThrows`; `leadIsDelivered`; `pasteIsSentByCredit` (40 KiB sent: 16384 bytes go out in frames of at most 16 KiB, the rest after CREDIT frames); `queueCapRefuses`; `resizeSendsAFrame`; `closeSendsCloseAndStopsSending`; `linkLossClosesTheClaim`; `watchChannelIgnoresLead` (unchanged behaviour).
- [ ] **Step 2–4:** FAIL, implement (`_channels` holds both kinds behind one private interface with `_onFrame` and `_end`), PASS; `test/link_test.dart` still passes.
- [ ] **Step 5:** commit `feat(mobile): claim channel in the mux client`.

### Task 6: TermSession leads

**Files:** Modify `mobile/lib/terminal/term_session.dart`; Test new `mobile/test/term_session_test.dart` (fake mux and `FakeVt`)

**Interfaces:**
- Consumes: Task 4 encoders, Task 5 `ClaimChannel`.
- Produces on `TermSession`: `Future<String?> takeOver(int cols, int rows)` (null on success, else the refusal); `bool get leading`; `String? leadLost` (set once when the relay ends the lead, cleared by `takeOver`); `void key(VtKey key, {int mods = 0})`; `void text(String s)`; `bool paste(String s)`; `void wheel({required bool up, required int col, required int row})`; `void resizeLead(int cols, int rows)`; `void release()`. The constructor keeps `target`.

- [ ] **Step 1: failing tests:** `takeOverOpensAClaimAtTheSize`; `leaderSendsFocusGained` (only when the emulator has mode 1004); `repliesAreSentOnlyWhileLeading` (a DA query in Data: nothing sent in Watch, the reply sent as claim input while leading); `repliesWaitForTheResyncAfterLeader` (a query in Data that arrives after `Lead('leader')` but before the watch channel's Resync is not answered: the Mac answered it already); `leadLostReturnsToWatchAndStopsInput` (`leading` false, `leadLost` set, later `key()` sends nothing); `releaseSendsFocusLostThenClose`; `closeReleasesTheClaim`; `wheelFallsBackToArrowsOnTheAlternateScreen` (no tracking, alt screen, mode 1007 → the arrow key bytes; main screen → nothing); `resizeLeadSendsResizeAndSizesTheEmulator`; `sessionEndWhileLeadingEndsBoth`.
- [ ] **Step 2–4:** FAIL, implement (after each `_vt.write` call `takeReplies()` and send it only while leading and after the Resync that follows the leader report; on `Lead('leader')` set `_fit` to the lead size), PASS.
- [ ] **Step 5:** commit `feat(mobile): TermSession takes the lead`.

### Task 7: Session screen: Take over

**Files:** Modify `mobile/lib/screens/session.dart`; Test `mobile/test/session_term_test.dart`

**Interfaces:** consumes Task 6. The `keys` table gains each key's `VtKey` and mods; a `paste` key is added.

- [ ] **Step 1: failing tests:** `takeOverButtonIsDisabledWithoutATerminal` (present, disabled on a pane that is not Live); `takeOverResetsTheFitFirst` (the `session.grid` reset answer precedes the claim OPEN; `autoFit.wanted` false after); `takeOverUsesThePhoneGrid` (cols = `_fitColumns()`, rows = box height / cell height, both from a `LayoutBuilder` around the Term view: `_width` and `_height` are set only while the text view is laid out); `toolbarFitsAPhoneWidthWithASplit` (360 dp wide, five segments, no overflow); `refusalStaysInWatch` (reason shown once, button back to `Take over`); `keyBarSendsEncodedKeysWhileLeading` (no `session.type`); `composerSendsTextThenEnter`; `pasteKeyPastes` (Take over: paste encoder; Watch: `session.type`); `dragSendsWheelWhileLeading` (no `session.scroll`); `fitIsDisabledWhileLeading`; `leadLostReturnsToWatch` (message `The computer took the lead back.` once); `pauseAndPaneSwitchRelease`; `keyboardInsetResizesTheLead` (one RESIZE 300 ms after the last layout change).
- [ ] **Step 2–4:** FAIL, implement (toolbar segment `Take over` / `Give back`, `Key('takeOver')`; `type()` and `sendInput()` branch on `term.leading`), PASS.
- [ ] **Step 5:** show the owner the rendered toolbar in both modes (a golden or a screenshot from the widget test) before more tests are added; commit `feat(mobile): Take over on the session screen`.

### Task 8: Zoom and pan of the Term view

**Files:** Create `mobile/lib/terminal/term_gestures.dart`; Modify `mobile/lib/screens/session.dart` (`_termView` uses it; replaces Task 1's detector); Test new `mobile/test/term_gestures_test.dart`, `session_term_test.dart`

**Interfaces (Produces):** `class TermGestures extends StatefulWidget { const TermGestures({required Widget child, required Size content, required double rowHeight, required void Function(int rows) onScroll}); }`: one pointer vertical → `onScroll(rows)` (rows = distance / (rowHeight × scale), remainder kept); two pointers → scale clamped 1...6 around the focal point and pan clamped to the content; double tap → scale 1. At scale 1 the bottom rows are in view, as now.

- [ ] **Step 1: failing tests:** `oneFingerDragReportsRows`; `pinchZoomsAroundTheFocalPoint`; `scaleIsClamped`; `panStaysInsideTheContent`; `doubleTapResets`; `zoomedDragStillScrollsByRows` (row height × scale); `paneSwitchResetsTheZoom`; `tallGridShowsItsBottomRows`.
- [ ] **Step 2–4:** FAIL, implement (`GestureDetector` scale callbacks with `pointerCount`, a `Transform` over the child; no `InteractiveViewer`, which takes one-finger drags as pan), PASS.
- [ ] **Step 5:** commit `feat(mobile): pinch zoom and pan in the Term view`.

### Task 9: Docs, rules, skill

- [ ] `.claude/rules/control-api.md` (Relay mux): the claim channel contract of Task 3 (frames, reasons, window, role timeout, resync at lead changes, cap), `session.attach` `claim` and `nonce`, `phoneLead`, the two events and relay lines; drop "LEAD and relay-to-phone CREDIT are not sent" and "OPEN with `claim` is refused". Pane lead: the phone as a leader and the cover text.
- [ ] Spec: M5 line and the "Still open" list per the header and call 14; OPEN/OPENED fields of a claim.
- [ ] `site/commands.html`: `session attach --claim`, `phone.claimed` / `phone.released`, `phoneLead`. `site/docs.html#phone-app`: Take over, give back, the gestures, paste; `#remote-sessions-lead`: one bullet for the phone. `plugins/elis/skills/elis/SKILL.md` (events list, description trigger) and `reference.md`. `mobile/README.md`: one line on the shim's new exports.
- [ ] Commit `docs: phone Take over`.

### Task 10: Gates

- [ ] `cd macos/ElisCore && swift test`; `cd macos && make test-app && make lint`; then `lsappinfo list | grep -A4 elis.debug` (stop leaked test processes only).
- [ ] `cd mobile && tool/build-vtshim.sh && flutter analyze --no-pub && flutter test --no-pub && flutter build apk --debug --no-pub`; `unzip -l` shows `libvtshim.so` for both ABIs.
- [ ] The Linux CI job stays green (no new unguarded pty code).

### Task 11: End to end on the owner's phone over Bluetooth (controller only, never a subagent)

- [ ] Build the Mac app Debug and launch one isolated instance per `CLAUDE.md` (`env -u …`, `open -n --env ELIS_STATE_DIR=/tmp/elis-m5`, Live sessions on); every `elisctl` call uses the Debug binary with `--socket`. Create test sessions there only: a shell, `vim`, and `cd ~/IdeaProjects/elis && claude`.
- [ ] `adb install -r` the debug APK (never uninstall, never `flutter test integration_test`); ask the owner to pair the phone with the Debug relay and to turn Wi-Fi off, so the `via` chip reads Bluetooth. Allow the Bluetooth prompt the Debug build raises.
- [ ] Check with screenshots (`adb exec-out screencap -p`), each on a local row and on one remote row (elis-server or attached Mac):
  1. Watch: one-finger drag scrolls Claude Code's transcript; pinch zooms, two fingers pan, double tap resets.
  2. Take over: the Mac pane shows `In use on your phone`; `tree` shows `phoneLead` and the Mac's `lead: follower`; `events` printed `phone.claimed`; the program redraws at the phone's grid.
  3. Input: key bar arrows in `vim`, composer text plus Enter in the shell, paste of a multi-line clipboard (bracketed in zsh), drag scrolls Claude Code, the soft keyboard opening resizes the program.
  4. A key on the Mac's cover: the phone returns to Watch with the message; `phone.released` printed.
  5. Give back, app pause, and Bluetooth off on the phone: each time the Mac leads again within a few seconds and `phoneLead` is gone.
  6. A 200 KiB paste completes and the relay's memory stays flat.
- [ ] Stop the Debug instance by pid with SIGTERM, confirm no Dock tile lingers, report the results with the screenshots.
