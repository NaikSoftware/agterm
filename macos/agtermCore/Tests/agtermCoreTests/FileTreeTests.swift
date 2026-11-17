import Foundation
import Testing
@testable import agtermCore

struct FileTreeTests {
    private func makeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ name: String, in dir: URL) throws {
        try Data().write(to: dir.appendingPathComponent(name))
    }

    @Test func childrenSortFoldersFirstNatural() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch("a10", in: dir)
        try touch("a2", in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("z"), withIntermediateDirectories: false)
        let entries = try FileTree.children(of: dir)
        #expect(entries.map(\.url.lastPathComponent) == ["z", "a2", "a10"])
        #expect(entries.map(\.isDirectory) == [true, false, false])
    }

    @Test func childrenHideDSStoreAndGit() throws {
        let dir = try makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        try touch(".DS_Store", in: dir)
        try touch(".env", in: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: false)
        #expect(try FileTree.children(of: dir).map(\.url.lastPathComponent) == [".env"])
    }

    @Test func childrenOfMissingDirectoryThrows() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(throws: (any Error).self) { try FileTree.children(of: missing) }
    }

    @Test func copyDestinationAddsCopySuffix() {
        let dir = URL(fileURLWithPath: "/t")
        let src = dir.appendingPathComponent("a.txt")
        #expect(FileTree.copyDestination(for: src, in: dir) { _ in false }.lastPathComponent == "a.txt")
        #expect(FileTree.copyDestination(for: src, in: dir) { $0 == "a.txt" }.lastPathComponent == "a copy.txt")
        let taken: Set = ["a.txt", "a copy.txt"]
        #expect(FileTree.copyDestination(for: src, in: dir) { taken.contains($0) }.lastPathComponent == "a copy 2.txt")
    }

    @Test func copyDestinationFolder() {
        let dir = URL(fileURLWithPath: "/t")
        let src = dir.appendingPathComponent("src", isDirectory: true)
        #expect(FileTree.copyDestination(for: src, in: dir) { $0 == "src" }.lastPathComponent == "src copy")
    }

    @Test func copyDestinationDotfileIsExtensionless() {
        let dir = URL(fileURLWithPath: "/t")
        let src = dir.appendingPathComponent(".env")
        #expect(FileTree.copyDestination(for: src, in: dir) { $0 == ".env" }.lastPathComponent == ".env copy")
    }

    @Test func cannotMoveIntoSelfOrDescendant() {
        let a = URL(fileURLWithPath: "/t/a")
        let other = URL(fileURLWithPath: "/x")
        #expect(!FileTree.canMove(a, into: a))
        #expect(!FileTree.canMove(a, into: URL(fileURLWithPath: "/t/a/b")))
        #expect(FileTree.canMove(a, into: URL(fileURLWithPath: "/t/ab")))
        #expect(FileTree.canMove(a, into: other))
    }

    @Test func cannotMoveIntoCurrentParent() {
        #expect(!FileTree.canMove(URL(fileURLWithPath: "/t/a/f.txt"), into: URL(fileURLWithPath: "/t/a")))
    }

    @Test func renameRejectsBadNames() {
        for bad in ["", "  ", "a/b", "a:b", ".", ".."] {
            #expect(FileTree.renameError(bad, sibling: { _ in false }) != nil, "\(bad)")
        }
        #expect(FileTree.renameError("taken", sibling: { $0 == "taken" }) != nil)
        #expect(FileTree.renameError("ok.txt", sibling: { _ in false }) == nil)
    }

    @Test func pasteTargetResolves() {
        let root = URL(fileURLWithPath: "/r")
        let dir = FileTreeEntry(url: URL(fileURLWithPath: "/r/d"), isDirectory: true)
        let file = FileTreeEntry(url: URL(fileURLWithPath: "/r/d/f.txt"), isDirectory: false)
        #expect(FileTree.pasteTarget(selection: dir, root: root) == dir.url)
        #expect(FileTree.pasteTarget(selection: file, root: root) == dir.url)
        #expect(FileTree.pasteTarget(selection: nil, root: root) == root)
    }
}
