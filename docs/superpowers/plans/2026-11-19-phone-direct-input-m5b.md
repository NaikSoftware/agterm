# Phone Direct Input (M5b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On a Live pane the phone takes the lead by itself at its first input and from then on sends every key, text, paste, wheel notch, focus change and tap straight to the program; the Take over button is gone.

**Architecture:** No frame or command changes: the claim channel and its window stay as M5 built them; the relay adds a resync after a claim RESIZE, and `session.text` learns to read a covered remote pane from its daemon. `TermSession` gains one ordered input queue that holds intents while the claim opens, sends them at the leader report and keeps a 20 ms gap before a composer's Enter. The session screen claims at the first input instead of at a button, opens a no-suggestions keyboard at a tap whose keys go to the program, keeps its view rule (Term for a full-screen program, history for a shell), and falls back to `session.type` / `session.scroll` only where a claim is impossible.

**Tech Stack:** Flutter (Dart 3.13, Android), `dart:ffi`, C shim over libghostty-vt; Swift 6 (`elisctlKit`), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-18-phone-terminal-stream-design.md`, as changed by the owner decision below. Base: `docs/superpowers/plans/2026-11-18-phone-take-over-m5.md` (what exists), `.superpowers/sdd/2026-11-18-phone-take-over-m5/final-review.md` (I1 to I3, M1, M2, M4), `.claude/rules/control-api.md` (Relay mux, Take over).

**Owner decision (2026-11-19, binding): direct by default.**
- No Take over / Give back button. The toolbar holds only the pane segments, and only with a split.
- On a Live pane the first input of any kind claims the lead: a key-bar key, a composer send, a paste, an answer button, a one-finger scroll, a tap. Looking never claims.
- While the phone leads, all input goes through the claim channel, encoded by the shim. A tap is a left click (press, release) at the cell under the finger when the program tracks the mouse.
- The phone releases on leaving the screen, app pause, pane switch and link loss. The Mac takes the lead back by a key on its cover.
- The app bar shows when the phone leads.
- The indirect path stays only for a pane that is not Live and for a pane whose claim was refused, for that visit.
- Auto-fit: while the phone leads, the grid is the lead size; after the phone's own release the fit resumes; after a Mac take-back it stays off for the visit.

**Owner decisions (2026-11-19, second message), from a bug the owner saw:** while the phone led, showing or hiding the soft keyboard left Claude Code's screen garbled. Cause: `TermSession.resizeLead` resized the phone's emulator when it sent RESIZE, while output for the old grid was still on its way, and the relay answered a claim RESIZE with `pollSoon()` only, with no RESYNC.
- **Resize fix.** After a claim RESIZE the relay resyncs that pane's watch channels (RESYNC, GRID, a fresh screen at the new grid), one resync for a burst of resizes. The phone sizes its emulator from RESYNC and GRID, never when it sends RESIZE.
- **The soft keyboard never resizes the program**, leading or not: the view keeps the bottom rows above the keyboard. The grid changes only with the fit, the lead start, and a real layout change such as a rotation (through the resize fix).

**Owner decisions (2026-11-19, third message):**
- **The view while leading follows the existing rule, unchanged:** a full-screen program (alternate screen) shows the Term view, a plain terminal (main screen) shows the Scrollback history view, also while the phone leads. Input still goes direct. This replaces final-review I2's "Term while leading". The history view keeps working while the phone leads, on local rows and on remote rows (attached Mac, elis-server). A one-finger scroll on the history view scrolls the history, not a wheel.
- **Any tap on the terminal claims the lead**, also on a program that does not track the mouse.
- **Direct typing, no button.** A tap on the terminal (Term or history view) sends the click when the program tracks the mouse and opens the soft keyboard, bound to a hidden input. Each keystroke goes straight to the program. The keyboard stays until the user hides it; a tap elsewhere in the program just clicks. The keyboard is a no-suggestions one (visible-password style, as Termux), so each letter arrives as a key; text from an IME commit goes as text; a large edit (voice, the keyboard's clipboard) goes as a paste; Backspace, Enter and arrows map to keys. The composer stays for long text, voice and autocorrect.

**Owner decision (2026-11-19, fourth message): "not every click shows the keyboard, only clicks on inputs."** One visible rule: a tap opens the soft keyboard only when it lands on the row of the visible text cursor, the caret the user sees. Any other tap only claims and clicks (when the program tracks the mouse). A hidden cursor (`ESC[?25l`) means no tap opens the keyboard. The key bar and the composer work regardless. This narrows the third message's "a tap opens the soft keyboard". Evidence: Claude Code enables mouse modes 1000/1002/1003/1004/1006, never hides the cursor and parks it in its input box; a shell keeps the cursor on its prompt line.

## Global Constraints

- The M5 plan's Global Constraints apply unchanged (paths, `#if os(macOS)`, `flutter test --no-pub test/<file>`, `flutter analyze --no-pub` with 0 issues, `mobile/tool/build-vtshim.sh` and its `FUNCS` list after a `vtshim.c` change, explicit staging, no `macos/CHANGELOG.md`).
- No frame, protocol command, event or read-back changes. `session attach --claim`, `phoneLead`, `phone.claimed` and `phone.released` stay as they are. Control-API exemption: this change adds nothing to drive; the lead is already readable as `phoneLead`.
- Remote rows (attached Mac, elis-server) take the same path: no branch on where the pane runs.
- Never `flutter test integration_test`, adb or an emulator from a subagent. Delegated agents receive verbatim: "never execute `elis`/`elisctl` against the default socket, never launch or quit the app, static reading only."
- Tasks 5, 6, 7 and 8 all edit `mobile/lib/screens/session.dart` and run in that order, one at a time. Tasks 1, 2, 3 and 4 are independent of each other.
- Exact values: Enter gap 20 ms; input queue 256 intents and 1 MiB of text; covered-fit retries 3, 1 s apart; resync 150 ms after the last claim RESIZE; remote history read limit 5 s; keyboard paste threshold 64 characters or any newline; chip texts `Phone leads` and `Taking the lead…`.

## Decisions taken in this plan (planner's calls)

1. **Input made while the claim opens is queued on the phone**, as intents, and sent at the leader report. Reason: once the claim leads, the Mac's attach is a follower and zmx drops its input, so an indirect first input can vanish or arrive out of order.
2. **A refused claim replays the queue through `session.type`**, in order; the pane is then indirect for the visit and the refusal is said once. Reason: the input is neither lost nor sent twice.
3. **A queue is dropped when the phone itself ends the claim before it leads** (pane switch, pause, leaving). Reason: the claim cannot be cancelled before OPENED and may lead for a moment, so a replay could be refused or dropped.
4. **Queue bounds: 256 intents and 1 MiB of text.** Past them the input is refused with `The computer has not taken the earlier input yet.` Reason: the same cap as the claim channel's own queue.
5. **Taps and wheel notches made before the leader report only claim; they are not replayed.** Reason: the reset and the claim change the grid, so the cell under the finger is no longer the same.
6. **The Enter gap is 20 ms and lives in the ordered send path of `TermSession`**, not in a timer in the screen. Reason: a key pressed inside the gap must not overtake the Enter, and a flushed queue must keep the gap. The Mac's `KeystrokeSegments.submitGap` is 10 ms; the owner asked for about 20.
7. **What claims:** key bar, composer send, paste, answer buttons, a keystroke of the terminal keyboard, a single tap on either view, and a one-finger scroll on the Term view. **What is looking:** two-finger zoom and pan, double tap, scrolling and selecting on the history view, focusing the composer.
8. **After a Mac take-back any new input claims again.** A drag already in progress at the take-back does nothing until a finger goes down again. Reason: one rule with no timer; the finger rule is visible to the user.
9. **A double tap is looking:** it resets the zoom, sends no click, does not claim and does not open the keyboard. Reason: it is the existing zoom gesture, and the single tap already waits for it.
10. **A single tap acts after the double-tap timeout** (about 300 ms): the click and the keyboard both come then. Reason: one detector must tell the two apart.
11. **A tap anywhere in the terminal box claims; the click is sent only for a touch on a grid cell of the Term view.** A tap on the history view sends no click. Reason: a scrolled, reflowed history has no cell under the finger, and a click on a cell the finger did not touch is a wrong result.
12. **The chip reads `Taking the lead…` while the claim is pending and `Phone leads` while it leads**, in the same bordered tag as the link chip. Reason: the wait can be 10 s with input queued.
13. **History of a covered remote pane comes from that pane's daemon over ssh:** `session.text` runs `zmx screen <daemon> --all` on the host, off the main actor, at most one read per pane at a time, limit 5 s. Reason: the refusal existed only because that read cannot be synchronous; the daemon's screen has the leader's layout, and the fix serves every caller, not only the phone.
14. **The wait for the Mac's grid report (`_refitAfter`, `_refitTimer`) is deleted**; I3's bounded retry carries the refit. Reason: only the Give back button reached that wait.
15. **M2 falls back to the role** when no watch channel of the link has a `paneID` for that target and pane yet. Reason: the claim may open first.
16. **The relay resyncs 150 ms after the last RESIZE of a claim** (injected `after`, one pending resync per claim). Reason: the phone already waits 300 ms for a layout to settle, and the daemon needs a moment to apply the size before the fresh viewer attach reads it; `resync()` is followed by `pollSoon()` so a size applied late still reaches the phone as GRID.
17. **The lead grid's rows are computed from the view's height plus the keyboard inset** (`MediaQuery.viewInsets.bottom`). Reason: that is the height without the keyboard, so the keyboard changes nothing and a rotation still does.
18. **The emulator resize at the leader report stays** (`_onClaim`). Reason: a lead change already resyncs the watch channel right after it; only the RESIZE path lacked one.

19. **A daemon-backed `session.text` answers the daemon screen's `columns` and `rows`**, not the covered surface's. Reason: the phone sizes the history text by `columns`, and the covered surface keeps the Mac's grid.
20. **The terminal keyboard's keystrokes route as key-bar keys do** (direct when the pane can be claimed, else `session.type`, one call at a time in order). A pane with no live terminal has no cursor, so no tap opens the keyboard there. Reason: the rule reads the cursor the user sees, and that pane shows none.
21. **The hidden input holds a two-space sentinel and is reset after every change**; a shorter value is that many Backspace keys, a longer one is the inserted text. Reason: Android reports Backspace from a soft keyboard only as a text change.
22. **An insertion is a paste when it has a newline or more than 64 characters**, else typed text. Reason: a swiped word stays text; voice and clipboard inserts are longer.
23. **After the user hides the keyboard, the next single tap on the cursor row shows it again**; focusing the composer moves typing there until the next tap on the terminal. Reason: the keyboard has one owner at a time, and the caret shows which.
24. **On the Term view the cursor row is `snapshot.cursorY` when `snapshot.cursorVisible`; the tap's row is the cell row under the finger with zoom and pan undone, any column.** Reason: the whole input line is the target, not the one caret cell.
25. **On the history view the cursor row is the text's last line**, and the empty area below it counts as that row; it applies only while the history is at its bottom (`vScroll.offset == 0`) and the live snapshot's cursor is visible. Reason: the history is reflowed and trimmed of trailing blank rows, so the live `cursorY` cannot be mapped to an exact line; a shell's caret sits on its last line. Scrolled up, the caret is not on screen and no tap opens the keyboard.

## Review Focus

1. The Mac takes the lead back while a finger is still dragging: the drag does not claim again; the next touch does. → Task 7 `dragInFlightAtTakeBackDoesNotReclaim`.
2. Keys typed in the seconds before the leader report, then a refusal (old zmx): each arrives once, in order, through `session.type`. → Task 2 `refusalKeepsTheQueueForTakeUnsent`, Task 5 `refusedClaimReplaysTheQueueIndirectly`.
3. A composer line followed at once by a key-bar key: the Enter still comes 20 ms after the text and before that key. → Task 2 `aKeyInTheGapFollowsTheEnter`.
4. A pane switch or pause right after typing, before the lead: nothing reaches either pane later. → Task 5 `paneSwitchDropsThePendingQueue`.
5. Opening a session and only reading or zooming: no OPEN with `claim`, the Mac stays uncovered. → Task 5 `lookingNeverClaims`, Task 7 `zoomAndDoubleTapDoNotClaim`.
6. The keyboard opens and closes while Claude Code redraws under the phone's lead: no RESIZE is sent and the screen stays clean. A rotation in the same state: one RESIZE, one RESYNC, a clean screen at the new grid. → Task 6 `keyboardDoesNotResizeTheLead`, Task 2 `oldGridBytesAfterAResizeDrawAtTheOldGrid`, Task 3 `resizeOfTheClaimResyncsTheWatchChannel`.
7. The phone leads a shell on a remote row: the history view keeps updating and scrolls. → Task 4 `coveredRemotePaneTextReadsItsDaemon`, Task 5 `historyKeepsUpdatingWhileLeading`.

---

### Task 1: Shim click export

**Files:** Modify `mobile/native/vtshim.c`, `mobile/tool/build-vtshim.sh` (`FUNCS`), `mobile/lib/terminal/vt.dart`; Test `mobile/test/vt_test.dart`

**Interfaces (Produces):**
- C: `int32_t vts_encode_click(Vt* v, uint16_t col, uint16_t row, uint8_t* out, int32_t cap)`: a left-button press then release at the centre of the zero-based cell (`x = col * 8 + 4`, `y = row * 16 + 8`, the wheel's 8x16 cells), both in `out`. Returns the total bytes, 0 when the program does not track the mouse, `-needed` when `cap` is short.
- Dart: `Uint8List Vt.encodeClick({required int col, required int row})`.

- [ ] **Step 1: failing tests** in `vt_test.dart`: `clickIsEmptyWithoutMouseTracking` (fresh emulator: `encodeClick(col: 2, row: 3)` is empty); `clickIsPressThenReleaseInSgr` (after writing `\x1b[?1000h\x1b[?1006h`: bytes equal `\x1b[<0;3;4M\x1b[<0;3;4m`); `clickInLegacyEncoding` (after `\x1b[?1000h` only: `\x1b[M #$` then `\x1b[M##$`); `clickGrowsTheBufferOnce` (as the existing `-needed` test for the wheel). The vectors are xterm's; a mismatch is reported to the controller, not adjusted.
- [ ] **Step 2:** `tool/build-vtshim.sh && flutter test --no-pub test/vt_test.dart`: FAIL (symbol missing).
- [ ] **Step 3:** implement beside `vts_encode_wheel`, sharing its size setup; add the lookup to `_Lib` and the name to `FUNCS`.
- [ ] **Step 4:** PASS. **Step 5:** commit `feat(mobile): click encoder in the vt shim`.

### Task 2: `TermSession` input queue, Enter gap, click, M1

**Files:** Modify `mobile/lib/terminal/term_session.dart`; Test `mobile/test/term_session_test.dart` (its `FakeVt` in `session_term_test.dart` gains `encodeClick`)

**Interfaces:**
- Consumes: `Vt.encodeClick` (Task 1).
- Produces (replacing today's `key`, `text`, `paste`):
  - `void arm()`: input queues from now; `takeOver` follows. `bool get pending`: armed or claimed, and not leading.
  - `bool key(VtKey key, {int mods = 0, required String seq})`, `bool text(String s)`, `bool paste(String s)`, `bool line(String s)` (the text as typed text, skipped when empty, then Enter 20 ms later). Each returns false when it was neither sent nor queued: not armed and not leading, closed, or past 256 intents / 1 MiB.
  - `void click({required int col, required int row})` and the existing `wheel(...)`: sent only while leading, never queued.
  - `List<String> takeUnsent()`: the queued intents as `session.type` strings in order (`seq` for a key, the text, the clipboard, and for a line the text then `\r`), clearing the queue.
- One FIFO serves both states. While leading it drains at once, except that a `line` holds everything behind it for 20 ms between its text and its Enter. At `Lead('leader')` it drains after the focus report. `release()` sends what is already draining without gaps, then focus out and CLOSE, and drops a queue that never led. A `ClaimClosed` drops it. A refusal from `takeOver` keeps it for `takeUnsent()`.
- M1: `Opened` sets `_resynced = true` while a claim is held.
- Resize fix: `resizeLead` while leading sends RESIZE and nothing else: no `fitted()`, no `_fit`, no emulator resize. The emulator takes the new size from the Resync and Grid that follow.

- [ ] **Step 1: failing tests:** `inputBeforeTheLeadIsSentOnceAtTheLeaderReport` (arm, `key`, `text`, then OPENED and LEAD: the claim got focus-in if mode 1004, then the key, then the text, each once); `lineSendsEnterAfter20ms` (leading: text at once, no Enter at 19 ms, Enter at 20 ms; use `fakeAsync`); `aKeyInTheGapFollowsTheEnter` (`line('ls')` then `key(tab)` at once: order text, Enter, tab); `aFlushedLineKeepsTheGap`; `emptyLineSendsOnlyEnter`; `refusalKeepsTheQueueForTakeUnsent` (`takeOver` returns the refusal; `takeUnsent()` equals `['\x1b', 'ls', '\r']` for esc then `line('ls')`, and is empty on a second call); `releaseBeforeTheLeadDropsTheQueue`; `claimClosedDropsTheQueue`; `queueRefusesPastItsBounds` (the 257th intent returns false; a 1 MiB + 1 text returns false); `inputWithoutArmOrLeadReturnsFalse`; `releaseInTheGapStillSendsEnter`; `clickAndWheelAreNotQueued`; `clickSendsTheEncodedBytesWhileLeading`; `repliesArmWhenTheWatchOpensUnderAHeldClaim` (claim leads before the watch channel's Opened; a query written after Opened is answered on the claim); `oldGridBytesAfterAResizeDrawAtTheOldGrid` (leading at 80x24, `resizeLead(60, 20)`: the claim got RESIZE 60x20, `FakeVt` is still 80x24 when a following Data is written, and becomes 60x20 only at Resync then Grid 60x20). Rewrite `resizeLeadSendsResizeAndSizesTheEmulator` as `resizeLeadSendsResizeOnly`.
- [ ] **Step 2:** `flutter test --no-pub test/term_session_test.dart`: FAIL.
- [ ] **Step 3:** implement; update the existing tests that call `key`/`text`/`paste` to the new signatures.
- [ ] **Step 4:** PASS, with `test/session_term_test.dart` still compiling. **Step 5:** commit `feat(mobile): queue input until the phone leads; Enter after a gap`.

### Task 3: Relay: resync after a claim RESIZE, claim by pane id (M2), waits on state (M4)

**Files:** Modify `macos/ElisCore/Sources/elisctlKit/PhoneLinkClaim.swift`, `PhoneLinkSession.swift`, `PhoneLinkPty.swift`; Test `macos/ElisCore/Tests/elisctlKitTests/PhoneLinkSessionTests.swift`, `PhoneLinkPtyTests.swift`, `PhoneLinkTerminalResyncTests.swift`

**Interfaces (Produces):** `PhoneLinkClaim.init(..., watched: String?, ...)`: when set, `start()` adds `args["paneID"] = watched`. `PhoneLinkSession.openClaim` passes the `paneID` of its watch terminal with the same `target` and `pane`, else nil. `PhoneLinkPty.writerIdle: Bool` (internal, read under the write lock: the writer thread is parked with nothing to write). `PhoneLinkClaim.Link` gains `resized: (String) -> Void`, called on the relay queue 150 ms after the last accepted RESIZE of a leading claim (through the claim's injected `after`; a newer RESIZE supersedes a waiting call; a stopped claim calls nothing). `PhoneLinkSession` wires it to `watching(paneID).forEach { $0.resync(); $0.pollSoon() }` and drops the `pollSoon()` in its `.resize` case.

- [ ] **Step 1: failing tests:** `claimNamesTheWatchedPane` (a watch channel opened on `left` with pane id `P1`, then a claim OPEN for the same target and pane: the stub's `session.attach` request has `args.paneID == "P1"` and `args.claim == true`); `claimWithoutAWatchNamesTheRole` (no `paneID` key); `resizeOfTheClaimResyncsTheWatchChannel` (a watch and a leading claim on one pane; RESIZE 100x40, advance 150 ms: the watch channel gets one RESYNC, then GRID 100x40 from the stub's screen, and the stub saw one more viewer attach; nothing before the 150 ms); `aBurstOfResizesResyncsOnce` (three RESIZE frames 50 ms apart: one RESYNC, 150 ms after the third); `resizeOutOfRangeDoesNotResync`; `resizeThenCloseDoesNotResync`. Update `phoneCloseOfTheClaimPollsSoon`'s resize variant to the new behavior.
- [ ] **Step 2:** `cd macos/ElisCore && swift test --filter PhoneLinkSessionTests`: FAIL.
- [ ] **Step 3:** implement M2 and the resize resync.
- [ ] **Step 4:** M4. In `idleWriterSleepsAndEndsWithTerminate` take `idle` only after `#expect(await eventually { pty.writerIdle })`; the 500 ms wait before the negative assertion stays. In `pollSoonReadsTwice` replace `usleep(300_000)` with `harness.wait` on the state the following assertions read (the relay queue has taken the second read's answer); add a harness accessor if none shows it.
- [ ] **Step 5:** `swift test --filter PhoneLinkSessionTests`, `--filter PhoneLinkPtyTests`, `--filter PhoneLinkTerminalResyncTests`: PASS. **Step 6:** commit `fix(phone): a claim resize resyncs the watch channel; a claim names the watched pane`.

### Task 4: App: history of a covered remote pane

**Files:** Modify `macos/ElisCore/Sources/ElisCore/RemoteSession.swift`, `macos/Elis/Control/ControlServer+PaneLead.swift`, `ControlServer+SurfaceIO.swift` (the `session.text` path near line 315), `ControlServer+Attach.swift` (`liveSource` becomes internal); Test `macos/ElisCore/Tests/ElisCoreTests/RemoteSessionTests.swift` (or the suite that holds `screenCommand`), hosted `macos/ElisTests/PaneLeadTests.swift`

**Interfaces (Produces):**
- `RemoteSession.zmxScreenArguments(endpoint:daemon:all: Bool = false)` and `RemoteSession.screenCommand(host:endpoint:daemon:all: Bool = false, connectTimeout:)`: `all` appends `--all`. Additive defaults; no public symbol narrows.
- `PaneSource` gains `.remote(host: String, endpoint: ControlZmxEndpoint, daemon: String)`, returned for a covered pane whose `liveSource` is remote. `coveredCursor` and `coveredType` keep today's refusal text for it.
- `session.text` on that case runs the `screenCommand(all:)` argv on a plain `Thread` through an injected runner (`var remoteScreenRead: @Sendable ([String], TimeInterval) -> String?` on `ControlServer`, default a `Process` with a 5 s limit), parses with `ZmxScreen(output:)` and answers as the local daemon branch does. A second request for the same pane while one runs awaits the same read. A failed read answers `could not read the pane on <host>`.
- Every daemon-backed answer (local and remote) sets `columns` and `rows` from the `ZmxScreen`.

- [ ] **Step 1: failing tests:** `screenCommandAllAddsTheFlag`; hosted `coveredRemotePaneTextReadsItsDaemon` (a pane with a remote `liveSource` marked covered in `ZmxLeadBook`; the injected runner returns a recorded `zmx screen --all` output of an 47-column screen: `session.text` with `lines: 2000` is ok, its text is the output's, `columns == 47`, and the runner got an argv ending in `--all`); `coveredRemoteReadFailureIsRefused` (runner returns nil: the error names the host); `twoReadsOfOnePaneShareOneRun`; `coveredRemoteTypeStaysRefused`; `coveredLocalTextReportsTheDaemonGrid`.
- [ ] **Step 2:** `cd macos/ElisCore && swift test --filter RemoteSession`; `xcodebuild test ... -only-testing:ElisTests/PaneLeadTests`: FAIL.
- [ ] **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** commit `fix(control): session text reads a covered remote pane from its daemon`.

### Task 5: Session screen: claim at the first input, no button, chip

**Files:** Modify `mobile/lib/screens/session.dart`; Test `mobile/test/session_term_test.dart`; replace goldens `mobile/test/goldens/session_toolbar_{watch,lead,disabled}.png` with `session_toolbar_split.png` and `session_appbar_{pending,lead}.png`

**Interfaces:**
- Consumes: Task 2's `TermSession` API.
- Produces: `void _claim()` (no-op when `term == null`, a claim is asked or held, or the pane is in `_noClaim`; else arms the term at once, sets `_claimed`, then gives the fit back and calls `takeOver` with `_phoneGrid()`), `final _noClaim = <String>{}` (panes refused on this visit), `bool get _direct` (`term != null && !_noClaim.contains(pane)`). Tasks 5 and 6 call `_claim()` and read `_direct`, `_lead`, `_leading`.

Rules to implement:
- Every input entry (`_press`, `_paste`, `type`, `sendInput`, answer buttons) calls `_claim()` and, when `_direct`, hands the intent to the term (`key` with its `seq`, `text`, `paste`, `line`); a false result is reported with decision 4's text and the composer keeps its text. When not `_direct` the indirect code of today runs unchanged.
- `takeOver` is sent only after the fit's `session.grid` reset has answered, including a fit call that was in flight when the input came (the disabled button that guarded this is gone). A refused reset abandons the claim like a refusal.
- A refusal: report it once, add the pane to `_noClaim`, clear `_claimed`, send `takeUnsent()` through `session.type` one string at a time in order, then `_syncFit()`.
- `toggleLead` and the Take over segment are deleted. `_toolbar` renders nothing without a split.
- App bar: a private tag widget replaces the inline `via` container and is used twice: `Key('via')` as today, and `Key('lead')` reading `Taking the lead…` while `_lead && !_leading`, `Phone leads` while `_leading`, absent otherwise.
- The view rule is unchanged (`_termShown`, `_history`, `_pickView`): the history view shows on the main screen and keeps polling `session.text` while the phone leads.

- [ ] **Step 1: failing tests** (replace the `takeOver*`, `giveBack*` and toolbar-button tests): `lookingNeverClaims` (open, pump 5 s, pinch: no OPEN with `claim`); `keyBarKeyClaimsAndArrivesOnceAfterTheLead`; `composerSendClaimsAndSendsALine`; `pasteClaims`; `answerButtonClaims`; `inputDuringAFitInFlightClaimsAfterTheReset` (the claim OPEN follows the `session.grid` `reset` answer; the key arrives once); `refusedClaimReplaysTheQueueIndirectly` (refusal text shown once; `session.type` calls equal the queued strings in order; a later key goes through `session.type` with no new OPEN); `paneSwitchDropsThePendingQueue`; `pauseReleasesAndTheNextInputClaimsAgain`; `macTakeBackThenAKeyClaimsAgain` (one message `The computer took the lead back.`, then a key sends a new claim OPEN); `notLivePaneTypesIndirectly`; `chipShowsPendingThenLeadsThenClears`; `historyKeepsUpdatingWhileLeading` (`FakeVt.alt = false`, leading: `Key('screen')` stays, a later `session.text` answer replaces its text, no `Key('term')`); `historyScrollDoesNotClaim` (a drag on the history view while not leading: no claim OPEN, no wheel, no `session.scroll`); `toolbarIsEmptyWithoutASplit`; `refusedInputKeepsTheComposerText`. Goldens: split toolbar, app bar pending, app bar leading.
- [ ] **Step 2:** `flutter test --no-pub test/session_term_test.dart`: FAIL.
- [ ] **Step 3:** implement. **Step 4:** PASS; `flutter test --no-pub --update-goldens test/session_term_test.dart` once, and attach the three PNGs to the task report for the owner.
- [ ] **Step 5:** commit `feat(mobile): the phone leads at its first input; no Take over button`.

### Task 6: Auto-fit under automatic claims (I3); the keyboard resizes nothing

**Files:** Modify `mobile/lib/screens/session.dart` (`_syncFit`, `_syncTerm`, `_onTerm`, `dispose`); Test `mobile/test/session_term_test.dart`

**Interfaces:** Consumes Task 5's `_lead`. Produces `int _coveredTries` and `Timer? _fitRetry`.

Rules to implement:
- Delete `_refitAfter`, `_refitTimer` and `_refit`.
- `_coveredTries = 3` wherever a lead of this screen ends other than by a Mac take-back: a term closed while `_lead` (pause, pane switch), a term that ended while `_lead`, and a lead lost as `Disconnected` or revoked. It belongs to the screen, so it survives the term's replacement.
- In `_syncFit`, an `ElisError` on a fit (not a reset) with `_coveredTries > 0`: decrement, no report, `autoFit.wanted` unchanged, and `_fitRetry` calls `_syncFit` after 1 s. A fit that succeeds sets `_coveredTries = 0`. With none left, today's handling applies.
- `_phoneGrid()` computes its rows from `_height + MediaQuery.viewInsetsOf(context).bottom`, so the soft keyboard does not change the lead grid (the fit already runs only on a state change, not on a layout change). `_layoutLead` keeps its 300 ms settle and now fires only for a real layout change. The Term view already keeps the bottom rows in view at 1x.
- Unchanged: auto-fit stands down while `_lead`; a refusal resumes it at once; a Mac take-back sets `autoFit.wanted = false` for the visit.

- [ ] **Step 1: failing tests:** `coveredFitAfterOwnReleaseRetries` (lead, pause, resume; the fake refuses the first `session.grid` fit as covered and accepts the second: no message, the fit lands 1 s later); `staleGridAfterReleaseDoesNotStopTheFit` (the same with a Grid report of the lead size arriving before the first fit: still fitted after the retry); `fourthCoveredRefusalIsReported` (four refusals: one message, auto-fit off); `macTakeBackKeepsTheFitOff` (no `session.grid` fit for the rest of the visit, also after a later claim ends by pause and resume); `refusedClaimResumesTheFit`; `keyboardDoesNotResizeTheLead` (leading; a 300 px bottom view inset appears and goes, pump 1 s each: no RESIZE on the claim, no `session.grid`, the last grid row is still on screen above the keyboard); `keyboardDuringThePendingClaimChangesNothing` (the claim OPEN carries the rows of the full height); `rotationResizesTheLeadOnce` (the surface size swaps width and height: one RESIZE after 300 ms, and the emulator takes the size only from the Grid that follows). These replace `keyboardInsetResizesTheLead` and `keyboardDuringThePendingClaimResizesTheLead`.
- [ ] **Step 2:** FAIL. **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** commit `fix(mobile): a covered fit retries; the keyboard no longer resizes the program`.

### Task 7: Taps and scroll

**Files:** Modify `mobile/lib/terminal/term_gestures.dart`, `mobile/lib/screens/session.dart` (`_termView`, `_wheel`); Test `mobile/test/term_gestures_test.dart`, `mobile/test/session_term_test.dart`

**Interfaces:** Consumes `TermSession.click`, `_claim()`, `_direct`. Produces `TermGestures.onTap: VoidCallback?` (a single tap; never fires for a double tap or after a pinch).

Rules to implement:
- A single tap anywhere in the terminal box, on the Term view or the history view (`SelectableText.onTap`): `_claim()`, and when the touch is on the cursor row (decisions 24 and 25) `_showKeyboard()` (a hook Task 8 fills; empty here). Produces `bool _onCursorRow` for that test. On the Term view, when `_leading` and the touch is on a grid cell, also `click` at that cell with zoom and pan undone, as `_wheel` maps it but without clamping. When not `_direct` a tap sends nothing; it still opens the keyboard on the cursor row when a live snapshot exists.
- A one-finger drag on the history view scrolls the history as today and claims nothing.
- A one-finger scroll: when `_direct`, `_claim()` and, once `_leading`, the wheel; notches before the lead are dropped. When not `_direct`, `session.scroll` as today.
- A finger that was down when the Mac took the lead back scrolls and claims nothing until a new pointer goes down.

- [ ] **Step 1: failing tests:** gestures: `tapFiresOnce`, `doubleTapDoesNotFireTap`, `pinchDoesNotFireTap`. Screen: `tapClicksTheCellUnderTheFinger` (leading, `FakeVt` records `encodeClick(col, row)` for a tap at a known cell); `zoomedTapHitsTheCellUnderTheFinger`; `tapOutsideTheGridClaimsWithoutAClick` (a claim OPEN, no click after LEAD); `tapOnTheHistoryViewClaimsWithoutAClick`; `tapClaimsAndIsNotReplayed` (a tap before the lead sends a claim OPEN and no click after LEAD); `tapWithMouseOffClaimsAndSendsNothing` (empty `encodeClick`: a claim OPEN, no bytes on the claim after LEAD); `tapOnAnIndirectPaneSendsNothing` (no `session.type`, no OPEN); `scrollClaimsThenSendsWheel`; `scrollOnARefusedPaneUsesSessionScroll`; `dragInFlightAtTakeBackDoesNotReclaim` (a drag continues after the take-back: no OPEN; lift, touch and drag: a new claim OPEN); `zoomAndDoubleTapDoNotClaim`.
- [ ] **Step 2:** `flutter test --no-pub test/term_gestures_test.dart test/session_term_test.dart`: FAIL.
- [ ] **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** commit `feat(mobile): a tap clicks in the program; a scroll claims the lead`.

### Task 8: Direct typing from the soft keyboard

**Files:** Create `mobile/lib/terminal/term_keyboard.dart`; Modify `mobile/lib/screens/session.dart`; Test `mobile/test/term_keyboard_test.dart` (new), `mobile/test/session_term_test.dart`

**Interfaces:**
- Consumes: Task 5's routing (`_claim()`, `_direct`, `TermSession.key/text/paste`), Task 7's `_showKeyboard()` hook.
- Produces:

```dart
/// A hidden input that turns soft-keyboard edits into terminal input.
class TermKeyboard extends StatefulWidget {
  const TermKeyboard({super.key, required this.focus, required this.onKey, required this.onText, required this.onPaste});
  final FocusNode focus;
  final void Function(VtKey key, int mods) onKey;
  final void Function(String text) onText;
  final void Function(String text) onPaste;
}
```

Rules to implement:
- The widget is a zero-size `EditableText`-backed field placed in the session screen's stack: `keyboardType: TextInputType.visiblePassword`, `autocorrect: false`, `enableSuggestions: false`, `enableIMEPersonalizedLearning: false`, `TextInputAction.none`, no visible caret or selection handles.
- Its value is always two spaces with the caret at the end. On a change with no active composing range: a shorter value sends `onKey(VtKey.backspace, 0)` once per removed character; a longer value takes the inserted text: `\n` alone is `onKey(VtKey.enter, 0)`; a newline inside it or more than 64 characters is `onPaste`; anything else is `onText`. Then the value is reset. While a composing range is active nothing is sent; its text goes out as `onText` when the range ends.
- The field's action (the keyboard's Enter) is `onKey(VtKey.enter, 0)` and keeps the focus.
- Key events that reach the focus (a hardware keyboard, an IME's arrow keys): arrows, Home, End, Page Up, Page Down, Tab, Escape, Backspace and Enter map to their `VtKey` with shift, ctrl and alt as `mods`; ctrl with a letter of the `keys` table maps to that key. Other key events are left to the text input.
- Screen: `_showKeyboard()` is called only by Task 7's tap on the cursor row. It requests the field's focus and asks the platform to show the keyboard (`SystemChannels.textInput.invokeMethod('TextInput.show')` when it already has the focus). Nothing hides it but the user; a pane switch keeps it. `onKey`, `onText` and `onPaste` route exactly as `_press`, `type` and `_paste` do: `_claim()`, then the term when `_direct`, else `session.type` with the key's `seq` (Backspace is `\x7f`), through one serial chain so indirect keystrokes keep their order.
- The keyboard showing resizes nothing (Task 6).

- [ ] **Step 1: failing tests.** Widget (`term_keyboard_test.dart`, driving `tester.testTextInput`): `aLetterIsText` (`a` typed: `onText('a')`, value back to two spaces); `backspaceIsAKey` (value shortened by one: one `onKey(backspace)`; by two: two); `backspaceRepeats` (three deletions in a row: three keys); `enterActionIsAKeyAndKeepsFocus`; `ukrainianCommitIsText` (`привіт` inserted at once: `onText('привіт')`); `composingSendsOnlyAtItsEnd` (composing `при`, then committed `привіт`: one `onText('привіт')`); `aLargeEditIsAPaste` (65 characters: `onPaste`; 64: `onText`; `a\nb`: `onPaste`); `arrowKeyEventIsAKey` (`LogicalKeyboardKey.arrowUp`: `onKey(arrowUp, 0)`; with shift: `mods == vtShift`); `keyboardIsAskedWithoutSuggestions` (the client configuration: `visiblePassword`, `autocorrect` false, `enableSuggestions` false). Screen: `tapOnTheCursorRowOpensTheKeyboard` (`FakeVt` cursor visible at row 5: a single tap on a cell of row 5, in a column away from the caret, makes `tester.testTextInput.isVisible`; not after a double tap); `tapOffTheCursorRowOnlyClicks` (a tap on row 2: a click on the claim, the keyboard not visible); `hiddenCursorNeverOpensTheKeyboard` (`cursorVisible` false: a tap on the cursor's row clicks, no keyboard); `historyViewUsesTheLiveCursorRow` (`FakeVt.alt = false`, cursor visible: a tap on the last text line of `Key('screen')` and one in the empty area below it open the keyboard; a tap on an earlier line does not; with the cursor hidden, or the history scrolled up, none does); `keyBarAndComposerWorkWithAHiddenCursor`; `typedKeysGoToTheClaim` (tap on the cursor row, LEAD, type `l`, `s`, Enter: the claim got `l`, `s`, the encoded Enter, in order, and no `session.type`); `typedKeysOnANonLivePaneUseSessionType` (calls `l`, `s`, `\r`, in order, one at a time); `cursorRowTapAfterHidingShowsTheKeyboardAgain`; `tappingTheProgramKeepsTyping` (with the keyboard up, a tap on a cell off the cursor row: a click, the keyboard still visible, the next letter reaches the claim); `keyboardShownByATapDoesNotResize` (no RESIZE, no `session.grid`); `composerFocusTakesTypingUntilTheNextTap`.
- [ ] **Step 2:** `flutter test --no-pub test/term_keyboard_test.dart test/session_term_test.dart`: FAIL.
- [ ] **Step 3:** implement. **Step 4:** PASS.
- [ ] **Step 5:** commit `feat(mobile): a tap opens the keyboard and keys go straight to the program`.

### Task 9: Docs

**Files:** Modify `site/docs.html` (lines near 849 and 1113 to 1116), `mobile/README.md`, `linux/README.md` (phone section), `.claude/rules/control-api.md` (Take over section, line near 2640), `macos/ARCHITECTURE.md`, `plugins/elis/skills/elis/SKILL.md` and `reference.md`, the spec (its "Modes: Watch and Take over" section and decision 4, marked superseded by this plan). `site/commands.html` is checked and left alone unless it names the button.

Content, stated once per surface in that surface's own style:
- `site/docs.html`: replace the Take over item with a Direct input item: the phone takes the pane's lead at the first key, send, paste, scroll or tap; the Mac shows *In use on your phone*; the chip `Phone leads`; a tap on the line with the text cursor opens the keyboard, whose keys go straight to the program; a tap elsewhere clicks where the program tracks the mouse; the composer stays for long text, voice and autocorrect; a shell still shows its history while the phone leads, on remote rows too; leaving, switching panes or pausing returns the lead; a key on the Mac's cover takes it back and the next input on the phone takes it again; opening a session only to read never covers the Mac; a pane that is not Live, or a host that cannot hand over the lead, is typed into through the Mac. Update the Gestures item (tap) and the Fit item (`after the Mac takes a pane back, the phone stops fitting until you leave the session`). No mechanism in the guide.
- Rules and `ARCHITECTURE.md`: the queue until the leader report, the 20 ms gap, the claim by watched pane id, the covered-fit retry, the resync after a claim RESIZE and the phone sizing from RESYNC and GRID, and `session.text` reading a covered remote pane from its daemon (`control-api.md`'s Pane lead section owns that contract; `site/commands.html` only if it states the old refusal). The guide says once that the keyboard does not resize the program. Keep `session attach --claim`, `phoneLead` and the events as they are.
- Skill: reword "Take over" mentions to "the phone leads a pane"; triggers stay.

- [ ] **Step 1:** edit. **Step 2:** `grep -rniE "take over|give back" site mobile/README.md linux/README.md plugins macos/ARCHITECTURE.md .claude/rules`: only the CLI's own wording and the zmx role sense remain; list each remaining hit in the report.
- [ ] **Step 3:** commit `docs: phone direct input`.

### Task 10: Gates and device checks

- [ ] **Step 1 (subagent, once each):** `cd macos/ElisCore && swift test`; `make test-app`; `make lint`; in `mobile/`: the temporary `sdk:` constraint and `flutter pub get` per `CLAUDE.md`, `flutter analyze --no-pub`, `flutter test --no-pub`, then restore `pubspec.yaml` and `pubspec.lock`; `lsappinfo list | grep -A4 elis.debug`.
- [ ] **Step 2 (controller only, the owner's phone over Bluetooth, `adb install -r`, never uninstall):**
  1. Open a Live session and only read for 10 s: the Mac shows no cover, `phoneLead` is absent.
  2. Press a key: the chip reads `Phone leads`, the Mac's cover shows, the key arrived once.
  3. Composer text then send into Claude Code: the prompt is submitted, not left as a paste (I1; Bluetooth can merge the two frames).
  4. Type in a shell: the history view shows the typing and still scrolls while the phone leads.
  4a. Tap Claude Code's input line and a shell's prompt line: Gboard opens; a tap on any other row does not open it, and neither does a tap in a program that hides its cursor (`top`). Gboard shows without a suggestion strip; type Latin and Ukrainian letters, Backspace (also held), Enter, and a clipboard insert from the keyboard; each lands once in Claude Code's input box. Tap a TUI element with the keyboard up: it clicks and typing still works. Hide the keyboard, tap: it returns.
  5. Tap a button or a line in a mouse-tracking program (`htop`, `vim` with `:set mouse=a`): the click lands on that cell; the same zoomed in.
  6. A key on the Mac's cover: one message on the phone; the next key on the phone leads again; the grid is not refitted.
  7. Pause and resume, and switch panes and back within a second: the fit returns without a message (I3).
  8. Leading Claude Code, show and hide the keyboard five times while it prints: no junk on the screen, and the Mac's cover reports the same grid throughout. Then rotate the phone and back: the screen is clean at each grid.
  9. A remote row, if the owner's Elis has one: steps 2, 4 and 7; step 4 is the check of Task 4. Otherwise report it as not checked.
