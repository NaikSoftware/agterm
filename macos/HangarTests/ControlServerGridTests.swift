import AppKit
import XCTest
@testable import Hangar
import HangarCore

@MainActor
final class ControlServerGridTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var panes: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hangar-grid-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
    }

    override func tearDown() async throws {
        panes.forEach(ZmxLeadBook.shared.forget)
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeServer() -> ControlServer {
        ControlServer(library: library, actions: AppActions(library: library),
                      settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                      identity: AppIdentity(version: "test", commit: "test"), zmxClient: nil,
                      socketPath: stateDir.appendingPathComponent("control.sock").path)
    }

    private func makeSession(split: Bool = false, command: String = "/bin/cat") throws -> (store: AppStore, session: Session) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        session.surface = realizedView(session: session, command: command)
        if split {
            store.toggleSplit(session.id)
            let right = realizedView(session: session, command: command)
            right.isSplitPane = true
            session.splitSurface = right
        }
        return (store, session)
    }

    private func realizedView(session: Session?, command: String, env: [String: String] = [:]) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: 12, command: command, env: env)
        view.session = session
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(view.isRealized)
        return view
    }

    private func view(_ session: Session) throws -> GhosttySurfaceView {
        try XCTUnwrap(session.surface as? GhosttySurfaceView)
    }

    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testAForcedGridReachesLibghosttyAndResetReturnsTheViewsGrid() throws {
        let server = makeServer()
        let (_, session) = try makeSession()
        let surface = try view(session)
        let fitted = surface.gridSize()
        XCTAssertNotEqual(fitted.columns, 40)

        let forced = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left,
                                           grid: ControlGrid(columns: 40, rows: 10))
        XCTAssertTrue(forced.ok, forced.error ?? "")
        XCTAssertEqual(forced.result?.id, session.id.uuidString)
        XCTAssertEqual(forced.result?.pane, "left")
        XCTAssertEqual(forced.result?.columns, 40)
        XCTAssertEqual(forced.result?.rows, 10)
        XCTAssertEqual(surface.gridSize().columns, 40)
        XCTAssertEqual(surface.gridSize().rows, 10)

        let reset = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left, grid: nil)
        XCTAssertTrue(reset.ok, reset.error ?? "")
        XCTAssertEqual(reset.result?.columns, fitted.columns)
        XCTAssertEqual(reset.result?.rows, fitted.rows)
        XCTAssertNil(surface.forcedGrid)
    }

    func testAForcedGridLargerThanTheViewHolds() throws {
        let server = makeServer()
        let (_, session) = try makeSession()
        let response = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left,
                                             grid: ControlGrid(columns: 200, rows: 80))
        XCTAssertEqual(response.result?.columns, 200)
        XCTAssertEqual(response.result?.rows, 80)
    }

    func testAViewSizeChangeHandsTheGridBackToTheView() throws {
        let server = makeServer()
        let (_, session) = try makeSession()
        let surface = try view(session)
        _ = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left, grid: ControlGrid(columns: 40, rows: 10))

        surface.setFrameSize(NSSize(width: 600, height: 400))

        XCTAssertNil(surface.forcedGrid)
        XCTAssertGreaterThan(surface.gridSize().columns, 40)
        XCTAssertGreaterThan(surface.gridSize().rows, 10)
    }

    func testAFontChangeKeepsTheForcedGrid() async throws {
        let server = makeServer()
        let (_, session) = try makeSession()
        let surface = try view(session)
        _ = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left, grid: ControlGrid(columns: 40, rows: 10))
        let before = surface.cellSize()

        _ = surface.performBindingAction("increase_font_size:4")
        try await waitUntil { surface.cellSize()?.height != before?.height && surface.gridSize() == (40, 10) }

        XCTAssertNotEqual(surface.cellSize()?.height, before?.height)
        XCTAssertEqual(surface.gridSize().columns, 40)
        XCTAssertEqual(surface.gridSize().rows, 10)
    }

    func testTheRightPaneIsAddressedAndNeedsASplit() throws {
        let server = makeServer()
        let (_, plain) = try makeSession()
        XCTAssertEqual(server.setSessionGrid(plain.id.uuidString, window: nil, pane: .right,
                                             grid: ControlGrid(columns: 40, rows: 10)).error, "session has no split pane")
        XCTAssertEqual(server.scrollSession(plain.id.uuidString, window: nil, pane: .right, lines: -3).error,
                       "session has no split pane")

        let (_, split) = try makeSession(split: true)
        let response = server.setSessionGrid(split.id.uuidString, window: nil, pane: .right,
                                             grid: ControlGrid(columns: 40, rows: 10))
        XCTAssertEqual(response.result?.pane, "right")
        XCTAssertEqual((split.splitSurface as? GhosttySurfaceView)?.gridSize().columns, 40)
        XCTAssertNil(try view(split).forcedGrid)
    }

    func testTheTreeListsOnlyForcedPanes() throws {
        let server = makeServer()
        let (store, session) = try makeSession(split: true)
        XCTAssertNil(node(server.buildTree(in: store), session)?.paneGrids)

        _ = server.setSessionGrid(session.id.uuidString, window: nil, pane: .right, grid: ControlGrid(columns: 40, rows: 10))

        let grids = node(server.buildTree(in: store), session)?.paneGrids
        XCTAssertNil(grids?.left)
        XCTAssertEqual(grids?.right, ControlGrid(columns: 40, rows: 10))
    }

    private func node(_ tree: ControlTree, _ session: Session) -> ControlSessionNode? {
        tree.workspaces.flatMap(\.sessions).first { $0.id == session.id.uuidString }
    }

    func testSessionTextReportsThePanesGrid() throws {
        let server = makeServer()
        let (_, session) = try makeSession()
        let fitted = try view(session).gridSize()

        let text = server.readSessionText(session.id.uuidString, window: nil, options: ControlSessionTextOptions(pane: nil, all: false, lines: nil))
        XCTAssertEqual(text.result?.columns, fitted.columns)
        XCTAssertEqual(text.result?.rows, fitted.rows)

        _ = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left, grid: ControlGrid(columns: 40, rows: 10))
        let forced = server.readSessionText(session.id.uuidString, window: nil, options: ControlSessionTextOptions(pane: nil, all: false, lines: nil))
        XCTAssertEqual(forced.result?.columns, 40)
        XCTAssertEqual(forced.result?.rows, 10)
    }

    func testScrollWheelsThePaneTowardOlderOutput() async throws {
        let server = makeServer()
        let (_, session) = try makeSession(command: "/bin/sh -c 'seq 1 300; exec cat'")
        let surface = try view(session)
        try await waitUntil { surface.readScreenText(all: false, lines: nil)?.contains("300") == true }
        XCTAssertEqual(surface.readScreenText(all: false, lines: nil)?.contains("300"), true)

        let response = server.scrollSession(session.id.uuidString, window: nil, pane: .left, lines: -30)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertEqual(response.result?.id, session.id.uuidString)
        XCTAssertEqual(response.result?.pane, "left")
        XCTAssertEqual(response.result?.lines, -30)
        try await waitUntil { surface.readScreenText(all: false, lines: nil)?.contains("300") == false }
        XCTAssertEqual(surface.readScreenText(all: false, lines: nil)?.contains("300"), false)
    }

    func testScrollReachesAMouseReportingProgramInsideASmallForcedGrid() async throws {
        let server = makeServer()
        let (_, session) = try makeSession(command: "/bin/sh -c \"printf '\\033[?1000h\\033[?1006h'; echo READY; exec cat -v\"")
        let surface = try view(session)
        let screen = { (surface.readScreenText(all: true, lines: nil) ?? "").replacingOccurrences(of: "\n", with: "") }
        _ = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left, grid: ControlGrid(columns: 30, rows: 8))
        try await waitUntil { surface.gridSize() == (30, 8) && screen().contains("READY") }
        XCTAssertTrue(surface.gridSize() == (30, 8) && screen().contains("READY"), screen())

        XCTAssertTrue(server.scrollSession(session.id.uuidString, window: nil, pane: .left, lines: -3).ok)

        try await waitUntil { screen().contains("<64;") }
        XCTAssertTrue(screen().contains("<64;"), screen())
    }

    func testAPaneWithoutAWindowIsRefusedAndKeepsNoGrid() throws {
        let server = makeServer()
        let (_, session) = try makeSession()
        let surface = try view(session)
        surface.window?.contentView = nil

        let response = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left,
                                             grid: ControlGrid(columns: 40, rows: 10))

        XCTAssertEqual(response.error, "pane is not on screen")
        XCTAssertNil(surface.forcedGrid)
        XCTAssertFalse(session.hasForcedGrid)
        XCTAssertEqual(server.scrollSession(session.id.uuidString, window: nil, pane: .left, lines: -3).error,
                       "pane is not on screen")
    }

    func testAResetClearsTheGridOfAPaneWithoutAWindow() throws {
        let server = makeServer()
        let (_, session) = try makeSession()
        let surface = try view(session)
        XCTAssertTrue(server.setSessionGrid(session.id.uuidString, window: nil, pane: .left, grid: ControlGrid(columns: 40, rows: 10)).ok)
        surface.window?.contentView = nil

        let response = server.setSessionGrid(session.id.uuidString, window: nil, pane: .left, grid: nil)

        XCTAssertTrue(response.ok, response.error ?? "")
        XCTAssertNil(surface.forcedGrid)
        XCTAssertFalse(session.hasForcedGrid)
    }

    func testACoveredPaneRefusesGridAndScrollButAResetClearsItsRecord() throws {
        let server = makeServer()
        let store = try XCTUnwrap(library.activeStore)
        let session = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID),
                                                     cwd: NSTemporaryDirectory()))
        let identity = UUID()
        panes.append(identity)
        let surface = realizedView(session: session, command: "/bin/cat", env: ["HANGAR_PANE_ID": identity.uuidString])
        session.surface = surface
        let id = session.id.uuidString
        ZmxLeadBook.shared.begin(ZmxLeadAttachment(nonce: "n", claim: true), pane: identity)
        _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:leader:1")), pane: identity)
        XCTAssertTrue(server.setSessionGrid(id, window: nil, pane: .left, grid: ControlGrid(columns: 40, rows: 10)).ok)
        _ = ZmxLeadBook.shared.apply(try XCTUnwrap(ZmxLeadNotice(title: "zmx-role;n:follower:2")), pane: identity)
        let refusal = "pane is covered while another Mac leads it; take the lead first (session lead)"

        XCTAssertEqual(server.setSessionGrid(id, window: nil, pane: .left, grid: ControlGrid(columns: 30, rows: 8)).error, refusal)
        XCTAssertEqual(surface.forcedGrid?.columns, 40)
        XCTAssertEqual(server.scrollSession(id, window: nil, pane: .left, lines: -3).error, refusal)
        let reset = server.setSessionGrid(id, window: nil, pane: .left, grid: nil)
        XCTAssertTrue(reset.ok, reset.error ?? "")
        XCTAssertNil(surface.forcedGrid)
        XCTAssertFalse(session.hasForcedGrid)
    }
}
