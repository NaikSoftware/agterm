# Open terminal links in a session overlay

## Overview
- A new setting chooses where a clicked web link from terminal output opens: the browser (default, today's
  behavior) or a full session web overlay with JavaScript, the navigation bar and saved logins.
- Only `http`/`https` links are affected. `mailto`, `ftp` and the Finder reveal of `file://` stay as they are.
- A link in a markdown HUD always opens in the browser, whatever the setting says, and the HUD stays up.
- While a HUD is up on a session, links in that session's panes open in the browser too: a full session
  page would close the HUD for good.
- A page opened this way can leave its first site: main-frame navigation across origins is allowed, and the
  panel header names the site of the document shown.
- Whenever the overlay cannot open or would not be visible, an eligible link is handed to the browser
  instead. Ignored schemes stay ignored.
- Control: `hangarctl browser links [browser|overlay]` sets or reads the setting and `tree` reports it.
  `hangarctl session overlay open --url URL --browse --js --navigation --persistent` opens the page a
  click opens; `--browse` alone only widens navigation.

## Context (from discovery)
- Every clicked link ends in `GhosttySurfaceView.openLink` (`Hangar/Ghostty/GhosttySurfaceView+Input.swift:583`),
  queued from `GHOSTTY_ACTION_OPEN_URL` in `Hangar/Ghostty/GhosttyCallbacks.swift:129`. The callback carries
  the URL only and runs after the click, so the click's modifiers are not available: no per-click override.
- `LinkPolicy.disposition` (`HangarCore/Sources/HangarCore/LinkPolicy.swift`) returns `.open` for
  `http`, `https`, `mailto`, `ftp`; `.reveal` for local `file://`; `.ignore` otherwise.
- HUD links reach the same `openLink` on the HUD's surface (`Hangar/Ghostty/HudLinkClick.swift`, #707).
- Surface ownership, enough to tell where a click came from with no new field: `hudBodyFile` is set on a
  HUD surface; `session` on primary and split panes; a sessionless surface whose `focusSession` owns it as
  its scratch surface is the scratch; other sessionless surfaces with a `focusSession` are program
  overlays; a quick terminal has no owner (`TerminalView.swift:47,61` supplies `focusSession`).
- Zoom: while `terminalZoom.target` is set, `WindowContentView.swift:320` hides the split layer and
  `WindowContentView+Zoom.swift:142` hosts the zoomed terminal surface only. Opening a page does not clear
  zoom (`TerminalZoom.swift:217`), so a page opened from a zoomed window is accepted and invisible.
- Slot: `AppStore.openHtmlOverlay` (`HangarCore/Sources/HangarCore/AppStore+HtmlOverlay.swift:40`) closes a
  HUD, then refuses with `.alreadyOpen` for a program or page, and `.presenter` while a presenter owns the
  session. The host adapter `openHtmlOverlay` in `Hangar/Control/ControlServer+SessionActions.swift:70`
  also refuses a remotely reserved slot and a failing saved store, then builds a persistent page eagerly
  so `browser.clear` counts it. It is `private`; the `openSessionOverlay` action is its public entry, and
  `GhosttySurfaceView` holds no reference to the server or to settings.
- `openLink` calls `NSWorkspace` directly, so a test of it today opens the real browser or Finder.
- Navigation: `HtmlNavigationPolicy.decide` (`HangarCore/Sources/HangarCore/HtmlOverlay.swift:238`) keeps a
  URL page's main frame on its original origin; anything else goes to a confirm sheet and the browser.
  New-window requests are confirmed-external; `createWebViewWith` returns nil.
- Header: `HtmlOverlay.identity` (`HtmlOverlay.swift:130`) shows the ORIGINAL origin for a URL page;
  `Hangar/Views/HtmlOverlayView.swift:81` draws it. Live page facts arrive through `setHtmlPage`
  (`HtmlPageInfo.page` is the current URL).
- Control bridge: installed for file pages only (`HtmlOverlayRegistry.swift:332`), so a URL page with
  JavaScript cannot reach `hangar.request`. This stays.
- Pattern for an app-global browser command: `browser.clear` in `ControlDispatcher+Browser.swift`,
  `ControlActions.clearBrowser`, `ControlServer+AppCommands.swift:134`, `hangarctlKit/MiscCommands.swift`.
- Pattern for a page flag: `--persistent`, see `docs/plans/completed/20261001-html-overlay-persistent-storage.md`
  (`ControlArgs`, `OverlayHtmlError`, `ControlDispatcher+Overlay.swift:39,131`, `ControlHtmlOverlayNode` in
  `ControlProjection.swift:402`).
- Settings: `HangarCore/Sources/HangarCore/AppSettings.swift`, `Hangar/SettingsModel.swift`,
  `Hangar/Views/SettingsView.swift`; enum-like settings are stored as raw strings and unknown values
  resolve to the default (`.claude/rules/settings.md`).
- `tree` top level: `ControlTree` in `ControlProjection.swift:562`, filled by `ControlServer.buildTree`
  (`ControlServer.swift:803`) and `AppStore.controlTree` (`AppStore.swift:280`); page nodes come from
  `AppStore.htmlOverlayNodes` (`AppStore+HtmlOverlay.swift:138`).
- `HtmlBridge.windowless` (`HtmlBridge.swift:59`) lists the commands a file page may send with no window.
- `--chromeless` already requires `--html` (`OverlayHtmlError.chromelessRequiresFile`), so a URL browsing
  page can never be chromeless.
- `scripts/test-app.sh` passes no arguments to `xcodebuild`, so it always runs the whole hosted suite.

## Development Approach
- **testing approach**: tests first for everything host-free in `HangarCore` (setting, routing decision,
  navigation policy, identity, protocol, dispatcher, projection, CLI); hosted tests on the in-process
  listener for WebKit navigation and for the click path.
- Complete each task before the next; all tests for a task pass before moving on.
- Every task includes its tests. Update this plan when scope changes.
- Existing pages keep their behavior: without `--browse` nothing about a page changes.

## Testing Strategy
- **core tests** (`cd HangarCore && swift test`): each task below.
- **hosted tests**: navigation across origins on the in-process listener, the header label after a
  navigation, the click path with its fallbacks. During a task run them with a direct `xcodebuild test`
  call carrying `-only-testing:HangarTests/<Class>/<test>` and the options `scripts/test-app.sh` uses.
- **gates**, once at the end: `swift test`, `make test-app`, `make lint`, and the Release build
  `scripts/build.sh`.
- One new XCUITest, for the picker, beside its siblings in `HangarUITests/SettingsUITests.swift`; it carries
  the General tab fit assertion. Run it alone with `-only-testing:`. The click path needs none: hosted
  tests cover it through `openLink`.

## Progress Tracking
- Mark completed items with `[x]` when done.
- Add newly discovered tasks with ➕ prefix, blockers with ⚠️ prefix.

## Solution Overview
- **Setting.** `LinkOpenMode` (`browser`, `overlay`) in `HangarCore`, stored on `AppSettings` as a raw
  string, default `browser`. One persistence path serves the Settings picker and the control command.
- **Routing decision in core.** A host-free function decides, from the link disposition, the setting and
  where the click came from, between `browser`, `overlay(sessionID)`, `reveal` and `ignore`. The click
  origin is one of: pane (session id), scratch (owning session id), HUD, program overlay, quick terminal.
  Only pane and scratch with an `http`/`https` link and mode `overlay` give `overlay`. The origin is
  derived from the surface's existing ownership fields.
- **Open with fallback in the app.** `openLink` asks the routing function. The surface gets an injected
  link opener set where surfaces are built; it reads the live setting and, for `overlay`, runs the
  existing `openSessionOverlay` action for the exact owner session id with a browsing page: JavaScript
  on, navigation bar on, saved store, full size, no session selection. Any refusal (occupied or reserved
  slot, presenter, saved store unavailable, unknown session) opens the link in the browser. A page that
  opened and then failed to load stays up with its existing Open in Browser action; no automatic
  browser launch.
- **HUD up.** A pane or scratch click on a session whose HUD is active opens the browser. The opener checks
  this live, after the route chooses the overlay and beside the zoom check. `AppStore.openHtmlOverlay` closes
  a HUD before taking the slot and reports success, so this is checked before the open, not read from a
  refusal.
- **Zoomed window.** A click in a window whose terminal zoom is active opens the browser: the page would
  be hidden behind the zoomed surface. Zoom is left alone, because clearing it returns to the selected
  session, which may not be the one clicked.
- **System effects are injected.** The opener carries the open and reveal effects, `NSWorkspace` by
  default, so tests assert them without opening anything. `mailto`/`ftp` keep the system scheme handler;
  the HTML `SystemBrowser`, which forces the default web browser, is not reused for them.
- **Browsing page.** `HtmlOverlay.browse` is a per-page flag. With it, `HtmlNavigationPolicy` allows
  main-frame `http`/`https` navigation to any origin, user-activated or not (script, form, redirect).
  File and custom schemes stay denied, new-window requests stay confirmed-external, subframes are
  unchanged. Without it, the origin-pinned policy is untouched.
- **No event, no restore.** The setting is poll-only through `tree`; pages stay ephemeral and only the
  setting persists. Each Mac applies its own setting to its own clicks.
- **Header.** For a browsing page, `identity` is the origin of the document currently shown, taken from
  the reported page URL, falling back to the source origin until the first report. Never the page title.
- **Rejected:** keeping a HUD alive under the page (needs HUD ownership separate from the slot occupant),
  a per-click modifier (the callback has no click state), importing browser logins (not possible),
  popup login support (the web view refuses new windows).

## Technical Details
- `AppSettings.linkOpenMode: String?`, `effectiveLinkOpenMode: LinkOpenMode` (unknown or nil → `.browser`).
- `LinkPolicy.ClickOrigin`: `.pane(UUID)`, `.scratch(UUID)`, `.hud`, `.programOverlay`, `.quick`.
- `LinkPolicy.Route`: `.browser(URL)`, `.overlay(URL, session: UUID)`, `.reveal(URL)`, `.ignore`;
  `LinkPolicy.route(for:mode:origin:)` wraps `disposition`.
- `HtmlOverlay.browse: Bool`, default false. Valid only with a URL source: `--browse` without `--url` is
  rejected by the dispatcher; the existing `--chromeless requires --html` rule covers the header.
  `--browse` changes navigation scope only; `--js`, `--navigation`, `--persistent` stay separate flags.
- Protocol: command `browser.links` with optional `mode`; no `mode` reads. Refuses a target or `--window`
  like `browser.clear`, and joins `HtmlBridge.windowless`. The effective mode comes back in `result.text`
  so a plain CLI read prints it. `ControlArgs.browse` for `session.overlay.open`.
- Read-back: `ControlTree.linkOpenMode` (always the effective value), `ControlHtmlOverlayNode.browse`
  (decoded with `decodeIfPresent ... ?? false`).
- Settings UI: a picker "Open links in" with "Browser" and "Session overlay", in the General tab's Mouse
  section, accessibility id `settings-link-open-mode`. The tab has a fixed-size window and a fit assertion
  (`SettingsUITests.swift:85`); if the row does not fit, stop and ask before moving anything.

## What Goes Where
- **Implementation Steps**: code, tests and docs in this repo.
- **Post-Completion**: manual checks in an isolated Debug instance.

## Implementation Steps

### Task 1: Setting and link routing in core

**Files:**
- Modify: `HangarCore/Sources/HangarCore/AppSettings.swift`
- Modify: `HangarCore/Sources/HangarCore/LinkPolicy.swift`
- Modify: `HangarCore/Tests/HangarCoreTests/LinkPolicyTests.swift`
- Modify: `HangarCore/Tests/HangarCoreTests/AppSettingsTests.swift`

- [x] write tests for `effectiveLinkOpenMode`: nil, `browser`, `overlay`, unknown value, round trip through encode/decode
- [x] write tests for `LinkPolicy.route`: every origin × both modes for `https`; `mailto`/`ftp` always browser; `file://` always reveal; ignored schemes stay ignored
- [x] add `LinkOpenMode`, the stored setting and its effective accessor
- [x] add `LinkPolicy.ClickOrigin`, `LinkPolicy.Route` (nested, like `LinkDisposition`) and `LinkPolicy.route`
- [x] update the `LinkPolicy` doc comment, which says the app side only calls two `NSWorkspace` methods
- [x] run `swift test` for these suites - must pass before task 2

### Task 2: Browsing pages: navigation scope and current-origin header

**Files:**
- Modify: `HangarCore/Sources/HangarCore/HtmlOverlay.swift`
- Modify: `Hangar/Views/HtmlOverlayRegistry.swift`
- `Hangar/Views/HtmlOverlayView.swift` needs no change: it already draws `overlay.identity` and redraws on every page report
- Modify: `HangarCore/Tests/HangarCoreTests/HtmlOverlayTests.swift`
- Modify: `HangarCore/Tests/HangarCoreTests/DashboardCoverTests.swift`
- Modify: `HangarTests/HtmlOverlayRegistryTests.swift`

- [x] write policy tests: a browsing page allows cross-origin main-frame `http`/`https` navigation with and without user activation; denies `file`, custom schemes and `about` stays allowed; new-window stays external only when user-activated; a non-browsing page decides exactly as before
- [x] write identity tests: a browsing page shows the reported page's origin, the source origin before the first report, and never the title; a non-browsing URL page and a file page are unchanged; the dashboard cover (`DashboardCover.swift:17,21`) reads the same identity and follows it
- [x] add `HtmlOverlay.browse` and the policy branch
- [x] make `identity` follow the shown document for a browsing page; confirm the view redraws when the page report changes
- [x] update the doc comments this falsifies: `HtmlOverlay.identity`, `HtmlNavigationPolicy`, and `browserURL` in `HtmlOverlayRegistry.swift:424`
- [x] write hosted tests on the in-process listener: a redirect to a second origin loads in a browsing page and is blocked in an ordinary one; first committed site → second site → back, with the header label following each; a failed or cancelled cross-origin load leaves the label naming the document still shown
- [x] run the targeted core and hosted tests - must pass before task 3

### Task 3: Control API and CLI

**Files:**
- Modify: `HangarCore/Sources/HangarCore/ControlProtocol.swift`
- Modify: `HangarCore/Sources/HangarCore/ControlDispatcher.swift`
- Modify: `HangarCore/Sources/HangarCore/ControlDispatcher+Browser.swift`
- Modify: `HangarCore/Sources/HangarCore/ControlDispatcher+Overlay.swift`
- Modify: `HangarCore/Sources/HangarCore/ControlDispatcherOptions.swift`
- Modify: `HangarCore/Sources/HangarCore/ControlActionsDefaults.swift`
- Modify: `HangarCore/Sources/HangarCore/ControlProjection.swift`
- Modify: `HangarCore/Sources/HangarCore/HtmlBridge.swift`
- Modify: `HangarCore/Sources/hangarctlKit/MiscCommands.swift`
- Modify: `HangarCore/Sources/hangarctlKit/SessionCommands.swift`
- Modify: `HangarCore/Sources/HangarCore/AppStore.swift` (`controlTree`)
- Modify: `HangarCore/Sources/HangarCore/AppStore+HtmlOverlay.swift` (`htmlOverlayNodes`)
- Modify: `Hangar/Control/ControlServer.swift` (`buildTree`, and the exhaustive command switch at `:574`)
- Modify: `Hangar/Control/ControlServer+AppCommands.swift`
- Modify: `Hangar/Control/ControlServer+SessionActions.swift`
- Modify: `Hangar/SettingsModel.swift`
- Modify: `HangarCore/Tests/HangarCoreTests/` `ControlDispatcherBrowserTests.swift`, `ControlDispatcherOverlayTests.swift`, `AppStoreTreeProjectionTests.swift`, `HtmlBridgeTests.swift`, `MockControlActions.swift`
- Modify: `HangarCore/Tests/hangarctlKitTests/MiscCommandsTests.swift` (`browser links`), `OverlayCommandsTests.swift` (`--browse`)
- Modify: `HangarTests/ControlServerTests.swift`

- [x] write dispatcher tests for `browser.links`: set each mode, bare read, invalid mode, target and `--window` refused
- [x] write dispatcher tests for `--browse`: accepted with `--url`; rejected with `--html` and without a page; `--url --browse --chromeless` still fails on the existing chromeless rule
- [x] write projection tests: `tree.linkOpenMode` reports the effective value including the default; `htmlOverlays[].browse` round-trips and decodes as false when absent
- [x] write CLI tests for `hangarctl browser links` and `session overlay open --browse`
- [x] add the protocol command, argument, action, dispatch and CLI; add `browser.links` to `HtmlBridge.windowless` with its test, and to the app's command switch
- [x] implement the app adapter: read and write the setting through the same `SettingsModel` path the picker uses; pass `browse` into `HtmlOverlay`
- [x] fill `linkOpenMode` in `buildTree`/`controlTree` and `browse` in `htmlOverlayNodes`
- [x] write a socket round-trip test: set the mode, read it back from `tree`; open a browsing page and read `browse` from `htmlOverlays`
- [x] run the targeted tests - must pass before task 4

### Task 4: Click path, fallbacks and the Settings picker

**Files:**
- Modify: `Hangar/Ghostty/GhosttySurfaceView+Input.swift`
- Modify: `Hangar/Ghostty/GhosttySurfaceView.swift`
- Create: `Hangar/Ghostty/LinkOpener.swift`
- Modify: `Hangar/hangarApp.swift` (one shared opener, set where the app is composed; a surface before that keeps the default, which opens the browser)
- Modify: `Hangar/Control/ControlServer+SessionActions.swift`
- Modify: `Hangar/Views/SettingsView.swift`
- Modify: `HangarTests/GhosttySurfaceViewInputTests.swift`, `HangarTests/SettingsModelTests.swift`
- Create: `HangarTests/ControlServerLinkOverlayTests.swift`
- Modify: `HangarUITests/SettingsUITests.swift`

- [x] derive `LinkClickOrigin` from the surface's ownership fields, HUD first; no new identity field
- [x] add the shared `LinkOpener` and set it once in `hangarApp.init`; its open and reveal effects are replaceable on their own, so a test swaps them on a factory-built surface and keeps the factory's overlay wiring
- [x] route `openLink` through `LinkPolicy.route`; for `.overlay`, run `openSessionOverlay` for the owner session id with a browsing page (JavaScript, navigation bar, saved store, full size), without selecting another session
- [x] fall back to the browser on every refusal (occupied slot, remotely reserved slot, presenter, saved store unavailable, unknown session) when the owner session's HUD is active, and when the owning window's terminal zoom is active
- [x] add the "Open links in" picker to the General tab, bound to the same setting
- [x] write hosted tests, split across `GhosttySurfaceViewInputTests` (surfaces given each ownership shape: origin per kind, overlay then browser fallback) and `ControlServerLinkOverlayTests` (the open and its refusals on real sessions): pane link in overlay mode opens a browsing page on that session; scratch link opens on its owning session; HUD link opens the browser and the HUD is still active; quick terminal and program-overlay links open the browser; each refusal opens the browser; a pane click on a session with an active HUD opens the browser and the HUD is still active; a click in a zoomed window opens the browser, creates no page and leaves zoom set; `mailto` and `file://` are unchanged; browser mode never opens a page; a browsing page whose load fails stays up and the open effect is not called
- [x] write a hosted test that the `SettingsModel` value behind the picker and `browser.links` are one value; add `testLinkOpenModePickerPersists` to `SettingsUITests.swift` with the fit assertion and run it alone
- [x] run the targeted hosted tests - must pass before task 5

### Task 5: Verify acceptance criteria
- [x] verify each Overview bullet against the built app's tests
- [x] run `cd HangarCore && swift test`
- [x] run `make test-app`
- [x] run `make lint`
- [x] run `scripts/build.sh` (Release)
- [x] run `lsappinfo list | grep -A4 hangar.debug` and clear leaked test processes

### Task 6: [Final] Update documentation
- [x] `site/docs.html`: the setting, what it covers, the fallbacks, HUD links, that logins are Hangar's own
- [x] `site/commands.html`: `browser links`, `--browse`, `tree.linkOpenMode`, `htmlOverlays[].browse`
- [x] `plugins/hangar/skills/hangar/SKILL.md` and `reference.md`: the command, the flag, both read-backs
- [x] `.claude/rules/control-api.md`: `browser.links` in the public catalog and in the bridge sentence beside `browser.clear`; record that the setting has no event and pages no restore
- [x] `.claude/rules/settings.md`: the setting as a control-backed one, like `flaggedViewLayout`
- [x] `.claude/rules/libghostty.md`: no change, it does not cover link clicks; the routing seam is recorded in `control-api.md`
- [x] `ARCHITECTURE.md`: no change, it does not describe link routing
- [x] move this plan to `docs/plans/completed/`

## Post-Completion

**Manual verification** in an isolated Debug instance (`/tmp` state dir, its own socket):
- click a link in overlay mode, sign in on a site with a redirect login, close, click again: still signed in
- confirm the header shows the login site's origin during the redirect
- click a link while a program overlay is up: the browser opens
- click a HUD link: the browser opens and the HUD stays
- click a pane link while a HUD is up: the browser opens and the HUD stays
- click a link in a zoomed pane: the browser opens and zoom stays
- change the picker in Settings and confirm `hangarctl browser links` reads the new value
