import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class SidebarBandTests: XCTestCase {
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var actions: AppActions!
    private var window: NSWindow!
    private var outline: SidebarOutlineView!
    private var coordinator: WorkspaceSidebar.Coordinator!

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agterm-band-tests-\(UUID().uuidString)", isDirectory: true)
            library = WindowLibrary(directory: stateDir)
            actions = AppActions(library: library)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            window?.orderOut(nil)
            window = nil
            outline = nil
            coordinator = nil
            GhosttyApp.shared.setFlaggedViewLayout(.flat)
            actions = nil
            library = nil
            try? FileManager.default.removeItem(at: stateDir)
            stateDir = nil
        }
        try await super.tearDown()
    }

    func testTintedWorkspaceBandsEveryRowOfItsGroup() throws {
        let (store, workspace) = try twoSessionWorkspace()
        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        mount(store)
        XCTAssertEqual(edges(), [.first, .middle, .last])
    }

    func testTintChangeAfterMountRepaintsTheWholeGroup() throws {
        let (store, workspace) = try twoSessionWorkspace()
        mount(store)
        XCTAssertEqual(edges(), [nil, nil, nil])
        store.setTint(SidebarTint(color: .green), forWorkspace: workspace.id)
        coordinator.reconcile()
        XCTAssertEqual(edges(), [.first, .middle, .last])
        store.setTint(nil, forWorkspace: workspace.id)
        coordinator.reconcile()
        XCTAssertEqual(edges(), [nil, nil, nil])
    }

    func testCollapsedWorkspaceIsASingleBand() throws {
        let (store, workspace) = try twoSessionWorkspace()
        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        mount(store)
        outline.collapseItem(try XCTUnwrap(coordinator.workspaceNode(forID: workspace.id)))
        XCTAssertEqual(edges(), [.single])
        outline.expandItem(try XCTUnwrap(coordinator.workspaceNode(forID: workspace.id)))
        XCTAssertEqual(edges(), [.first, .middle, .last])
    }

    func testFoldingACompanionParentMovesTheGroupEnd() throws {
        let (store, workspace) = try twoSessionWorkspace()
        let parent = try XCTUnwrap(workspace.sessions.last)
        _ = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "companion")).get()
        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        mount(store)
        let parentNode = coordinator.node(for: parent.id, kind: .session)
        outline.expandItem(parentNode)
        XCTAssertEqual(edges(), [.first, .middle, .middle, .last])
        outline.collapseItem(parentNode)
        XCTAssertEqual(edges(), [.first, .middle, .last])
    }

    func testTintedSessionGetsAWash() throws {
        let (store, workspace) = try twoSessionWorkspace()
        let session = try XCTUnwrap(workspace.sessions.last)
        store.setTint(SidebarTint(color: .red), forSession: session.id)
        mount(store)
        XCTAssertNotNil(try rowView(forItem: session.id).rowWash)
        XCTAssertNil(try rowView(forItem: workspace.id).rowWash)
    }

    func testActiveRowHasAWaveUntilItGoesIdle() throws {
        let (store, workspace) = try twoSessionWorkspace()
        let session = try XCTUnwrap(workspace.sessions.first)
        mount(store)
        session.agentIndicator = AgentIndicator(status: .active)
        coordinator.reconcile()
        let row = try rowView(forItem: session.id)
        let wave = try XCTUnwrap(row.waveLayer)
        XCTAssertTrue(row.layer?.sublayers?.first === wave)
        XCTAssertTrue(wave.masksToBounds)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            XCTAssertNotNil(wave.sublayers?.first?.animation(forKey: SidebarRowView.waveKey))
        }

        session.agentIndicator = AgentIndicator(status: .idle)
        coordinator.reconcile()
        XCTAssertNil(try rowView(forItem: session.id).waveLayer)
        XCTAssertNil(wave.superlayer)
    }

    func testWaveRoundsOnlyAtTheBandsOuterCorners() throws {
        let (store, workspace) = try twoSessionWorkspace()
        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        for session in workspace.sessions { session.agentIndicator = AgentIndicator(status: .active) }
        mount(store)
        let middle = try XCTUnwrap(rowView(forItem: try XCTUnwrap(workspace.sessions.first).id).waveLayer)
        let last = try XCTUnwrap(rowView(forItem: try XCTUnwrap(workspace.sessions.last).id).waveLayer)
        XCTAssertEqual(middle.cornerRadius, 0)
        XCTAssertEqual(last.cornerRadius, SidebarRowView.bandRadius)
        XCTAssertEqual(last.maskedCorners.rawValue.nonzeroBitCount, 2)
    }

    func testActiveGlyphFadesAndBlinkReplacesTheFade() throws {
        try XCTSkipIf(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, "Reduce Motion stops the fade")
        let icon = StatusIconView()
        icon.apply(AgentIndicator(status: .active))
        XCTAssertNotNil(icon.layer?.animation(forKey: "agent-status-fade"))
        icon.apply(AgentIndicator(status: .active, blink: true))
        XCTAssertNil(icon.layer?.animation(forKey: "agent-status-fade"))
        icon.apply(AgentIndicator(status: .blocked))
        XCTAssertNil(icon.layer?.animation(forKey: "agent-status-fade"))
    }

    func testFlatFlaggedListDrawsNoBand() throws {
        let (store, workspace) = try twoSessionWorkspace()
        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        for session in workspace.sessions { store.setFlag(true, forSession: session.id) }
        GhosttyApp.shared.setFlaggedViewLayout(.flat)
        store.setSidebarMode(.flagged)
        mount(store)
        XCTAssertEqual(edges(), [nil, nil])
    }

    func testWorkspaceSymbolExists() {
        XCTAssertNotNil(NSImage(systemSymbolName: "square.on.square", accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: InterfaceElement.workspaceIcons.symbolName!, accessibilityDescription: nil))
    }

    private func twoSessionWorkspace() throws -> (AppStore, Workspace) {
        let store = try XCTUnwrap(library.activeStore)
        let workspace = try XCTUnwrap(store.workspaces.first)
        XCTAssertEqual(store.workspaces.count, 1)
        XCTAssertEqual(workspace.sessions.count, 1)
        _ = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        return (store, try XCTUnwrap(store.workspaces.first))
    }

    private func edges() -> [SidebarBandEdge?] {
        outline.layoutSubtreeIfNeeded()
        return (0..<outline.numberOfRows).map { (outline.rowView(atRow: $0, makeIfNecessary: true) as? SidebarRowView)?.band?.edge }
    }

    private func rowView(forItem id: UUID) throws -> SidebarRowView {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == id })
        return try XCTUnwrap(outline.rowView(atRow: row, makeIfNecessary: true) as? SidebarRowView)
    }

    private func mount(_ store: AppStore) {
        outline = SidebarOutlineView()
        coordinator = WorkspaceSidebar.Coordinator(store: store, actions: actions)
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.headerView = nil
        outline.rowSizeStyle = .custom
        outline.rowHeight = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        scroll.documentView = outline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false // see SidebarStatusBlinkTests for why
        window.contentView = scroll

        coordinator.outlineView = outline
        coordinator.renameController.outlineView = outline
        coordinator.seedExpansionFromModel()
        coordinator.reconcile()
    }
}
