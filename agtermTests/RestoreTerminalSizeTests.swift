import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class RestoreTerminalSizeTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var outline: NSOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!
    private var savedUserKeyEquivalents = true

    override func setUp() async throws {
        try await super.setUp()
        savedUserKeyEquivalents = NSMenuItem.usesUserKeyEquivalents
        NSMenuItem.usesUserKeyEquivalents = false
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agterm-restore-size-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        actions = AppActions(library: library)
    }

    override func tearDown() async throws {
        NSMenuItem.usesUserKeyEquivalents = savedUserKeyEquivalents
        outline = nil
        coordinator = nil
        actions = nil
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private func makeSplitSession() throws -> (session: Session, left: GhosttySurfaceView, right: GhosttySurfaceView) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.currentWorkspaceID)
        let session = try XCTUnwrap(store.addSession(toWorkspace: workspace, cwd: NSTemporaryDirectory()))
        let left = realizedView(session: session)
        session.surface = left
        store.toggleSplit(session.id)
        let right = realizedView(session: session)
        right.isSplitPane = true
        session.splitSurface = right
        return (session, left, right)
    }

    private func realizedView(session: Session) -> GhosttySurfaceView {
        let view = GhosttySurfaceView(workingDirectory: NSTemporaryDirectory(), fontSize: 12, command: "/bin/cat")
        view.session = session
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 480, height: 320), styleMask: [],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        addTeardownBlock { window.orderOut(nil) }
        XCTAssertTrue(view.isRealized)
        return view
    }

    private func rowMenuItem(_ store: AppStore, _ session: Session) throws -> NSMenuItem {
        outline = NSOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        coordinator.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.rebuildAndReload()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == session.id })
        let menu = try XCTUnwrap(coordinator.menu(forRow: row))
        return try XCTUnwrap(menu.items.first { $0.title == "Restore Terminal Size" }, "\(menu.items.map(\.title))")
    }

    func testAForcedPaneMarksItsSessionUntilItsViewResizes() throws {
        let (session, left, right) = try makeSplitSession()
        XCTAssertFalse(session.hasForcedGrid)

        right.setForcedGrid((columns: 40, rows: 10))
        XCTAssertTrue(session.hasForcedGrid)

        left.setFrameSize(NSSize(width: 300, height: 200))
        XCTAssertTrue(session.hasForcedGrid)
        right.setFrameSize(NSSize(width: 300, height: 200))
        XCTAssertFalse(session.hasForcedGrid)
    }

    func testTheRowItemIsDisabledUntilAPaneIsForcedAndRestoresEveryPane() throws {
        let (session, left, right) = try makeSplitSession()
        let store = try XCTUnwrap(library.activeStore)
        XCTAssertFalse(try rowMenuItem(store, session).isEnabled)

        left.setForcedGrid((columns: 40, rows: 10))
        right.setForcedGrid((columns: 30, rows: 8))
        let item = try rowMenuItem(store, session)
        XCTAssertTrue(item.isEnabled)
        coordinator.perform(item.action, with: item)

        XCTAssertNil(left.forcedGrid)
        XCTAssertNil(right.forcedGrid)
        XCTAssertFalse(session.hasForcedGrid)
        XCTAssertNotEqual(left.gridSize().columns, 40)
    }

    func testTheSessionMenuActionFollowsTheActiveSession() throws {
        let (session, left, _) = try makeSplitSession()
        let store = try XCTUnwrap(library.activeStore)
        _ = store.selectSession(session.id)
        XCTAssertFalse(actions.canRestoreActiveTerminalSize)

        left.setForcedGrid((columns: 40, rows: 10))
        XCTAssertTrue(actions.canRestoreActiveTerminalSize)
        actions.restoreActiveTerminalSize()

        XCTAssertNil(left.forcedGrid)
        XCTAssertFalse(actions.canRestoreActiveTerminalSize)
    }

    func testTearingDownAForcedPaneClearsTheSessionFlag() throws {
        let (session, _, right) = try makeSplitSession()
        right.setForcedGrid((columns: 40, rows: 10))

        right.teardown()

        XCTAssertFalse(session.hasForcedGrid)
    }
}
