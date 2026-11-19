# Dev Servers on the Phone (Part 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A loopback `--url` page (a dev server on the host where the session runs) opens on the phone while the phone leads, with HTTP and WebSocket passing unchanged.

**Architecture:** The relay's presenter lists `page.forward`, so the origin hands it a loopback page as `.forwarded(url)`. The phone listens on `127.0.0.1` and opens one mux channel of a new type `forward` per accepted TCP connection that carries the sheet's cookie. The relay connects each channel to the loopback port the page names: directly for a local row, through one `ssh -L` listener per page for a remote row.

**Tech Stack:** Swift 6 (`ElisCore`, `elisctlKit`), Swift Testing, Dart / Flutter (`dart:io` `ServerSocket`), `webview_flutter`.

**Spec:** `docs/superpowers/specs/2026-11-20-phone-pages-design.md`, "Part 2". This plan stacks on `docs/superpowers/plans/2026-11-20-phone-pages-part1.md`; its branch is cut from Part 1's branch tip.

## Global Constraints

- All of Part 1's Global Constraints apply.
- The relay forwards only to the loopback host and port the page's URL names (`HtmlSource.isLoopback`), and only for a page the origin handed to this phone and that is still open.
- Works over BLE; nothing is hidden or disabled there. The sheet shows loading and the transport.
- Both PRs merge back to back with no release between them. If this part stalls, stop and ask the owner.
- The whole gates run once, in Task 7.

## Names reused from Part 1 (exact)

- `PresentationHub.pageForwardKind` (`"page.forward"`), `PresentationPageSource.forwarded(String)`, `AppStore.handedSource`: these already exist on master, not from Part 1 (ruling G6).
- `PresentationTestSupport.swift` in `ElisCoreTests` (Part 1 ruling F8): the shared `phone(_:)` harness.
- `PhoneLinkPresenter` (`kinds`, `Link`, `highWater`), `PhoneLinkPresenter+Pages.swift`, `PhoneLinkLineStream`, `PhoneLinkSession`.
- `PhoneLinkScheduler.open(channel:low:)`, `PhonePage` (`kind`, `url`), `PhonePageDown`, `PhonePageCodec`.
- Dart: `Mux`, `PresentChannel`, `PageLink`, `PhonePage`, `PageServer`, `PageSheet`, `PageChip`.
- Part 1 ruling F3: no single `present` line may exceed `PhoneLinkPresenter.highWater`; an `.overflowed` enqueue closes the channel. The same holds for forward output.
- `RemoteSession.forwardCommand(host:spec:)` (existing, `RemoteSession.swift:85`).

## Not verified by this plan

The remote-row branch (the `ssh -L` listener per page) has a unit test of its argv and no end-to-end run: the emulator task uses a local row.

## Tunnel gate (owner decision, spec "Part 2")

A path secret would break a dev server's absolute URLs, so the tunnel checks a cookie instead. Without a gate any site in Chrome on the phone, or any other app, could reach `127.0.0.1:<port>` and the dev server behind it.
- Before load the sheet sets cookie `elis_tunnel_<port>=<128-bit random hex>` for `http://127.0.0.1:<port>` through Android `CookieManager`, `HttpOnly; SameSite=Strict; Path=/`. A new value per sheet; the sheet removes it (an expired `Set-Cookie`) when it closes. Cookies ignore ports, so the name carries the port and a value is never reused across sheets. `webview_flutter`'s `WebViewCookie` carries no `HttpOnly` or `SameSite`, so a one-method platform channel calls `CookieManager.getInstance().setCookie(url, value)` and `flush()`.
- On every accepted connection the tunnel reads the first request's headers (up to `\r\n\r\n`), at most 16 KiB, within 5 s. Without the exact cookie, it closes the socket before it opens the `forward` channel. Fail closed: a parse error, the cap or the timeout closes too. After the check the buffered bytes go first into the channel; later requests on that connection are not parsed.
- The listener binds `127.0.0.1` only and closes with the sheet. It first binds the port of the page's URL (dev servers bake the port into absolute and HMR WebSocket URLs, and check `Host` and `Origin`), then port 0.

## Review Focus

1. A page that opens more connections than the cap (16): the extra connection is refused and the others keep working. Test in Task 3.
2. The dev server is not running when the page opens: the sheet shows the load failure, the channel closes, the page stays open for a reload. Test in Task 3.
3. A long-lived WebSocket while a large asset downloads and the user types: vt goes first, both streams finish. Test in Task 3.
4. A `forward` OPEN for a page id the origin never handed to this phone, or for a closed page: refused. Test in Task 3.
5. The page moves to the Mac (claim closes) with connections open: every forward channel closes and the phone's listener stops. Tests in Tasks 3 and 4.
6. A request without the sheet's cookie (another app, a site in Chrome): closed before any mux channel opens. Tests in Task 4.

## File Structure

| File | Responsibility |
|---|---|
| `macos/ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkMessages.swift` | `PhoneLinkOpen.page` |
| `macos/ElisCore/Sources/elisctlKit/PhoneLinkForward.swift` (new) | one `forward` channel: a TCP connection and its two credit windows |
| `macos/ElisCore/Sources/elisctlKit/PhoneLinkPresenter+Forward.swift` (new) | which pages may be forwarded, and the per-page ssh listener |
| `mobile/lib/pages/page_tunnel.dart` (new) | the phone's listener, its cookie gate and its `forward` channels |
| `mobile/android/app/src/main/kotlin/.../MainActivity.kt` | `setCookie` / `clearCookie` method channel over `CookieManager` |

---

### Task 1: The presenter takes loopback pages

**Files:**
- Modify: `macos/ElisCore/Sources/elisctlKit/PhoneLinkPresenter.swift` (`kinds`), `PhoneLinkPresenter+Pages.swift` (`pageRequest`)
- Create: `macos/ElisCore/Sources/elisctlKit/PhoneLinkPresenter+Forward.swift`
- Modify: `macos/ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkPages.swift` (doc of `PhonePage.kind`: add `"forward"`)
- Test: `macos/ElisCore/Tests/elisctlKitTests/PhoneLinkPresenterPagesTests.swift`, `macos/ElisCore/Tests/ElisCoreTests/AppStoreRemotePageTests.swift`

**Interfaces — Produces:**
```swift
// PhoneLinkPresenter.kinds gains PresentationHub.pageForwardKind
extension PhoneLinkPresenter {
    /// Where a forward channel for `page` connects, nil when the page is not an open forwarded page of this presenter.
    func forwardTarget(page: String) -> (host: String, port: UInt16)?
}
```
A `.forwarded(url)` request becomes a `page` line with `kind: "forward"` and `url`. For a local row `forwardTarget` is the URL's own host and port (default 80). For a remote row the presenter starts `RemoteSession.forwardCommand(host:, spec: "127.0.0.1:<free local port>:<url host>:<url port>")` once per page, waits until the local port accepts, and `forwardTarget` is `("127.0.0.1", <local port>)`; the process ends with the page. A URL that fails `HtmlSource.isLoopback`, or an ssh listener that does not come up in 10 s, answers `pageRejected`.
Ruling G1: Part 1's `spawn` seam builds a line stream from `(origin, pageToken)` and cannot carry this process. Add a second seam `forwardSpawn: ([String]) throws -> PhoneLinkLineStream`, defaulting to `PhoneLinkLineStream.process(argv:queue:)`: `close()` stops the `ssh -N` child, and `onEnd` means the listener died (its forwards close). Port readiness is a separate poll of the local port, bounded by the 10 s limit.

- [ ] **Step 1: Failing tests.**
  - `AppStoreRemotePageTests.aLoopbackUrlGoesToAPhoneThatForwards`: the Part 1 `phone(_:)` harness plus `page.forward`; `openRemotePage` of `http://127.0.0.1:5173/` is `.opened` and the phone sink holds `.pageRequest` with `.forwarded("http://127.0.0.1:5173/")`. (Part 1's `.local` test keeps a phone without the kind.)
  - `PhoneLinkPresenterPagesTests.aForwardedPageBecomesAForwardLine`: the phone reads `page` with `kind == "forward"`, `url == "http://127.0.0.1:5173/"`; `forwardTarget(page:)` is `("127.0.0.1", 5173)`; after `pageClose` it is nil.
  - `aRemoteRowStartsOneListenerPerPage`: with Part 1's `spawn` seam for the presentation stream, a recording `forwardSpawn` (G1) and `origin.host == "h"`, the argv recorded by `forwardSpawn` equals `RemoteSession.forwardCommand(host: "h", spec: "127.0.0.1:<port>:127.0.0.1:5173")`, it is started once for two forward channels, and its stream is `close()`d on `pageClose`.
  - `aNonLoopbackForwardIsRejected`: `.forwarded("http://example.com/")` → the stub reads `pageRejected`.
- [ ] **Step 2:** `cd macos/ElisCore && swift test --filter "PhoneLinkPresenterPagesTests|AppStoreRemotePageTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS.
- [ ] **Step 5:** Commit `feat(relay): the phone presenter takes loopback pages`.

### Task 2: Mux channel type `forward` on the relay

**Files:**
- Modify: `macos/ElisCore/Sources/ElisCore/PhoneLink/PhoneLinkMessages.swift` (`PhoneLinkOpen`)
- Create: `macos/ElisCore/Sources/elisctlKit/PhoneLinkForward.swift`
- Modify: `macos/ElisCore/Sources/elisctlKit/PhoneLinkSession.swift` (`open`, `receive`, `closeChannel`, `close`)
- Modify: `macos/ElisCore/Sources/elisctlKit/PhoneLinkPresenter.swift`, `PhoneLinkPresenter+Pages.swift` (`Link.pageEnded`, ruling G2)
- Test: `macos/ElisCore/Tests/ElisCoreTests/PhoneLinkMessagesTests.swift`

**Interfaces — Produces:**
```swift
// PhoneLinkOpen gains: public var page: String?      (init default nil; OPEN {"type":"forward","target":…,"page":…})
final class PhoneLinkForward: @unchecked Sendable {
    struct Link {
        let frame: (PhoneLinkFrame) -> Void                          // OPENED, CLOSE
        let output: (Data) -> PhoneLinkScheduler.Enqueue             // bytes to the phone, under its credit
        let pending: () -> Int
        let credit: (_ bytes: UInt32, _ sent: @escaping () -> Void) -> Void
        let ended: () -> Void
    }
    /// Bytes the phone may send ahead of CREDIT.
    static let window = 65536
    static let maxForwards = 16
    static let connectTimeout: TimeInterval = 5
    init(channel: UInt32, host: String, port: UInt16, queue: DispatchQueue, link: Link)
    func start()                 // connects; OPENED on success, OPENED with error "could not connect: <reason>" on failure
    func input(_ bytes: Data)    // from the phone; past `window` unacknowledged closes with reason "input overflow"
    func drained()               // reads the socket again while link.pending() < PhoneLinkPresenter.highWater
    func stop()
}
```
The socket is read on a plain thread, one read at a time, and the next read waits for `drained()`. Bytes written to the socket are credited back as `PhoneLinkClaim` does (`sendCredit`). The peer's EOF sends CLOSE with reason `closed`.

`PhoneLinkSession.open`: type `forward` needs `page`, a presenter whose `request.target == request.target`, and a non-nil `forwardTarget(page:)`; else OPENED error `no such page`. A 17th forward gets `too many connections`. Forward channels open with `scheduler.open(channel:, low: true)` and do not count toward `maxTerminals`. When a presenter stops or its page closes, the session stops that page's forwards.
Ruling G2: Part 1's `PhoneLinkPresenter.Link` has no page-closed signal. Add `let pageEnded: (_ page: String) -> Void`, called once when a page leaves the presenter for any cause (`pageClose`, `closed` from the phone, a pipe's end, `stop()`); the session stops that page's forwards from it.
Ruling G5: Task 2 ships `PhoneLinkForward` and the session routing with one message test; its behavior tests are Task 3. Dispatch Tasks 2 and 3 to one implementer as one unit, write Task 3's tests first, and review them together.

- [ ] **Step 1: Failing test.** `PhoneLinkOpen` round-trips `page` and omits the key when nil.
- [ ] **Step 2:** `swift test --filter PhoneLinkMessagesTests`. Expected: FAIL.
- [ ] **Step 3:** Implement the message, `PhoneLinkForward` and the session routing.
- [ ] **Step 4:** Run again. Expected: PASS. `swift build` clean.
- [ ] **Step 5:** Commit `feat(relay): a forward channel carries one TCP connection`.

### Task 3: Relay forward tests against a real loopback server

**Files:**
- Test: `macos/ElisCore/Tests/elisctlKitTests/PhoneLinkForwardTests.swift` (new)

**Interfaces — Consumes:** Tasks 1 and 2; the Part 1 fixtures (`MobileFixture`, `MemoryPhone`, `FrameReader`, `RawStubServer`). The test starts its own TCP listener on `127.0.0.1:0` on a plain thread and hands its port to the stub's `.forwarded` page.

- [ ] **Step 1: Tests.**
  - `bytesPassBothWays`: OPEN forward → OPENED; phone DATA `GET / HTTP/1.1\r\n\r\n` reaches the listener; the listener's reply reaches the phone byte for byte; the phone reads CREDIT for what it sent.
  - `aForwardForAnUnknownPageIsRefused` and `aForwardAfterThePageClosedIsRefused` (Review Focus 4): OPENED error `no such page`.
  - `aDeadServerRefusesTheChannelAndKeepsThePage` (Review Focus 2): the listener is closed first; OPENED error starts with `could not connect`; a later forward after the listener restarts on the same port opens.
  - `theSeventeenthConnectionIsRefused` (Review Focus 1): 16 open; the 17th OPENED error is `too many connections`; closing one admits the next.
  - `aLargeBodyAndAnOpenSocketShareTheLink` (Review Focus 3): one forward stays open and idle (a WebSocket), a second downloads 2 MiB while vt DATA is enqueued; every byte arrives in order, vt frames are read before the remaining forward frames, and the idle forward is still open.
  - `closingThePageClosesItsForwards`: the stub sends `pageClose`; the phone reads CLOSE on each forward channel and the listener sees EOF.
  - `inputPastTheWindowClosesTheChannel`: 65537 bytes with no CREDIT → CLOSE reason `input overflow`.
- [ ] **Step 2:** `swift test --filter PhoneLinkForwardTests`. Fix `PhoneLinkForward` or the session until all pass; blocking calls stay on plain threads (`.claude/rules/tests.md`).
- [ ] **Step 3:** Commit `test(relay): forward channels against a loopback server`.

### Task 4: Phone — `forward` channel and the tunnel listener

**Files:**
- Modify: `mobile/lib/link/mux.dart`
- Create: `mobile/lib/pages/page_tunnel.dart`
- Test: `mobile/test/mux_test.dart`, `mobile/test/page_tunnel_test.dart` (new), `mobile/test/wire_names_test.dart`

**Interfaces — Produces:**
```dart
// mux.dart
ForwardChannel forward(String target, String page);    // OPEN {"type":"forward","target":…,"page":…}
class ForwardChannel {
  Future<void> get opened;                              // throws ElisError with the relay's reason
  Stream<Uint8List> get bytes;                          // CREDIT is sent as the listener consumes them
  bool send(Uint8List bytes);                           // queued under the relay's 65536-byte window, as ClaimChannel
  Future<void> close();
}
// page_tunnel.dart
class PageTunnel {
  /// Binds 127.0.0.1:`preferredPort`, else 127.0.0.1:0. `cookie` is `name=value` the first request must carry.
  static Future<PageTunnel> start(ForwardChannel Function() open, {required int preferredPort,
      required String cookie, Duration headerTimeout = const Duration(seconds: 5)});
  static const maxHeaderBytes = 16 * 1024;
  static String newCookie(int port);   // 'elis_tunnel_<port>=' + 16 bytes from Random.secure(), hex
  int get port;
  Uri urlFor(Uri original);       // same path, query and fragment; scheme http, host 127.0.0.1, this port
  int get connections;
  Future<void> close();           // closes the listener, every socket and every channel
}
```
Each accepted socket is held until its first request's headers pass the gate (Tunnel gate above); only then it opens one channel and sends the buffered bytes first. Socket bytes go to `send`, channel bytes to the socket, either side's end closes the other. A refused OPEN closes the socket. Ruling G4: `PageLink` does not touch tunnels. The sheet owns the tunnel and its cookie (Task 5), and Part 1 Task 13 already removes the sheet in the same frame as `link.page == null`, for any cause.

- [ ] **Step 1: Failing tests.** `mux_test`: `forward opens, carries bytes and credits`. `page_tunnel_test`: a client socket connected to `port` sends bytes that arrive on the fake channel, and the channel's bytes arrive at the client; `a refused channel closes the socket`; `close ends every socket` (Review Focus 5, with two connected clients: both see the end, `connections == 0`); `urlFor(Uri.parse('http://localhost:5173/a?b#c'))` is `http://127.0.0.1:<port>/a?b#c`. Gate (Review Focus 6), each asserting the fake `open` was never called: `no cookie closes the socket`; `a wrong cookie closes the socket`; `headers over 16 KiB close the socket`; `headers not finished before the timeout close the socket`; `a WebSocket upgrade with the cookie passes` (`GET /ws` with `Upgrade: websocket`, `Connection: Upgrade` and the cookie among others in `Cookie:`: the channel receives the request bytes unchanged, then frames both ways); `a request after close is refused` (connect after `close()` fails). Port: `the preferred port is used when free`, and `a busy preferred port falls back to a random one`. `wire_names_test`: the OPEN type `forward` and the page kind `forward`.
- [ ] **Step 2:** `cd mobile && flutter test --no-pub test/mux_test.dart test/page_tunnel_test.dart test/wire_names_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again, `flutter analyze --no-pub`. Expected: PASS, clean.
- [ ] **Step 5:** Commit `feat(mobile): a tunnel for loopback pages`.

### Task 5: Phone — the sheet loads a forwarded page

**Files:**
- Modify: `mobile/lib/pages/page_sheet.dart`, `mobile/android/app/src/main/kotlin/.../MainActivity.kt` (the cookie channel)
- Test: `mobile/test/page_sheet_test.dart`

**Interfaces — Consumes:** `PageTunnel`, `PhonePage.kind == "forward"`, `Mux.forward`.

Rules: a `forward` page starts a `PageTunnel` (preferred port = the URL's port), sets its cookie through the platform channel, and only then loads `urlFor(Uri.parse(page.url))`. The sheet's close, for any cause (its `dispose` included), clears the cookie and closes the tunnel; it is their only owner (ruling G4). JavaScript is unrestricted when the page has `javascript`, as for a `url` page. Navigation stays on `127.0.0.1:<tunnel port>` unless `browse`. No adapter and no prelude: a URL page has no bridge. The identity strip shows the original URL (`page.title`) and the transport tag (`m.via`). While the main frame loads, the strip shows a progress bar; a failed load shows the error and a `Key('pageReload')` button, and reports `state` with `load: "failed"`.

- [ ] **Step 1: Failing widget tests** (fake `webView` builder, fake cookie channel): `a forward page loads through the tunnel` (the cookie is set before the controller is asked for a `127.0.0.1` URL with the page's path); `closing the sheet clears the cookie and closes the tunnel`; `two sheets in turn get different cookie values`; `a failed load shows reload and reports failed`; `the strip shows the original URL and the transport`.
- [ ] **Step 2:** `flutter test --no-pub test/page_sheet_test.dart`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS.
- [ ] **Step 5:** Commit `feat(mobile): a dev server opens in the page sheet`.

### Task 6: Docs and skill

**Files:**
- Modify: `site/docs.html` (`#phone-app`), `.claude/rules/control-api.md` (the `present` contract from Part 1: add `forward`, `maxForwards`, the window, the refusal texts; the phone's cookie gate, its 16 KiB cap and timeout, and the port choice), `plugins/elis/skills/elis/SKILL.md`, `plugins/elis/skills/elis/reference.md`, `site/llms.txt` if Part 1 touched it

Content:
- `docs.html`: a `--url` page on the session host's loopback (a dev server) opens on the phone, hot reload included; it is slow over Bluetooth; only the page's own sheet reaches the server (a per-sheet cookie), other apps and sites on the phone cannot; generated apps (a file manager, a workflow view, a log viewer) are served this way.
- `SKILL.md`: trigger "show the dev server on my phone"; pattern: start the server on loopback, `elisctl session overlay open --url http://127.0.0.1:PORT --js --block`, stop the server when the command returns. Ruling G3: `--js` is required; a `--url` page runs its own scripts only with it, on the Mac (`HtmlOverlayRegistry.swift:260`) and on the phone, so without it a dev server page is blank. `docs.html` shows the same command.

- [ ] **Step 1:** Write the text.
- [ ] **Step 2:** Commit `docs: dev servers on the phone`.

### Task 7: Emulator end-to-end, review, gates

Verbatim rule: never execute `elis`/`elisctl` against the default socket, never launch or quit `~/Applications/Elis.app`. Agent-owned emulator only.

- [ ] **Step 1:** Bring up the isolated Debug instance, the relay and the paired emulator exactly as Part 1 Task 15 Steps 1-3 (state dir `/tmp/elis-pp2`).
- [ ] **Step 2:** In the scratchpad create a real Vite app (`npm create vite@latest app -- --template vanilla`, `npm install`). Add to its `index.html` `<script type="module" crossorigin src="/extra.js"></script>` (`extra.js` sets `document.body.dataset.extra = 'ok'`). Start `npx vite --host 127.0.0.1 --port 5173 --strictPort` on a plain background process and record its pid. The tunnel logs each refused connection with the reason (`adb logcat`).
- [ ] **Step 3:** With the emulator leading: `$CTL session overlay open --url http://127.0.0.1:5173/ --js --block --target <id> --socket $S/elis.sock` in the background.
  Expected: the sheet shows the page (screenshot); `tree` shows `htmlOverlays[0].url` and `phone == true`.
- [ ] **Step 4:** Change the text in `main.js`. Expected within 5 s: the emulator shows it without any tap (HMR over the WebSocket; screenshot), and `extra.js` ran. `adb logcat` shows no refused connection from the WebView. If the HMR handshake or the `crossorigin` module request arrives without the cookie, do NOT remove the gate: stop and report to the lead with the log.
- [ ] **Step 4a:** Gate from outside the sheet: `adb shell 'toybox nc 127.0.0.1 <tunnel port>'` sending `GET / HTTP/1.1` without a cookie, and the same URL opened in Chrome on the emulator: both get the connection closed, and the Vite log shows no request.
- [ ] **Step 5:** `adb shell input keyevent KEYCODE_HOME`: the page shows on the Mac instance (`tree` without `phone`), served there directly. Bring the app back: the sheet shows the page again and Step 4 still works.
- [ ] **Step 6:** Close the sheet. Expected: the `--block` command returns the dismissed status; the server's log shows its sockets closed. Stop the dev server by pid.
- [ ] **Step 7:** `kill -TERM <pid>` of the Debug instance; `lsappinfo list | grep -A4 elis.debug`; stop the emulator. Report each expected result as seen or not seen; a failure goes back to its task.
- [ ] **Step 8:** Run the `cross-model-review` workflow (or `/code-review`) on this part's diff; verify each finding against the code and fix what holds, test first.
- [ ] **Step 9: Gates, once.** `cd macos/ElisCore && swift test`; `cd macos && make test-app` then `lsappinfo list | grep -A4 elis.debug`; `cd macos && make lint`; `cd mobile && flutter analyze --no-pub && flutter test --no-pub`. Expected: all pass, zero lint findings. Restore a temporary `sdk:` change before the last commit.
- [ ] **Step 10:** Both PRs are ready to merge back to back; tell the lead, and do not merge Part 1 alone.
