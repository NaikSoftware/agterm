import AppKit
import XCTest
@testable import agterm
import agtermCore

@MainActor
final class FileTreeViewTests: XCTestCase {
    private var stateDir: URL!
    private var rootDir: URL!
    private var library: WindowLibrary!
    private var window: NSWindow!
    private var coordinator: FileTreeOutline.Coordinator!
    private var pasteboard: NSPasteboard!
    private var shownErrors: [[String]] = []

    override func setUp() async throws {
        try await super.setUp()
        let base = FileManager.default.temporaryDirectory
        stateDir = base.appendingPathComponent("agterm-file-tree-state-\(UUID().uuidString)", isDirectory: true)
        rootDir = base.appendingPathComponent("agterm-file-tree-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: rootDir.appendingPathComponent("zeta/inner"), withIntermediateDirectories: true)
        try fm.createDirectory(at: rootDir.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        try Data().write(to: rootDir.appendingPathComponent("a-file.txt"))
        try Data().write(to: rootDir.appendingPathComponent("zeta/leaf.md"))
        library = WindowLibrary(directory: stateDir)
        let store = try XCTUnwrap(library.activeStore)
        coordinator = FileTreeOutline.Coordinator(store: store)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("agterm-test-\(UUID().uuidString)"))
        coordinator.pasteboard = pasteboard
        coordinator.presentErrors = { [unowned self] in shownErrors.append($0) }
        let scroll = FileTreeOutline.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.setRoot(.folder(rootDir))
    }

    override func tearDown() async throws {
        coordinator?.stop()
        pasteboard?.releaseGlobally()
        window?.orderOut(nil)
        window = nil
        coordinator = nil
        library = nil
        try? FileManager.default.removeItem(at: rootDir)
        try? FileManager.default.removeItem(at: stateDir)
        try await super.tearDown()
    }

    private var outline: FileTreeOutlineView { coordinator.outlineView! }

    private func names() -> [String] {
        (0 ..< outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FileTreeNode)?.url.lastPathComponent }
    }

    private func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    func testRootListsFoldersFirst() {
        XCTAssertEqual(names(), ["alpha", "zeta", "a-file.txt"])
        XCTAssertTrue(coordinator.emptyLabel.isHidden)
    }

    func testExpandingAFolderLoadsItsChildren() throws {
        let zeta = try XCTUnwrap(outline.item(atRow: 1) as? FileTreeNode)
        XCTAssertNil(zeta.children)
        outline.expandItem(zeta)
        XCTAssertEqual(names(), ["alpha", "zeta", "inner", "leaf.md", "a-file.txt"])
    }

    func testFileCreatedOnDiskAppearsAndKeepsExpansion() throws {
        let zeta = try XCTUnwrap(outline.item(atRow: 1) as? FileTreeNode)
        outline.expandItem(zeta)
        try Data().write(to: rootDir.appendingPathComponent("new.txt"))
        XCTAssertTrue(waitFor { names().contains("new.txt") }, "watcher should add the file: \(names())")
        XCTAssertTrue(outline.isItemExpanded(zeta))
    }

    func testFileCreatedInAnExpandedFolderAppearsAndKeepsExpansion() throws {
        let zeta = try XCTUnwrap(outline.item(atRow: 1) as? FileTreeNode)
        outline.expandItem(zeta)
        try Data().write(to: rootDir.appendingPathComponent("zeta/added.txt"))
        XCTAssertTrue(waitFor { names().contains("added.txt") }, "watcher should add the file: \(names())")
        XCTAssertTrue(outline.isItemExpanded(zeta))
    }

    func testDeletingTheRootShowsFolderNotFound() throws {
        try FileManager.default.removeItem(at: rootDir)
        XCTAssertTrue(waitFor { !coordinator.emptyLabel.isHidden })
        XCTAssertEqual(coordinator.emptyLabel.stringValue, "Folder not found")
        XCTAssertEqual(outline.numberOfRows, 0)
    }

    func testSelectionFollowsTheNodeWhenAFileSortsAboveIt() throws {
        let row = try XCTUnwrap(names().firstIndex(of: "a-file.txt"))
        let selected = try XCTUnwrap(outline.item(atRow: row) as? FileTreeNode)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try Data().write(to: rootDir.appendingPathComponent("0-first.txt"))
        XCTAssertTrue(waitFor { names().contains("0-first.txt") }, "watcher should add the file: \(names())")
        XCTAssertEqual(outline.selectedRowIndexes.count, 1)
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? FileTreeNode === selected)
    }

    func testSelectionInsideAFolderFollowsTheNode() throws {
        let zeta = try XCTUnwrap(outline.item(atRow: 1) as? FileTreeNode)
        outline.expandItem(zeta)
        let row = try XCTUnwrap(names().firstIndex(of: "leaf.md"))
        let selected = try XCTUnwrap(outline.item(atRow: row) as? FileTreeNode)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try Data().write(to: rootDir.appendingPathComponent("zeta/aaa.txt"))
        XCTAssertTrue(waitFor { names().contains("aaa.txt") }, "watcher should add the file: \(names())")
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? FileTreeNode === selected)
    }

    func testRecreatedRootClearsFolderNotFound() throws {
        try FileManager.default.removeItem(at: rootDir)
        XCTAssertTrue(waitFor { !coordinator.emptyLabel.isHidden })
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        XCTAssertTrue(waitFor { coordinator.emptyLabel.isHidden }, "label: \(coordinator.emptyLabel.stringValue)")
    }

    func testNoLocalFolderShowsTheMessage() {
        coordinator.setRoot(.noLocalFolder)
        XCTAssertFalse(coordinator.emptyLabel.isHidden)
        XCTAssertEqual(coordinator.emptyLabel.stringValue, "No local folder")
        XCTAssertEqual(outline.numberOfRows, 0)
    }

    private func node(_ name: String) throws -> FileTreeNode {
        let row = try XCTUnwrap(names().firstIndex(of: name), "no row \(name): \(names())")
        return try XCTUnwrap(outline.item(atRow: row) as? FileTreeNode)
    }

    private func selectRow(_ name: String) throws {
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: try node(name))), byExtendingSelection: false)
    }

    private func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: rootDir.appendingPathComponent(path).path)
    }

    private func selectedNames() -> [String] { coordinator.selectedNodes().map(\.url.lastPathComponent) }

    func testCopyPasteIntoItsOwnFolderCreatesACopy() throws {
        try selectRow("a-file.txt")
        coordinator.copySelection()
        coordinator.paste()
        XCTAssertTrue(exists("a-file.txt"))
        XCTAssertTrue(exists("a-file copy.txt"))
        XCTAssertEqual(selectedNames(), ["a-file copy.txt"])
        XCTAssertEqual(shownErrors, [])
    }

    func testCopyPasteIntoAFolderKeepsTheName() throws {
        try selectRow("a-file.txt")
        coordinator.copySelection()
        try selectRow("alpha")
        coordinator.paste()
        XCTAssertTrue(exists("a-file.txt"))
        XCTAssertTrue(exists("alpha/a-file.txt"))
        XCTAssertEqual(selectedNames(), ["a-file.txt"])
        XCTAssertTrue(outline.isItemExpanded(try node("alpha")))
    }

    func testCutPasteMovesAndClearsTheCutDimming() throws {
        try selectRow("a-file.txt")
        coordinator.cutSelection()
        XCTAssertFalse(coordinator.cutPaths.isEmpty)
        try selectRow("alpha")
        coordinator.paste()
        XCTAssertFalse(exists("a-file.txt"))
        XCTAssertTrue(exists("alpha/a-file.txt"))
        XCTAssertTrue(coordinator.cutPaths.isEmpty)
        XCTAssertFalse(coordinator.canPaste)
        XCTAssertEqual(selectedNames(), ["a-file.txt"])
        XCTAssertEqual(outline.level(forRow: outline.selectedRow), 1)
    }

    func testCutThenAnExternalPasteboardWriteCopiesInstead() throws {
        try selectRow("a-file.txt")
        coordinator.cutSelection()
        pasteboard.clearContents()
        pasteboard.writeObjects([rootDir.appendingPathComponent("a-file.txt") as NSURL])
        try selectRow("alpha")
        coordinator.paste()
        XCTAssertTrue(exists("a-file.txt"))
        XCTAssertTrue(exists("alpha/a-file.txt"))
    }

    func testMoveOntoAnExistingNameIsRefused() throws {
        try Data("keep".utf8).write(to: rootDir.appendingPathComponent("alpha/a-file.txt"))
        try selectRow("a-file.txt")
        coordinator.cutSelection()
        try selectRow("alpha")
        coordinator.paste()
        XCTAssertTrue(exists("a-file.txt"))
        XCTAssertEqual(try String(contentsOf: rootDir.appendingPathComponent("alpha/a-file.txt"), encoding: .utf8), "keep")
        XCTAssertEqual(shownErrors.count, 1)
    }

    func testRenameToAnExistingNameKeepsTheOldName() throws {
        try Data().write(to: rootDir.appendingPathComponent("b-file.txt"))
        coordinator.reload(try XCTUnwrap(coordinator.rootNode))
        XCTAssertFalse(coordinator.rename(try node("a-file.txt"), to: "b-file.txt"))
        XCTAssertTrue(exists("a-file.txt"))
        XCTAssertTrue(names().contains("a-file.txt"))
        XCTAssertEqual(shownErrors.count, 1)
    }

    func testRenameMovesTheFileAndSelectsIt() throws {
        XCTAssertTrue(coordinator.rename(try node("a-file.txt"), to: "renamed.txt"))
        XCTAssertFalse(exists("a-file.txt"))
        XCTAssertEqual(selectedNames(), ["renamed.txt"])
    }

    func testCaseOnlyRenameSucceeds() throws {
        XCTAssertTrue(coordinator.rename(try node("a-file.txt"), to: "A-File.txt"), "errors: \(shownErrors)")
        let listed = try FileManager.default.contentsOfDirectory(atPath: rootDir.path)
        XCTAssertTrue(listed.contains("A-File.txt"), "\(listed)")
        XCTAssertFalse(listed.contains("a-file.txt"))
        XCTAssertEqual(shownErrors, [])
    }

    func testBeginRenameSelectsTheNameWithoutItsExtension() throws {
        let file = try node("a-file.txt")
        coordinator.beginRename(file)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: file), makeIfNecessary: false) as? NSTableCellView)
        let editor = try XCTUnwrap(cell.textField?.currentEditor())
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 6))
    }

    func testTrashRemovesTheRowAndKeepsTheItemInTheTrash() throws {
        // Leaves an `agterm-test-` file in the user's Trash.
        let name = "agterm-test-trash-\(UUID().uuidString).txt"
        try Data().write(to: rootDir.appendingPathComponent(name))
        coordinator.reload(try XCTUnwrap(coordinator.rootNode))
        try selectRow(name)
        let trashed = coordinator.trashSelection()
        XCTAssertFalse(names().contains(name))
        XCTAssertEqual(trashed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed[0].path))
        XCTAssertEqual(shownErrors, [])
    }

    func testRootChangeMidRenameCancelsIt() throws {
        let other = rootDir.appendingPathComponent("alpha")
        try Data().write(to: other.appendingPathComponent("b.txt"))
        coordinator.beginRename(try node("a-file.txt"))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.string = "typed.txt"
        coordinator.setRoot(.folder(other))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertTrue(exists("a-file.txt"))
        XCTAssertFalse(exists("typed.txt"))
        XCTAssertFalse(exists("alpha/typed.txt"))
        XCTAssertNil(coordinator.renamingNode)
        coordinator.beginRename(try node("b.txt"))
        XCTAssertNotNil(coordinator.renamingNode)
    }

    func testNewCompanionHereUsesThePanelsStoreNotTheFrontWindow() throws {
        let panelStore = coordinator.store
        let parent = try XCTUnwrap(panelStore.selectedSessionID)
        let front = try XCTUnwrap(library.store(for: library.newWindow().id))
        XCTAssertFalse(front === panelStore)
        let actions = AppActions(library: library)
        coordinator.actions = actions
        let item = NSMenuItem()
        item.representedObject = rootDir
        coordinator.newCompanionHere(item)
        let companion = try XCTUnwrap(panelStore.workspaces.flatMap(\.sessions).first { $0.parentID == parent })
        XCTAssertEqual(companion.initialCwd, rootDir.path)
        XCTAssertFalse(front.workspaces.flatMap(\.sessions).contains { $0.parentID != nil })
    }
}
