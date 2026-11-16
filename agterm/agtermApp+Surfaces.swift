import agtermCore
import AppKit
import SwiftUI

extension agtermApp {
    /// Surface factory: a libghostty-backed view for the session, spawning a login shell in its initial working
    /// directory. On shell exit the view calls back to close the owning session in the store.
    /// Internal rather than private: `SurfaceFactorySeedTests` drives it to pin the launch-seed wiring.
    @MainActor
    static func makeSurface(for session: Session, store: AppStore, env: [String: String],
                            services: SurfaceServices) -> GhosttySurfaceView {
        // GhosttyApp resolved resources and latched restore mode before WindowLibrary assembled the launch
        // inventory, so every later factory reads the same process policy and GHOSTTY_RESOURCES_DIR.
        let ghostty = GhosttyApp.shared
        // `initialCommand` (`session.new --command`) replaces the login shell and closes the session on its exit
        // (like kitty); it is the durable creation identity, re-emitted by every `snapshot()`. `foregroundCommand`,
        // a distinct child captured at quit, is consumed run-once; an exec-replacing command has a nil libghostty
        // foreground pid, so it is never captured and restores via the exec `command` path, keeping close-on-exit.
        // `LaunchSeedProvider` owns the precedence between them and resolves it at spawn time, not here, so
        // the pending slots stay on the session until the pane really spawns.
        // without the claim: a pane relaunched while another Mac leads its daemon comes back covered
        let lead = ZmxLeadAttachment(claim: false)
        let zmx = ZmxLaunch.wrapsLocally(mode: ghostty.launchRestoreMode, session: session)
            ? ZmxLaunch.configuration(paneIdentity: session.paneIdentity, pane: "primary", environment: env, lead: lead)
            : nil
        let disposition = ZmxLaunch.disposition(requested: ghostty.requestedRestoreMode,
                                                active: ghostty.launchRestoreMode, configuration: zmx)
        if disposition.backedByZmx {
            services.zmxForegroundResolver?.noteLifecycleChange()
            ZmxLeadBook.shared.begin(lead, pane: session.paneIdentity)
        }
        let view = GhosttySurfaceView(workingDirectory: session.localWorkingDirectory(reported: session.initialCwd,
                                                                                   homeDirectory: NSHomeDirectory()),
                                      fontSize: session.fontSize.map(Float.init),
                                      env: Self.surfaceEnv(disposition: disposition, fallback: env),
                                      backedByZmx: disposition.backedByZmx)
        let provider = LaunchSeedProvider.pane(session: session, pane: .left, disposition: disposition,
                                               policy: Self.launchSeedPolicy(ghostty, context: services.launchContext))
        view.launchSeed = provider
        services.spawnRegistry?.enqueue(view, key: session.paneIdentity, provider: provider)
        Self.wirePane(view, session: session, store: store, services: services)
        return view
    }

    /// The callbacks every session pane carries, whichever slot it sits in and whether a factory or a
    /// fresh attach built it. Each one reads the surface's LIVE role, so nothing here is slot-specific.
    @MainActor
    private static func wirePane(_ view: GhosttySurfaceView, session: Session, store: AppStore,
                                 services: SurfaceServices) {
        view.session = session
        if let title = GhosttyApp.shared.staticTitle { view.applyTitle(title) }
        let sessionID = session.id
        view.onExit = { [weak view] in
            guard let view else { return }
            Self.handlePaneExit(view, store: store, sessionID: sessionID, library: services.library)
        }
        view.onFocusChange = { [weak view] focused in
            guard let splitFocused = Self.focusedSplitState(focused, surface: view) else { return }
            store.session(withID: sessionID)?.splitFocused = splitFocused
            // focusing a pane means you've seen the session: clear the badge and any delivered banners.
            store.markSeen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        // focus-free half of the clear above: zoom hosting suppresses the focus report though the refocused
        // user is looking right at this surface.
        view.onClearUnseen = {
            store.markSeen(sessionID)
            NotificationManager.shared.clearDelivered(sessionID: sessionID)
        }
        Self.wireStatusClear(view, store: store, sessionID: sessionID)
        view.onUserInput = { keystroke in
            store.noteUserActivity()
            store.forwardSeenKeystroke(keystroke, forSession: sessionID)
            // typing in the session counts as seeing it, but its banners stay: a note that arrived
            // mid-typing would vanish on the next key before it could be read.
            guard (store.session(withID: sessionID)?.unseenCount ?? 0) > 0,
                  GhosttyApp.shared.badgeReset.clearsBadge(on: keystroke) else { return }
            store.clearUnseen(sessionID)
        }
        view.onFontSizeChange = { [weak view] size in
            Self.persistFontSize(size, from: view, store: store, sessionID: sessionID)
        }
        view.onPwdChange = { store.rememberFolder($0, reportedBy: sessionID) }
        Self.wireSearchCallbacks(view, store: store, sessionID: sessionID, actions: services.actions)
        view.onExitHeld = { [weak view] in
            guard let view else { return }
            // the wrapper is gone, so no key can end a wait; a replaced surface's late exit is not this pane's
            if let pane = UUID(uuidString: view.paneToken),
               view.session?.surface === view || view.session?.splitSurface === view {
                RemoteReconnectBook.shared.cancel(pane: pane)
            }
            Self.remotePaneStopped(view, store: store, sessionID: sessionID, library: services.library,
                                   attach: services.actions.remoteAttacher as? RemoteAttachLines)
            PaneLead.heldExit?(view)
        }
    }

    /// replacePane puts a surface built from `launch` in `old`'s slot and retires `old`, running none of
    /// the pane's close paths. `spawnFirst` creates the new surface at the old size BEFORE the free: libghostty
    /// routes a queued child-exit by surface address, and a surface created after it can take the old exit.
    /// Retiring keeps the old surface allocated until its threads have exited, without the main thread waiting on them.
    @MainActor
    static func replacePane(_ old: GhosttySurfaceView, launch: PaneReattach, lead: ZmxLeadAttachment, cover: Bool,
                            spawnFirst: Bool = false, services: SurfaceServices) -> GhosttySurfaceView? {
        guard let session = old.session, let store = services.library.store(forSession: session.id),
              let identity = old.isSplitPane ? session.splitPaneIdentity : session.paneIdentity
        else { return nil }
        // a dashboard cell's transient font is not the pane's: seeding from it would persist the small size
        let fontSize = old.dashboardFontOverride == nil ? old.currentFontSize() ?? session.fontSize : session.fontSize
        let view = GhosttySurfaceView(workingDirectory: launch.workingDirectory, fontSize: fontSize.map(Float.init),
                                      command: launch.command, waitAfterCommand: launch.wait,
                                      env: launch.environment, backedByZmx: old.backedByZmx)
        view.isSplitPane = old.isSplitPane
        Self.wirePane(view, session: session, store: store, services: services)
        view.dashboardFontOverride = old.dashboardFontOverride
        ZmxLeadBook.shared.begin(lead, pane: identity, reattaching: cover)
        if session.remoteHost != nil { RemoteRespawnBook.shared.attachStarted(pane: identity, session: session.id) }
        // the old client's exit must not close the pane the new one now owns
        _ = old.claimProcessExit()
        let hadFocus = old.window?.firstResponder === old
        // synchronously: the retired surface's END_SEARCH callback is dropped
        if session.searchSurface === old {
            session.searchActive = false
            session.searchNeedle = ""
            session.searchTotal = nil
            session.searchSelected = nil
            session.searchSurface = nil
        }
        if old.isSplitPane { session.splitSurface = view } else { session.surface = view }
        if spawnFirst {
            view.frame = old.frame.isEmpty ? NSRect(x: 0, y: 0, width: 800, height: 600) : old.frame
            view.createSurface()
        }
        old.retireSurface()
        if old.backedByZmx { services.zmxForegroundResolver?.noteLifecycleChange() }
        if hadFocus { view.focusAfterReparent() }
        return view
    }

    /// Shell-exit handler for BOTH pane factories, dispatched on the surface's CURRENT role, not the factory that
    /// built it (role-aware like `onFocusChange`): a promoted split survivor (main slot, `isSplitPane` cleared) must
    /// run `closePrimaryPane`, or a re-split then a main-pane exit fires the stale `closeSplitPane` — its guard now
    /// passes with both slots live — tearing down the fresh right pane, stranding the session on the dead left.
    @MainActor
    static func handlePaneExit(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID,
                               library: WindowLibrary, alreadyFinalized: UUID? = nil) {
        guard let session = store.session(withID: sessionID), session.surface === view || session.splitSurface === view else { return }
        // the catalog owns a remote window's panes: an exit here attaches again, or keeps an ended row's screen
        if session.remotePresentation?.binding.catalogOwned == true {
            let pane = view.isSplitPane ? session.splitPaneIdentity : session.paneIdentity
            if !session.ended, !(pane.map(session.catalogPaneHeld) ?? false) { PaneLead.reattach?(view, false) }
            return
        }
        if view.isSplitPane {
            store.closeSplitPane(sessionID, alreadyFinalized: alreadyFinalized)
        } else {
            // the daemon's leader is read before the respawn replaces it, so its successor can be told apart
            let publishRespawn = view.backedByZmx ? view.zmxSessionName.flatMap { PaneLead.ownerRespawn?(sessionID, $0) } : nil
            // makeSplitSurface omits onFontSizeChange, but a promoted survivor is the sole pane and must persist
            // its own cmd +/-. a respawned parent gets a fresh primary surface, which wires its own.
            let outcome = store.closePrimaryPane(sessionID, alreadyFinalized: alreadyFinalized)
            if outcome == .respawned { publishRespawn?() }
            if outcome == .promoted,
               let promoted = store.session(withID: sessionID)?.surface as? GhosttySurfaceView {
                promoted.onFontSizeChange = { store.setFontSize(sessionID, $0) }
                // the same "session survived ⇒ its split was promoted" test, for a dashboard holding this
                // session by `<id>:right`. synchronous, so it lands before the reconcile onChange prunes the
                // cell; this is the only place that can tell promotion from the split's own shell exiting.
                library.windowID(for: store)
                    .flatMap { DashboardControllerRegistry.shared.controller(for: $0) }?
                    .promoteSplitMember(session: sessionID)
            }
        }
        // focus the surviving (now maximized) pane, else the session reselected to; the collapse/switch re-hosts
        // the target, hence the retry. `topmostSurface` prefers an overlay/scratch cover over the pane it hides.
        if let survivor = store.session(withID: sessionID) ?? store.activeSession,
           HtmlOverlayRegistry.shared.focusCover(of: survivor) { return }
        let target = store.session(withID: sessionID)?.topmostSurface ?? store.activeSession?.topmostSurface
        (target as? GhosttySurfaceView)?.focusAfterReparent()
    }

    /// This launch's replay policy, latched before the deck mounted: the rerun master switch, the user's
    /// `restore-denylist.conf` and the daemons the reap saw alive. Internal so a test can pin the last.
    @MainActor
    static func launchSeedPolicy(_ ghostty: GhosttyApp, context: LaunchSpawnContext) -> LaunchSeedPolicy {
        LaunchSeedPolicy(restoreEnabled: ghostty.restoreRunningCommand, denylist: ghostty.restoreDenylist,
                         runningNames: context.runningNames,
                         suppressedDaemons: Set(context.suppressedLaunchPayloads.map(ZmxSupport.daemonName(for:))),
                         receivingShell: ghostty.commandProgram ?? ZmxLaunch.passwordDatabaseLoginShell())
    }

    /// A wrapped pane's shell environment is zmx's own; every other disposition inherits the pane env.
    /// Fixed at construction like `backedByZmx`, because the disposition is.
    private static func surfaceEnv(disposition: ZmxLaunch.Disposition,
                                   fallback: [String: String]) -> [String: String] {
        guard case .wrapped(let zmx) = disposition else { return fallback }
        return zmx.environment
    }

    /// Wires the four `onSearch*` callbacks to the owning session's search fields, resolved live via `sessionID`.
    /// START toggles: with the bar open it sends `end_search` (the ⌘F-again close), letting the resulting END
    /// clear; else it opens the bar (seeding any returned needle) and pins THIS surface as `searchSurface`, the
    /// owner the bar's needle/navigate/close drive. END is the single clear point — fields, owner, bar, and first
    /// responder back to the visible terminal. TOTAL/SELECTED carry the count/index; both factories share it, so
    /// GUI and control pin the owner alike.
    @MainActor
    static func wireSearchCallbacks(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID,
                                    actions: AppActions) {
        view.isSearchable = true
        view.onSearchStart = { [weak view] needle in
            guard let session = store.session(withID: sessionID) else { return }
            if session.searchActive {
                // ⌘F-again close: end search on the PINNED owner, not the just-fired `view`, so a second ⌘F on
                // the OTHER split pane closes the original owner instead of stranding it in libghostty search.
                (session.searchSurface as? GhosttySurfaceView)?.endSearch()
                return
            }
            session.searchActive = true
            session.searchSurface = view
            if let needle, !needle.isEmpty { session.searchNeedle = needle }
        }
        view.onSearchEnd = {
            guard let session = store.session(withID: sessionID) else { return }
            session.searchActive = false
            session.searchNeedle = ""
            session.searchTotal = nil
            session.searchSelected = nil
            session.searchSurface = nil
            // refocus ONLY while this is still the selected session and no cover is up: `session.search --close
            // --target <background>` would otherwise make a hidden, opacity-0 surface first responder and steal
            // input from the visible session (hidden views CAN), and a cover owns focus. `topmostSurface` catches
            // the in-deck overlay/scratch (overlay > scratch > active pane) but not the quick-terminal panel,
            // so bail while that is up — it refocuses on hide; the retry outlasts the SwiftUI teardown.
            guard store.selectedSessionID == sessionID else { return }
            let windowID = actions.library.windowID(forSession: sessionID)
            guard !QuickTerminalController.shared.holdsKey else { return }
            // terminal zoom owns focus above the deck and zoom-enter ends an open search; this END lands a tick
            // later, so refocusing would steal first responder back from the zoomed terminal.
            guard windowID.flatMap({ TerminalZoomRegistry.shared.controller(for: $0) })?.target == nil else { return }
            // a control picker is the topmost modal: `session.search --to close` stays valid cleanup while one
            // is pending, but its async END must not return focus behind it.
            guard PickRegistry.shared.controller(for: windowID)?.modalPending != true else { return }
            actions.resignDismissedFieldEditor(for: windowID)
            if HtmlOverlayRegistry.shared.focusCover(of: session) { return }
            if let surface = session.topmostSurface as? GhosttySurfaceView, !surface.deferFocusToAsk() { surface.focusAfterReparent() }
        }
        view.onSearchTotal = { total in store.session(withID: sessionID)?.searchTotal = total }
        view.onSearchSelected = { selected in store.session(withID: sessionID)?.searchSelected = selected }
    }

    /// Wires the pane-scoped keystroke-clear: `keyDown` fires `onUserInputClearsStatus` unconditionally, and this
    /// closure hands it to `AppStore.clearStatus(by:)`, which clears only when the keystroke's OWN pane owns the
    /// status under the Status reset setting, read live from `GhosttyApp` so a Settings change applies to the
    /// next key. A block set from a background pane survives typing elsewhere. Main/split read
    /// the LIVE `isSplitPane` at keystroke time, so a promoted survivor clears as `.left`, matching its migrated
    /// status identity and `tree` addressing; a captured `.right` would clear the wrong pane and leave both panes
    /// `.right`-wired after a re-split. The scratch passes `fixedPane: .scratch`: never promoted, no `view.session`.
    @MainActor
    static func wireStatusClear(_ view: GhosttySurfaceView, store: AppStore, sessionID: UUID,
                                fixedPane: StatusPane? = nil) {
        view.onUserInputClearsStatus = { [weak view] keystroke in
            let pane = fixedPane ?? ((view?.isSplitPane ?? false) ? .right : .left)
            let reset = GhosttyApp.shared.statusReset
            if store.forwardStatusKeystroke(keystroke, pane: pane, forSession: sessionID) { return }
            // a status mirrored from an origin pane this Mac has no counterpart for is not this pane's to clear
            guard store.session(withID: sessionID)?.remotePresentation?.allowsKeystrokeStatusClear != false else { return }
            store.clearStatus(by: keystroke, pane: pane, reset: reset, forSession: sessionID)
        }
    }

    /// Split-pane surface factory: a second independent login shell in the session's current directory, wired as
    /// `isSplitPane` so its PWD/title reports go to `session.splitCwd`/`splitTitle` and its shell exit closes
    /// just the split (hide + teardown), not the session.
    /// Internal rather than private: `SurfaceFactorySeedTests` drives it to pin the launch-seed wiring.
    @MainActor
    static func makeSplitSurface(for session: Session, store: AppStore, env: [String: String],
                                 services: SurfaceServices) -> GhosttySurfaceView {
        // cwd is the persisted `initialSplitCwd` (a restored split keeps its own directory), else the session's
        // effectiveCwd, both through `Session.localWorkingDirectory`: the directory is the LOCAL launch's,
        // whether that is a shell or the attach-time ssh client. Font size matches the primary; env inherits
        // the parent's window/workspace/session ids.
        // Creation, capture and override precedence matches the primary.
        let ghostty = GhosttyApp.shared
        let lead = ZmxLeadAttachment(claim: false)
        let zmx = ZmxLaunch.wrapsLocally(mode: ghostty.launchRestoreMode, session: session)
            ? ZmxLaunch.configuration(paneIdentity: session.splitPaneIdentity, pane: "split", environment: env, lead: lead)
            : nil
        let disposition = ZmxLaunch.disposition(requested: ghostty.requestedRestoreMode,
                                                active: ghostty.launchRestoreMode, configuration: zmx)
        if disposition.backedByZmx {
            services.zmxForegroundResolver?.noteLifecycleChange()
            if let identity = session.splitPaneIdentity { ZmxLeadBook.shared.begin(lead, pane: identity) }
        }
        let cwd = session.localWorkingDirectory(reported: session.initialSplitCwd ?? session.effectiveCwd,
                                                homeDirectory: NSHomeDirectory())
        let view = GhosttySurfaceView(workingDirectory: cwd,
                                      fontSize: session.fontSize.map(Float.init),
                                      env: Self.surfaceEnv(disposition: disposition, fallback: env),
                                      backedByZmx: disposition.backedByZmx)
        let provider = LaunchSeedProvider.pane(session: session, pane: .right, disposition: disposition,
                                               policy: Self.launchSeedPolicy(ghostty, context: services.launchContext))
        view.launchSeed = provider
        services.spawnRegistry?.enqueue(view, key: session.splitPaneIdentity, provider: provider)
        view.isSplitPane = true
        Self.wirePane(view, session: session, store: store, services: services)
        return view
    }

    /// Overlay-terminal surface factory: an ephemeral surface running the session's `overlayCommand` in
    /// `overlayCwd` (default the session's current dir). NOT wired to the session (no `view.session`), so its
    /// PWD reports don't clobber the session cwd; on exit `onExit` → `closeOverlay` tears it down and hides it.
    ///
    /// `pane` picks WHICH slot supplies the command/cwd/wait/color and receives the exit status: nil is the
    /// session-wide overlay, `left`/`right` the pane-scoped one covering that split pane alone. The temp
    /// exit-code file is minted per call, so two pane overlays open at once never share one.
    ///
    /// A HUD occupies the session-wide slot with the bundled helper as its command: it spawns NON-FOCUSING
    /// and captures no exit status, since it is a message the app painted rather than a program the caller
    /// ran. Its body file is the helper's only input, deleted with the surface like the exit-code file.
    @MainActor
    static func makeOverlaySurface(for session: Session, store: AppStore, pane: OverlayPane?,
                                   env: [String: String]) -> GhosttySurfaceView {
        let sessionID = session.id
        let spec = Self.overlaySpec(for: session, pane: pane)
        // the session-wide slot's occupant decides passivity; the body file is what that occupant needs
        let isHud = pane == nil && session.hudActive
        let hudFile = isHud ? session.hudFile : nil
        let codeFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("agterm-ovl-\(UUID().uuidString).code")
        // an explicit `--cwd` is the caller's local choice; only the inherited default follows the remote rule.
        let context = OverlayLaunchContext(
            command: spec.command,
            cwd: OverlayLaunchContext.cwd(explicit: spec.cwd, session: session, homeDirectory: NSHomeDirectory()),
            sessionEnvironment: env)
        let fontSize = isHud ? session.hudFontSize ?? session.fontSize : session.fontSize
        let view = GhosttySurfaceView(workingDirectory: context.cwd,
                                      fontSize: fontSize.map(Float.init), command: OverlayCapture.surfaceCommand,
                                      waitAfterCommand: spec.wait, autoFocus: !isHud,
                                      env: context.localEnvironment(codeFile: codeFile, hudFile: hudFile))
        view.overlayCodeFile = codeFile
        view.hudBodyFile = hudFile
        // the panel was sized from an estimated cell before this surface existed; once it has a grid, and
        // whenever a config reload changes its cell, the refresh measures with the cell libghostty draws
        if isHud { view.onGridChange = { [weak session] in session?.onHudGeometryChange?() } }
        // the overlay's own background color (`session.overlay.open --background-color`), applied in
        // createSurface — the overlay is sessionless, so it can't read it off the session there.
        view.overlayBackgroundColorHex = spec.backgroundColor
        // record the exit status on teardown (always via destroySurface), so it survives a `session.overlay.close`
        // that bypasses onExit; a force-close removes the session first and no-ops here, where it is unqueryable.
        //
        // the pane arm's callbacks re-resolve their pane from the slot the surface CURRENTLY occupies, never
        // the captured `pane`: `closePrimaryPane` MOVES a right-pane overlay into the left slot without
        // rebuilding the view (`TerminalSurfaceHost.makeNSView` reuses a non-nil slot), so a captured `.right` would
        // close nothing, record the status where `session.overlay.result --pane left` can't read it, and leave
        // the promoted pane under a dead overlay forever. The captured value is the pre-realization fallback,
        // for the window between the open and the slot holding this surface.
        if let pane {
            let livePane: @MainActor () -> OverlayPane = { [weak view] in
                guard let view else { return pane }
                return store.session(withID: sessionID)?.paneOverlayRole(of: view) ?? pane
            }
            view.onExitCodeCaptured = { store.recordPaneOverlayExit(sessionID, pane: livePane(), code: $0) }
            view.onExit = { store.closePaneOverlay(sessionID, pane: livePane()) }
            view.onExitHeld = { store.replicaOverlayHeld(forSession: sessionID, pane: livePane()) }
            // a PANE overlay tracks its pane's focus like the pane itself does: clicking it moves
            // `splitFocused`, so the deck's per-pane focus gate keeps it active instead of resigning first
            // responder on the next update, and `focusedOverlayPane` (⌘W rung, search, `topmostSurface`)
            // agrees with what the user sees.
            view.onFocusChange = { focused in
                guard focused else { return }
                store.session(withID: sessionID)?.splitFocused = livePane() == .right
            }
        } else {
            // a HUD records nothing: its "program" is the app's own painter, so an exit status would put a
            // number `session.overlay.result` could report for a message nobody ran.
            if !isHud {
                view.onExitCodeCaptured = { store.recordOverlayExit(sessionID, code: $0) }
            }
            view.onExit = { store.closeOverlay(sessionID) }
            view.onExitHeld = { store.replicaOverlayHeld(forSession: sessionID, pane: nil) }
        }
        // typing is user activity: resets the auto-follow idle timer so an idle fire can't change the selection
        // (vanishing the overlay) mid-typing. destroySurface nils this, breaking the store->surface->closure cycle.
        view.onUserInput = { _ in store.noteUserActivity() }
        return view
    }

    /// The four fields the overlay factory reads, from the session-wide slot (`pane == nil`) or that pane's
    /// slot. `PaneOverlay` carries them for both kinds; the session-wide slot has no such value type and its
    /// extra `overlaySizePercent` is geometry the factory never reads. The empty pane fallback is unreachable
    /// — every mount site tests the same slot in the pass that reaches this factory — but keeps it total.
    @MainActor
    private static func overlaySpec(for session: Session, pane: OverlayPane?) -> PaneOverlay {
        guard let pane else {
            return PaneOverlay(command: session.overlayCommand ?? "", cwd: session.overlayCwd,
                               backgroundColor: session.overlayBackgroundColor, wait: session.overlayWait)
        }
        return session.paneOverlay(pane) ?? PaneOverlay(command: "")
    }
}
