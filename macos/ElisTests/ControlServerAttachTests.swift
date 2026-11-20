import AppKit
import XCTest
@testable import Elis
@testable import ElisCore

@MainActor
final class ControlServerAttachTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private let client = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", runner: { _ in "" })
    private let originEndpoint = ControlZmxEndpoint(executable: "/opt/zmx", socketDirectory: "/run/zmx-origin")

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("elis-attach-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeServer(zmxClient: ZmxClient? = nil, outdatedBefore: Date? = nil) -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                      identity: AppIdentity(version: "test", commit: "test"), zmxClient: zmxClient ?? client,
                      zmxOutdatedBefore: outdatedBefore, socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    /// A server whose `zmx list` reports the session's daemon created at `created` seconds, against a cutoff of 1000.
    private func makeServer(daemonOf session: Session, created: Int) -> ControlServer {
        let row = "name=\(ZmxSupport.daemonName(for: session.paneIdentity))\tpid=200\tclients=1\tcreated=\(created)"
        let listing = ZmxClient(executablePath: "/tmp/zmx", socketDirectory: "/tmp/zmx-dir", runner: { _ in row })
        return makeServer(zmxClient: listing, outdatedBefore: Date(timeIntervalSince1970: 1000))
    }

    /// A row whose panes carry `ELIS_PANE_ID` tokens; never put in a window, so nothing launches.
    /// `realized: false` leaves the slots empty, as for a pane never shown since launch.
    private func makeSession(live: Bool, split: Bool = false, realized: Bool = true) throws -> (store: AppStore, session: Session) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        guard realized else { return (store, session) }
        session.surface = view(token: session.paneIdentity.uuidString, live: live)
        if split {
            store.toggleSplit(session.id)
            let right = view(token: try XCTUnwrap(session.splitPaneIdentity).uuidString, live: live)
            right.isSplitPane = true
            session.splitSurface = right
        }
        return (store, session)
    }

    private func view(token: String, live: Bool) -> GhosttySurfaceView {
        GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), command: "/bin/cat",
                           env: ["ELIS_PANE_ID": token], backedByZmx: live)
    }

    private func treePaneID(_ store: AppStore, _ session: Session, kind: String) -> String? {
        store.controlTree(paneForeground: { _ in nil }).workspaces.flatMap(\.sessions)
            .first { $0.id == session.id.uuidString }?.surfaces?.first { $0.kind == kind }?.paneID
    }

    /// The attach with its per-call nonce masked, so two builds of one attach compare equal.
    private func masked(_ attach: ControlAttach?) -> ControlAttach? {
        attach.map {
            ControlAttach(argv: $0.argv.map { $0.replacingOccurrences(of: "ZMX_MANAGED=[0-9a-f]+", with: "ZMX_MANAGED=*",
                                                                       options: .regularExpression) },
                          paneID: $0.paneID, screen: $0.screen, remote: $0.remote)
        }
    }

    private func attach(_ server: ControlServer, _ target: String, args: ControlArgs? = nil) async -> ControlResponse {
        await server.dispatch(ControlRequest(cmd: .sessionAttach, target: target, args: args))
    }

    func testLocalLivePaneReturnsAViewerAttach() async throws {
        let server = makeServer()
        let (store, session) = try makeSession(live: true)
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "left"))

        let response = await attach(server, session.id.uuidString)

        XCTAssertTrue(response.ok, response.error ?? "")
        let expected = try ControlAttach.viewer(.local(endpoint: client.endpoint, daemon: ZmxSupport.daemonName(for: session.paneIdentity)),
                                                paneID: paneID)
        XCTAssertEqual(masked(response.result?.attach), masked(expected))
    }

    func testLocalLivePaneNamesItsOrigin() async throws {
        let server = makeServer()
        let (store, session) = try makeSession(live: true)
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "left"))

        let response = await attach(server, session.id.uuidString)

        XCTAssertEqual(response.result?.attach?.origin, ControlAttachOrigin(session: session.id.uuidString, pane: paneID, host: nil),
                       response.error ?? "")
    }

    func testSplitPaneAttachesTheSplitDaemon() async throws {
        let server = makeServer()
        let (store, session) = try makeSession(live: true, split: true)
        let split = try XCTUnwrap(session.splitPaneIdentity)
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "right"))
        let expected = try ControlAttach.viewer(.local(endpoint: client.endpoint, daemon: ZmxSupport.daemonName(for: split)),
                                                paneID: paneID)

        let byPane = await attach(server, session.id.uuidString, args: ControlArgs(pane: "right"))
        let byToken = await attach(server, session.id.uuidString, args: ControlArgs(paneID: paneID))

        XCTAssertEqual(masked(byPane.result?.attach), masked(expected), byPane.error ?? "")
        XCTAssertEqual(masked(byToken.result?.attach), masked(expected), byToken.error ?? "")
    }

    private func claiming(_ pane: String? = nil) -> ControlArgs {
        var args = ControlArgs(pane: pane)
        args.claim = true
        return args
    }

    func testClaimingAttachForALivePane() async throws {
        let server = makeServer()
        let (store, session) = try makeSession(live: true)
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "left"))

        let response = await attach(server, session.id.uuidString, args: claiming())

        let attach = try XCTUnwrap(response.result?.attach, response.error ?? "")
        let nonce = try XCTUnwrap(attach.nonce)
        let expected = try ControlAttach.claimer(.local(endpoint: client.endpoint, daemon: ZmxSupport.daemonName(for: session.paneIdentity)),
                                                 paneID: paneID)
        XCTAssertEqual(masked(attach), masked(expected))
        XCTAssertTrue(attach.argv.contains("ZMX_MANAGED=\(nonce)"))
        XCTAssertTrue(attach.argv.contains("ZMX_MANAGED_CLAIM=1"))
    }

    func testClaimRefusedForAPaneThatIsNotLive() async throws {
        let server = makeServer()
        let (_, session) = try makeSession(live: false)
        let target = session.id.uuidString

        let response = await attach(server, target, args: claiming())

        XCTAssertEqual(response.error, "\(target) is not a Live session")
        XCTAssertNil(response.result?.attach)
    }

    func testTreeShowsPhoneLead() throws {
        let (store, session) = try makeSession(live: true)
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "left"))
        let lead = { store.controlTree(paneForeground: { _ in nil }).workspaces.flatMap(\.sessions)
            .first { $0.id == session.id.uuidString }?.surfaces?.first { $0.kind == "left" }?.phoneLead }
        XCTAssertNil(lead())

        library.phoneLeads = { $0 == paneID }

        XCTAssertEqual(lead(), true)
    }

    func testRefusesAPaneThatIsNotLive() async throws {
        let server = makeServer()
        let (_, session) = try makeSession(live: false)
        let target = session.id.uuidString

        let plain = await attach(server, target)
        let noSplit = await attach(server, target, args: ControlArgs(pane: "right"))
        let unknown = await attach(server, target, args: ControlArgs(paneID: "nope"))

        XCTAssertEqual(plain.error, "\(target) is not a Live session")
        XCTAssertNil(plain.result?.attach)
        XCTAssertEqual(noSplit.error, "session has no split pane")
        XCTAssertEqual(unknown.error, "unknown pane id: nope")
    }

    func testAttachedRowUsesItsOrigin() async throws {
        let server = makeServer()
        let (store, session) = try makeSession(live: false)
        let originPane = UUID()
        let daemon = ZmxSupport.daemonName(for: originPane)
        store.bindRemote(RemoteBinding(remoteSessionID: "r", daemonsByLocalPane: [session.paneIdentity: daemon], presentationVersion: 1,
                                       origin: .init(host: "mini", endpoint: originEndpoint, sessionName: "r")),
                         forSession: session.id)
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "left"))

        let response = await attach(server, session.id.uuidString)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(masked(response.result?.attach),
                       masked(try ControlAttach.viewer(.remote(host: "mini", endpoint: originEndpoint, daemon: daemon), paneID: paneID)))
        XCTAssertEqual(response.result?.attach?.origin, ControlAttachOrigin(session: "r", pane: originPane.uuidString, host: "mini"))
    }

    func testServerWindowRowUsesItsCatalogPane() async throws {
        let server = makeServer()
        let (store, session) = try makeSession(live: false)
        let catalogDaemon = ZmxSupport.daemonName(for: session.paneIdentity)
        let paneEndpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/srv/zmx-dir")
        store.bindRemote(RemoteBinding(remoteSessionID: "s", daemonsByLocalPane: [session.paneIdentity: "stale"], presentationVersion: 1,
                                       origin: .init(host: "box", endpoint: originEndpoint, sessionName: "s"), catalogOwned: true,
                                       originHeadless: true),
                         forSession: session.id)
        session.catalogPanes = [session.paneIdentity: CatalogPane(identity: session.paneIdentity, daemon: catalogDaemon, endpoint: paneEndpoint)]
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "left"))

        let response = await attach(server, session.id.uuidString)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(masked(response.result?.attach),
                       masked(try ControlAttach.viewer(.remote(host: "box", endpoint: paneEndpoint, daemon: catalogDaemon), paneID: paneID)))
        XCTAssertEqual(response.result?.attach?.origin,
                       ControlAttachOrigin(session: "s", pane: session.paneIdentity.uuidString, host: "box"))

        session.catalogPanes[session.paneIdentity]?.held = true
        let held = await attach(server, session.id.uuidString)
        XCTAssertEqual(held.error, "\(session.id.uuidString) is not a Live session")
    }

    func testAPaneNeverRealizedIsNotRealizedOnEveryRowKind() async throws {
        let server = makeServer()
        let (_, local) = try makeSession(live: true, realized: false)
        let (store, attached) = try makeSession(live: false, realized: false)
        store.bindRemote(RemoteBinding(remoteSessionID: "r", daemonsByLocalPane: [attached.paneIdentity: "d"], presentationVersion: 1,
                                       origin: .init(host: "mini", endpoint: originEndpoint, sessionName: "r")),
                         forSession: attached.id)
        let (_, catalog) = try makeSession(live: false, realized: false)
        store.bindRemote(RemoteBinding(remoteSessionID: "s", daemonsByLocalPane: [:], presentationVersion: 1,
                                       origin: .init(host: "box", endpoint: originEndpoint, sessionName: "s"), catalogOwned: true,
                                       originHeadless: true),
                         forSession: catalog.id)
        catalog.catalogPanes = [catalog.paneIdentity: CatalogPane(identity: catalog.paneIdentity, daemon: "d", endpoint: originEndpoint)]

        for session in [local, attached, catalog] {
            let response = await attach(server, session.id.uuidString)
            XCTAssertEqual(response.error, "session not realized")
        }
    }

    func testAttachedRowSplitPaneUsesItsSplitDaemon() async throws {
        let server = makeServer()
        let (store, session) = try makeSession(live: false, split: true)
        let split = try XCTUnwrap(session.splitPaneIdentity)
        let splitDaemon = ZmxSupport.daemonName(for: UUID())
        store.bindRemote(RemoteBinding(remoteSessionID: "r", daemonsByLocalPane: [session.paneIdentity: "primary", split: splitDaemon],
                                       presentationVersion: 1, origin: .init(host: "mini", endpoint: originEndpoint, sessionName: "r")),
                         forSession: session.id)
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "right"))

        let response = await attach(server, session.id.uuidString, args: ControlArgs(pane: "right"))

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(masked(response.result?.attach),
                       masked(try ControlAttach.viewer(.remote(host: "mini", endpoint: originEndpoint, daemon: splitDaemon), paneID: paneID)))
    }

    func testServerWindowRowSplitPaneUsesItsCatalogPane() async throws {
        let server = makeServer()
        let (store, session) = try makeSession(live: false, split: true)
        let split = try XCTUnwrap(session.splitPaneIdentity)
        let splitEndpoint = ControlZmxEndpoint(executable: "/srv/zmx", socketDirectory: "/srv/zmx-split")
        store.bindRemote(RemoteBinding(remoteSessionID: "s", daemonsByLocalPane: [:], presentationVersion: 1,
                                       origin: .init(host: "box", endpoint: originEndpoint, sessionName: "s"), catalogOwned: true,
                                       originHeadless: true),
                         forSession: session.id)
        session.catalogPanes = [
            session.paneIdentity: CatalogPane(identity: session.paneIdentity, daemon: "primary", endpoint: originEndpoint),
            split: CatalogPane(identity: split, daemon: ZmxSupport.daemonName(for: split), endpoint: splitEndpoint),
        ]
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "right"))

        let response = await attach(server, session.id.uuidString, args: ControlArgs(pane: "right"))

        XCTAssertTrue(response.ok, response.error ?? "")
        let expected = try ControlAttach.viewer(.remote(host: "box", endpoint: splitEndpoint, daemon: ZmxSupport.daemonName(for: split)), paneID: paneID)
        XCTAssertEqual(masked(response.result?.attach), masked(expected))
    }

    func testOutdatedLocalDaemonIsRefused() async throws {
        let (_, session) = try makeSession(live: true)
        let server = makeServer(daemonOf: session, created: 999)

        let response = await attach(server, session.id.uuidString)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error, "session predates this version; restart it to watch it on the phone")
        XCTAssertNil(response.result?.attach)
    }

    func testCurrentLocalDaemonIsServed() async throws {
        let (_, session) = try makeSession(live: true)
        let server = makeServer(daemonOf: session, created: 1000)

        let response = await attach(server, session.id.uuidString)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNotNil(response.result?.attach)
    }
}
