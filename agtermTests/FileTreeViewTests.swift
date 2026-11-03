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
        let scroll = FileTreeOutline.makeScrollView(coordinator: coordinator)
        scroll.frame = NSRect(x: 0, y: 0, width: 240, height: 400)
        window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        coordinator.setRoot(.folder(rootDir))
    }

    override func tearDown() async throws {
        coordinator?.stop()
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

    func testNoLocalFolderShowsTheMessage() {
        coordinator.setRoot(.noLocalFolder)
        XCTAssertFalse(coordinator.emptyLabel.isHidden)
        XCTAssertEqual(coordinator.emptyLabel.stringValue, "No local folder")
        XCTAssertEqual(outline.numberOfRows, 0)
    }
}
