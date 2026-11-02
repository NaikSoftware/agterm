# File Tree Panel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A minimal file tree column to the right of the sessions sidebar that shows the active session's current directory, opens files in agterm's built-in viewers, and supports rename, delete, cut/copy/paste, drag-move, drag-out to the terminal and "new companion here".

**Architecture:** Per-window state (`filePanelVisible`, `filePanelWidth`) lives on `AppStore` and persists in `Snapshot`, mirroring `sidebarVisible`/`sidebarWidth`, with matching control API. Host-free file logic (listing, collision names, move validation) and the icon catalog live in `agtermCore`. The panel itself is an AppKit `NSOutlineView` wrapped in `NSViewRepresentable`, the same choice and theming path as `WorkspaceSidebar`. Icons are glyphs from the Atom `file-icons` package fonts, tinted at draw time.

**Tech Stack:** Swift 6, SwiftUI + AppKit (`NSOutlineView`, `NSPasteboard`, `FSEventStream`, CoreText font registration), `FileManager`, Swift Testing / XCTest per existing targets.

**Spec:** No separate spec. The user's request (this conversation, 2026-11-03), restated as requirements:
- second column right of the sessions sidebar, toggled by a titlebar button next to the sidebar toggle;
- flat, minimal, matches the sidebar; follows the app theme live, including theme-picker preview;
- Atom `file-icons` icon set (user decision);
- tree of the current directory;
- click opens md/txt/image in the built-in viewer, anything else in the system default app;
- context menu: rename, delete, new subsession (companion) here, cut/copy/paste;
- ⌘C / ⌘X / ⌘V and the menu analogs (user decision: Cmd, not Ctrl);
- drag and drop to move inside the tree;
- drag a file into a terminal pane (agents run in the terminal; there is no separate agent input field, verified).

## Global Constraints

- `agtermCore` imports no AppKit, GhosttyKit, Metal or CoreGraphics. Colors cross as hex strings, geometry as `Double`.
- Every change builds and passes `cd agtermCore && swift test`, `make test-app`, `make lint` (zero findings). Run each full gate once, at the end; run new tests with `-only-testing:` / `--filter` while iterating.
- Never execute `agterm`/`agtermctl` against the default socket, never launch or quit the deployed app. Manual runs use an isolated `open -n` Debug instance per `CLAUDE.md`.
- Work in a native Claude worktree forked from fetched `origin/master` (this fork: `NaikSoftware/agterm`); symlink the six ignored artifacts per `CLAUDE.md` "Worktrees and local builds".
- Do not animate the panel's show/hide: resizing the detail column reflows every eager-deck surface (`WindowContentView.swift:312-315`).
- Never overwrite an existing file on paste, move or rename. A collision on copy gets a Finder-style name; a collision on move or rename is refused with an error.
- Delete moves to the Trash (`FileManager.trashItem`), never `removeItem`.
- Comments: only non-obvious constraints, one line. No doc comment longer than its body.
- Do NOT add an `InterfaceElement` case for the new button (user decision): the button is always shown.
- Default chord for `toggle_file_panel`: ⌃⌘E (free today; ⌃⌘S is the sidebar).

## Review Focus

1. The shown directory is deleted or becomes unreadable (agent `rm -rf`, `cd` into a dir without permission) → panel shows an empty-state line, never crashes or shows stale rows. Test in Task 2 (`childrenOfMissingDirectoryThrows`) and Task 5 (empty state).
2. Active session is remote (`remoteHost != nil`) and its cwd does not exist locally → panel shows "No local folder", not the Mac's home tree. Covered by reusing `Session.localWorkingDirectory`; check in Task 5.
3. Paste or drag-move onto a name that already exists → copy gets "name copy"/"name copy 2", move is refused; nothing is overwritten. Tests in Task 2.
4. Moving a folder into itself or its own descendant → refused. Test in Task 2.
5. A huge directory (`node_modules`, 10k+ entries) expanded → children load lazily per expansion; the watcher reloads only expanded folders. Manual check in Task 5.

---

### Task 1: File panel state, persistence and control API

**Files:**
- Modify: `agtermCore/Sources/agtermCore/AppStore.swift` (next to `sidebarVisible`:82 and `sidebarWidth`:116-121; `controlTree` near :424)
- Create: `agtermCore/Sources/agtermCore/AppStore+FilePanel.swift`
- Modify: `agtermCore/Sources/agtermCore/Snapshot.swift` (optional fields with decode defaults, like `sidebarWidth`)
- Modify: `agtermCore/Sources/agtermCore/ControlProtocol.swift`, `ControlProjection.swift` (`ControlTree`), `ControlDispatcher.swift`, `ControlActions.swift`, `ControlActionsDefaults.swift`
- Modify: `agtermCore/Sources/agtermctlKit/MiscCommands.swift`, `SocketClient.swift`
- Modify: `agterm/Control/ControlServer+AppCommands.swift`
- Test: `agtermCore/Tests/agtermCoreTests/AppStoreFilePanelTests.swift` (new), `ControlDispatcherFilePanelTests.swift` (new), `SnapshotRoundTripTests.swift`, `AppStoreTreeProjectionTests.swift`, `MockControlActions.swift`; `agtermCore/Tests/agtermctlKitTests/CommandsTests.swift`

**Interfaces:**
- Produces:
  - `AppStore.filePanelVisible: Bool` (default `false`), `AppStore.filePanelWidth: Double` (default 240, clamp 160...560)
  - `AppStore.setFilePanelVisible(_ visible: Bool)` (no-op when unchanged, then `save()`), `AppStore.toggleFilePanelVisible()`, `AppStore.setFilePanelWidth(_ width: Double)` (clamps, no-op when unchanged, saves)
  - `ControlCommand.filePanel = "filepanel"`, `.filePanelWidth = "filepanel.width"`; `ControlArgs.filePanelWidth: Double?`; `ControlResult.filePanelWidth: Double?`
  - `ControlTree.filePanelVisible: Bool?`, `ControlTree.filePanelWidth: Double?`
  - `ControlActions.setFilePanelVisibility(_ mode: ControlToggleMode) -> ControlResponse`, `setFilePanelWidth(_ points: Double, window: <same selector type setSidebarWidth uses>) -> ControlResponse`
  - CLI: `agtermctl filepanel [show|hide|toggle]`, `agtermctl filepanel width <points> [--window ...]`

- [ ] **Step 1: Write failing tests**

```swift
@Test func filePanelDefaultsHiddenAt240() { let s = AppStore(); #expect(!s.filePanelVisible); #expect(s.filePanelWidth == 240) }
@Test func filePanelWidthClamps() { let s = AppStore(); s.setFilePanelWidth(10); #expect(s.filePanelWidth == 160); s.setFilePanelWidth(9999); #expect(s.filePanelWidth == 560) }
@Test func filePanelStateRoundTripsThroughSnapshot()   // visible=true, width=300 survive encode/decode
@Test func oldSnapshotWithoutFilePanelDecodesDefaults() // JSON lacking both keys → false / 240
@Test func treeReportsFilePanelState()                  // controlTree.filePanelVisible/Width match the store
// dispatcher
@Test func filePanelToggleRoutesToActions()             // mode "toggle" → mock records .toggle
@Test func filePanelRejectsBadMode()                    // error == "invalid filepanel mode: bogus"
@Test func filePanelWidthRejectsNonFinite()             // .infinity → ok == false
// ctl
#expect(try request(["filepanel", "hide"]) == ControlRequest(cmd: .filePanel, args: ControlArgs(mode: "hide")))
#expect(try request(["filepanel", "width", "300"]) == ControlRequest(cmd: .filePanelWidth, args: ControlArgs(filePanelWidth: 300)))
```

Use the construction helpers the neighboring sidebar tests use; match their style.

- [ ] **Step 2: Run them, expect compile failure**

Run: `cd agtermCore && swift test --filter 'FilePanel|filepanel'`
Expected: FAIL (unknown members).

- [ ] **Step 3: Implement**, mirroring each sidebar counterpart named in the Files list line for line. `ControlServer.setFilePanelVisibility` uses `library.activeStore` like `setSidebarVisibility`. No window-list cache field and no notification: read-back is the `tree` top level.

- [ ] **Step 4: Run tests, expect PASS** (same command).

- [ ] **Step 5: Commit** `feat: add file panel state and control commands`

---

### Task 2: Host-free file operations

**Files:**
- Create: `agtermCore/Sources/agtermCore/FileTree.swift`
- Test: `agtermCore/Tests/agtermCoreTests/FileTreeTests.swift` (real temp directories)

**Interfaces:**
- Produces:
  - `public struct FileTreeEntry: Equatable, Sendable { public let url: URL; public let isDirectory: Bool }`
  - `public enum FileTree`:
    - `static func children(of dir: URL) throws -> [FileTreeEntry]`: folders first, then `localizedStandardCompare` by name; hides only `.DS_Store` and `.git`; shows other dotfiles; throws when the directory is missing or unreadable.
    - `static func copyDestination(for source: URL, in dir: URL, exists: (String) -> Bool) -> URL`: `name.ext`, then `name copy.ext`, `name copy 2.ext`, …; a folder or extensionless file appends to the whole name.
    - `static func canMove(_ source: URL, into dir: URL) -> Bool`: false when `dir` equals `source`, is inside `source` (compare standardized path components, not string prefixes), or already is `source`'s parent.
    - `static func renameError(_ newName: String, sibling exists: (String) -> Bool) -> String?`: nil when valid; errors for empty/whitespace, containing `/` or `:`, `.`/`..`, or an existing sibling.
    - `static func pasteTarget(selection: FileTreeEntry?, root: URL) -> URL`: folder → itself, file → its parent, nil → root.

- [ ] **Step 1: Write failing tests**

```swift
@Test func childrenSortFoldersFirstNatural()  // files "a10","a2", dir "z" → ["z","a2","a10"]
@Test func childrenHideDSStoreAndGit()        // .DS_Store, .git hidden; .env shown
@Test func childrenOfMissingDirectoryThrows()
@Test func copyDestinationAddsCopySuffix()    // "a.txt" exists → "a copy.txt"; also "a copy.txt" → "a copy 2.txt"
@Test func copyDestinationFolder()            // "src" exists → "src copy"
@Test func cannotMoveIntoSelfOrDescendant()   // /t/a → /t/a, /t/a/b refused; /t/ab allowed (prefix trap)
@Test func cannotMoveIntoCurrentParent()
@Test func renameRejectsBadNames()            // "", "  ", "a/b", "..", existing → non-nil
@Test func pasteTargetResolves()
```

- [ ] **Step 2: Run, expect FAIL**: `cd agtermCore && swift test --filter FileTreeTests`
- [ ] **Step 3: Implement** with `FileManager.contentsOfDirectory(at:includingPropertiesForKeys: [.isDirectoryKey])`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat: add host-free file tree operations`

---

### Task 3: Atom file icons

**Files:**
- Create: `agterm/Resources/file-icons/` with TrueType fonts, because CoreText does not load WOFF/WOFF2: `DevOpicons.ttf` and `MFixx.ttf` from the `dist/` folders of `file-icons/DevOpicons` and `file-icons/MFixx`; `fontawesome-webfont.ttf` from Font Awesome 4.7.0 (`FortAwesome/Font-Awesome@v4.7.0:fonts/`); `file-icons.ttf` converted once from `file-icons/icons:dist/file-icons.woff2` with `woff2_decompress` (Homebrew `woff2`), since upstream ships no TTF. Use the same font versions the Atom package bundles (`file-icons/atom:fonts/`) where they differ. Add `LICENSE-file-icons.md` (ISC, from `file-icons/icons`), `LICENSE-atom-file-icons.md` (MIT, from `file-icons/atom`), and the DevOpicons (MIT), MFixx (MIT) and Font Awesome (OFL-1.1) license texts.
- Modify: `project.yml`: exclude `Resources/file-icons` from the `agterm` source path and re-add it as `type: folder, buildPhase: resources`, exactly like `Resources/markdown` (lines ~57 and ~93-95). Regenerate with `xcodegen`.
- Create: `agtermCore/Sources/agtermCore/FileIconCatalog.swift`
- Create: `agterm/Views/FilePanel/FileIconRenderer.swift`
- Test: `agtermCore/Tests/agtermCoreTests/FileIconCatalogTests.swift`, `agtermTests/FileIconRendererTests.swift`

**Interfaces:**
- Produces:
  - `public enum FileIconFont: String, Sendable { case fileIcons, devopicons, mfixx, fontAwesome }`. The raw value is each font's PostScript name; read the real names from the fonts after registration and use those.
  - `public struct FileIcon: Equatable, Sendable { public let font: FileIconFont; public let glyph: UInt32; public let color: FileIconColor }`
  - `public enum FileIconColor: CaseIterable, Sendable` with Atom's hues (`red, orange, yellow, green, cyan, blue, purple, pink, grey`) and `func hex(dark: Bool) -> String`: `medium-*` values from `file-icons/atom:styles/colours.less` when `dark`, `dark-*` values when light.
  - `public enum FileIconCatalog { static func icon(forName name: String, isDirectory: Bool) -> FileIcon }`
  - App: `@MainActor enum FileIconRenderer { static func image(for icon: FileIcon, pointSize: CGFloat, dark: Bool) -> NSImage }`: registers the four fonts once with `CTFontManagerRegisterFontsForURL(.process)`, draws the glyph in the icon color into a cached `NSImage` (cache key: font, glyph, size, dark).

Catalog content: about 40 entries. For each, take the icon name, font and colour from `file-icons/atom:config.cson`, and the codepoint from the font's charmap (`file-icons/icons:charmap.md`, the `file-icons/DevOpicons` and `file-icons/MFixx` charmaps, the Font Awesome 4.7 cheatsheet). Cover at least: exact names `Dockerfile`, `Makefile`, `package.json`, `Package.swift`, `README*`, `LICENSE*`, `.gitignore`, `.env*`, `*.lock`/`*-lock.json`; extensions `swift js mjs cjs ts tsx jsx json yaml yml toml md markdown txt sh zsh bash py go rs rb java kt c h cpp hpp cs php html css scss sql xml svg png jpg jpeg gif webp pdf zip gz dart lua vue svelte`. Directory → Font Awesome `folder` (U+F07B); unknown file → Font Awesome `file-o` (U+F016), both `grey`. Exact names win over extensions; matching is case-insensitive.

- [ ] **Step 1: Write failing tests**

```swift
@Test func exactNameBeatsExtension()    // "package.json" → npm icon, not the json icon
@Test func extensionIsCaseInsensitive() // "A.SWIFT" == "a.swift"
@Test func directoryUsesFolder()        // isDirectory → .fontAwesome, 0xF07B
@Test func unknownUsesGenericFile()     // "x.qqq" → .fontAwesome, 0xF016
@Test func everyColorHasBothHexes()     // all cases: hex(dark:) matches ^#[0-9a-f]{6}$ for true and false
// hosted: every FileIconFont resolves via NSFont(name:size:) after registration; image(for:) is non-empty
```

- [ ] **Step 2: Run, expect FAIL**: `swift test --filter FileIconCatalogTests`
- [ ] **Step 3: Implement the catalog and the renderer; add the fonts and licenses.**
- [ ] **Step 4: Run** `swift test --filter FileIconCatalogTests` and `-only-testing:agtermTests/FileIconRendererTests` → PASS.
- [ ] **Step 5: Commit** `feat: add Atom file-icons catalog and renderer`

---

### Task 4: Panel column, toggle button and actions

**Files:**
- Modify: `agterm/Views/WindowContentView.swift` (`splitRoot` :297-317, divider drag :385-396, `terminalAreaInset` :574-581)
- Modify: `agterm/Views/WindowContentView+Titlebar.swift` (`titlebarRow` :45-85, `sidebarToggleButton` :131-141)
- Modify: `agterm/AppActions.swift` (next to `toggleSidebar` :800-804), `agterm/agtermApp+Menus.swift` (View menu :239-246), `agterm/AppActions+Palette.swift`
- Modify: `agtermCore/Sources/agtermCore/BuiltinAction.swift`, `PaletteCatalog.swift`
- Create: `agterm/Views/FilePanel/FileTreeView.swift` (placeholder body in this task: themed empty column)
- Test: `agtermCore` keymap/palette tests that enumerate builtins (update expectations); `agtermUITests/ControlSidebarStatusUITests.swift`: add `testFilePanelShowHideToggle` mirroring `testSidebarShowHideToggle`.

**Interfaces:**
- Consumes: Task 1 store API.
- Produces:
  - `BuiltinAction.toggleFilePanel = "toggle_file_panel"`, default `Chord(mods: [.command, .control], key: "e")`; `PaletteCommand.toggleFilePanel` titled "Toggle File Panel".
  - `AppActions.toggleFilePanel()` (guarded by `uiActionsEnabled`, calls `store?.toggleFilePanelVisible()`).
  - `WindowContentView.leadingColumnsWidth: CGFloat` = `(sidebarVisible ? sidebarWidth + 1 : 0) + (filePanelVisible ? filePanelWidth + 1 : 0)`; `terminalAreaInset` and the titlebar's title/trailing offsets use it instead of `sidebarWidth`. Keep the zoom/dashboard conditions `terminalAreaInset` already has.
  - `FileTreeView(store: AppStore)`: the SwiftUI-facing entry point, filled in Task 5.

Layout: the `HStack` order is sidebar column, sidebar divider, file panel column (`.frame(width: store.filePanelWidth)`), file panel divider (same 1px line + 12pt drag handle as `sidebarDivider`, writing `store.filePanelWidth` per tick and `save()` on release), detail column. The panel shows whether or not the sidebar is visible. Background: the same `sidebarTintWash` as the sidebar column, with `titlebarHairline` on top. Button: `Image(systemName: "folder")`, accessibility id `file-panel-toggle-button`, tooltip `helpHint("Toggle File Panel", .toggleFilePanel)`, placed immediately right of `sidebarToggleButton` in both titlebar layouts (sidebar visible: inside the right-aligned group, widening its `max(40, sidebarWidth - 78)` budget by the button width; sidebar hidden: after the sidebar toggle).

- [ ] **Step 1: Write the failing UI test** `testFilePanelShowHideToggle`: `filepanel show` → `tree` reports `filePanelVisible == true`; `toggle` → false; button tap → true.
- [ ] **Step 2: Run it, expect FAIL**: `-only-testing:agtermUITests/ControlSidebarStatusUITests/testFilePanelShowHideToggle` (follow `.claude/rules/ui-tests.md`).
- [ ] **Step 3: Implement** the layout, button, action, menu item, palette entry and keymap entry.
- [ ] **Step 4: Run the UI test and `swift test --filter 'Keymap|Palette|Builtin'`, expect PASS.**
- [ ] **Step 5: Manual check** in an isolated Debug instance: palette and switcher stay centred on the terminal area with both columns open; the titlebar title does not overlap the buttons.
- [ ] **Step 6: Commit** `feat: add file panel column and toggle`

---

### Task 5: Tree view, theming, live refresh, open on click

**Files:**
- Modify: `agterm/Views/FilePanel/FileTreeView.swift`
- Create: `agterm/Views/FilePanel/FileTreeWatcher.swift`
- Create: `agterm/Views/FilePanel/FileTreeView+Open.swift`
- Test: `agtermTests/FileTreeViewTests.swift`

**Interfaces:**
- Consumes: `FileTree.children(of:)`, `FileIconCatalog`, `FileIconRenderer`, `Session.localWorkingDirectory(reported:homeDirectory:)`, `Session.focusedCwd`, `LinkOpener.shared.markdown/.image/.text`, `LinkPolicy.markdownExtensions`, `LinkPolicy.imageExtensions`, `TextPage.isEligible(file:)`.
- Produces:
  - `final class FileTreeNode` (reference type, stable per path; `url`, `isDirectory`, lazily loaded `children: [FileTreeNode]?`), cached in the coordinator by standardized path so reloads keep expansion and selection.
  - `final class FileTreeWatcher { init(root: URL, onChange: @escaping @MainActor ([String]) -> Void); func stop() }`: `FSEventStreamCreate` with `kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents`, latency 0.3 s; the callback hops to main with the changed paths. The C callback captures nothing and gets `self` through the context `info` pointer (see `.claude/rules/libghostty.md` and the `swift-concurrency` skill).
  - Coordinator method `open(_ node: FileTreeNode)`.

Behaviour:
- Root = `store.activeSession.map { $0.localWorkingDirectory(reported: $0.focusedCwd, homeDirectory: …) }`. When the session is remote and the path does not exist locally, show "No local folder". Rebuild when the root path changes, observed through Observation in `updateNSView`.
- One header line above the outline: the root folder name, medium weight, `chromeText.opacity(0.6)`, full path in its tooltip.
- Outline config copies `WorkspaceSidebar` (`WorkspaceSidebar.swift:30-50`): `rowSizeStyle = .custom`, `style = .plain`, `indentationPerLevel = 14`, `backgroundColor = .clear`, `selectionHighlightStyle = .none`, no header, row height `AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)`, `allowsMultipleSelection = true`. Reuse `SidebarRowView` for the selection pill if it has no sidebar-node dependency; otherwise extract its `drawBackground` into a shared helper rather than copy it.
- Cell: 16pt icon (from `FileIconRenderer`, `dark: GhosttyApp.shared.terminalThemeIsDark`) + 6pt gap + name in `NSFont.systemFont(ofSize: sidebarFontSize)`, colored with `SidebarCellView.themeTextColor(selected:)` (reuse it; do not re-derive). Dotfiles at 0.6 alpha. Cut items (Task 6) at 0.5 alpha.
- Theme: observe `.agtermAppearanceChanged`; set `outlineView.appearance` like `applyThemeAppearance` (`WorkspaceSidebar.swift:272`) and reload visible rows so icons re-render with the new `dark` value and text colors refresh. The theme-picker preview goes through the same notification.
- Watcher: on change, for each changed path whose parent node is loaded, re-list that parent and `reloadItem(_:reloadChildren: true)`; drop nodes that no longer exist. If the root itself vanishes, show "Folder not found".
- `children(of:)` errors: a subfolder shows no children; the root shows the empty-state line.
- Open: double-click or Return. Folder → expand/collapse. File by extension: markdown → `LinkOpener.shared.markdown(url, sessionID, nil)`, image → `.image(url, sessionID)`, `TextPage.isEligible` → `.text(TextLink(...))`; if the completion reports `false`, or for any other file, `NSWorkspace.shared.open(url)`. A single click only selects, because opening on single click breaks drag and multi-select. Record this in the PR description.

- [ ] **Step 1: Hosted test** `FileTreeViewTests`: with a temp dir as root, the outline shows folders first; expanding a folder loads its children; a file created on disk appears within 2 s (watcher); deleting the root shows "Folder not found".
- [ ] **Step 2: Run, expect FAIL**: `-only-testing:agtermTests/FileTreeViewTests`
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Manual check** in an isolated Debug instance: theme picker preview repaints rows and icons live and they stay readable on a light and a dark theme; `cd` in the session moves the tree; expanding a large `node_modules` shows no visible hang; a remote session shows "No local folder".
- [ ] **Step 6: Commit** `feat: show the session directory tree in the file panel`

---

### Task 6: Context menu, rename, delete, clipboard, new companion

**Files:**
- Create: `agterm/Views/FilePanel/FileTreeView+Actions.swift`
- Modify: `agterm/AppActions+Companions.swift`
- Test: `agtermTests/FileTreeViewTests.swift` (extend)

**Interfaces:**
- Consumes: `FileTree.copyDestination`, `FileTree.canMove`, `FileTree.renameError`, `FileTree.pasteTarget`; `AppStore.addCompanion(to:options:)`, `AppStore.addSession(toWorkspace:cwd:...)`.
- Produces:
  - `AppActions.newCompanion(cwd: String)`: `store.addCompanion(to: activeSession, options: CompanionOptions(cwd: cwd))`; on `.failure` (for example a remote parent) fall back to `store.addSession(toWorkspace: <active session's workspace>, cwd: cwd)`; then `noteUserActivity()`, `selectSession`, `focusActiveSession()` as `newCompanion(_:in:)` does.
  - Coordinator: `copySelection()`, `cutSelection()`, `paste()`, `trashSelection()`, `beginRename(_:)`.

Behaviour:
- Context menu on the clicked row (select it first if it is not in the selection), in this order: Open, Open with Default App, separator, New Companion Here (folder → itself, file → its parent), separator, Cut, Copy, Paste, separator, Rename…, Move to Trash. Paste is disabled when the pasteboard holds no file URLs. Context menu on empty space: New Companion Here (root), Paste.
- Clipboard: write `NSURL`s to `NSPasteboard.general`, so copy and paste work with Finder both ways. Cut is internal state: remember the cut URLs and the pasteboard `changeCount`; paste moves them only if `changeCount` is unchanged, otherwise it copies. The paste destination is `FileTree.pasteTarget`. Copy uses `copyDestination`. Move refuses when `canMove` is false or the name exists in the target, and one `NSAlert` sheet lists the skipped items.
- Keys while the outline is first responder: ⌘C/⌘X/⌘V via the standard `copy:`/`cut:`/`paste:` responder actions (with `validateMenuItem`) so the Edit menu works; no ⌃ variants (user decision); ⌘⌫ → Move to Trash; Return → open (Task 5).
- Rename: inline edit of the cell's text field, with the name selected without its extension, like Finder. Commit validates with `renameError`; an error shows in an `NSAlert` sheet and keeps the old name. Escape cancels.
- Move to Trash: `FileManager.trashItem`, no confirmation (recoverable from the Trash). Errors go to one `NSAlert` sheet.
- After every operation, reload the affected parents and select the result.

- [ ] **Step 1: Extend hosted tests**: copy+paste into a folder creates "name copy"; cut+paste moves; cut, then an external pasteboard write, then paste copies instead of moving; rename to an existing name keeps the old name; trash removes the row and `trashItem`'s result URL exists.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat: add file panel context menu and clipboard`

---

### Task 7: Drag and drop

**Files:**
- Create: `agterm/Views/FilePanel/FileTreeView+DragDrop.swift`
- Test: `agtermTests/FileTreeViewTests.swift` (extend; call the data source drop methods directly)

**Interfaces:**
- Consumes: `FileTree.canMove`, `FileTree.copyDestination`.

Behaviour:
- Drag source: `outlineView(_:pasteboardWriterForItem:)` returns the node's `NSURL`. The terminal surface already accepts `.fileURL` drops and pastes the shell-escaped path (`GhosttySurfaceView+Input.swift:8-27`), so drag-to-terminal and drag-to-agent need no other code. A folder dropped on the sessions sidebar creates a session there through existing code; leave that as is.
- Drop target: register `.fileURL`. Drop on a folder row → into it; on a file row → retarget to its parent (`setDropItem`); on empty space → root.
- Source is this panel → `.move`, validated with `canMove` and refused when the name exists in the target. Source is outside (Finder) → `.copy` with `copyDestination`. Holding ⌥ forces copy for an internal drag.
- Highlight the target folder row with the selection-pill color at low alpha.

- [ ] **Step 1: Write failing tests**: an internal drop of a file onto a folder moves it; a folder dropped onto its own child is refused (`validateDrop` returns `[]`); an external drop copies with a collision name.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Manual check**: drag a file into a terminal pane running `claude` → the path appears at its prompt.
- [ ] **Step 6: Commit** `feat: drag and drop in the file panel`

---

### Task 8: Docs, skill, gates

**Files:**
- Modify: `site/docs.html` (a short "File panel" section), `site/commands.html` (`filepanel`, `filepanel width`, tree fields `filePanelVisible`, `filePanelWidth`), `site/index.html` only if its feature list names sidebar features.
- Modify: `plugins/agterm/skills/agterm/SKILL.md` (pointer and trigger words "file panel", "file tree") and its `reference.md` (commands and read-back).
- Modify: `.claude/rules/control-api.md` (catalog entry next to `sidebar*`, with one line recording the deliberate exemption: `filepanel` state is read back on the `tree` top level only, with no `window.list` field and no change notification), `.claude/rules/keymap.md` if it lists builtins.
- Third-party notice: add the icon fonts wherever the markdown-it and highlight.js licenses are credited; if nowhere, the license files in `agterm/Resources/file-icons/` are enough.

- [ ] **Step 1: Update the docs** (short; no command totals anywhere).
- [ ] **Step 2: Run the gates once**: `cd agtermCore && swift test`, `make test-app`, `make lint`. All pass, zero lint findings.
- [ ] **Step 3: Run** `lsappinfo list | grep -A4 agterm.debug` and clean up leaked test processes per `CLAUDE.md`.
- [ ] **Step 4: Commit** `docs: document the file panel`
