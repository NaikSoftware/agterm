# Pages on the Phone (Part 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A page a session opens with `elisctl session overlay open` shows on the phone while the phone leads the pane, and on the Mac otherwise.

**Architecture:** The relay (`elisctl mobile serve`) registers one `zmx.present` subscriber per session the phone views. It lists a new kind `viewer.phone` and reports the lead of the panes the phone claimed. `PresentationHub` routes pages to it and routes all other work as if it did not exist. The relay carries the page over a new mux channel type `present`; the phone shows it in a WebView sheet, and file pages load through a loopback `HttpServer` on the phone.

**Tech Stack:** Swift 6 (`ElisCore`, `elisctlKit`, app target), Swift Testing / XCTest, Dart / Flutter, `webview_flutter` (Android System WebView).

**Spec:** `docs/superpowers/specs/2026-11-20-phone-pages-design.md`. Part 2 plan: `docs/superpowers/plans/2026-11-20-phone-pages-part2.md`.

## Global Constraints

- Work only in the worktree, branch `worktree-phone-pages`. All `macos/` commands run from `macos/`.
- Verbatim rule: never execute `elis`/`elisctl` against the default socket, never launch or quit `~/Applications/Elis.app`.
- `ElisCore` imports no AppKit, GhosttyKit, Metal or CoreGraphics. Relay code is `#if os(macOS)`.
- SwiftLint: 200-column lines, 1000-line files, 800-line types. `PresentationFrames.swift` has 960 lines: add nothing to it.
- A `public` `ElisCore` symbol may have a caller in agterm-linux: new parameters get defaults, nothing public is narrowed.
- Targeted tests only while working (`swift test --filter`, `-only-testing:`, `flutter test --no-pub <file>`). The whole gates run once, in Task 17.
- Part 1 docs and skill text do not mention dev servers. Master never holds Part 1 without Part 2: do not merge this PR alone.
- No feature is hidden or disabled on BLE.
- Comments stay short (CLAUDE.md "Working norms"); test comments are rare and one line.
- A page never reaches `phone.*` or the pairing token: a bridge line goes only into the page channel, never to mux channel 0.

## Verified before planning (Task 1 re-checks and records these)

- A phone claim marks the Mac's pane `.follower`. The claim is an ordinary claiming attach (`PhoneAttach.swift:44`, `ZmxLeadAttachment(claim: true)`); the daemon then reports `follower` to the Mac's own client, and `PaneLead.report` applies it (`Elis/Ghostty/PaneLead.swift:41`). `PaneLeadCover` reads the same `ZmxLeadBook` state and uses `phoneLeads` only for the label (`PaneLeadCover.swift:21,57`). So `presentsRemotely` (`ZmxLead.swift:208`) is true while the phone leads.
- `PresentationHub.route` (`PresentationHub.swift:334`) returns the subscriber whose newest `lead.report` names the pane (`claimant`, `:341`), else the grant holder. A subscriber needs no grant to report a lead (`receive`, `:289`).
- A pass runs when the Mac's own role flips: `trackOpenWorkPlaces` (`Elis/Control/ControlServer+Presentation.swift:87`) observes `ZmxLeadBook` and calls `scheduleOpenWork`.
- For a Live pane the pane token equals the pane identity (`ZmxSupport.swift:114`), and a remote daemon name encodes the origin's pane identity (`RemotePresentationState.swift:36`).

## Deviations from the spec (the lead decides; the plan follows the first option)

1. **Hello kinds.** The relay does not list `page.text`, `page.files` or `page.links`. Listing them obliges the phone to answer text actions with `pageResult`, serve `logTail`, and follow markdown links. Without them a log page goes to the Mac by the missing-kind rule, a text page shows static, and a markdown page shows without links.
2. **Bridge with page JavaScript off.** The Mac runs the adapter in an isolated `WKContentWorld`; Android has none. The phone enables WebView JavaScript for every file page and blocks the page's own scripts with a `Content-Security-Policy: script-src 'none'` header from its loopback server when the page has no `--js`. Task 12 proves or refutes this on the emulator before the sheet is built. Tasks 11 and 12 depend on no earlier task except Task 0; run them first to learn the result early.
3. **Content pages.** `RemotePageResources.content()` returns a file to read, not HTML. The relay builds the HTML with `ImagePage.html`, `DocumentPage.page`, `MarkdownPage.html` and `TextPage.html`, and sends the renderer script from the app bundle's `markdown` folder.
4. **UI test.** Default UI-test launches bypass zmx (`.claude/rules/ui-tests.md:50`), so no pane can follow. The `--block` / dismissed case is a hosted test in `ElisTests/ControlServerPageServeTests`.
5. **`presenters` read-back.** A phone subscriber is not counted in `presenters.mirrors` or `viewers`; `phoneViewers` already reports it.
6. **Remote rows.** `htmlOverlays[].phone` shows in the origin's tree only; the Mac that carries the phone has no slot for a page of an attached row. No remote row runs in the emulator task: the remote branch is covered by `aRemoteOriginIsReachedThroughItsArgv` and by the page-serve tests that already run over a socket.
7. **Board.** Save PNG/SVG needs a WebView download handler; no task adds one.

## Review Focus

1. An origin that predates `viewer.phone` (an older Mac or elis-server behind a remote row): the phone sends no `lead.report` there, so asks never route to a viewer that ignores them. Test in Task 9.
2. The phone leads and a page of a kind it lacks opens (a log page, a loopback URL): the page shows on the Mac, it is not refused. Test in Task 3.
3. The phone drops between the page request and its 30 s claim: the page opens on the Mac. Test in Task 4.
4. A file page larger than the channel buffer (512 KiB) while the user types: the page arrives whole and vt output is sent first. Tests in Tasks 6 and 9.
5. A request to the phone's loopback server from another app (no secret, or `POST`): refused. Test in Task 11.

## File Structure

| File | Responsibility |
|---|---|
| `macos/ElisCore/Sources/ElisCore/PresentationHub.swift` | `viewer.phone`, `Work`, filtered `route` / `leadClaimant` |
| `macos/ElisCore/Sources/ElisCore/ZmxLead.swift` | `remoteRecipient` / `pendingRecipient` with `work`, `pageRecipient` |
| `macos/ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkPages.swift` (new) | `present` channel line types |
| `macos/ElisCore/Sources/ElisCore/HtmlBridgeAdapter.swift` (new) | the bridge adapter script, one source |
| `macos/ElisCore/Sources/ElisCore/MarkdownAssets.swift` (moved from `Elis/Views`) | renderer scripts and styles from a folder |
| `macos/ElisCore/Sources/elisctlKit/PhoneLinkLineStream.swift` (new) | newline-delimited duplex over a socket or a child process |
| `macos/ElisCore/Sources/elisctlKit/PhoneLinkPresenter.swift` (new) | one `zmx.present` subscriber and its page channels |
| `macos/ElisCore/Sources/elisctlKit/PhoneLinkPresenter+Pages.swift` (new) | page request to `page` line, content HTML, fetch and bridge |
| `mobile/lib/pages/page_link.dart` (new) | the `present` channel's state for one session |
| `mobile/lib/pages/page_server.dart` (new) | loopback `HttpServer` for file pages |
| `mobile/lib/pages/page_sheet.dart` (new) | the WebView sheet, identity strip and chip |

---

### Task 0: Worktree setup

**Files:** none tracked.

- [ ] **Step 1:** In `macos/scripts/setup.sh` read how each stamp is written. Compute what this worktree would write for ghostty (`GHOSTTY_REV` + digest of `scripts/ghostty-patches/*.patch`) and zmx (`ZMX_REV`, `ZMX_TARGET`, digest of `scripts/zmx-patches/*.patch` and `scripts/zmx-patches/ghostty/*.patch`). Compare with `/Users/n.savchenko/IdeaProjects/elis/macos/.ghostty-build-stamp` (`83fb95624b0439ee660c2679b43b38c8b63769cd 2e5037255cfc8eb4`) and `.zmx-build-stamp` (`8bab1f0173b07e79835ea372d749af3dbf0d0842 aarch64-macos.14.0 3d266ab1cb3b82e3`).
- [ ] **Step 2:** For each set whose stamp matches, symlink from the main checkout with absolute targets: `GhosttyKit.xcframework`, `Elis/Resources/ghostty`, `Elis/Resources/terminfo`, `.ghostty-build-stamp`; `Elis/Resources/zmx`, `.zmx-build-stamp`. A set that differs gets no link; `scripts/setup.sh` builds it.
- [ ] **Step 3:** `cd macos && make build` (or `scripts/build.sh`). Expected: BUILD SUCCEEDED.
- [ ] **Step 4:** `cd mobile && ./tool/build-vtshim.sh`. If `flutter --version` is below the `sdk:` in `pubspec.yaml`, set a temporary `sdk:` and run `flutter pub get`; restore `pubspec.yaml` and `pubspec.lock` before every commit that touches neither.
- [ ] **Step 5:** `flutter test --no-pub test/mux_test.dart`. Expected: all pass.

### Task 1: Record the lead and routing facts

**Files:**
- Test: `macos/ElisCore/Tests/ElisCoreTests/AppStoreOpenWorkTests.swift`

- [ ] **Step 1:** Re-read the four lines under "Verified before planning" in the code. If one no longer holds, stop and report to the lead.
- [ ] **Step 2:** Add `aGrantlessViewerThatReportsTheLeadIsRouted`: with the suite's `session()` and `viewer(session, leads: true)` (no `acquire`), `hub.route(session: session.id, pane: session.paneIdentity) == viewer.gen` and `host.presentsRemotely(session, paneIdentity: session.paneIdentity)`.
- [ ] **Step 3:** `cd macos/ElisCore && swift test --filter AppStoreOpenWorkTests`. Expected: PASS (this pins current behavior).
- [ ] **Step 4:** Commit `test: a viewer without the grant takes the work of a pane it leads`.

### Task 2: `viewer.phone` and work-kind routing in the hub

**Files:**
- Modify: `macos/ElisCore/Sources/ElisCore/PresentationHub.swift` (`supportedKinds` `:73`, `receive` `:279`, `route` `:334`, `claimant` `:341`, `leadClaimant` `:365`)
- Modify: `macos/ElisCore/Sources/ElisCore/AppStore+RemotePresentation.swift:322` (`presentersNode`)
- Test: `macos/ElisCore/Tests/ElisCoreTests/PresentationHubTests.swift`

**Interfaces — Produces:**
```swift
extension PresentationHub {
    public static let viewerPhoneKind = "viewer.phone"      // in supportedKinds
    public enum Work: Sendable { case page, other }
    public func route(session: UUID, pane: UUID?, work: Work = .other) -> Int?
    public func leadClaimant(session: UUID, pane: UUID, work: Work = .other) -> Int?
    public func isPhone(owner: Int) -> Bool                   // supports(viewerPhoneKind, owner:)
    public func macViewerCount(session: UUID) -> Int          // subscribers without viewer.phone
}
```
The filter lives in one place: the private `claimant(session:pane:work:)` (`:341`) drops subscribers listing `viewer.phone` for `.other`; `route` and `leadClaimant` only pass `work` on. A `presenterAcquire` from such a subscriber is answered `presenterRefused`.

- [ ] **Step 1: Failing tests** in `PresentationHubTests`:
  - `aPhoneClaimantTakesPagesOnly`: phone subscriber (kinds include `viewer.phone`, `lead.report`) reports pane P. `route(pane: P, work: .page) == phone`; `route(pane: P) == nil`; `leadClaimant(pane: P) == nil`.
  - `otherWorkGoesToTheNextClaimantThenTheHolder`: Mac viewer A holds the grant, Mac viewer B reported P earlier, phone reported P last. `route(pane: P) == B`; after B withdraws, `== A`.
  - `aPhoneNeverBecomesTheGrantHolder`: phone sends `presenterAcquire`: its sink's last frame is `.presenterRefused`, `presenter(of:) == nil`. Then a Mac holder unsubscribes with the phone still connected: the phone gets no `.presenterVacant`, and `route(pane: nil)` for an unled session is nil.
  - `theKindIsNegotiated`: `PresentationHub.supportedKinds.contains("viewer.phone")`, and `isPhone(owner:)` is true only for a subscriber whose hello listed it.
- [ ] **Step 2:** `swift test --filter PresentationHubTests`. Expected: FAIL to compile (`work:` unknown).
- [ ] **Step 3:** Implement the interface above. `presentersNode` uses `macViewerCount` for `viewers` and `mirrors`, and returns nil when it is 0.
- [ ] **Step 4:** `swift test --filter PresentationHubTests`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): viewer.phone takes pages and no other work`.

### Task 3: Placement guard at every call site

**Files:**
- Modify: `macos/ElisCore/Sources/ElisCore/ZmxLead.swift:214-224`
- Modify: `macos/ElisCore/Sources/ElisCore/AppStore+RemotePage.swift` (`openRemotePage` recipient `:69` and refusals `:71-73`, `offerPendingPage` `:158`, `pageRecipient` `:315`)
- Modify: `macos/ElisCore/Sources/ElisCore/AppStore+OpenWork.swift` (`place` `:72`, `placePages` `:167`)
- Test: `macos/ElisCore/Tests/ElisCoreTests/AppStoreOpenWorkTests.swift`, `AppStoreRemotePageTests.swift`, `AppStoreRemoteAskTests.swift`, `AppStoreRemoteOverlayTests.swift`, `AppStorePresentationTests.swift`, `SessionPickTests.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces:
```swift
extension AppStore {
    func remoteRecipient(_ session: Session, paneIdentity: UUID?, work: PresentationHub.Work = .other) -> Int?
    func pendingRecipient(_ session: Session, paneIdentity: UUID?, work: PresentationHub.Work = .other) -> Int?
    /// The viewer a page goes to: the `.page` recipient, or the `.other` one when that is a phone that cannot show it.
    func pageRecipient(_ session: Session, paneIdentity: UUID?, source: PresentationPageSource, log: Bool, held: Bool) -> Int?
}
```
`held: true` applies `takesHeldWork`. Page sites (`openRemotePage`, `offerPendingPage`, `pageRecipient(_:pane:)`) pass `.page` or use `pageRecipient(…source:)`. `place(_:pane:work:)` in `AppStore+OpenWork` (`:72`, the `leadClaimant` call at `:82`) takes the work kind with no default: `placeSessionAsk`, `placeWindowAsk` and `placePick` pass `.other`, `placePages` passes `.page`. `remoteRecipient(work:)` only forwards it to `route`. `placePages` asks `.page` and, when the viewer is a phone that fails `presenterShows`, asks `.other`. The non-page sites keep the default and need no edit: `AppStore+Presentation.swift:136`, `AppStore+RemoteAsk.swift:26,48`, `AppStore+RemoteOverlay.swift:51,93`, `SessionPick.swift:434,472`, `AppStore+RemotePresentation.swift:334`, and the ask and pick `place()` calls.

In `openRemotePage`, a `.forwarded` or unsupported source no longer returns `.loopback` / `.unsupported` when the first recipient is a phone: the fallback recipient decides, and a nil one on a Mac returns `.local`.

- [ ] **Step 1: Failing tests.** Add to the suite harness `phone(_ session:, kinds:)`: `viewer(session, leads: true, kinds: PresentationHub.pageKinds + ["lead.report", "page.content", "page.document", "pending.snapshot", "job.token", "offer.id", "viewer.phone"])`. One test per site, each on a Mac origin with the pane `.follower`:
  - `AppStoreOpenWorkTests.aLeadingPhoneGetsThePageRequest`: `openPage(url()) == .opened`, phone sink holds `.pageRequest`.
  - `AppStoreRemoteAskTests.anAskStaysHereWhileOnlyThePhoneLeads`: `openRemoteAsk(...) == .notPresented`; with a Mac viewer holding the grant the ask's `owner` is that viewer.
  - `AppStoreRemoteOverlayTests.aProgramOverlayNeverGoesToThePhone`, `SessionPickTests.aPickNeverGoesToThePhone` (`presentPickRemotely == nil`), `AppStorePresentationTests.aStatusSoundNeverGoesToThePhone` (`presentStatusSoundRemotely == false`): the phone sink gets no frame of that kind.
  - `AppStoreOpenWorkTests.openAskAndPickStayPutAtAPhoneTakeOver`: ask and pick open locally, phone reports the lead, `pass(session)`: the phone sink holds no `askRequest` / `pickRequest`.
  - `…onAHeadlessOriginOtherWorkGoesToTheMacViewer`: `session(headless: true)`, Mac viewer with the grant, phone leads: an ask opened there has the Mac viewer as owner; without the Mac viewer it stays pending (`askRemoteOwner == nil`).
  - `AppStoreOpenWorkTests.aGuiAskInAWindowStaysOffThePhone`: a GUI ask anchored to the session is open in the window's controller (`local(controller, window:)`), the phone reports the lead, `pass(session, local:)`: `controller.pendingAsk != nil`, the phone sink holds no `askRequest`.
  - `AppStoreOpenWorkTests.aHeldInteractionOnAHeadlessOriginStaysOffThePhone`: `session(headless: true)`, an ask and a pick held pending, only the phone connected and leading; `host.offerPendingInteractions(forSession:now:)`: the phone sink holds no `askRequest` or `pickRequest`, and both stay pending. A held page is offered to it.
  - `AppStoreRemotePageTests.aPageKindThePhoneLacksGoesToTheNextRecipient`: phone without `page.content` leads, Mac viewer holds the grant: an image page's request is in the Mac viewer's sink. With no next claimant and no grant holder the origin keeps it: `openRemotePage == .local` on a Mac. Same for a loopback URL (`http://127.0.0.1:5173/`): `.local`, not `.loopback`.
- [ ] **Step 2:** `swift test --filter "AppStoreOpenWorkTests|AppStoreRemotePageTests|AppStoreRemoteAskTests|AppStoreRemoteOverlayTests|AppStorePresentationTests|SessionPickTests"`. Expected: the new tests FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same command. Expected: PASS, the existing tests included.
- [ ] **Step 5:** Commit `feat(core): work the phone does not show goes to the next viewer`.

### Task 4: Pages follow the phone's lead

**Files:**
- Test: `macos/ElisCore/Tests/ElisCoreTests/AppStoreOpenWorkTests.swift`
- Modify (only if a test fails): `macos/ElisCore/Sources/ElisCore/AppStore+OpenWork.swift`, `AppStore+PageMove.swift`

**Interfaces — Consumes:** Task 3 `phone(_:)` harness.

- [ ] **Step 1: Tests.**
  - `aPageReturnsHomeWhenThePhoneWithdrawsTheLead`: phone holds a URL page (reported `.loaded`); `lead(phone, [])`, `setLead(.leader, pane:)`, `pass(session)`: `session.htmlOverlayActive`, phone sink's last frame is `.pageClose` with reason `PresentationPageChange.channelLost`.
  - `aPageGoesBackToTheSamePhoneWhenItLeadsAgain`: then `setLead(.follower)`, `lead(phone, [pane])`, `pass`: the phone sink holds a second `.pageRequest` with a new `offer`; its `pageState` echoing that offer commits (`slot.owner == phone.gen`).
  - `aPageThePhoneNeverClaimedComesHome` (Review Focus 3): file page offered to the phone; `hub.unsubscribe(phone.id)`, `setLead(.leader)`, `pass`: the page is mounted here, its outcome still open (`HtmlPageOutcomes.shared` not dismissed).
  - `aHiddenPageMovesHidden`: a local page hidden with `session.setOverlayHidden(true, slot: nil)`; the phone leads, `pass`: the phone sink holds `.pageRequest` followed by `.pageCommand` with action `.hide` (`offered.hidden`, `AppStore+PageMove.swift`).
  - `onlyPagesOfTheLedPaneMove`: session with a split; pages in the session-wide slot, `.left` and `.right`; the phone leads the split pane only: its sink holds one `.pageRequest`, for the `.right` page. Leading the primary pane instead offers the `.left` and the session-wide page.
  - `aPageRowStays`: a session with `content == .page`; the phone leads, `pass`: no `.pageRequest`.
  - `aMoveKeepsTheBlockingOutcomeOpen`: across phone → Mac → phone, `HtmlPageOutcomes.shared` holds the page as pending each time.
  - `aPhoneWithOfferIdIsNeverRecordedAsGivenUp`: after the first test, `OfferlessHolders.shared.held(job, by: phone.gen) == false`.
  - `aLoadedPageSurvivesThePhoneLeavingWhileThePaneStillFollows`: phone holds a loaded page; `hub.unsubscribe(phone.id)` with the pane still `.follower`, `pass`: the page is mounted here (`remoteOverlayOwnerLost`, `AppStore+RemoteOverlay.swift:199`, then `placePages`), and its outcome is still open.
  - `aLoadingPageWhosePhoneLeavesIsNotDismissed`: file page claimed, no `pageState` yet; `hub.unsubscribe(phone.id)`, then `host.remotePageLost(page)` (the pipe's end arriving second), `pass`: the outcome is still open and the page is mounted here. The reverse order (`remotePageLost` first) ends the page as dismissed today (`AppStore+OpenWork.swift:58-61`); that order is what Task 9's teardown rule prevents, so assert it as the documented current behavior in `aPagePipeLostBeforeItLoadedEnds`.
- [ ] **Step 2:** `swift test --filter AppStoreOpenWorkTests`. Fix what fails in the two source files; record the cause in the commit message.
- [ ] **Step 3:** Commit `test(core): an open page follows the phone's lead both ways`.

### Task 5: Attach answer names the origin; `phone` read-back

**Files:**
- Modify: `macos/ElisCore/Sources/ElisCore/PhoneAttach.swift`
- Modify: `macos/Elis/Control/ControlServer+Attach.swift`
- Modify: `macos/ElisCore/Sources/ElisCore/ControlProjection.swift:542` (`ControlHtmlOverlayNode`), `AppStore+HtmlOverlay.swift:410`
- Test: `macos/ElisCore/Tests/ElisCoreTests/AppStoreTreeProjectionTests.swift`, `macos/ElisCore/Tests/ElisCoreTests/PhoneAttachTests.swift`, `macos/ElisTests/ControlServerAttachTests.swift`

**Interfaces — Produces:**
```swift
public struct ControlAttachOrigin: Codable, Sendable, Equatable {
    public let session: String   // the session's id on the host that owns its presentation hub
    public let pane: String      // that host's pane identity, the UUID a lead.report names
    public let host: String?     // ssh host; nil when this app is the origin
}
// ControlAttach gains: public let origin: ControlAttachOrigin?   (decodeIfPresent, init default nil)
// ControlHtmlOverlayNode gains: public let phone: Bool?            (true when the slot's owner lists viewer.phone, else omitted)
```
App: local row → `(session.id, identity, nil)`; remote row → `(binding.remoteSessionID, ZmxSupport.paneIdentity(fromDaemonName: daemon), origin.host)`, for `catalogOwned` rows too.

- [ ] **Step 1: Failing tests.** `ControlAttach` round-trips `origin` and decodes an answer without it as nil. `htmlOverlayNodes` of a session whose remote slot is owned by a `viewer.phone` subscriber has `phone == true`, and `nil` for a Mac viewer's. Hosted: `session.attach` on a local Live session answers `origin.session == session.id.uuidString`, `origin.pane == paneID`, `origin.host == nil`.
- [ ] **Step 2:** Run the three suites filtered. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS.
- [ ] **Step 5:** Commit `feat(control): session.attach names the origin; htmlOverlays[].phone`.

### Task 6: Mux channel type `present` and its scheduler class

**Files:**
- Modify: `macos/ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkScheduler.swift`
- Create: `macos/ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkPages.swift`
- Test: `macos/ElisCore/Tests/ElisCoreTests/PhoneLinkSchedulerTests.swift`, `PhoneLinkMessagesTests.swift`

**Interfaces — Produces:**
```swift
// PhoneLinkScheduler
public mutating func open(channel: UInt32, low: Bool = false)   // low channels are served only when no other opened channel has a frame

/// Relay to phone, one JSON object per line, key "t" first by sorting.
public enum PhonePageDown: Codable, Equatable, Sendable {
    case page(PhonePage)                                             // t: "page"
    case command(id: String, seq: Int, action: String, sizePercent: Int?)  // t: "command"; action: close|hide|show|reload|back|forward|resize|browser
    case res(id: String, seq: Int, mime: String?, data: Data?, end: Bool, error: String?)   // t: "res"
    case reply(id: String, seq: Int, response: String?, error: String?)                      // t: "reply"
}
public struct PhonePage: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String          // "file" | "url" | "content"
    public var path: String?         // file: the absolute path on the origin
    public var url: String?
    public var html: String?         // content
    public var script: String?       // content: the renderer the phone runs after load
    public var adapter: String?      // file: HtmlBridgeAdapter.script(handler: "window.__elis")
    public var javascript: Bool, chromeless: Bool, browse: Bool, hidden: Bool
    public var title: String         // the identity strip's text
    public var sizePercent: Int?
}
/// Phone to relay.
public enum PhonePageUp: Codable, Equatable, Sendable {
    case fetch(id: String, seq: Int, path: String)
    case bridge(id: String, seq: Int, line: String)
    case state(id: String, load: String, title: String?, current: String?, canGoBack: Bool, appliedSeq: Int, hidden: Bool, error: String?)
    case closed(id: String, dismissed: Bool)
}
public enum PhonePageCodec {
    public static func encode(_ line: PhonePageDown) -> Data          // sorted keys, unescaped slashes, newline appended
    public static func decode(_ line: Data) throws -> PhonePageUp
}
```
`res.data` is base64 (JSONEncoder's `Data` default), at most `PageServeCodec.maxChunkBytes` per line.

- [ ] **Step 1: Failing tests.** Scheduler `aLowChannelWaitsForVt`: channels 2 (normal) and 3 (`low: true`) both hold data and credit; `next` returns channel 2 until it is empty, then 3; channels 0 and 1 still go first. Codec: `PhonePageCodec.encode(.command(id: "p", seq: 3, action: "hide", sizePercent: nil))` equals `{"action":"hide","id":"p","seq":3,"t":"command"}\n`; `decode` of `{"t":"closed","id":"p","dismissed":true}` equals `.closed(id: "p", dismissed: true)`; an unknown `t` throws.
- [ ] **Step 2:** `swift test --filter "PhoneLinkSchedulerTests|PhoneLinkMessagesTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS.
- [ ] **Step 5:** Commit `feat(core): present channel lines and a low scheduler class`.

### Task 7: The bridge adapter and renderer assets move into ElisCore

**Files:**
- Create: `macos/ElisCore/Sources/ElisCore/HtmlBridgeAdapter.swift`
- Move: `macos/Elis/Views/MarkdownAssets.swift` → `macos/ElisCore/Sources/ElisCore/MarkdownAssets.swift`
- Modify: `macos/Elis/Views/HtmlOverlayBridge.swift` (`adapterScript` `:20`, `helperScript` `:94`), and each `MarkdownAssets.shared` user in `macos/Elis/Views`
- Test: `macos/ElisCore/Tests/ElisCoreTests/HtmlBridgeAdapterTests.swift` (new)

**Interfaces — Produces:**
```swift
public enum HtmlBridgeAdapter {
    /// The `data-elis` adapter. `handler` is a JS expression for an object whose `postMessage(body)` returns a Promise.
    public static func script(handler: String) -> String
    /// `elis.request` for a `--js` page, over the same handler.
    public static func helperScript(handler: String) -> String
}
public struct MarkdownAssets: Sendable {
    public let script, style, textScript, textStyle: String
    public init(directory: URL?)      // nil or a missing file reads as ""
}
```
The script text moves verbatim; only the handler expression becomes a parameter. The app keeps `HtmlOverlayBridge.adapterScript = HtmlBridgeAdapter.script(handler: "window.webkit.messageHandlers.\(handlerName)")` and `MarkdownAssets.shared = MarkdownAssets(directory: Bundle.main.resourceURL?.appendingPathComponent("markdown"))` in an app-target extension.

- [ ] **Step 1: Failing test.** `script(handler: "window.__elis")` contains `const handler = window.__elis;` and does not contain `webkit`. `MarkdownAssets(directory: nil).script == ""`.
- [ ] **Step 2:** `swift test --filter HtmlBridgeAdapterTests`. Expected: FAIL.
- [ ] **Step 3:** Implement and move.
- [ ] **Step 4:** `swift test --filter HtmlBridgeAdapterTests`, then `xcodebuild test -project Elis.xcodeproj -scheme Elis -destination 'platform=macOS' -only-testing:ElisTests/ControlServerPageServeTests/testARelayedSubmitIsRecordedOnThisMac`. Expected: PASS (the Mac's bridge still works).
- [ ] **Step 5:** Commit `refactor: one source for the page bridge adapter and renderer assets`.

### Task 8: `PhoneLinkLineStream`

**Files:**
- Create: `macos/ElisCore/Sources/elisctlKit/PhoneLinkLineStream.swift`
- Test: `macos/ElisCore/Tests/elisctlKitTests/PhoneLinkLineStreamTests.swift` (new)

**Interfaces — Produces:**
```swift
/// Newline-delimited lines both ways over a control-socket stream or a child process's stdio. One line is delivered,
/// and the next is read only after `resume()`. Callbacks run on `queue`.
final class PhoneLinkLineStream: @unchecked Sendable {
    static let maxLine = PresentationCodec.maxFrameBytes
    /// Sends `request` on the app socket and waits for its ok reply (as `StreamBridge.open`), off `queue`.
    static func socket(path: String, request: ControlRequest, queue: DispatchQueue) throws -> PhoneLinkLineStream
    /// Runs `argv` with pipes on stdin and stdout; stderr is dropped.
    static func process(argv: [String], queue: DispatchQueue) throws -> PhoneLinkLineStream
    func start(onLine: @escaping (Data) -> Void, onEnd: @escaping () -> Void)
    func send(_ line: Data)          // newline included by the caller
    func resume()
    func close()                     // terminates the process or shuts the socket; onEnd does not run after it
}
```
Reads and writes run on plain threads (`.claude/rules/tests.md`), writes through `StreamBridge.sendAll`.

- [ ] **Step 1: Failing tests** with the suite's `RawStubServer`: `socketStreamDeliversLinesOneAtATime` (the stub writes two lines; the second arrives only after `resume()`); `aRefusedRequestThrows` (stub answers `{"ok":false,"error":"no"}`: `socket(...)` throws with `no`); `processStreamEndsWhenTheChildExits` (`argv: ["/bin/sh","-c","echo a; exit 0"]`: one line `a`, then `onEnd`); `aLineOverTheCapEndsTheStream`.
- [ ] **Step 2:** `swift test --filter PhoneLinkLineStreamTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS.
- [ ] **Step 5:** Commit `feat(relay): a line stream over the app socket or ssh`.

### Task 9: `PhoneLinkPresenter` — subscribe, lead report, OPEN `present`

**Files:**
- Create: `macos/ElisCore/Sources/elisctlKit/PhoneLinkPresenter.swift`
- Modify: `macos/ElisCore/Sources/elisctlKit/PhoneLinkSession.swift` (`open` `:95`, `receive` `:62`, `closeChannel`, `close`, `openClaim` link closures), `PhoneLinkClaim.swift` (`answered`)
- Test: `macos/ElisCore/Tests/elisctlKitTests/PhoneLinkPresenterTests.swift` (new), `PhoneLinkSessionTests.swift`

**Interfaces:**
- Consumes: Tasks 5, 6, 8; `PhoneLinkTerminal.requestAttach(target:args:socketPath:done:)`; `RemoteSession.presentCommand(host:session:)`.
- Produces:
```swift
final class PhoneLinkPresenter: @unchecked Sendable {
    struct Link {
        let frame: (PhoneLinkFrame) -> Void                       // OPENED, CLOSE
        let output: (Data) -> PhoneLinkScheduler.Enqueue          // one PhonePageDown line
        let pending: () -> Int                                     // scheduler.pendingBytes(channel:)
        let ended: () -> Void
    }
    static let kinds = ["lead.report"] + PresentationHub.pageKinds
        + ["page.content", "page.document", "pending.snapshot", "job.token", "offer.id", "viewer.phone"]
    /// Page lines waiting in the scheduler past which page pipes are not resumed.
    static let highWater = 256 * 1024
    static let maxPresenters = 8
    let channel: UInt32
    let request: PhoneLinkOpen
    private(set) var asking: Bool
    init(channel: UInt32, request: PhoneLinkOpen, socketPath: String, queue: DispatchQueue, peer: String,
         log: @escaping (String) -> Void, link: Link)
    func start()
    func setLeads(_ panes: Set<UUID>)     // sent as lead.report only when the origin's hello echoed viewer.phone, and only when changed
    func receive(_ bytes: Data)           // DATA from the phone: PhonePageUp lines
    func drained()                        // the scheduler sent a frame: resume page pipes under highWater
    func stop()
}
// PhoneLinkClaim gains: private(set) var originPane: UUID?   (from attach.origin?.pane)
//                       var leading: Bool { paneID != nil && !stopped }
```
`start()`: `requestAttach(target: request.target, args: [:])` → `origin`. No `origin` (an older app) → OPENED with error `Elis is too old to show pages`. Local (`host == nil`) → `PhoneLinkLineStream.socket(path:, request: ControlRequest(cmd: .zmxPresent, target: origin.session))`; remote → `.process(argv: RemoteSession.presentCommand(host:session:))`. It sends `hello` (`PresentationCodec.version`, `kinds`, mode `.mirror`) as `RemotePresentationClient` does (`RemotePresentationClient.swift:353`), takes the generation from the origin's hello, answers `ping` with `ack`, and ignores every other frame except `pageRequest`, `pageClose`, `pageCommand` (Task 10). A headless origin sends held and moved work in batches (`ServerStreams.swift:114`): `pendingChunk` goes into a `PresentationPendingBatch`, and `pendingCommit` applies its entries through the same switch, as `RemotePresentationClient.swift:314-321` does. The presentation stream is `resume()`d at once after every line: only page pipes wait on `highWater`, or the hub drops the phone as stalled. Then OPENED (`PhoneLinkOpened()`, no size). The presentation stream ending sends CLOSE with reason `presentation ended`.

`PhoneLinkSession`: OPEN type `present` is accepted for channels ≥ 2, at most `maxPresenters`, one per `target` (`channel already open` for a second); it calls `scheduler.open(channel:, low: true)`. `(.data, ch)` goes to the presenter. After each claim `leadChanged`, `released`, claim close and presenter hello, the session calls `presenter.setLeads(Set(claims.values.filter { $0.request.target == target && $0.leading }.compactMap(\.originPane)))`. `pump()` calls `drained()` on every presenter after a send. `close(reason:)` stops presenters.

Teardown order in `stop()`: close the presentation stream first and leave the page pipes to the origin, which retires them when the subscriber goes (`RemotePageEnds.onWithdrawn`). The relay closes a pipe itself only on that pipe's EOF, or 2 s after `stop()`. A pipe closed first reads on the origin as a lost page, and a page still loading then ends as dismissed (`AppStore.remotePageLost`).

Test seam: `init` takes `spawn: (ControlAttachOrigin, _ pageToken: String?) throws -> PhoneLinkLineStream`, defaulting to the socket and ssh choice above, so a test drives the remote branch without ssh.

- [ ] **Step 1: Failing tests** (`MobileFixture`, `MemoryPhone`, `FrameReader`, `RawStubServer`; the stub answers `session.attach` with an `origin` and plays the origin's side of `zmx.present`):
  - `openPresentIsAccepted`: OPEN `{"type":"present","target":"S"}` → the stub receives `zmx.present` then a hello listing `viewer.phone` and `offer.id`; the phone reads OPENED without error.
  - `anAppWithoutOriginRefusesPresent`: OPENED error `Elis is too old to show pages`.
  - `aSecondPresentForTheSessionIsRefused`: `channel already open`.
  - `theLeadIsReportedWhileTheClaimIsOpen`: after the claim's leader report the stub reads `lead.report` with the origin pane; after the phone's CLOSE of the claim it reads `lead.report` with `[]`.
  - `noLeadReportToAnOriginWithoutViewerPhone` (Review Focus 1): the stub's hello omits `viewer.phone`; no `lead.report` arrives after the claim leads.
  - `aPingIsAcked`: stub sends `ping`; reads `ack` with the hello's `gen`.
  - `linkCloseEndsThePresenter`: the stub's stream reaches EOF after `close(reason:)`.
  - `aRemoteOriginIsReachedThroughItsArgv`: the stub's attach answer has `origin.host == "h"`; with the default `spawn` replaced by a recorder, it is called with that origin, and `RemoteSession.presentCommand(host: "h", session: origin.session)` is what the default builds (assert the argv, do not run it).
  - `aPendingBatchDeliversItsPage`: the stub sends a `pageRequest` wrapped by `PresentationPendingBatch.chunks` then `pendingCommit`; the phone reads one `page` line.
  - `thePresentationStreamIsReadWhileAPageWaits`: with the channel's pending bytes over `highWater`, a `ping` is still acked.
- [ ] **Step 2:** `swift test --filter "PhoneLinkPresenterTests|PhoneLinkSessionTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS, existing `PhoneLinkSessionTests` included.
- [ ] **Step 5:** Commit `feat(relay): the phone subscribes as a presenter and reports its lead`.

### Task 10: Relay page handling — request, fetch, bridge, state, close

**Files:**
- Create: `macos/ElisCore/Sources/elisctlKit/PhoneLinkPresenter+Pages.swift`
- Test: `macos/ElisCore/Tests/elisctlKitTests/PhoneLinkPresenterPagesTests.swift` (new), `macos/ElisTests/ControlServerPageServeTests.swift`, `macos/ElisCore/Tests/ElisCoreTests/HtmlBridgeTests.swift`

**Interfaces:**
- Consumes: Task 9; `RemoteSession.pageServeCommand(host:token:)`; `PageServeFrame`, `PageServeCodec`; `HtmlBridgeAdapter`, `MarkdownAssets`.
- Produces (internal to the presenter): one `PhoneLinkLineStream` per channel page, opened with `ControlRequest(cmd: .sessionOverlayPageServe, target: token)` locally or `pageServeCommand` remotely, held while the page shows.

Behavior:
- `pageRequest` → by `source`: `.url` → `page` line, kind `url`. `.file` → open the page pipe, then kind `file` with `path` and `adapter` (`HtmlBridgeAdapter.script(handler: "window.__elis")`, plus `helperScript` when `javascript`). `.image`, `.document`, `.markdown`, `.text` → open the pipe, read the page's own file with a `resource` request, build `html` with `ImagePage.html(data:mimeType:)`, `DocumentPage.page(_:)`, `MarkdownPage.html(markdown:images:style:)` (pictures from `MarkdownPage.remoteImageReferences`, each fetched over the pipe) or `TextPage.html(text:language:line:style:)`, and send kind `content` with `script` from `MarkdownAssets(directory:)` of `Bundle.main.resourceURL/markdown`, falling back to `<executable dir>/../Resources/markdown`. `.forwarded` or a pipe that cannot open → `pageRejected` with the offer echoed.
- Every answer to the origin echoes the request's `offer`.
- `fetch` → `.resource(id: n, path:)`; `head`/`chunk`/`end`/`failure` → `res` lines keyed by the phone's `seq`. `bridge` → `.bridge(id: n, request: line)`; `reply`/`failure` → `reply` line. A bridge line is never written anywhere else.
- `state` → `.pageState` (load `loaded`/`failed`, title, address = `current`, `canGoBack`, `appliedSeq`, `hidden`, `offer`). `closed` → `.pageClosed(PresentationPageChange(page:, offer:))`, and the pipe closes.
- A hidden page that moves arrives as `pageRequest` then `pageCommand` `hide`. When the `hide` arrives before the relay has written the `page` line (a file or content page still opening its pipe), the relay sets `PhonePage.hidden`; otherwise it sends the `command`.
- `pageCommand` → `command` line (`hide`, `show`, `reloadOriginal`/`reloadCurrent` → `reload`, `back`, `forward`, `resize` with `sizePercent`, `browser` as `browser`). The phone applies the actions it knows and counts every `seq` as applied. `pageClose` → `command` `close` and the pipe closes; a `pageClose` with reason `channel-lost` gets no `pageClosed` answer.
- A page pipe is `resume()`d only while `link.pending() < highWater`.
- The phone's line over `ControlWire.maxRequestLineBytes`, or one that does not decode, closes the channel with reason `bad page line`.

- [ ] **Step 1: Failing tests.**
  - `aUrlPageBecomesAPageLine`: stub sends `pageRequest` (url, offer 7); the phone reads `page` with `kind == "url"`; the phone's `state` loaded reaches the stub as `pageState` with `offer == 7`.
  - `aFetchIsServedThroughThePageChannel`: file page; the stub sees `session.overlay.page.serve <token>`; phone `fetch` → stub reads `resource` with that path; stub's `head`, `chunk`, `end` → phone reads `res` lines, the last with `end == true`.
  - `aFetchOutsideTheGrantIsRefused`: the stub answers `failure` `file is outside the page's folder`; the phone reads `res` with that `error`. (The origin's gate itself is `ControlServerPageServeTests.testAFileOutsideTheGrantIsRefusedOnTheChannel`.)
  - `aBridgeLineNeverReachesChannelZero`: phone `bridge` with `{"cmd":"phone.status"}`; the stub's control connection receives no `phone.status` request, its page pipe receives `bridge`; the stub's `failure` `phone.status cannot be sent from a page` reaches the phone as `reply.error`. Add to `HtmlBridgeTests` (if `:185` does not already pin the text) that the refusal message is exactly that.
  - `closedRecordsDismissed`: phone `closed` dismissed → stub reads `pageClosed` with the offer and no reason.
  - `aLargeFileDoesNotOverflowTheChannel` (Review Focus 4): the stub streams 2 MiB of chunks while the phone grants credit slowly; the phone receives every byte in order, and vt DATA enqueued meanwhile is read before the page's remaining lines.
  - `stoppingClosesThePresentationStreamBeforeThePagePipe`: with a file page open, `close(reason:)`: the stub sees EOF on the presentation stream before EOF on the page pipe.
  - `aLogPageIsNotOffered`: covered by `kinds`; assert `!PhoneLinkPresenter.kinds.contains("page.text")`.
  - Hosted, `ControlServerPageServeTests.testABlockingPageClosedFromThePhoneEndsDismissed`: pane set `.follower` (as `:164`), a raw socket subscriber with `viewer.phone` reports the lead, `session.overlay.open --html --block` runs off the main thread, the subscriber claims the page and sends `pageClosed`: the command returns with the dismissed exit code, and `tree` shows no `htmlOverlays` entry.
- [ ] **Step 2:** `swift test --filter PhoneLinkPresenterPagesTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again, then the hosted test with `-only-testing:ElisTests/ControlServerPageServeTests/testABlockingPageClosedFromThePhoneEndsDismissed`. Expected: PASS.
- [ ] **Step 5:** Commit `feat(relay): pages, their files and their bridge reach the phone`.

### Task 11: Phone — `present` channel, `PageLink`, loopback server

**Files:**
- Modify: `mobile/lib/link/mux.dart`
- Create: `mobile/lib/pages/page_link.dart`, `mobile/lib/pages/page_server.dart`
- Test: `mobile/test/mux_test.dart`, `mobile/test/page_link_test.dart` (new), `mobile/test/page_server_test.dart` (new), `mobile/test/wire_names_test.dart`

**Interfaces — Produces:**
```dart
// mux.dart
PresentChannel present(String target);                 // OPEN {"type":"present","target":target}
class PresentChannel {
  Future<void> get opened;                              // throws ElisError with the relay's reason
  Stream<Map<String, dynamic>> get lines;               // one decoded JSON line each; CREDIT is sent as lines are delivered
  void send(Map<String, dynamic> line);
  Future<void> close();
  String? get ended;                                    // the CLOSE reason, 'Disconnected' on link loss
}
// page_link.dart
class PhonePage { final String id, kind, title; final String? path, url, html, script, adapter;
                  final bool javascript, chromeless, browse; bool hidden; int? sizePercent; int appliedSeq; }
class PageLink extends ChangeNotifier {
  PageLink(Mux mux, String target);
  bool get supported;                                   // false after an 'unsupported channel type' refusal
  PhonePage? get page;                                  // the newest open page; null when none
  Stream<PageCommand> get commands;                     // (id, seq, action, sizePercent) for the sheet to apply
  Future<PageFile> fetch(String id, String path);       // completes on the first res line; throws ElisError(error)
  Future<String> bridge(String id, String line);        // the origin's raw JSON reply; throws ElisError
  void report(String id, {required String load, String? title, String? current, bool canGoBack = false, String? error});
  void closed(String id, {required bool dismissed});
  void dispose();                                       // closes the channel; every page is dropped
}
class PageFile { final String mime; final Stream<List<int>> bytes; }
class PageCommand { final String id, action; final int seq; final int? sizePercent; }
// page_server.dart
class PageServer {
  static Future<PageServer> start(Future<PageFile> Function(String path) fetch, {required bool javascript});
  Uri urlFor(String originPath);                        // http://127.0.0.1:<port>/<secret><originPath>
  Future<void> close();
}
```
The secret is 16 bytes from `Random.secure()`, hex. The server answers 404 for a wrong secret, 405 for a method other than GET, 404 with the error text for a failed fetch, and sets `Content-Security-Policy: script-src 'none'` when `javascript` is false. The channel ending, or a `command` `close`, removes the page and notifies; the page map is empty after `dispose()`.

- [ ] **Step 1: Failing tests.**
  - `mux_test`: `present opens and decodes lines` (OPENED without size completes `opened`; a DATA frame holding `{"t":"page",…}\n` split across two frames yields one map); `an older relay refuses present` (`unsupported channel type` → `opened` throws, `PageLink.supported == false`, no retry).
  - `page_link_test`: a `page` line sets `page`; `command` `close` clears it; the channel's CLOSE clears it; `closed(id, dismissed: true)` sends `{"t":"closed","id":…,"dismissed":true}`; `fetch` sends `fetch` with a fresh `seq` and completes from `res` lines; a `res.error` fails it.
  - `page_server_test` (Review Focus 5): GET with the secret returns the fetched bytes and mime; a wrong secret → 404 and `fetch` is not called; `POST` → 405; `javascript: false` sets the CSP header.
  - `wire_names_test`: the `t` values `page`, `command`, `res`, `reply`, `fetch`, `bridge`, `state`, `closed` and the OPEN type `present`.
- [ ] **Step 2:** `cd mobile && flutter test --no-pub test/mux_test.dart test/page_link_test.dart test/page_server_test.dart test/wire_names_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS. `flutter analyze --no-pub` clean.
- [ ] **Step 5:** Commit `feat(mobile): the present channel and the page loopback server`.

### Task 12: Spike — the bridge and renderers in Android WebView

**Files:**
- Modify: `mobile/pubspec.yaml` (add `webview_flutter`, newest version that builds with the project's compileSdk), `mobile/android/app/src/main/AndroidManifest.xml`
- Create: `mobile/android/app/src/main/res/xml/network_security_config.xml`, `mobile/integration_test/page_webview_test.dart`

`network_security_config.xml` permits cleartext for `127.0.0.1` only; the manifest's `<application>` references it. Run only on the agent-owned emulator.

- [ ] **Step 1:** Write `page_webview_test.dart`. It starts a `PageServer` over an in-memory `fetch` and a `WebViewController` with JavaScript unrestricted, a JavaScript channel `ElisChannel`, and this prelude run before the adapter: `window.__elis = { postMessage(body) { … returns a Promise resolved by window.__elisReply(id, ok, value) } }`. Cases:
  1. `javascript: false`, page `<script>document.title='ran'</script><button type="button" data-elis="notify" data-elis-title="x">b</button>`: the title stays unchanged (page script blocked by the CSP header); after `runJavaScript(adapter)` a tap on the button makes `ElisChannel` receive a body with `cmd == "notify"`.
  2. `javascript: true`: the title becomes `ran`, and `elis.request({cmd:'notify'})` reaches `ElisChannel`.
  3. Content page: `loadHtmlString(MarkdownPage-shaped html)` with its `default-src 'none'` meta, then `runJavaScript(script)`: `#elis-page` has children.
- [ ] **Step 2:** `flutter test integration_test/page_webview_test.dart -d <emulator>`. Expected: 3 pass.
- [ ] **Step 3:** If case 1 or 3 fails, stop and report to the lead with the failing case and the WebView's console output; do not pick another mechanism alone. If all pass, restore any temporary `sdk:` change and commit `test(mobile): the page bridge and renderers run in the system WebView`.

### Task 13: Phone — the page sheet and its chip

**Files:**
- Create: `mobile/lib/pages/page_sheet.dart`
- Modify: `mobile/lib/screens/session.dart` (`_syncTerm` `:162`, `dispose`, the `AppBar` `actions` `:606`, the body `Column`)
- Test: `mobile/test/page_sheet_test.dart` (new), `mobile/test/session_term_test.dart`

**Interfaces:**
- Consumes: Task 11 `PageLink`, `PhonePage`, `PageServer`; Task 12 prelude.
- Produces:
```dart
class PageSheet extends StatefulWidget {   // key: Key('pageSheet')
  const PageSheet({required this.link, required this.page, required this.onSwipeDown, this.webView});
  final Widget Function(PageSheetController)? webView;   // test seam: no platform view in widget tests
}
class PageChip extends StatelessWidget { /* key: Key('pageChip'), shows the page title, onTap */ }
```
Rules:
- The session screen owns one `PageLink` while it is mounted and `m.state == LinkState.connected && m.mux != null`; it is rebuilt when `m.mux` changes. Backgrounding does not dispose it: the claim closes, the origin moves the page to the Mac and sends `close`, and the page comes back with a new `page` line when the phone leads again. Pages are independent of the watched pane.
- The sheet is a child of a `Stack` over the terminal, not a route. Height is the full body for `sizePercent` 100 or null, else that fraction from the bottom. The terminal keeps its edge-to-edge layout.
- Identity strip (unless `chromeless`): the page's `title` text and a close button `Key('pageClose')`; URL pages add back when `canGoBack`.
- Loading: `file` → `PageServer.start`, load `urlFor(path)`; `url` → load it; `content` → `loadHtmlString(html)` then `runJavaScript(script)` on finish.
- JavaScript mode: unrestricted for `file` and `content`; for `url` only when `javascript`. `file` pages get the prelude and `adapter` on every page finish in the main frame. File access and content access off.
- Navigation: `url` pages stay on their first origin unless `browse`; `file` pages stay under the server's secret prefix; any other main-frame navigation is prevented. `window.close()` is observed through the prelude (`window.close = () => ElisChannel.postMessage('{"close":true}')`).
- Close button, Android back while the sheet is open, and `window.close()` call `link.closed(id, dismissed: true)` and remove the sheet at once.
- A page that arrives with `hidden: true`, or whose first `command` is `hide`, shows the chip and no sheet; `show` or a tap on the chip opens it.
- Swipe down hides the sheet and shows `PageChip` in the `AppBar` `actions`, before the `lead` tag; a tap shows the sheet again. The WebView stays mounted (`Offstage`) so the page stays live.
- `command` `hide` / `show` set the same hidden state and are reported in `state.hidden`; `reload`, `back`, `forward`, `resize` act on the controller; every applied command raises `appliedSeq` in the next `report`.
- `link.page == null` removes the sheet and the chip in the same frame, whatever the cause.

- [ ] **Step 1: Failing widget tests** with a fake `webView` builder: `a page line shows the sheet`; `close sends closed and removes the sheet`; `swipe down leaves the chip and one tap brings the sheet back`; `the chip goes when the page leaves` (origin `close`, then channel CLOSE: `find.byKey(Key('pageChip'))` finds nothing); `sizePercent 50 takes half the body`; `a hidden page shows only the chip`; in `session_term_test`: `backgrounding keeps the present channel` (the fake mux sees CLOSE on the claim channel only; a `command` `close` then removes the sheet and the chip, and a new `page` line after resume shows the sheet again); `leaving the session closes the present channel`.
- [ ] **Step 2:** `flutter test --no-pub test/page_sheet_test.dart test/session_term_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again and `flutter analyze --no-pub`. Expected: PASS, clean.
- [ ] **Step 5:** Commit `feat(mobile): a page opens in a sheet over the session`.

### Task 14: Docs and skill

**Files:**
- Modify: `site/docs.html` (`#phone-app`, `:1106`), `site/commands.html` (`htmlOverlays[]` fields; `session.attach` answer), `.claude/rules/control-api.md` (routing bullet `:2384`; relay mux `:239-277`), `docs/superpowers/specs/2026-11-18-phone-terminal-stream-design.md` (pages leave its non-goals), `plugins/elis/skills/elis/SKILL.md` (`description` trigger and the phone section `:835`), `plugins/elis/skills/elis/reference.md`, `site/llms.txt` if it lists phone features

Content, each fact once:
- `docs.html`: a page a session opens shows on the phone while the phone leads the pane, on the Mac otherwise; it follows the lead both ways; a move reloads the page, so scroll and form state are lost; asks, picks, program overlays, HUDs and sounds stay on the Mac; log pages and pages of a kind the phone cannot show open on the Mac; the chip. No mention of dev servers.
- `commands.html`: `htmlOverlays[].phone`, `attach.origin`.
- `control-api.md`: the placement rule (`viewer.phone`, `Work`, the next-recipient fallback), the `present` channel contract (lines of Task 6, `low` class, `highWater`, caps, refusal texts).
- `SKILL.md`: trigger "show this on my phone / show a page where I am"; rule: to show a page use `elisctl session overlay open --html FILE --js` (never `open`); it follows the user to the phone.

- [ ] **Step 1:** Write the text. Bump the `?v=` on `style.css` links only if `style.css` changes.
- [ ] **Step 2:** `grep -n -i "dev server" site/docs.html plugins/elis/skills/elis/SKILL.md | grep -i phone`. Expected: no line added by this task.
- [ ] **Step 3:** Commit `docs: pages on the phone`.

### Task 15: Emulator end-to-end

**Files:** none tracked unless a defect is fixed (then a failing test first, in the owning task's style).

Verbatim rule: never execute `elis`/`elisctl` against the default socket, never launch or quit `~/Applications/Elis.app`. Use only an agent-owned emulator, never the owner's phone (`flutter test integration_test` uninstalls the app).

- [ ] **Step 1:** `S=/tmp/elis-pp1; mkdir -p $S; printf '{"workspaceGuideDone":true}' > $S/settings.json`. Build Debug (`scripts/build.sh` Debug variant or `xcodebuild -configuration Debug`). Launch: `env -u <every inherited CLAUDE*, ELIS_*, GHOSTTY_* name> open -n <Debug Elis.app> --env ELIS_STATE_DIR=$S`. Verify with `ps eww -p <pid>`. If `$S/elis.sock` is absent after 10 s, stop the pid and relaunch without `-g`. Record the pid.
- [ ] **Step 2:** `CTL=<Debug app>/Contents/MacOS/elisctl`. `$CTL phone port 47821 --socket $S/elis.sock` (any free port; check the form with `$CTL phone port --help`), `$CTL phone on --socket $S/elis.sock`, `$CTL phone link --socket $S/elis.sock`.
- [ ] **Step 3:** Start the agent-owned emulator, `flutter run -d <emulator>` from `mobile/`. Rewrite the link's `h=` to `10.0.2.2`; type it into the pair screen with `adb shell input text` in 40-character chunks.
- [ ] **Step 4:** On the emulator open a Live session and tap the terminal (the tag shows `Leading`). `printf '<h1 id=t>hello</h1><button type=button data-elis=notify data-elis-title=hi>n</button>' > /tmp/pp1.html`; `$CTL session overlay open --html /tmp/pp1.html --target <id> --socket $S/elis.sock`.
  Expected: the sheet shows `hello` (screenshot with `adb exec-out screencap -p`); `$CTL tree --json --socket …` shows `htmlOverlays[0].phone == true`; the Mac window shows no page; tapping `n` posts the notification on the Mac instance.
- [ ] **Step 5:** `adb shell input keyevent KEYCODE_HOME`. Expected within 5 s: `tree` shows the page without `remote`/`phone` (on the Mac). Bring the app back (`adb shell monkey -p ua.naiksoftware.elis 1`). Expected: the sheet shows again, `phone == true`.
- [ ] **Step 6:** Repeat Step 4 with `--markdown`, `--image`, `--url https://example.com` and `--html … --js --block`; close the last from the sheet and check the command's exit status is the dismissed one. Swipe a sheet down, check the chip, close the page from the Mac side with `session overlay close`, check the chip is gone.
- [ ] **Step 7:** `kill -TERM <pid>`; `lsappinfo list | grep -A4 elis.debug` (handle an entry as CLAUDE.md "Worktrees and local builds" says; tell the lead if a Dock tile lingers). Stop the emulator.
- [ ] **Step 8:** Report each expected result as seen or not seen. A failure goes back to its task; do not continue to Task 16 with one open.

### Task 16: Independent review

- [ ] **Step 1:** Run the `cross-model-review` workflow (or `/code-review`) on the branch diff. Verify each finding against the code; fix what holds with a test first.
- [ ] **Step 2:** Commit fixes per finding.

### Task 17: Gates, once

- [ ] **Step 1:** `cd macos/ElisCore && swift test`. Expected: all pass.
- [ ] **Step 2:** `cd macos && make test-app`. Expected: pass. Then `lsappinfo list | grep -A4 elis.debug`.
- [ ] **Step 3:** `cd macos && make lint`. Expected: zero findings.
- [ ] **Step 4:** `cd mobile && flutter analyze --no-pub && flutter test --no-pub`. Expected: clean, all pass. Restore `pubspec.yaml` `sdk:` and `pubspec.lock` if changed (keep the `webview_flutter` lines).
- [ ] **Step 5:** A failure is looked up in `docs/ci-flakes.md` before it is investigated. Do not open the PR for merge: Part 2 stacks on this branch.
