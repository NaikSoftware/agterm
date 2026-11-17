import HangarCore
import Foundation
import os
import SwiftUI

private let logger = Logger(subsystem: "ua.naiksoftware.hangar", category: "hangarApp")

@main
struct hangarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var appDelegate

    @Environment(\.openWindow) var openWindow

    @State var library: WindowLibrary
    @State var actions: AppActions
    @State var palette = PaletteController()
    @State private var sessionSwitcher: SessionSwitcher
    @State private var paneShortcuts: PaneShortcuts
    @State private var undoCloseShortcut: UndoCloseShortcut
    @State private var globalHotkey: GlobalHotkey
    @State var settingsModel: SettingsModel
    @State private var hookController: HookController
    @State private var controlServer: ControlServer
    @State var liveReset: LiveResetCoordinator
    @State private var customCommandRunner: CustomCommandRunner
    @State private var appearanceObserver: SystemAppearanceObserver
    @State private var accessibilityObserver: SystemAccessibilityObserver
    @State private var wakeObserver: SystemWakeObserver
    @State private var linkObserver: RemoteLinkObserver
    @State private var phoneRelay: PhoneRelay

    private let zmxForegroundResolver: ZmxForegroundResolver?
    private let captureOnExit: AppDelegate.ExitCapture?

    /// The launch spawn queue and the routing of its grants, handed to both pane factories. It stays UNARMED
    /// here, so every pane spawns on request exactly as it did before pacing existed; a launch restore is
    /// what arms it.
    private let spawnRegistry: SpawnRegistry
    private let launchContext: LaunchSpawnContext
    /// The one-shot marker for a confirmed Live sessions reset, in the state directory; handed to the
    /// delegate on scene appear because the quit path is the only writer.
    private let liveResetMarkerStore: LiveResetMarkerStore

    /// The plain `WindowGroup`'s scene id, used by `openWindow(id:)` to spawn additional windows.
    private static let windowGroupID = "terminal"
    static let phoneWindowID = "phone"

    /// Held for the whole process; the kernel releases it at exit, a force-quit included.
    private static var stateDirectoryLock: StateDirectoryLock?

    /// Exits before anything reads or writes `directory` unless this process owns it. A lock that cannot
    /// be taken exits too: it does not show that no other process is using the directory.
    private static func claimStateDirectory(_ directory: URL) {
        let reason: String
        switch StateDirectoryLock.acquire(directory: directory) {
        case .owned(let lock):
            stateDirectoryLock = lock
            return
        case .heldByAnother:
            reason = "another instance is already running on \(directory.path); control it with hangarctl"
        case .unavailable(let detail):
            reason = "cannot claim the state directory: \(detail)"
        }
        logger.error("\(reason, privacy: .public)")
        FileHandle.standardError.write(Data("Hangar: \(reason)\n".utf8))
        exit(1)
    }

    /// Which hangar this is, read from the bundle ONCE and shared by every surface that reports a version:
    /// the `TERM_PROGRAM_VERSION` of each spawned terminal, the `tree` payload, and the `version` command.
    /// Nothing below the app target reads `Bundle.main` — a hosted test would see its own host bundle and
    /// the projections would disagree.
    static let appIdentity: AppIdentity = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return AppIdentity(version: version,
                           recordedCommit: Bundle.main.infoDictionary?["GitCommit"] as? String)
    }()

    /// The version paired with hangar's `TERM_PROGRAM` identity in every spawned terminal.
    private static let terminalProgramVersion = appIdentity.version

    /// Hosted XCTest loads the real executable before `setUp`, so its scheme sets isolated state/socket paths
    /// plus this sentinel pre-`init()`; the scene then mounts a placeholder — no surfaces, no server.
    static var isHostedUnitTest: Bool {
        ProcessInfo.processInfo.environment["HANGAR_HOSTED_TESTS"] == "1"
    }

    init() {
        #if DEBUG
        // in the environment, ahead of every reader of the variable and of every child that inherits it
        if let adopted = DebugStateDirectory.adopted(environment: ProcessInfo.processInfo.environment,
                                                     liveDirectory: PersistenceStore.defaultDirectory) {
            setenv(DebugStateDirectory.environmentKey, adopted, 1)
        }
        #endif
        let stateDirectory = ProcessInfo.processInfo.environment["HANGAR_STATE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PersistenceStore.defaultDirectory
        Self.claimStateDirectory(stateDirectory)
        liveResetMarkerStore = LiveResetMarkerStore(directory: stateDirectory)
        HtmlOverlayRegistry.shared.profile = BrowserProfile(directory: stateDirectory)
        // restoredRuntime's first GhosttyApp.shared touch loads this file once, so it must be current first;
        // the seeded default theme lives only in memory, never in settings.json.
        let settingsStore = SettingsStore(directory: stateDirectory)
        let launchSettings = settingsStore.load()
        _ = SettingsModel.writeGhosttyConfig(launchSettings)
        // the pacer exists before the library so the model can discard the key of a pane it removes before
        // that pane's window ever mounts; the registry that routes grants comes after
        let pacer = SpawnPacer()
        let restored = hangarApp.restoredRuntime(stateDirectory: stateDirectory, pacer: pacer,
                                                 flaggedLayout: launchSettings.effectiveFlaggedViewLayout)
        spawnRegistry = SpawnRegistry(pacer: pacer)
        let library = restored.library
        zmxForegroundResolver = restored.foregroundResolver
        launchContext = restored.spawnContext
        _library = State(initialValue: library)
        let actions = AppActions(library: library)
        _actions = State(initialValue: actions)
        // built before the control server so it can drive `keymap.reload`, safe since both need only the library.
        let settingsModel = SettingsModel(library: library, settingsStore: settingsStore)
        _settingsModel = State(initialValue: settingsModel)
        // here, not in the scene `.task`: the menu's first evaluation reads remotes through it, and a later
        // assignment invalidates nothing, leaving File ▸ Attach Remote disabled until an unrelated rebuild.
        actions.settingsModel = settingsModel
        captureOnExit = AppDelegate.makeExitCapture(
            settingsModel: settingsModel, zmxResolver: restored.foregroundResolver)
        let controlServer = ControlServer(library: library, actions: actions, settingsModel: settingsModel,
                                          identity: Self.appIdentity,
                                          zmxForegroundResolver: restored.foregroundResolver,
                                          zmxClient: restored.zmxClient,
                                          zmxOutdatedBefore: restored.zmxOutdatedBefore)
        _controlServer = State(initialValue: controlServer)
        let phoneRelay = PhoneRelay(stateDirectory: stateDirectory)
        phoneRelay.onEvent = { [weak library] in library?.emitAppEvent(ControlEventDraft(kind: $0, payload: ControlEventPayload(ip: $1))) }
        controlServer.phoneRelay = phoneRelay
        _phoneRelay = State(initialValue: phoneRelay)
        actions.remoteAttacher = controlServer
        actions.companionDuplicator = controlServer
        actions.sessionTyper = controlServer
        SessionLaunchers.refresh()
        SessionAgentMonitor.start(library: library, zmxResolver: restored.foregroundResolver)
        LinkOpener.shared.mode = { settingsModel.settings.effectiveLinkOpenMode }
        LinkOpener.shared.selectSession = { [weak actions] id, origin, pane in
            actions?.followSessionLink(id, from: origin, pane: pane)
        }
        LinkOpener.shared.sessionName = { [weak library] id, origin, pane in
            guard let library, let target = library.sessionLinkTarget(id, from: origin, pane: pane) else { return nil }
            return library.store(for: target.windowID)?.session(withID: target.sessionID)?.displayName
        }
        controlServer.installRemoteLinkClicks()
        LinkOpener.shared.overlay = { [weak controlServer] url, session, percent in
            controlServer?.openLinkOverlay(url, session: session, sizePercent: percent) ?? false
        }
        LinkOpener.shared.image = { [weak controlServer] url, session, done in
            guard let controlServer else { return done(false) }
            controlServer.openImageLink(url, session: session, completion: done)
        }
        LinkOpener.shared.markdown = { [weak controlServer] url, session, percent, done in
            guard let controlServer else { return done(false) }
            controlServer.openMarkdownLink(url, session: session, sizePercent: percent, completion: done)
        }
        LinkOpener.shared.text = { [weak controlServer] link, done in
            guard let controlServer else { return done(false) }
            controlServer.openTextLink(link, completion: done)
        }
        LinkOpener.shared.document = { [weak controlServer] url, session, percent, done in
            guard let controlServer else { return done(false) }
            controlServer.openDocumentLink(url, session: session, sizePercent: percent, completion: done)
        }
        let liveReset = LiveResetCoordinator(settingsModel: settingsModel,
                                             selection: { [weak controlServer] in controlServer?.liveResetSelection() })
        controlServer.liveReset = liveReset
        _liveReset = State(initialValue: liveReset)
        _sessionSwitcher = State(initialValue: SessionSwitcher(library: library, canSwitch: { actions.uiActionsEnabled }))
        _paneShortcuts = State(initialValue: PaneShortcuts(library: library, actions: actions))
        _undoCloseShortcut = State(initialValue: UndoCloseShortcut(actions: actions))
        _globalHotkey = State(initialValue: GlobalHotkey(settings: settingsModel))
        // built last: needs the keymap (settings), the action hub for built-in monitor binds, and the control
        // server's bound socket path for `{AGT_SOCKET}`.
        _customCommandRunner = State(initialValue: CustomCommandRunner(
            library: library, settings: settingsModel, actions: actions,
            usage: CustomCommandUsageStore(directory: stateDirectory),
            socketProvider: { controlServer.resolvedSocketPath },
            failureHud: FailureHud(
                open: { [weak controlServer] sessionID, spec, pane in
                    guard let controlServer else { return "control server is gone" }
                    let response = controlServer.openCommandFailureHud(sessionID, spec: spec, pane: pane)
                    return response.ok ? nil : response.error ?? "refused without a reason"
                })))
        // hooks.conf scripts: fed by the library's post-append observer, applied from the settings model.
        let hookController = HookController(library: library, settings: settingsModel,
                                            socketProvider: { controlServer.resolvedSocketPath })
        controlServer.hookStatus = { hookController.scheduler.status }
        _hookController = State(initialValue: hookController)
        // follows macOS light/dark via KVO on NSApp.effectiveAppearance; dependency-free, started in `.task`.
        _appearanceObserver = State(initialValue: SystemAppearanceObserver())
        // follows Reduce Motion / Reduce Transparency via NSWorkspace's accessibility-display notification,
        // fanning live changes to AppKit consumers; SwiftUI ones use Environment.
        _accessibilityObserver = State(initialValue: SystemAccessibilityObserver())
        // re-attempts surface creation on display wake: libghostty refuses to create one while the display
        // sleeps, which leaves a scheduled job's session realized-never and its --command unrun (#416).
        _wakeObserver = State(initialValue: SystemWakeObserver())
        _linkObserver = State(initialValue: RemoteLinkObserver { [weak controlServer] in
            controlServer?.retryRemoteLinksNow()
        })
        // the library restored the model and ran the reap inside its init, and no window has mounted yet;
        // arm records expectations only, so nothing here waits on a view.
        if !Self.isHostedUnitTest {
            let plan = library.launchSpawnPlan()
            spawnRegistry.pacer.arm(order: plan.order, burst: plan.burst)
            spawnRegistry.pacer.onDrain = { drained in
                logger.debug("launch spawn queue drained in \(drained / .milliseconds(1), format: .fixed(precision: 0)) ms")
            }
            logger.debug("launch spawn queue armed with \(plan.order.count) panes, \(plan.burst.count) in the burst")
        }
    }

    var body: some Scene {
        // a plain WindowGroup auto-opens one window at launch plus one per `openWindow(id:)`; value-based
        // `WindowGroup(for:)` can't bootstrap the first (no auto-open with SwiftUI restoration off). windows
        // claim the next open id off `WindowLibrary`'s claim queue (dedup-by-id); one past the set dismisses itself.
        WindowGroup(id: Self.windowGroupID) {
            if Self.isHostedUnitTest {
                HostedTestPlaceholder()
            } else {
                ContentView(
                    library: library,
                    makeSurface: {
                        Self.makeSurface(for: $0, store: $1,
                                         env: surfaceEnv(for: $0, pane: .left), services: surfaceServices)
                    },
                    makeSplitSurface: {
                        Self.makeSplitSurface(for: $0, store: $1,
                                              env: surfaceEnv(for: $0, pane: .right), services: surfaceServices)
                    },
                    makeOverlaySurface: {
                        Self.makeOverlaySurface(for: $0, store: $1, pane: $2, env: surfaceEnv(for: $0))
                    },
                    makeScratchSurface: { session, store in
                        // suppress the scratch's creation autoFocus when a caller's program overlay or the
                        // quick terminal is up — each renders above it and owns focus. A HUD renders
                        // above it too but owns nothing, so it must not hold focus off a scratch just shown.
                        let qtVisible = QuickTerminalController.shared.holdsKey
                        return Self.makeScratchSurface(for: session, store: store,
                                                       env: surfaceEnv(for: session, pane: .scratch),
                                                       suppressAutoFocus: session.coverOverlayVisible || qtVisible,
                                                       actions: actions)
                    },
                    captureOnExit: captureOnExit,
                    actions: actions,
                    palette: palette,
                    sessionSwitcher: sessionSwitcher
                )
                    .frame(minWidth: 640, minHeight: 400)
                    .task {
                        appDelegate.library = library
                        appDelegate.captureOnExit = captureOnExit
                        // `openWindow` lives only in the scene: hand it to the action hub for cross-window
                        // reveal and `window.new`/`window.select` (raise if on-screen, else claim + spawn).
                        // MUST precede `controlServer.start()`, or an early command finds it nil: ok, no window.
                        actions.openWindow = { id in
                            if WindowRegistry.shared.raise(id) { return }
                            library.enqueueClaim(id)
                            openWindow(id: Self.windowGroupID)
                        }
                        // start the control channel (idempotent); the delegate reference stops it + unlinks the
                        // socket on terminate.
                        appDelegate.controlServer = controlServer
                        controlServer.start()
                        // bind the app-level quick terminal (idempotent); its env needs the bound socket, so
                        // this follows `start()` like the surface environment does.
                        wireQuickTerminal(library: library)
                        // forwards to the BOUND socket: a refused instance's path belongs to another app
                        appDelegate.phoneRelay = phoneRelay
                        phoneRelay.attach(socketPath: controlServer.boundSocketPath)
                        // Ctrl-Tab session-switcher key monitors (idempotent).
                        sessionSwitcher.start()
                        // Ctrl-1/Ctrl-2 direct pane-focus key monitor (idempotent).
                        paneShortcuts.start()
                        // undo-close shortcut (idempotent); passes through text fields so native undo wins there.
                        undoCloseShortcut.start()
                        // the OS-registered quick-terminal chord (idempotent), re-registered on keymap reload.
                        // Must follow `wireQuickTerminal`, the hotkey being able to summon the panel at once.
                        globalHotkey.start()
                        // custom-command key monitor (idempotent): rebuilds its matcher from the keymap on
                        // `.hangarKeymapChanged`, removed on terminate via the delegate reference.
                        appDelegate.customCommandRunner = customCommandRunner
                        appDelegate.settingsModel = settingsModel
                        appDelegate.liveResetMarkerStore = liveResetMarkerStore
                        appDelegate.liveReset = liveReset
                        // hand the delegate the action hub and drain folders `open -a Hangar /path` queued
                        // before the window store resolved.
                        appDelegate.actions = actions
                        // hooks apply BEFORE the drain: a queued `open -a Hangar /path` creates a session, and a
                        // session.created hook must already be scheduled to see it (idempotent).
                        hookController.start()
                        // a hook on it calls back over the socket, so an unbound launch emits nothing
                        library.emitAppLaunched(ready: controlServer.boundSocketPath != nil)
                        appDelegate.drainPendingOpenDirectories()
                        customCommandRunner.start()
                        // seed the per-window settings into every open store now the model is wired: idempotent
                        // and order-independent of resolveStore/onAppear (later windows seed in resolveStore).
                        settingsModel.applyWindowSettingsToAllWindows()
                        actions.customCommandRunner = customCommandRunner
                        // the action hub opens the .themes palette for the "Select Theme…" launcher + menu.
                        actions.palette = palette
                        // register the notification delegate + request authorization (idempotent); the hub +
                        // library let a banner click reach the firing pane and stamp its window id in.
                        NotificationManager.shared.actions = actions
                        NotificationManager.shared.library = library
                        NotificationManager.shared.start()
                        let paneServices = surfaceServices
                        PaneLead.reattach = { old, claim in Self.reattachPane(old, claim: claim, services: paneServices) }
                        PaneLead.replace = { old, launch, lead in
                            Self.replacePane(old, launch: launch, lead: lead, cover: false, spawnFirst: true,
                                             services: paneServices)
                        }
                        PaneLead.roleChanged = { [library] view in
                            (view.session ?? view.scratchOwner).flatMap { library.store(forSession: $0.id) }?.leadRoleChanged()
                        }
                        PaneLead.reconnect = { old, cover in
                            Self.reattachPane(old, claim: false, cover: cover, services: paneServices)
                        }
                        PaneLead.heldExit = { [weak server = controlServer] view in server?.remotePaneHeld(view) }
                        PaneLead.catalogChannel = { [weak server = controlServer] session, user in
                            server?.catalogPool(forSession: session)?.lease(user)
                        }
                        PaneLead.ownerRespawn = { [weak server = controlServer] session, daemon in
                            let prior = server?.priorLeader(daemon: daemon)
                            return { server?.ownerRespawned(session: session, daemon: daemon, prior: prior) }
                        }
                        PaneLead.waitToReconnect = { [weak server = controlServer, library] view, cover in
                            guard let session = view.session, let store = library.store(holdingSession: session.id) else { return }
                            Self.remotePaneStopped(view, store: store, sessionID: session.id, library: library, attach: server)
                            server?.waitToReconnect(view, cover: cover)
                        }
                        // drive the Dock badge (via UNUserNotifications) from the app-wide unseen total — the
                        // sidebar pills' Session.unseenCount summed across windows.
                        DockBadgeController.shared.library = library
                        DockBadgeController.shared.start()
                        // keymap parse errors / conflicts from SettingsModel init — too early to post then,
                        // before registration. launch window only: `hasReopened` is false until `reopenWindows()`.
                        if !library.hasReopened, !settingsModel.keymapDiagnostics.isEmpty {
                            NotificationManager.shared.notifyKeymapDiagnostics(count: settingsModel.keymapDiagnostics.count)
                        }
                        if !library.hasReopened, !settingsModel.hooksDiagnostics.isEmpty {
                            NotificationManager.shared.notifyHooksDiagnostics(count: settingsModel.hooksDiagnostics.count)
                        }
                        if !library.hasReopened, settingsModel.remotes.issueCount > 0 {
                            NotificationManager.shared.notifyRemotesDiagnostics(count: settingsModel.remotes.issueCount)
                        }
                        // same for ghostty config diagnostics, recorded at boot by GhosttyApp.loadConfig
                        // (applicationDidFinishLaunching, before registration): same `hasReopened` gate.
                        if !library.hasReopened, GhosttyApp.shared.lastConfigDiagnosticsCount > 0 {
                            NotificationManager.shared.notifyConfigDiagnostics(count: GhosttyApp.shared.lastConfigDiagnosticsCount)
                        }
                        // same for the Live sessions reset, recorded by `restoredRuntime` before any window
                        if !library.hasReopened, let outcome = GhosttyApp.shared.liveResetOutcome {
                            NotificationManager.shared.notifyLiveResetOutcome(outcome)
                        }
                        // runs once via the library latch — the .task fires per window.
                        reopenWindows()
                        appDelegate.scheduleRestoredWindowReconciliation(reason: "scene-task")
                        // start appearance following last: `[.initial]` seeds the launch side once the
                        // eager-deck surfaces exist; idempotent, so per-window `.task` re-entry is safe.
                        appearanceObserver.start()
                        // consumers read current accessibility values at first render; this handles live flips.
                        accessibilityObserver.start()
                        wakeObserver.start()
                        linkObserver.start()
                        linkObserver.watchPath()
                        // last: an installer alert blocks the rest of the task, and the window behind it should
                        // be fully wired before it opens. `runIfDue` latches, so the per-window .task is safe.
                        ExtrasAutoInstaller.runIfDue(identity: Self.appIdentity)
                        WorkspaceSetupGuidePresenter.presentIfDue(actions: actions)
                    }
            }
        }
        // chromeless: traffic lights float over ContentView's custom titlebar row, so no empty strip above it.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
        .commands { appCommands }

        Settings {
            SettingsView(model: settingsModel)
        }

        Window("Connect a Phone", id: Self.phoneWindowID) {
            ConnectPhoneView(relay: phoneRelay)
        }
        .windowResizability(.contentSize)
        .commandsRemoved() // the app menu's item opens it; no second one in Window
    }

    @MainActor
    private struct RestoredRuntime {
        let library: WindowLibrary
        let foregroundResolver: ZmxForegroundResolver?
        /// Handed to `ControlServer` so the zmx commands can list and kill. It used to live only inside the
        /// finalizer/reap closures, where nothing else could reach it.
        let zmxClient: ZmxClient?
        let spawnContext: LaunchSpawnContext
        /// zmxOutdatedBefore is this launch's `ZmxBuildRecord` cutoff.
        var zmxOutdatedBefore: Date?
    }

    /// What the launch reap learned before any window mounted, read by every pane factory: the daemon names
    /// observed alive, a scheduling hint only. A class because the inventory sink fills it inside
    /// `WindowLibrary.init`, before the runtime that carries it exists.
    @MainActor
    final class LaunchSpawnContext {
        var runningNames: Set<String>?
        /// The claimed pane identities the library inventoried during bootstrap; nil when incomplete.
        var launchInventory: Set<UUID>?
        /// Panes whose reset could not be confirmed: they attach with no replay and no durable command.
        var suppressedLaunchPayloads: Set<UUID> = []
    }

    /// Builds the window library and zmx foreground resolver for the state directory. Bootstrap
    /// migrates/recovers persisted windows and inventories claimed pane identities before surfaces mount.
    private static func restoredRuntime(stateDirectory: URL, pacer: SpawnPacer,
                                        flaggedLayout: FlaggedViewLayout) -> RestoredRuntime {
        guard !isHostedUnitTest else {
            return RestoredRuntime(library: WindowLibrary(directory: stateDirectory, paneFinalizer: nil,
                                                          flaggedLayout: flaggedLayout),
                                   foregroundResolver: nil, zmxClient: nil, spawnContext: LaunchSpawnContext())
        }
        let ghostty = GhosttyApp.shared
        let environment = ProcessInfo.processInfo.environment
        let executable = ZmxLaunch.executablePath(bundleURL: Bundle.main.bundleURL, environment: environment,
                                                  allowDebugOverride: ZmxLaunch.allowDebugOverride)
        let client = ZmxClient(executablePath: executable,
                              socketDirectory: ZmxSupport.socketDirectory(forStateDirectory: stateDirectory.path),
                              sweeper: ProcessSweeper())
        let foregroundResolver = ZmxForegroundResolver(leaderProvider: { client.sessionLeaderPIDs(timeout: $0) })
        let context = LaunchSpawnContext()
        let library = WindowLibrary(
            directory: stateDirectory,
            paneFinalizer: {
                _ = client.kill(paneIdentities: $0)
                foregroundResolver.noteLifecycleChange()
            },
            launchInventorySink: { context.launchInventory = $0 },
            launchPaneDrop: { identities in
                for identity in identities { pacer.discard(identity) }
            },
            flaggedLayout: flaggedLayout)
        // the reap waits for the library so a confirmed Live sessions reset can narrow its marker against the
        // current claims first; both finish before any window mounts
        let outdatedBefore = ZmxBuildRecord.launchCutoff(bundledID: Self.bundledZmxBuildID(), directory: stateDirectory)
        var consumer = LiveResetConsumer.Dependencies(markerStore: LiveResetMarkerStore(directory: stateDirectory),
                                                      probe: LiveAttributionProbe())
        consumer.outdatedBefore = outdatedBefore
        let launch = LaunchOrchestration.Inputs(library: library, client: client, resolver: foregroundResolver,
                                                context: context, launchDecision: ghostty.restoreLaunchDecision)
        if let outcome = LaunchOrchestration.run(launch, consumer: consumer) {
            ghostty.recordLiveResetOutcome(outcome)
        }
        return RestoredRuntime(library: library, foregroundResolver: foregroundResolver, zmxClient: client,
                               spawnContext: context, zmxOutdatedBefore: outdatedBefore)
    }

    private static func bundledZmxBuildID() -> String? {
        guard let url = Bundle.main.url(forResource: "BUILD", withExtension: nil, subdirectory: "zmx") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Opens the windows open at quit beyond the one SwiftUI auto-opened at launch (which claimed the launch
    /// id). Runs once via the library latch: `consumeReopen` seeds the claim queue, returning the extra count.
    @MainActor
    private func reopenWindows() {
        let extra = library.consumeReopen()
        for _ in 0..<extra { openWindow(id: Self.windowGroupID) }
    }

    /// Which pane a focus report should record, read from the surface's LIVE role so a swapped terminal
    /// updates the slot it now occupies. nil when the report is a focus LOSS, which records nothing.
    @MainActor
    static func focusedSplitState(_ focused: Bool, surface: GhosttySurfaceView?) -> Bool? {
        guard focused else { return nil }
        return surface?.isSplitPane ?? false
    }

    /// Persist a font-size change only from the surface currently in the PRIMARY role; a split-role or
    /// unresolved surface changes size live without writing the session's persisted value.
    @MainActor
    static func persistFontSize(_ size: Double, from surface: GhosttySurfaceView?, store: AppStore, sessionID: UUID) {
        guard surface?.isSplitPane == false else { return }
        store.setFontSize(sessionID, size)
    }

    /// App-owned services every pane factory wires into the view it builds.
    struct SurfaceServices {
        let library: WindowLibrary
        let actions: AppActions
        let zmxForegroundResolver: ZmxForegroundResolver?
        let spawnRegistry: SpawnRegistry?
        let launchContext: LaunchSpawnContext
    }

    private var surfaceServices: SurfaceServices {
        SurfaceServices(library: library, actions: actions, zmxForegroundResolver: zmxForegroundResolver, spawnRegistry: spawnRegistry,
                        launchContext: launchContext)
    }

    /// The environment a tree surface (main / split / overlay / scratch) exposes to its shell: the `HANGAR_*`
    /// session facts plus hangar's identity (`TERM_PROGRAM`/`TERM_PROGRAM_VERSION`). The window id comes from the
    /// open store owning the session (split/overlay/scratch inherit it), the workspace from the session's owner.
    /// `HANGAR_SOCKET` is the path `ControlServer` will bind, resolved at init so a launch-window shell
    /// materializing before `start()` still sees it, honoring a test's `HANGAR_CONTROL_SOCKET` override, and
    /// replaced by an unbindable path when this instance refused it to another live one. `pane`
    /// injects `HANGAR_PANE` (`left`=main, `right`=split, `scratch`) so the hook wrapper forwards `--pane` and a
    /// background-pane status records which surface blocked; the overlay passes nil.
    @MainActor
    private func surfaceEnv(for session: Session, pane: StatusPane? = nil) -> [String: String] {
        var windowID: WindowInfo.ID?
        var workspaceID: UUID?
        if let resolvedWindowID = library.windowID(forSession: session.id) {
            windowID = resolvedWindowID
            if let workspace = library.store(for: resolvedWindowID)?.workspace(forSession: session.id) {
                workspaceID = workspace.id
            }
        }
        let paneIdentity: UUID? = switch pane {
        case .left: session.paneIdentity
        case .right: session.splitPaneIdentity
        case .scratch: UUID()
        case nil: nil
        }
        // a session-owned pane bakes its stable identity, so the hook resolves the surface's live slot after
        // promotion; scratch is ephemeral and gets one identity for the lifetime of its surface.
        return SurfaceEnvironment.session(sessionID: session.id, windowID: windowID,
                                          workspaceID: workspaceID, socketPath: controlServer.resolvedSocketPath,
                                          programVersion: Self.terminalProgramVersion,
                                          pane: pane, paneToken: paneIdentity?.uuidString)
    }

    /// The environment the quick terminal exposes — scratch, not in the tree and owned by no window, so its
    /// `HANGAR_*` values carry only enabled and socket facts, plus app identity.
    @MainActor
    func quickTerminalEnv() -> [String: String] {
        SurfaceEnvironment.quickTerminal(socketPath: controlServer.resolvedSocketPath,
                                         programVersion: Self.terminalProgramVersion)
    }

    /// The quick terminal's start directory: the active session's, through the remote rule, else HOME.
    @MainActor
    static func quickTerminalCwd(library: WindowLibrary?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard let session = library?.activeStore?.activeSession else { return home }
        return session.localWorkingDirectory(reported: session.effectiveCwd, homeDirectory: home)
    }

    /// Bind the app's one quick terminal to the library. Every provider resolves through `activeStore` at
    /// call time rather than capturing a window, the panel outliving any particular one; `canShow` is what
    /// keeps it from being summoned into an app with no window left to return to.
    @MainActor
    func wireQuickTerminal(library: WindowLibrary) {
        let controller = QuickTerminalController.shared
        controller.cwdProvider = { [weak library] in Self.quickTerminalCwd(library: library) }
        controller.envProvider = { [self] in quickTerminalEnv() }
        // typing counts as activity, so an idle auto-follow fire can't reshuffle the active window's
        // selection behind the panel while the user types (mirrors the overlay/scratch).
        controller.onUserInput = { [weak library] in library?.activeStore?.noteUserActivity() }
        controller.focusAllowed = { [weak library] in
            PickRegistry.shared.controller(for: library?.activeWindowID)?.modalPending != true
        }
        // the global hotkey reaches the controller directly, with none of the `uiActionsEnabled` gating every
        // in-app path has, so the pick term belongs here. Only that term: refusing a system-wide summon
        // because some BACKGROUND window has a dashboard open would defeat the point of the chord.
        controller.canShow = { [weak library] in
            guard let library, !library.openIDs().isEmpty else { return false }
            return PickRegistry.shared.controller(for: library.activeWindowID)?.modalPending != true
        }
        controller.terminalColorProvider = { WindowContentView.resolvedTerminalColor() }
    }
}
