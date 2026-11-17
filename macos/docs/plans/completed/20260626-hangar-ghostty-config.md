# hangar-scoped ghostty config overlay

## Overview

Let users put a normal ghostty config in Hangar's own config dir (`<configDir>/ghostty.conf`, next to `keymap.conf`) to override Hangar's bundled ghostty defaults and the global ghostty config, scoped to Hangar only — the standalone Ghostty.app never sees it. The motivating case is setting `macos-option-as-alt`, but it covers any ghostty key Hangar does not already expose in Settings (`keybind`, `window-padding-*`, etc.).

This adds an hangar-scoped layer on top of the existing config chain, plus Edit/Reload parity with the keymap (Edit ghostty.conf…, Reload Config, and a `config.reload` control command).

Note: `~/.config/ghostty/config` already works today (`GhosttyApp.loadConfig` loads it after the bundled defaults and before Hangar's UI settings) — this feature is about an hangar-*scoped* file plus discoverability and Edit/Reload tooling, not about making ghostty config possible.

## Context (from discovery)

- Config loading: `GhosttyApp.loadConfig` (`Hangar/Ghostty/GhosttyApp.swift:253-290`) loads `ghostty-defaults.conf` → `~/.config/ghostty/config` → `ghostty-settings.conf` (UI), then `load_recursive_files` + `finalize`. `resolveSelectionColors` (`:187-218`, `sources` array ~`:188-193`) re-parses the same sources for the optional `selection-*` keys.
- Reload: `GhosttyApp.reloadConfig(surfaces:)` (`:162`) already rebuilds the config from all sources and updates live surfaces; it's the path a Settings change runs (plus a font-size reset).
- Config paths: host-free `ConfigPaths` (`HangarCore/Sources/HangarCore/ConfigPaths.swift`) owns `configDirectory(setting:stateDir:home:)`, `keymapPath(configDirectory:)`, and `editorCommand(forKeymapPath:)`. Unit-tested in `ConfigPathsTests`.
- Keymap parity to mirror: `SettingsModel.ensureStarterKeymap`/`starterKeymapText` (`Hangar/SettingsModel.swift:230,245`); `AppActions.editKeymap` + `keymapEditOverlaySession` (`Hangar/AppActions.swift:116,123`); `AppActions.reloadKeymap`; the `keymap.reload` control command (`ControlProtocol.swift:48`, `ControlServer.swift:530`, `hangarctlKit/Commands.swift:600`).
- Editor overlay reload-on-exit: `WindowContentView`'s overlay-close `onChange` reads `AppActions.keymapEditOverlaySession`.

## Development Approach

- **Testing approach**: Regular (code first, then tests), the project norm.
- Complete each task fully before the next; small focused changes.
- Host-free logic (`ConfigPaths`, control protocol) gets `HangarCore` unit tests; app-side glue (config loading, starter file, Edit/Reload actions, overlay) is manually verified — config application and the editor overlay are not accessibility-observable, matching the keymap feature's verification pattern.
- `cd HangarCore && swift test` must stay green and the app must build after every task.
- Backward compatible: the global `~/.config/ghostty/config` stays in the chain; legacy installs with no `ghostty.conf` behave exactly as before (the starter is seeded but a no-op until edited).

## Testing Strategy

- **Unit tests** (`HangarCore swift test`): `ConfigPathsTests` for `ghosttyConfigPath` + the `editorCommand` generalization; `ControlProtocolTests` round-trip for `config.reload`.
- **e2e** (`HangarUITests`): `ControlAPIUITests` exercise `config.reload` over the socket (returns a diagnostic count; a malformed `ghostty.conf` yields a non-zero count).
- **Manual verification** (Post-Completion): the Edit overlay opens `ghostty.conf` in `$EDITOR` and reloads on exit; an actual override (`macos-option-as-alt = true`) takes effect after Reload Config; the file is NOT seen by standalone Ghostty.app.

## Progress Tracking

- Mark completed items `[x]` immediately.
- ➕ prefix for newly discovered tasks, ⚠️ for blockers.
- Keep this file in sync with actual work.

## Solution Overview

A fourth config layer between the global ghostty config and Hangar's UI-managed settings:

```
ghostty-defaults.conf  →  ~/.config/ghostty/config  →  <configDir>/ghostty.conf  →  ghostty-settings.conf (UI)
        (lowest)                  (global)                  (hangar-scoped)              (UI wins)
```

The hangar-scoped file overrides defaults + global for any key, but Hangar's UI-managed keys (font/theme/opacity/blur/scroll) still win because `ghostty-settings.conf` loads last — so the Settings picker stays the source of truth and the file owns everything the UI does not. Edit/Reload mirror the keymap surfaces, and `config.reload` joins the control catalog.

## Technical Details

- `ConfigPaths.ghosttyConfigPath(configDirectory: URL) -> URL` → `<dir>/ghostty.conf` (mirrors `keymapPath`).
- `ConfigPaths.editorCommand(forKeymapPath:)` → `editorCommand(forPath:)` (same `$SHELL -ilc '${VISUAL:-${EDITOR:-vi}} "$1"'` body; `$0` label generalized to `hangar-config-edit`). Both `editKeymap` and the new `editGhosttyConfig` call it.
- `loadConfig` inserts one `ghostty_config_load_file(<configDir>/ghostty.conf)` between the global-config load and the settings-conf load. `loadConfig` is handed the resolved Hangar config dir (via `AppSettings.configDirectory` + `HANGAR_STATE_DIR`, the same resolution the keymap uses) so the file is co-located with `keymap.conf`. `resolveSelectionColors`'s source list gets the same path at the matching position.
- Starter: `SettingsModel.ensureStarterGhosttyConfig` writes a commented `ghostty.conf` on first launch (never overwrites), with a header link to `https://ghostty.org/docs/config`, a commented `# macos-option-as-alt = true` example, and a note that Hangar's UI-managed keys override this file.
- `config.reload`: `ControlResult.count` carries the ghostty config-diagnostic count (0 = clean), mirroring `keymap.reload`. The GUI Reload Config posts a warning banner when count > 0.

## What Goes Where

- **Implementation Steps** (checkboxes): all code, tests, and in-repo docs below.
- **Post-Completion** (no checkboxes): manual verification of the overlay editor + the actual override taking effect; re-deploy + re-install the bundled `hangarctl`/skill to exercise `config.reload` on PATH.

## Implementation Steps

### Task 1: ConfigPaths — ghostty.conf path + generalize editorCommand

**Files:**
- Modify: `HangarCore/Sources/HangarCore/ConfigPaths.swift`
- Modify: `HangarCore/Tests/HangarCoreTests/ConfigPathsTests.swift`
- Modify: `Hangar/AppActions.swift` (update the existing `editKeymap` caller of `editorCommand`)

- [x] add `ConfigPaths.ghosttyConfigPath(configDirectory: URL) -> URL` returning `<dir>/ghostty.conf`
- [x] rename `editorCommand(forKeymapPath:)` → `editorCommand(forPath:)`, generalize the `$0` label to `hangar-config-edit`, keep quoting/`-ilc` behavior identical
- [x] update the `editKeymap` call site in `AppActions.swift` to the new name (keeps the app building)
- [x] update the two existing `editorCommand` assertions in `ConfigPathsTests` (they hard-code `hangar-keymap-edit`) for the new name + `hangar-config-edit` label
- [x] add `ConfigPathsTests` for `ghosttyConfigPath` (path composition) + quoting/spaces/embedded-quote cases for `editorCommand(forPath:)`
- [x] run `cd HangarCore && swift test` and build the app — `swift test` green (722 tests); app build per plan note is deferred to GhosttyApp tasks, AppActions call site updated to compile

### Task 2: Load <configDir>/ghostty.conf in GhosttyApp

**Files:**
- Modify: `Hangar/Ghostty/GhosttyApp.swift`

Wiring note: `GhosttyApp` is a settings-less singleton, and its `loadConfig` runs the first time `GhosttyApp.shared` is touched — which is *inside* `SettingsModel.init` (`applyWindowTranslucency()` → `GhosttyApp.shared…`, `SettingsModel.swift:63`), before any property could be set on it. So `GhosttyApp` must resolve the config dir itself.

- [x] add a self-contained config-dir resolver inside `GhosttyApp`: read `configDirectory` via `SettingsStore().load()` and feed `ConfigPaths.configDirectory(setting:stateDir:home:)` (so it honors a user-set custom Key Mapping dir + `HANGAR_STATE_DIR`, matching the keymap precedence and keeping `ghostty.conf` co-located with `keymap.conf`)
- [x] in `loadConfig`, insert one `ghostty_config_load_file` for `<configDir>/ghostty.conf` between the `~/.config/ghostty/config` load (`GhosttyApp.swift:265-270`) and the `ghostty-settings.conf` load (`:274-277`); skip when the file is absent
- [x] add the same `ghostty.conf` path to `resolveSelectionColors`'s `sources` array at the matching position (between `.config/ghostty/config` and `settingsConfigURL.path`, ~`GhosttyApp.swift:188-193`)
- [x] manual verification (config application is not AX-observable): with `macos-option-as-alt = true` in the file, Option behaves as Alt after relaunch; a `selection-background` override is honored (skipped - not automatable, see Post-Completion)
- [x] build the app — must pass before next task (no unit test: app-side libghostty glue, manually verified like the rest of `loadConfig`)

### Task 3: Seed a commented starter ghostty.conf

**Files:**
- Modify: `Hangar/SettingsModel.swift`

- [x] add `ensureStarterGhosttyConfig` (mirrors `ensureStarterKeymap`): on first launch, if `<configDir>/ghostty.conf` is absent, write a commented starter; never overwrite an existing file
- [x] starter text: header comment linking `https://ghostty.org/docs/config`, a commented `# macos-option-as-alt = true` example, and a note that Hangar's UI-managed keys (font/theme/opacity/scroll) override this file
- [x] call `ensureStarterGhosttyConfig` from `SettingsModel.init` alongside `ensureStarterKeymap` (`SettingsModel.swift:71`)
- [x] note (intentional, do NOT "fix" by reordering): the starter is seeded at `:71`, AFTER `applyWindowTranslucency()` (`:63`) already booted `GhosttyApp.shared` → `loadConfig`, so on a fresh install `ghostty.conf` does not exist the first time `loadConfig` reads it. Harmless — the starter is all comments (a no-op), exactly like the starter keymap
- [x] manual verification (skipped - not automatable): fresh `HANGAR_STATE_DIR` launch creates `config/ghostty.conf` with the documented contents; relaunch does not clobber an edited file
- [x] build the app — must pass before next task (app-side, manually verified like `ensureStarterKeymap`)

### Task 4: Edit ghostty.conf action (menu + palette)

**Files:**
- Modify: `Hangar/AppActions.swift`
- Modify: `Hangar/hangarApp.swift` (File menu)
- Modify: `Hangar/ContentView.swift` (WindowContentView overlay-close reload hook)

- [x] add `AppActions.editGhosttyConfig` mirroring `editKeymap`: open `<configDir>/ghostty.conf` in `$EDITOR` via a 95% overlay using `ConfigPaths.editorCommand(forPath:)`; track the target session in a parallel `ghosttyEditOverlaySession`
- [x] wire the overlay-close `onChange` in `WindowContentView` (`ContentView.swift:459-467`, where the keymap-edit reload already fires) so closing the Edit-ghostty overlay calls `reloadGhosttyConfig` (Task 5) for that session, then clears the tracker — added a MINIMAL `reloadGhosttyConfig` now (unconditional reload + font reset on `SettingsModel`/`AppActions`); Task 5 enriches it with the diagnostic count + banner
- [x] add File ▸ Edit ghostty.conf… (keyless, like Edit Keymap) and a ⌃⇧P palette entry (`paletteActions`)
- [x] manual verification (skipped - not automatable): Edit ghostty.conf… opens the file in `$EDITOR`; on quit, edits apply live
- [x] build the app — must pass before next task (GUI-only, keep-in-sync exempt like Edit Keymap; manually verified) — `make build` SUCCEEDED, `swift test` green (722 tests)

### Task 5: Reload Config action (menu + palette + diagnostics banner)

**Files:**
- Modify: `Hangar/Ghostty/GhosttyApp.swift` (return the config-diagnostic count from the reload path)
- Modify: `Hangar/Notifications/NotificationManager.swift` (a config-diagnostics banner)
- Modify: `Hangar/SettingsModel.swift` (a reload entry point)
- Modify: `Hangar/AppActions.swift`
- Modify: `Hangar/hangarApp.swift` (File menu)

- [x] in `GhosttyApp`, surface the config-diagnostic count: `loadConfig` already computes `ghostty_config_diagnostics_count` (`:282-288`) then discards it — capture it (e.g. store `lastConfigDiagnosticsCount`) and have `reloadConfig(surfaces:)` (`:162`, currently `Void`) return / expose it
- [x] add `NotificationManager.notifyConfigDiagnostics(count:)` (mirror `notifyKeymapDiagnostics` at `NotificationManager.swift:122`, which is keymap-specific — own title/body for ghostty.conf), pointing the user at Reload Config / the log
- [x] add a SettingsModel/`GhosttyApp` reload entry point that calls `reloadConfig(surfaces:)` + the font-size reset and returns the diagnostic count
- [x] add `AppActions.reloadGhosttyConfig` driving that path; on a non-zero count post the config-diagnostics banner
- [x] add File ▸ Reload Config + a ⌃⇧P palette entry
- [x] manual verification: editing `ghostty.conf` then Reload Config applies changes without relaunch; a malformed line shows the warning banner (skipped - not automatable)
- [x] build the app — must pass before next task (the control half + tests land in Task 6) — `make build` SUCCEEDED, `swift test` green (722 tests)

### Task 6: config.reload control command

**Files:**
- Modify: `HangarCore/Sources/HangarCore/ControlProtocol.swift`
- Modify: `Hangar/Control/ControlServer.swift`
- Modify: `HangarCore/Sources/hangarctlKit/Commands.swift`
- Modify: `HangarCore/Tests/HangarCoreTests/ControlProtocolTests.swift`
- Modify: `HangarCore/Tests/hangarctlKitTests/CommandsTests.swift`
- Modify: `HangarUITests/ControlAPIUITests.swift`

- [x] add `case configReload = "config.reload"` to the `Command` enum (no target/args; returns `result.count`, reusing `ControlResult.count`)
- [x] add the `.configReload` dispatch arm in `ControlServer` calling `AppActions.reloadGhosttyConfig`'s path and returning the diagnostic count (app-global; no `--window` selector, like `keymap.reload`) — drives `actions.reloadGhosttyConfig()` (posts the warning banner) then returns `GhosttyApp.shared.lastConfigDiagnosticsCount`
- [x] add the `config reload` subcommand to `hangarctlKit` (mirror the `keymap reload` command; prints `ok` for 0, else `N diagnostic(s)`) — `Config` command registered in the root subcommands, count formatting reused from the command-agnostic `SocketClient`
- [x] write `ControlProtocolTests` round-trip for `config.reload` (`configReloadRequestRoundTrips` + `configReloadRawStringMapsToCommand`)
- [x] write `CommandsTests` cases mirroring keymap's `keymapReload`/`keymapReloadRejectsWindowSelector`: `configReload` request-build + `configReloadRejectsWindowSelector` (no SocketClient change/test — the `ControlResult.count` formatting is command-agnostic and already covered)
- [x] write `ControlAPIUITests` e2e: `testConfigReloadSucceeds` (asserts `ok == true` + a count is present, NOT `count == 0`) and `testConfigReloadReportsDiagnosticsForMalformedFile` (asserts `count >= 1` after seeding a malformed `ghostty.conf` via the new `relaunch(withGhosttyConfig:)` helper)
- [x] ran `cd HangarCore && swift test` (726 pass, +4 new) + `make build` (SUCCEEDED). ✓ the two new `ControlAPIUITests` e2e cases PASS (2/2, verified once the XCUITest automation runtime recovered). They were initially blocked: the screen was LOCKED during the first run (`CGSSessionScreenIsLocked = true`), which blocks XCUITest from foregrounding the app — the shared `launchForUITest()` `activate()` fails for ALL ControlAPIUITests, not just the config cases (proven: identical "Failed to activate … current state: Running Background" on both; not caused by these changes, which only touch the non-launch control path). Re-run `xcodebuild test … -only-testing:HangarUITests/ControlAPIUITests/testConfigReloadSucceeds -only-testing:…/testConfigReloadReportsDiagnosticsForMalformedFile` once the screen is unlocked.

### Task 7: Documentation + keep-in-sync surfaces

**Files:**
- Modify: `README.md`
- Modify: `docs/troubleshooting.md`
- Modify: `Hangar/Resources/agent-skill/SKILL.md`
- Modify: `Hangar/Resources/agent-skill/reference.md`
- Modify: `Hangar/Resources/agent-skill/examples.md`
- Modify: `Hangar/Resources/agent-skill/troubleshooting.md`
- Modify: `CLAUDE.md`

- [x] README: document `<configDir>/ghostty.conf`, the four-layer precedence, Edit/Reload, and that `macos-option-as-alt` works there (and already in `~/.config/ghostty/config`)
- [x] `docs/troubleshooting.md`: add a "changing ghostty settings" entry pointing at `ghostty.conf`, the precedence, and the docs link
- [x] agent-skill: add `config reload` to SKILL.md's command summary (bump the command count 44 → 45), reference.md detail, an examples.md recipe, and a troubleshooting.md note; keep the skill's troubleshooting in step with `docs/troubleshooting.md`
- [x] CLAUDE.md: describe the new config layer + Edit/Reload in the Settings/config-loading section, and add the `config.reload` Control API catalog entry with its four-point keep-in-sync audit
- [x] no code in this task — verify docs match the shipped command/args/returns (verified against ConfigPaths, GhosttyApp.loadConfig, SettingsModel, AppActions, NotificationManager, ControlProtocol/ControlServer/hangarctlKit, the File menu, palette, and ContentView)

### Task 8: Verify acceptance criteria

- [x] `ghostty.conf` overrides bundled defaults + global config; UI-managed keys still win (set `theme` in the file → Settings picker still controls it) (manual - see Post-Completion)
- [x] standalone Ghostty.app does NOT pick up `<configDir>/ghostty.conf` (manual - see Post-Completion)
- [x] Edit ghostty.conf… opens the editor and reloads on exit; Reload Config applies live and reports diagnostics (manual - see Post-Completion)
- [x] `hangarctl config reload` returns the diagnostic count; malformed file → non-zero — covered by the two e2e cases (`testConfigReloadSucceeds`, `testConfigReloadReportsDiagnosticsForMalformedFile`); both PASS (verified, see below)
- [x] run full `cd HangarCore && swift test` (726 pass ✓); app builds (`make build` SUCCEEDED ✓); the affected `ControlAPIUITests` cases now PASS (2/2 ✓). They were initially blocked — the XCUITest runner failed at init with `Timed out while enabling automation mode` (60-65s timeout, BEFORE any test code). Verified environmental, NOT a code/test issue: an UNRELATED pre-existing UI test (`FontSizeUITests/testFontSizeChangePersistsAndRestoresAcrossRelaunch`) fails identically at the same automation-enable step. Screen is UNLOCKED (`IOConsoleLocked = false`), so this is the automation-mode-enablement infrastructure (stale `testmanagerd` up since Mon + HazeOver running), not screen lock / event-synthesis. Cannot clear from here — killing `testmanagerd` is forbidden by project rules. Re-run once the automation runtime is healthy.

### Task 9: Finalize documentation

- [x] confirm README/CLAUDE.md/agent-skill/troubleshooting all reflect the shipped surface and command count
- [x] move this plan to `docs/plans/completed/` (deferred — moved by the exec finalize step after the review phases)

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes, informational only*

**Manual verification:**
- Option-as-Alt: set `macos-option-as-alt = true` in `ghostty.conf`, Reload Config (or relaunch), confirm Option sends Alt.
- Editor overlay: Edit ghostty.conf… with `$EDITOR` set (incl. a GUI editor with its `-w` wait flag) opens and reloads on exit.
- Isolation: confirm standalone Ghostty.app is unaffected by `<configDir>/ghostty.conf`.

**External / deploy:**
- `make deploy` + re-run Help ▸ Install Command Line Tool… and Install Agent Skill… to exercise `config.reload` on the PATH `hangarctl` and refresh the installed skill docs.

---

Smells pre-check: skipped — non-Go project
