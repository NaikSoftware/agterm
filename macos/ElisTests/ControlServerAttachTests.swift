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

    private func makeServer() -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                      identity: AppIdentity(version: "test", commit: "test"), zmxClient: client,
                      socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    /// A row whose panes carry `ELIS_PANE_ID` tokens; never put in a window, so nothing launches.
    private func makeSession(live: Bool, split: Bool = false) throws -> (store: AppStore, session: Session) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
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
                          paneID: $0.paneID)
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
        let daemon = ZmxSupport.daemonName(for: UUID())
        store.bindRemote(RemoteBinding(remoteSessionID: "r", daemonsByLocalPane: [session.paneIdentity: daemon], presentationVersion: 1,
                                       origin: .init(host: "mini", endpoint: originEndpoint, sessionName: "r")),
                         forSession: session.id)
        let paneID = try XCTUnwrap(treePaneID(store, session, kind: "left"))

        let response = await attach(server, session.id.uuidString)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(masked(response.result?.attach),
                       masked(try ControlAttach.viewer(.remote(host: "mini", endpoint: originEndpoint, daemon: daemon), paneID: paneID)))
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

        session.catalogPanes[session.paneIdentity]?.held = true
        let held = await attach(server, session.id.uuidString)
        XCTAssertEqual(held.error, "\(session.id.uuidString) is not a Live session")
    }
}
