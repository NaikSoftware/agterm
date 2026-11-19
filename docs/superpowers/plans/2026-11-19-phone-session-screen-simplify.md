# Phone Session Screen Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone's session screen takes a Live pane's lead on open, hides the composer behind a remembered menu toggle, shows the status as a shape only, and drops the split action.

**Architecture:** All changes are in the Flutter app under `mobile/`. The lead-on-open reuses `_SessionScreenState._claim()` in `mobile/lib/screens/session.dart`, called when a pane's `TermSession` is created. The composer preference follows `BluetoothPref` in `mobile/lib/model.dart`.

**Tech Stack:** Flutter/Dart, flutter_test widget tests with the `Harness` fake relay in `mobile/test/session_term_test.dart`.

**Spec:** `docs/superpowers/specs/2026-11-19-phone-session-screen-simplify-design.md`

## Global Constraints

- Run from `mobile/`: `flutter analyze --no-pub` and `flutter test --no-pub`. Never `flutter test integration_test`.
- Until the local Flutter SDK matches `pubspec.yaml`, set a temporary `sdk:` constraint and run `flutter pub get`; restore `pubspec.yaml` and `pubspec.lock` before every commit.
- No attribution lines (no `Co-Authored-By`, no `Claude-Session`) in commits.
- The session view stays edge to edge: no new padding or chrome around the terminal.
- Never execute `elis`/`elisctl` against the default socket, never launch or quit the app, static reading only.
- Comments are rare, one line, only for a non-obvious why. Test comments are rare and one line.

## Review Focus

- A Mac take-back during a visit, then a pause/resume or a reconnect: the phone must not grab the lead again until the user's next input (pinned in Task 3: `macTakeBackIsNotReclaimedOnResume`).
- A pane whose claim was refused (`_noClaim`) must not loop on auto-claims (Task 3: `refusedPaneDoesNotClaimOnReopen`).
- The claim on open must send the phone's grid from the laid-out screen, not a zero size (Task 3: `openClaimsWithThePhoneGrid`).
- Showing or hiding the composer while leading changes the box height: the program gets one resize to the new grid (Task 2: `composerToggleWhileLeadingResizesOnce`).
- A non-Live pane keeps today's indirect typing with the composer hidden: soft keys and the key row still type through `session.type` (Task 2: `hiddenComposerStillTypesIndirectly`).

---

### Task 1: Status shape only, no split action

**Files:**
- Modify: `mobile/lib/screens/session.dart:585` (app bar `StatusChip`)
- Modify: `mobile/lib/screens/home.dart:797-821` (`StatusChip`: delete if no caller remains)
- Modify: `mobile/lib/screens/actions.dart:56-57` (split item)
- Test: `mobile/test/session_term_test.dart`, `mobile/test/home_test.dart`

**Interfaces:**
- Produces: the app bar status is `Semantics(label: statusLabel(s.status), child: StatusShape(s.status, size: 10, blink: s.blink))` with `key: const Key('status')`.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('statusShowsOnlyItsShape', (t) async {
  // Harness tree with status 'idle'
  expect(find.byKey(const Key('status')), findsOneWidget);
  expect(find.text('Idle'), findsNothing);
  expect(find.bySemanticsLabel('Idle'), findsOneWidget);
});
testWidgets('sessionActionsHaveNoSplit', (t) async {
  // open the sheet with the sessionMenu button
  expect(find.text('Split side by side'), findsNothing);
  expect(find.text('Hide split pane'), findsNothing);
});
```
Put `sessionActionsHaveNoSplit` where the actions sheet is already tested (grep `Split side by side` in `mobile/test/`); change any test that expects the split item.

- [ ] **Step 2: Run them to verify they fail**

Run: `flutter test --no-pub test/session_term_test.dart --plain-name statusShowsOnlyItsShape`
Expected: FAIL, `Idle` text found.

- [ ] **Step 3: Implement** the shape in the app bar, remove the split `_item`, delete `StatusChip` if unused.

- [ ] **Step 4: Run the tests to verify they pass**, plus `flutter analyze --no-pub`.

- [ ] **Step 5: Commit** `feat(mobile): the session shows its status as a shape and has no split action`

---

### Task 2: Composer hidden by default, remembered toggle

**Files:**
- Modify: `mobile/lib/model.dart` (new `ComposerPref` beside `BluetoothPref`)
- Modify: `mobile/lib/main.dart:82` (load it beside `BluetoothPref.load()`)
- Modify: `mobile/lib/screens/actions.dart:91` (`showSessionActions`)
- Modify: `mobile/lib/screens/session.dart` (build `_composer()` only when shown; pass the toggle)
- Test: `mobile/test/session_term_test.dart`

**Interfaces:**
- Produces:
  - `class ComposerPref { static bool shown = false; static Future<void> load(); static Future<void> set(bool v); }`, storage key `showComposer`, values `on`/`off`, same `FlutterSecureStorage` pattern as `BluetoothPref`.
  - `showSessionActions(BuildContext context, ElisModel m, Session s, {VoidCallback? onClosed, VoidCallback? onComposer})`: when `onComposer != null` the sheet shows `Show composer` or `Hide composer` (key `composerToggle`, icon `Icons.keyboard_outlined`); a tap pops the sheet, calls `ComposerPref.set(!ComposerPref.shown)`, then `onComposer()`. The list's long press passes no `onComposer`, so it has no such item.
- The key row (`_keyBar()`) and prompt answers stay in every case.

- [ ] **Step 1: Write the failing tests**

```dart
testWidgets('composerIsHiddenByDefault', ...)   // ComposerPref.shown = false: no 'Type, then send with Enter', key row present
testWidgets('menuShowsTheComposerAndRemembers', ...) // tap sessionMenu, composerToggle 'Show composer' -> composer visible, ComposerPref.shown true; reopen the sheet: 'Hide composer'
testWidgets('listSheetHasNoComposerToggle', ...)   // showSessionActions without onComposer: find.byKey(Key('composerToggle')) findsNothing
testWidgets('composerToggleWhileLeadingResizesOnce', ...) // leading, show the composer: exactly one claim RESIZE, to the new _phoneGrid
testWidgets('hiddenComposerStillTypesIndirectly', ...) // non-Live pane, key row Up: one session.type with ESC[A
```
Existing tests that use the composer set `ComposerPref.shown = true` in their setup; reset it to `false` in `tearDown`. `ComposerPref.set` must not touch secure storage in tests: write `shown` first and swallow a storage failure (`.catchError((_) {})` at the caller, as `main.dart` does for `BluetoothPref`).

- [ ] **Step 2: Run to verify they fail**

Run: `flutter test --no-pub test/session_term_test.dart --plain-name composerIsHiddenByDefault`
Expected: FAIL, composer found.

- [ ] **Step 3: Implement** `ComposerPref`, the sheet item, and `if (ComposerPref.shown) _composer()` in the screen's column; `onComposer: () => setState(() {})`.

- [ ] **Step 4: Run the whole file and analyze**

Run: `flutter test --no-pub test/session_term_test.dart && flutter analyze --no-pub`
Expected: all pass, no issues.

- [ ] **Step 5: Commit** `feat(mobile): the composer is hidden until the session menu shows it`

---

### Task 3: Take the lead on open

**Files:**
- Modify: `mobile/lib/screens/session.dart` (`_syncTerm`, `_onTerm`'s `leadLost` branch, the input handlers)
- Test: `mobile/test/session_term_test.dart`

**Interfaces:**
- Consumes: `_claim()`, `_noClaim`, `_lead`, `term`, `TermSession.leadLost`.
- Produces: `bool _macTookBack = false;` on the state — set when `leadLost` reports a Mac take-back (the branch that sets `autoFit.wanted = false`), cleared by any user input (every handler that calls `_claim()` today).

Rule: when `_syncTerm` creates a new `TermSession`, the screen claims it after the current frame (`WidgetsBinding.instance.addPostFrameCallback`), unless `_macTookBack` or `_noClaim.contains(pane)`, and only if that term is still `term` and mounted. A claim from input keeps working as today. Release paths (leave, pause, pane switch, link loss) are unchanged.

- [ ] **Step 1: Write the failing tests; rewrite `lookingNeverClaims`**

```dart
testWidgets('openClaimsWithThePhoneGrid', ...)        // start, opened: one claim OPEN; after LEAD, chip 'Leading'; its RESIZE grid == the fit's phone grid (as _lead(h) checks today)
testWidgets('lookingDoesNotClaimTwice', ...)          // after the open claim, a pinch adds no claim
testWidgets('pauseReleasesAndResumeClaimsAgain', ...) // pause: claim closed; resume: a new claim OPEN without input
testWidgets('paneSwitchClaimsTheNewPane', ...)         // tree with a Live split: rightPane tap -> left claim closed, right claim OPEN
testWidgets('macTakeBackIsNotReclaimedOnResume', ...)  // take-back, pause, resume: no new claim; then a key: one claim
testWidgets('refusedPaneDoesNotClaimOnReopen', ...)    // claim refused -> _noClaim; pause/resume: no claim OPEN
testWidgets('notLivePaneDoesNotClaim', ...)            // pane not in livePanes: no claim, no 'lead' chip
```
Update the existing claim tests (`keyBarKeyClaimsAndArrivesOnceAfterTheLead`, `composerSendClaimsAndSendsALine`, `pasteClaims`, `answerButtonClaims`, `inputDuringAFitInFlightClaimsAfterTheReset`, `pauseReleasesAndTheNextInputClaimsAgain`, `chipShowsPendingThenLeadsThenClears`, `historyScrollDoesNotClaim`, `pauseDuringThePendingClaim`, and any other that counts claims from zero) so they start from the open claim: assert on what the input adds, not on the claim's existence. Keep each test's intent; delete one only when an open claim makes it meaningless, and name it in the report.

- [ ] **Step 2: Run to verify the new tests fail**

Run: `flutter test --no-pub test/session_term_test.dart --plain-name openClaimsWithThePhoneGrid`
Expected: FAIL, no claim OPEN.

- [ ] **Step 3: Implement** the post-frame claim in `_syncTerm` and `_macTookBack`.

- [ ] **Step 4: Run all mobile tests and analyze**

Run: `flutter test --no-pub && flutter analyze --no-pub`
Expected: all pass (one known skip), no issues.

- [ ] **Step 5: Commit** `feat(mobile): opening a Live pane takes its lead`

---

### Task 4: Docs

**Files:**
- Modify: `site/docs.html` (phone section), `plugins/elis/skills/elis/` (where the phone lead is described), `mobile/README.md` if it describes the composer or the lead.

- [ ] **Step 1:** `grep -rn -iE "looking never|first input|take over|composer|Split side by side" site/docs.html plugins/elis/skills/elis mobile/README.md` and update each hit to: opening a Live pane leads; leave, pause, pane switch and link loss release; a Mac key takes it back and the phone leads again at its next input; the composer is shown from the session's ⋯ menu; no split action on the phone. Short, user-facing, no mechanism.
- [ ] **Step 2:** Commit `docs: the phone leads a session it opens`
