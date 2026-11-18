import AppKit
import XCTest
@testable import Elis
import ElisCore

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
                .appendingPathComponent("elis-band-tests-\(UUID().uuidString)", isDirectory: true)
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

    func testAWaveOnTheGroupsLastRowRoundsOnlyItsBottomCorners() throws {
        let (store, workspace) = try twoSessionWorkspace()
        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        for session in workspace.sessions { session.agentIndicator = AgentIndicator(status: .active) }
        mount(store)
        let middle = try rowView(forItem: try XCTUnwrap(workspace.sessions.first).id)
        let last = try rowView(forItem: try XCTUnwrap(workspace.sessions.last).id)
        last.layoutSubtreeIfNeeded()
        middle.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(middle.waveLayer).cornerRadius, 0)
        let wave = try XCTUnwrap(last.waveLayer)
        XCTAssertEqual(wave.cornerRadius, SidebarRowView.bandRadius - SidebarRowView.groupPadding)
        let bottom: CACornerMask = last.isFlipped ? [.layerMinXMaxYCorner, .layerMaxXMaxYCorner] : [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        XCTAssertEqual(wave.maskedCorners, bottom)
    }

    func testWaveFillsTheRowRectInsideTheBand() throws {
        let (store, workspace) = try twoSessionWorkspace()
        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        for session in workspace.sessions { session.agentIndicator = AgentIndicator(status: .active) }
        mount(store)
        for session in workspace.sessions {
            let row = try rowView(forItem: session.id)
            row.layoutSubtreeIfNeeded()
            let wave = try XCTUnwrap(row.waveLayer)
            XCTAssertEqual(wave.frame, row.rowRect)
            XCTAssertTrue(row.bandRect(try XCTUnwrap(row.groupEdge)).contains(wave.frame))
        }
    }

    func testSelectionTakesTheGroupTintThenTheSessionTintThenTheTheme() throws {
        let (store, workspace) = try twoSessionWorkspace()
        let first = try XCTUnwrap(workspace.sessions.first), second = try XCTUnwrap(workspace.sessions.last)
        store.setTint(SidebarTint(color: .red), forSession: second.id)
        mount(store)
        let theme = GhosttyApp.shared.terminalSelectionBackgroundColor ?? GhosttyApp.shared.terminalForegroundColor ?? .white
        XCTAssertEqual(try rowView(forItem: first.id).selectionColor, theme)
        XCTAssertEqual(try rowView(forItem: second.id).selectionColor, NSColor.tint(.red))

        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        coordinator.reconcile()
        XCTAssertEqual(try rowView(forItem: first.id).selectionColor, NSColor.tint(.blue))
        XCTAssertEqual(try rowView(forItem: second.id).selectionColor, NSColor.tint(.blue))
    }

    func testHoverClearsOnReuseAndWhenTheRowLeavesItsWindow() throws {
        let (store, workspace) = try twoSessionWorkspace()
        mount(store)
        let row = try rowView(forItem: try XCTUnwrap(workspace.sessions.first).id)
        row.isHovered = true
        row.prepareForReuse()
        XCTAssertFalse(row.isHovered)
        row.isHovered = true
        row.removeFromSuperview()
        XCTAssertFalse(row.isHovered)
    }

    func testGroupRowsCarryTheirEdgeExtrasAndKeepContentInsideTheBand() throws {
        let (store, workspace) = try twoSessionWorkspace()
        let third = try XCTUnwrap(store.addSession(toWorkspace: workspace.id, cwd: "/tmp"))
        store.setTint(SidebarTint(color: .blue), forWorkspace: workspace.id)
        mount(store)
        let ids = [workspace.id] + (try XCTUnwrap(store.workspaces.first)).sessions.map(\.id)
        XCTAssertEqual(ids.last, third.id)
        XCTAssertEqual(edges(), [.first, .middle, .middle, .last])
        for id in ids { try assertGeometry(of: id) }

        outline.collapseItem(try XCTUnwrap(coordinator.workspaceNode(forID: workspace.id)))
        XCTAssertEqual(edges(), [.single])
        try assertGeometry(of: workspace.id)
    }

    func testFoldingACompanionParentReNotesTheGroupsRowHeights() throws {
        let (store, workspace) = try twoSessionWorkspace()
        let parent = try XCTUnwrap(workspace.sessions.last)
        let companion = try store.addCompanion(to: parent.id, options: CompanionOptions(name: "companion")).get()
        mount(store)
        let parentNode = coordinator.node(for: parent.id, kind: .session)
        outline.expandItem(parentNode)
        let base = AppSettings.sidebarRowHeight(fontSize: GhosttyApp.shared.sidebarFontSize)
        let outer = SidebarRowView.groupGap + SidebarRowView.groupPadding
        XCTAssertEqual(try rowHeight(of: parent.id), base)
        XCTAssertEqual(try rowHeight(of: companion.id), base + outer)

        outline.collapseItem(parentNode)
        XCTAssertEqual(try rowHeight(of: parent.id), base + outer, "the parent is the group's last row now")
        try assertGeometry(of: parent.id)
    }

    private func rowHeight(of id: UUID) throws -> CGFloat {
        outline.layoutSubtreeIfNeeded()
        let row = try XCTUnwrap((0..<outline.numberOfRows).first { (outline.item(atRow: $0) as? SidebarNode)?.id == id })
        return outline.rect(ofRow: row).height
    }

    private func assertGeometry(of id: UUID, file: StaticString = #filePath, line: UInt = #line) throws {
        let rowView = try rowView(forItem: id)
        let row = outline.row(for: rowView)
        rowView.layoutSubtreeIfNeeded()
        let edge = try XCTUnwrap(rowView.groupEdge, file: file, line: line)
        let extras = SidebarRowView.edgeExtras(edge)
        let base = outline.frameOfCell(atColumn: 0, row: row).height
        XCTAssertEqual(rowView.bounds.height, base + extras.top + extras.bottom, "\(edge)", file: file, line: line)

        let band = rowView.bandRect(edge), content = rowView.contentRect
        XCTAssertTrue(band.contains(content), "\(edge)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(content.minX - band.minX, SidebarRowView.groupPadding, file: file, line: line)
        XCTAssertGreaterThanOrEqual(band.maxX - content.maxX, SidebarRowView.groupPadding, file: file, line: line)
        let flipped = rowView.isFlipped
        let topGap = flipped ? content.minY - band.minY : band.maxY - content.maxY
        let bottomGap = flipped ? band.maxY - content.maxY : content.minY - band.minY
        if extras.top > 0 { XCTAssertEqual(topGap, SidebarRowView.groupPadding, "\(edge) top", file: file, line: line) }
        if extras.bottom > 0 { XCTAssertEqual(bottomGap, SidebarRowView.groupPadding, "\(edge) bottom", file: file, line: line) }

        let cell = outline.convert(outline.frameOfCell(atColumn: 0, row: row), to: rowView)
        XCTAssertEqual(cell.minY, content.minY, "\(edge) cell top", file: file, line: line)
        XCTAssertEqual(cell.maxY, content.maxY, "\(edge) cell bottom", file: file, line: line)
    }

    func testTheDefaultStatusDotIsDrawnUnscaledAtNinePoints() throws {
        let icon = StatusIconView()
        icon.apply(AgentIndicator(status: .active))
        XCTAssertEqual(icon.imageScaling, .scaleNone, "the 16pt slot must not enlarge the dot")
        let expected = try XCTUnwrap(NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)))
        XCTAssertEqual(icon.image?.size, expected.size)
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

    func testRowIconsResolveFromTheBundle() throws {
        for name in ["workspace-stack", "workspace-stack-focused", "focus-frame", "focus-frame-fill", "session-terminal", "flag-lucide"] {
            let image = try XCTUnwrap(NSImage.bundledIcon(name, size: 15), name)
            XCTAssertTrue(image.isTemplate, name)
        }
        XCTAssertNotNil(NSImage(systemSymbolName: InterfaceElement.workspaceIcons.symbolName!, accessibilityDescription: nil))
        XCTAssertEqual(SessionLauncher.terminal.image(pointSize: 15)?.size, NSSize(width: 15, height: 15))
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
