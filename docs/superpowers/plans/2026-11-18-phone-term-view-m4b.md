# Phone Term view (M4b) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Android phone app shows a Live pane as a real, coloured terminal in Watch mode, fed by the M4a relay mux and drawn by libghostty-vt.

**Architecture:** A repo script builds libghostty-vt at the pinned `GHOSTTY_REV` with a small C shim into `libvtshim.so` (Android) and `libvtshim.dylib` (host, for tests). Dart binds the shim with `dart:ffi`. A mux client upgrades the existing connection with `{"mux":1}`, keeps control requests and events working over channels 0 and 1, and opens one vt channel per watched pane. A painter with a per-row cache draws the emulator's snapshot. The session screen uses the Term view for Live panes and keeps today's text view otherwise.

**Tech Stack:** Flutter (Dart 3.13, Android only), `dart:ffi` + `package:ffi`, C (NDK clang 28.2.13676358), zig@0.17, libghostty-vt.

**Spec:** `docs/superpowers/specs/2026-11-18-phone-terminal-stream-design.md` ("Phone terminal engine", "Session view", "Protocol model"). Relay contract: `.claude/rules/control-api.md` (relay mux paragraph, M4b wire contract). Spike: `.superpowers/spikes/spike-vt/` in the main checkout `/Users/n.savchenko/IdeaProjects/elis` (`shim/vtshim.c`, `app/lib/vt.dart`, `app/lib/main.dart` painter, `REPORT.md` build commands, `rec/` recordings with tmux references). Copy what you use into the repo; the spike folder is git-ignored scratch.

Out of scope (later milestones): the Chat/Text/Term switcher and Text mode (M6), Take over, input encoders, RESIZE, LEAD, pinch zoom/pan and Fit to phone on the Term view (M5), Bluetooth end-to-end on the emulator (M5), iOS.

## Global Constraints

- Phone code under `mobile/`. Tests: `cd mobile && flutter test --no-pub` (local Dart 3.13.2 vs the pubspec floor ^3.13.7). Lint: `flutter analyze --no-pub`, zero issues.
- `minSdk = 35`, NDK `28.2.13676358`, ABIs `arm64-v8a` and `x86_64` (emulator).
- `GHOSTTY_REV` is read from `macos/scripts/setup.sh` (one source of truth); zig is `zig@0.17` (`GHOSTTY_ZIG_FORMULA`). libghostty-vt builds unpatched (spike) — do not apply `macos/scripts/ghostty-patches/`.
- Built `.so`/`.dylib` files are not committed: `mobile/android/app/src/main/jniLibs/` and `mobile/build/vtshim/` are git-ignored and produced by the script with a stamp (rev + shim digest), like `.ghostty-build-stamp`.
- Wire rules from control-api.md, verbatim in behaviour: channel ids start at 2 and are used once per link; GRID always follows RESYNC; a `{"dropped":N}` or `{"gap":true}` line means re-read `tree`; an `OPENED {"error":"channel already open"}` for a channel the phone has open means "duplicate refused", the stream continues; CLOSE discards undelivered DATA and gets no answer; OPENED `{"error":"revoked"}` is followed by the link closing; the phone sends CREDIT for the bytes it has consumed, at least once per window; RESYNC resets the emulator and the phone's credit accounting.
- Watch mode only: the phone never sends DATA on a vt channel, never RESIZE; terminal query replies the emulator would produce are dropped.
- Delegated agents receive verbatim: "never execute `elis`/`elisctl` against the default socket, never launch or quit the app, static reading only." Nothing here needs a running Mac app; emulator runs are allowed only on an emulator the agent starts itself.
- Stage by explicit path; `.superpowers/` is not ignored by git in this repo except `sdd/` and `spikes/`.

## Decisions taken in this plan

- **Host build for tests:** the script also builds the shim for the host (`zig build -Demit-lib-vt` native, then `cc -shared`) into `mobile/build/vtshim/libvtshim.dylib`; Dart unit tests load it by that path and skip with a clear reason when it is missing. Android loads `libvtshim.so` from jniLibs.
- **Credit:** after the emulator has consumed a DATA payload, the phone sends CREDIT for its byte count, batched to at most one CREDIT per frame received or per 16 KiB, whichever comes first.
- **Upgrade fallback:** if the relay does not answer `{"mux":1}` with the upgrade answer within 5 s (an older Mac), the phone stays on the line protocol and the session screen keeps the text view.
- **Rendering:** the Term view draws the daemon's grid scaled to the screen width (no zoom yet); colours come from the emulator; the background and default foreground from `theme.dart` (`C.term`, `C.termText`); fonts `JetBrainsMono` then `NotoSansSymbols2`; emoji clusters use the platform emoji font. Mode 2026 holds painting while set, released after at most 1 s.
- **Input in Watch:** the existing input path of the session screen (`session.type`) stays; it goes over channel 0.

## Review Focus

1. The relay closes the link (Mac app quits, Wi-Fi drops) while a pane is watched: the screen shows a clear "disconnected" state and reconnects through the existing reconnect logic; no exception, no frozen frame. → Task 4 `linkLossClosesEveryChannel`, Task 5 `disconnectShowsReconnect`.
2. A flood (`yes`, a build log): RESYNC/GRID arrive; the view resets and shows the latest screen; memory stays bounded; the UI thread stays responsive. → Task 4 `resyncResetsTheEmulator`, Task 3 `rowCacheRepaintsOnlyChangedRows`.
3. A pane that is not Live, or a relay refusal (`session predates this version…`, `too many open panes`, `session not realized`): the text view stays, with the reason shown once. → Task 5 `refusalFallsBackToText`.
4. Leaving the session screen or backgrounding the app closes the vt channel (CLOSE sent) so the Mac's viewer count drops. → Task 5 `leavingClosesTheChannel`.
5. Wide and combined characters (CJK, emoji ZWJ, combining marks) draw in the right cells. → Task 3 `paintsWideAndCombinedCells` (from the spike's recordings).

---

### Task 1: Native build: libvtshim for Android and host

**Files:**
- Create: `mobile/native/vtshim.c` (from the spike, plus `vts_mode(v, mode)` reading a DEC private mode, used for 2026 and the alternate screen), `mobile/tool/build-vtshim.sh`
- Modify: `mobile/.gitignore` (jniLibs output, `build/vtshim/`, stamp), `mobile/README` or the closest existing build doc (one line: run the script before `flutter run`)
- Test: `mobile/tool/build-vtshim.sh --check` (prints the outputs and exits 0)

**Interfaces:** Produces `libvtshim.so` in `mobile/android/app/src/main/jniLibs/{arm64-v8a,x86_64}/` and `mobile/build/vtshim/libvtshim.dylib`; C API: `vts_new(cols, rows, scrollback)`, `vts_free`, `vts_write(v, data, len)`, `vts_resize(v, cols, rows)`, `vts_reset(v)`, `vts_mode(v, mode) -> int`, `vts_snapshot(v, out, cap) -> int` (the spike's cell layout: `cellWords = 5`, `hdrWords = 16`).

- [ ] **Step 1:** write the script: read `GHOSTTY_REV` from `macos/scripts/setup.sh`; shallow-fetch ghostty into a cache dir; `zig build -Demit-lib-vt -Doptimize=ReleaseFast` per target (REPORT.md commands); link the static `.a` with the shim (`-Wl,--whole-archive`, `-z max-page-size=16384`, `-s`); stamp; `--check`.
- [ ] **Step 2:** run it; expected: both `.so` files and the `.dylib` exist; `nm -D libvtshim.so | grep vts_` lists every function.
- [ ] **Step 3:** commit `feat(mobile): build libvtshim from the pinned ghostty`.

### Task 2: Dart binding

**Files:** Create `mobile/lib/terminal/vt.dart`; Modify `mobile/pubspec.yaml` (add `ffi:` explicitly); Test `mobile/test/vt_test.dart`, fixtures `mobile/test/fixtures/vt/` (two short recordings from the spike's `rec/` with their reference text)

**Interfaces:** `class Vt { Vt(int cols, int rows, {int scrollback = 1000}); void write(Uint8List bytes); void resize(int cols, int rows); void reset(); bool mode(int mode); VtSnapshot snapshot(); void dispose(); }`, `class VtSnapshot { int cols, rows, cursorX, cursorY; bool cursorVisible; List<VtRow> rows; }` with per-cell text, fg/bg (null = default), flags (bold, italic, underline, inverse, wide). Library opened by `Vt.open(path)`: Android `libvtshim.so`, tests `build/vtshim/libvtshim.dylib`.

- [ ] **Step 1: failing tests:** `writesTextIntoCells`; `replayMatchesReference` (each fixture's snapshot text equals its reference row by row); `resizeKeepsTheCursorInside`; `resetClears`; `synchronizedOutputModeIsReported` (`ESC[?2026h` → `mode(2026)`); `alternateScreenIsReported`. Skip with a reason when the dylib is missing.
- [ ] **Step 2–4:** `flutter test --no-pub test/vt_test.dart`: FAIL, implement, PASS.
- [ ] **Step 5:** commit `feat(mobile): libghostty-vt binding`.

### Task 3: Terminal painter

**Files:** Create `mobile/lib/terminal/terminal_view.dart`, `mobile/lib/terminal/row_cache.dart`; Test `mobile/test/terminal_view_test.dart`

**Interfaces:** `class TerminalView extends StatefulWidget { TerminalView({required VtSnapshot? snapshot, required bool hold}); }` draws the grid scaled to the width; `class RowCache { ui.Picture rowPicture(int y, VtRow row, CellMetrics m); }` keyed by row content hash and metrics.

- [ ] **Step 1: failing tests:** `rowCacheRepaintsOnlyChangedRows` (two snapshots differing in one row → one new picture); `paintsWideAndCombinedCells` (golden widget test from a spike fixture with CJK, emoji ZWJ, combining marks); `cursorDrawnAtItsCell`; `holdKeepsTheLastFrame` (hold true → no repaint; released after 1 s).
- [ ] **Step 2–4:** FAIL, implement (port the spike painter: ASCII runs batched, wide/cluster cells alone, combining marks never joined to ASCII runs, emoji font first for VS16/ZWJ/pictographs), PASS.
- [ ] **Step 5:** commit `feat(mobile): terminal painter with a row cache`.

### Task 4: Mux client

**Files:** Create `mobile/lib/link/mux.dart`; Modify `mobile/lib/client.dart` (expose the raw link to the mux after the upgrade; `call` goes through channel 0 when upgraded); Test `mobile/test/mux_test.dart` (a fake relay on a `StreamController`, frames from the M2 codec)

**Interfaces:** `class Mux { static Future<Mux?> upgrade(Connection c, {Duration timeout = const Duration(seconds: 5)}); Future<Map<String, dynamic>> call(String cmd, {String? target, Map<String, dynamic>? args}); Stream<Map<String, dynamic>> get events; Future<VtChannel> open(String target, {String? pane}); Stream<void> get closed; }`, `class VtChannel { Stream<VtEvent> get events; void consumed(int bytes); Future<void> close(); }` with `VtEvent` = `Opened(cols, rows)` | `Data(bytes)` | `Grid(cols, rows)` | `Resync()` | `Closed(reason)`.

- [ ] **Step 1: failing tests:** `upgradeSwitchesToFrames`; `noAnswerKeepsTheLineProtocol` (5 s, fake clock); `controlCallsMatchById`; `eventsDroppedOrGapAskForATreeReread`; `openStreamsData`; `channelIdsAreUsedOnce`; `duplicateRefusalDoesNotCloseALiveChannel`; `creditFollowsConsumption` (at most one CREDIT per frame or per 16 KiB); `resyncResetsTheEmulator` (a Resync event, credit accounting reset); `closeIsNotAnswered`; `revokedClosesTheLink`; `linkLossClosesEveryChannel`.
- [ ] **Step 2–4:** FAIL, implement, PASS. Also run `test/link_test.dart` (golden vectors) to confirm the codec is unchanged.
- [ ] **Step 5:** commit `feat(mobile): relay mux client`.

### Task 5: Session screen uses the Term view for Live panes

**Files:** Create `mobile/lib/terminal/term_session.dart` (owns a `Vt`, a `VtChannel`, the hold timer and the snapshot stream); Modify `mobile/lib/screens/session.dart` (choose Term for `backedByZmx` panes when a mux exists, else today's text view; stop the 700 ms `session.text` poll while Term is active), `mobile/lib/model.dart` (create the mux after connect); Test `mobile/test/session_term_test.dart` (widget tests with a fake mux)

**Interfaces:** consumes Task 2 `Vt`, Task 3 `TerminalView`, Task 4 `Mux`/`VtChannel`.

- [ ] **Step 1: failing tests:** `livePaneShowsTheTerminal`; `refusalFallsBackToText` (reason shown once); `disconnectShowsReconnect`; `leavingClosesTheChannel` (route pop and app pause both send CLOSE); `splitToggleReopensTheOtherPane`; `notLivePaneKeepsTheTextView`.
- [ ] **Step 2–4:** FAIL, implement, PASS.
- [ ] **Step 5:** commit `feat(mobile): Term view for Live panes`.

### Task 6: Gates and docs

- [ ] `cd mobile && flutter analyze --no-pub` (0 issues), `flutter test --no-pub` (all pass), `flutter build apk --debug --no-pub` after `tool/build-vtshim.sh` (the APK contains `lib/arm64-v8a/libvtshim.so` and `lib/x86_64/libvtshim.so`: check with `unzip -l`).
- [ ] Docs: the spec's "Where the code goes" points at `mobile/native/`, `mobile/tool/build-vtshim.sh`, `mobile/lib/terminal/`, `mobile/lib/link/mux.dart`; `site/docs.html` phone section: one bullet that a Live session shows as a live terminal (now true end to end). Commit `docs: phone Term view`.
