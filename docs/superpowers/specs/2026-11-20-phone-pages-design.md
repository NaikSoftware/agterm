# Pages on the phone

Date: 2026-11-20. Status: approved for planning (owner delegated review).

## Intent

A session program can put content in front of the person who drives the session.
Today it reaches only the Mac: a page opened while the person drives from the phone shows on the Mac,
under the "In use on your phone" cover, and the phone shows nothing.
The owner wants to see on the phone what the session opens for a person:
a Claude artifact, a dashboard such as ponytail's Board, an image, a dev server the agent runs,
and generated apps such as a file manager or a GitHub workflow view the agent writes and serves on the Mac.
The owner also wants the phone as an input: a camera photo goes into the session.

Success: the owner drives a session from the phone, asks an agent to show something,
and it opens on the phone, works there, and goes away when closed.

## Goals

- The phone is one more presenter of the session's existing HTML overlay.
  A page shows where the session is driven: on the phone while the phone leads the pane, on the Mac otherwise.
- These page sources work on the phone in v1: `--html` (with `--cwd`, `--js`, the bridge), `--url`, `--image`,
  `--markdown` without `--navigation`, `--text` without `--follow-file` (static),
  and loopback `--url` dev servers with WebSocket hot reload (part 2).
- A photo taken on the phone lands as a file next to the session and its path is pasted at the cursor.
- Local rows and remote rows (another Mac, elis-server) behave the same.

## Non-goals

- Intercepting `/usr/bin/open`, `BROWSER` or OSC 8 taps. `open` goes straight to LaunchServices and Elis never sees it;
  a PATH-front shim loses to `/usr/bin` and would catch every `open -a`.
  A program shows a page through `elisctl session overlay open`; the agent skill says so.
- Asks, picks, program overlays, HUDs and status sounds on the phone. They stay on the Mac as today.
- A browser: no address bar, tabs, or links followed past the page's bounds (CLAUDE.md overlay rule).
- In v1, named as a follow-up: `--text --follow-file` log pages (`page.text`), diff and files pages (`page.files`),
  and markdown with `--navigation` links (`page.links`).
  The hub filter sends them to the Mac viewer even while the phone leads.

## Anti-goals

- A page reaching `phone.*` or the pairing token.
- A file read on the Mac outside the page's grant.
- A page that outlives what it shows, on either screen.
- Large page transfers that stall typing in the terminal.
- A feature hidden or disabled because the transport is BLE; BLE is slow, and the user decides.

## Approaches

- **A. The phone becomes a presenter (chosen).** The relay registers a `zmx.present` subscriber for the phone.
  The existing placement rule routes pages to it while the phone leads the pane.
  No new page concept; `--block`, outcomes, release and read-back keep working.
- **B. A separate `session share` slot.** Cheaper (~500 lines), but a second page concept the Mac cannot show,
  no bridge, no dev servers, and no path for server rows.
- **C. Capture `open` / `BROWSER`.** Rejected: Elis cannot see `/usr/bin/open`.

The owner picked A after reviewing all three.

## Delivery

Separate PRs, in this order (my call; the owner did not object):

1. Pages on the phone.
2. Dev servers on the phone (loopback proxy).
3. Camera photo into the session.
4. Built-in pages: a later project with its own design.

Master never holds part 1 without part 2: a phone that leads could not show a loopback page, and a missing
remote path needs the owner's direct approval. PR 2 stacks on PR 1's branch, and both merge back to back with no
release between them. If part 2 stalls, stop and ask the owner; never merge part 1 alone.
PR 1's skill and `site/docs.html` text does not mention dev servers; PR 2 adds it.

## Part 1: pages on the phone

### Relay presenter

- `elisctl mobile serve` runs one `PhoneLinkPresenter` (new, elisctlKit) per session the phone views.
  It connects with `zmx.present <session>` on the app socket for local rows, and with
  `ssh -T <host> elisctl zmx present` for server and other-Mac rows, through the argv builders the relay
  already uses for `session.attach`.
- Its hello lists `lead.report`, every `PresentationHub.pageKinds` entry, `page.content`, `page.document`,
  `pending.snapshot`, `job.token`, `offer.id`, and a new `viewer.phone`.
  The hub negotiates `viewer.phone` (`supportedKinds + [viewerPhoneKind]`) but keeps it out of `supportedKinds`:
  that list is also the Mac viewer's own hello (`RemotePresentationClient`), and a Mac must never list it.
  It omits `page.text`, `page.files` and `page.links` (see Non-goals).
  `offer.id` is required, and the relay echoes the offer in its answers: without it `noteGivenUp`
  (`OfferlessHolders.swift:20`) records the phone after its first give-back, and pages never return to it.
  It never asks for the presenter grant and ignores every other frame (`layout`, status, pick).
- It sends `lead.report` for a pane while the phone's claim on it is open and withdraws it when the claim closes,
  and only after the origin's hello lists `viewer.phone`: an older origin would route asks to it.
  `session.attach` answers `origin {session, pane, host}`, the ids a `lead.report` names on the origin.
  `PresentationHub.route` already returns the newest claimant (`PresentationHub.swift:334`),
  so routing does not change.

### Placement guard

- One rule: work the phone does not show is routed as if no `viewer.phone` subscriber existed.
  The next claimant or the grant holder (the user's Mac viewer) gets it; with neither, the origin keeps it.
  A nil recipient is not enough: on a headless elis-server origin nil means "hold for a viewer",
  so an ask would hang unseen on both screens.
- The filter lives in `PresentationHub` (`route`, `leadClaimant`, and `pendingRecipient`), taking the work kind
  (`.page` or `.other`), so every path obeys it: new work through `remoteRecipient`,
  open work moved by `AppStore+OpenWork.place()` (`placeSessionAsk`, `placeWindowAsk`, `placePick`),
  and held work offered by `offerPendingInteractions`.
  Without it asks fail with `.formUnsupported`, open asks and picks move to a phone that ignores them,
  and overlays and sounds go to a viewer that cannot show them.
- `.page`: `AppStore+RemotePage` and `placePages`. `.other`: `AppStore+Presentation`, `AppStore+RemoteAsk`,
  `AppStore+RemoteOverlay`, `AppStore+RemotePresentation`, `SessionPick`, and the non-page `place()` calls.
- A page the phone cannot show (a missing kind) goes to the next recipient by the same rule,
  instead of the `.loopback` / `.unsupported` refusal (`AppStore+RemotePage.swift:71-73`).
  A phone shows a page only when it lists every kind the page uses: `page.text` for a log page,
  `page.files` for a diff page, `page.links` for markdown with links. No downgrade as for an older Mac.
  Loopback `--url` pages go to the phone through part 2.
- Before coding, confirm that a phone claim makes the Mac's `ZmxLeadBook` mark the pane `.follower`;
  `presentsRemotely` depends on it.

### Wire

- A new mux OPEN type `present` with `{target}`, one channel per viewed session.
  An older relay answers `unsupported channel type`, and the phone runs without pages.
  No new frame kind: both decoders treat an unknown kind as fatal.
- The channel uses its own credit window and sits below vt in the scheduler (0 > 1 > vt > present).
- Relay to phone (JSON lines): `page` (id, kind, path or url, javascript, chromeless, browse, title, sizePercent),
  `command` (close, hide, show, reload, navigate), and answers to `fetch` and `bridge`.
  A content page (image, markdown, text) is a `page` line with the HTML the relay renders with `ImagePage`,
  `MarkdownPage` or `TextPage`, plus the renderer script; `MarkdownAssets` moves into ElisCore for that.
- Phone to relay: `fetch` (id, seq, path), `bridge` (id, seq, line), `state` (loaded or failed, title, current,
  canGoBack; sent on as `pageState`), `closed` (id, dismissed).

### File pages and the bridge

- The relay claims a file page with its single-use token through `session.overlay.page.serve <token>`,
  on the app socket or over ssh, inside the existing 30 s window, and holds that `PageServeStream` while the page shows.
- Each `fetch` becomes a `PageServeFrames` resource request, gated by `RemotePageResources.resolve`.
- Each `bridge` line becomes a `PageServeFrames` bridge request, dispatched on the origin through `HtmlBridge`.
  The relay never forwards a bridge line as a channel-0 command: channel 0 runs with the pairing token's full authority.
- `adapterScript` moves into ElisCore. The relay sends it with the page, so the phone and the Mac run one source.

### Phone

- New dependency `webview_flutter` (Android System WebView, present on minSdk 35).
- A page sheet over the session view. Full height for `sizePercent` 100, else that fraction.
  The session screen stays edge to edge (owner preference).
- File pages load from a Dart `HttpServer` on `127.0.0.1` with a random 128-bit path secret per sheet, GET only,
  closed with the sheet. Every request becomes a `fetch`.
- URL pages load directly, pinned to their origin; `--browse` lifts the pin.
  Content pages load the relay's HTML.
- Android has no isolated content world, so WebView JavaScript is on for every file page to run the bridge adapter.
  Without `--js` the loopback server sends `Content-Security-Policy: script-src 'none'`, which blocks the page's own
  scripts. An emulator spike (part 1 Task 12) proves this before the sheet is built; if it fails, work stops for the
  owner. `elis.request` only for `--js` file pages, in the main frame. File and content access off.
- Markdown links render as plain text, inactive and not styled as links: never a dead tap.
- The identity strip mirrors the Mac's.
- Close, back and `window.close()` send `closed` with `dismissed`. The origin records it and fires `HtmlOverlayReleases`.
- A sheet swiped down stays live behind a page chip in the session's top bar; one tap brings it back.
  The chip is the page's only entry point.

### Following the lead

- A page follows the pane lead in both directions, already open pages included.
  When the phone's claim closes (background, leaving the session, pane switch, link loss), the page moves to the Mac.
  When the phone claims again (resume claims on OPENED, `session.dart:208`), the page moves back to the phone.
  After a Mac take-back the phone claims on its next input, and the page returns then.
- Keeping the lead report alive while a sheet is open without a claim was rejected:
  placement would depend on state the user cannot see. A page is where "Leading" shows.
- Only pages of the pane the phone leads move, plus a session-wide page when that pane is the primary one.
  Pages of other panes and page rows (`session.content == .page`) stay where they are.
- A hidden page moves hidden (`offered.hidden`): on the phone it sits behind the chip with no sheet.
- A move does not end `--block`; the outcome stays pending.
- Known limit, stated in the docs: a move reloads the page, so scroll and form state are lost.
  Every app switch on the phone moves the page twice. Only a grace period before the claim closes would reduce that,
  which changes the 2026-11-19 lead decision ("pause releases it"); it is left to the owner.

### Clearing

- The sheet and its chip close whenever the page leaves the phone: the claim closes, the `present` channel ends,
  or the origin sends `close`. A chip for a page that is now on the Mac is a defect.
- When the phone disconnects, the relay ends the subscriber, the lead report goes away,
  and `reconcileOpenWork` moves the page back to the Mac.
- The `present` channel lives while the session screen is open, not while the app is in the foreground.
  In the background the claim closes and the origin moves the page; the channel stays and receives it back.

### Emulator test

The owner asked for testing on an Android emulator. Each part ends with an end-to-end run:
an isolated Debug instance (short `/tmp` `ELIS_STATE_DIR`, its own relay port), an agent-owned emulator paired
through `10.0.2.2`, and a page opened with `elisctl --socket <isolated>` while the emulator leads.
The run checks that the page shows on the emulator, returns to the Mac on background, and comes back on resume.
Never run integration tests on the owner's phone: `flutter test integration_test` uninstalls the app.

### Read-back and CLI

- No new command: `session.overlay.open` and its lifecycle commands work unchanged.
- `htmlOverlays[].phone: true` on `ControlHtmlOverlayNode` when the slot's owner lists `viewer.phone`.
  `elisctl tree` prints it; `site/commands.html` lists it.
- `presenters` in the tree counts no phone; `phoneViewers` already reports it.

### Tests

- ElisCore: a `viewer.phone` fake subscriber that reports the lead gets the `pageRequest`;
  gets no ask, overlay, pick or sound (one test per call site), and no already open ask or pick at take-over;
  with a Mac viewer also attached, that work goes to the Mac viewer, on a local and on a headless origin;
  a page of a kind it lacks goes to the next recipient;
  a log page, a diff page and a markdown page with links each go to the Mac viewer while the phone leads,
  with `htmlOverlays[].phone` absent;
  the page returns to the Mac when the lead is withdrawn, and back to the same subscriber when it reports the lead again;
  a hidden page moves hidden; a `viewer.phone` subscriber never becomes `grant.holder`;
  a GUI ask in a window and a held interaction on a headless origin stay off the phone.
- elisctlKit `PhoneLinkSession`: OPEN `present` accepted; a `fetch` outside the grant refused;
  a `bridge` line with `phone.status` refused with `cannot be sent from a page`; `closed` records dismissed.
- `ControlProjection`: `phone: true`.
- Flutter: `present` channel decoding; the loopback server refuses a wrong secret; sheet close sends `closed`.
- Emulator spike: a markdown page without `--navigation` has no active or link-styled element.
- One hosted test in `ElisTests/ControlServerPageServeTests`: `--html --block`, closed from a fake phone,
  exit code dismissed. Not a UI test: default UI-test launches bypass zmx, so no pane can follow.

### Docs

- `site/docs.html` phone section; `site/commands.html` read-back field; `control-api.md` placement rule;
  the phone stream spec (pages leave its non-goals).
- `plugins/elis/skills/elis/SKILL.md`: a trigger and a rule. To show a page, use
  `session overlay open --html FILE --js`, never `open`; it follows the user to the phone.
- `site/docs.html` and the skill say plainly that log pages, diff pages and markdown with `--navigation`
  open on the Mac even while the phone leads. The skill warns that `--block` on such a page waits on a screen
  the user may not see.

### Board

Elis cannot catch ponytail's `open board.html`. A few lines in ponytail's `openBoard` fix it:
when `ELIS_SESSION_ID` is set, run `elisctl session overlay open --html <file> --js --target <id>`.
`board.html` needs `--js`, because its inline script fills the page. Ponytail is third-party.
On the phone, Save PNG/SVG needs a WebView download handler,
and the board's theme resets each time, because storage is per page.

## Part 2: dev servers on the phone (short)

- A loopback `--url` page routed to `viewer.phone` opens on the phone.
- A separate TCP listener on the phone tunnels that page: each accepted connection that passes the gate opens a
  mux channel `forward {page id}`. The relay connects it to the Mac's loopback port, or through ssh to the server
  host's loopback for a server row. HTTP and WebSocket (hot reload) pass unchanged.
- The relay forwards only to the loopback port the page names, and only for a page the origin handed to this phone.
- Threat: the tunnel listens on `127.0.0.1` of the phone, so without a gate any site open in Chrome on the phone,
  or any other app, could reach `127.0.0.1:<port>` and through it the dev server on the Mac.
- Gate. Before load, the phone sets a cookie with a 128-bit random value for `http://127.0.0.1:<port>` through
  Android `CookieManager`, `HttpOnly`, `SameSite=Strict`. Each sheet gets a new value, removed when the sheet closes.
  Cookies ignore ports, so a value is never reused across sheets.
  On every accepted connection the tunnel reads the first request's headers, with a 16 KiB cap and a timeout.
  Without the right cookie it closes the connection before it opens the `forward` mux channel. It fails closed.
- The listener binds `127.0.0.1` only and closes with the sheet.
  It first tries the port number of the Mac's dev server, then a random one:
  dev servers bake the port into absolute URLs and HMR WebSocket URLs, and check `Host` and `Origin`.
- The emulator run checks with a real Vite dev server that Android System WebView sends the cookie on the HMR
  WebSocket handshake and on `<script type=module crossorigin>` requests. If it does not, the gate stays and work
  stops for the owner.
- Works over BLE; slow, and the sheet shows loading and the transport.
- Stopping the agent's server: the agent opens the page with `--block` and stops its server when that returns.
  The skill documents the pattern.
- This is the path for generated apps: a file manager, a GitHub workflow view, a log viewer.

## Part 3: camera photo into the session (short)

- A camera control in the phone's session view takes a photo, or picks one from the gallery.
- The phone sends it over a mux channel `upload {target, name, size}` in 64 KiB frames.
- The relay writes it on the host where the session runs (local, or through ssh for a server row) into a per-session
  folder under the state directory, then pastes the absolute path at the cursor through the session's normal paste path.
  This works for any program; an agent reads the path.
- Read-back and cleanup of that folder, and a size cap, are open.
- Known limit: the system camera sends the phone app to the background, so an open page moves to the Mac and back,
  and reloads. No grace period without the owner asking for one.

## Part 4: built-in pages (later)

Elis ships pages of its own that open the same way, so an agent does not write them each time:
for example a file manager for the session's folder and a GitHub workflow view for the session's repository.
They build on parts 1 and 2. They get their own design: which pages, who serves them, and what they may touch.

## Decisions

The owner delegated open questions to a stand-in reviewer, who decided from the owner's earlier answers:

- Pages follow the lead both ways (see Following the lead).
- Parts 1 and 2 merge back to back (see Delivery).
- The bridge works on the phone in v1, with the same refusals as on a second Mac:
  a `data-elis` button that is silently dead on the phone would break "a page works the same wherever it shows".
- Work the phone does not show goes to the next viewer, not to nil (see Placement guard).
- v1 scope is the list under Goals; log, diff and linked-markdown pages are a follow-up (owner, 2026-11-20).
- The part 2 tunnel is gated by a cookie, not accepted open (owner, 2026-11-20).

## v1 limits for the final report

- Log pages (`--text --follow-file`), diff and files pages, and markdown with `--navigation` stay on the Mac.
- Every app switch on the phone moves an open page twice and reloads it.
- Save PNG/SVG in Board needs a WebView download handler; no task adds one.
- Remote rows are covered by kit tests only, not on the emulator.
- On a headless (elis-server) origin a page stays on the phone after the phone stops leading,
  until another viewer reports the lead of that pane (pre-flight ruling F9).

## Left to the builder

- `PageServeFrames` request shapes and the hub's acceptance of a grant-less subscriber; read before coding.
- How the relay names a remote row's pane identity in `lead.report`.
- `reconcileOpenWork` for a phone that drops inside the 30 s claim window.
