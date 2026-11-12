import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ProjectFolderScanTests {
    private let fm = FileManager.default

    private func makeRoot(dirs: [String] = [], files: [String] = []) throws -> String {
        let root = fm.temporaryDirectory.appendingPathComponent("agterm-scan-\(UUID().uuidString)").path
        for dir in dirs { try fm.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true) }
        for file in files { #expect(fm.createFile(atPath: "\(root)/\(file)", contents: Data())) }
        return Workspace.normalizedFolder(root) ?? root
    }

    @Test func skipsHiddenAndFiles() throws {
        let root = try makeRoot(dirs: ["app", ".cache", "real"], files: ["notes.txt"])
        try fm.createSymbolicLink(atPath: "\(root)/linked", withDestinationPath: "\(root)/real")
        let names = ProjectFolderScan.candidates(in: root, workspaces: []).map(\.name)
        #expect(names == ["app", "linked", "real"])
    }

    @Test func detectsGitDirAndGitFile() throws {
        let root = try makeRoot(dirs: ["dir/.git", "plain", "worktree"], files: ["worktree/.git"])
        let candidates = ProjectFolderScan.candidates(in: root, workspaces: [])
        #expect(candidates.map(\.isGitRepository) == [true, false, true])
        #expect(candidates.first?.path == "\(root)/dir")
    }

    @Test func sortsNaturally() throws {
        let root = try makeRoot(dirs: ["app10", "app2", "Beta"])
        #expect(ProjectFolderScan.candidates(in: root, workspaces: []).map(\.name) == ["app2", "app10", "Beta"])
    }

    @Test func marksPinnedAndNamed() throws {
        let root = try makeRoot(dirs: ["api", "cli", "web"])
        let pinned = Workspace(name: "site", projectFolder: "\(root)/web")
        let named = Workspace(name: "api")
        let existing = ProjectFolderScan.candidates(in: root, workspaces: [pinned, named]).map(\.existing)
        #expect(existing == [.named(named.id, "api"), .none, .pinned(pinned.id)])
    }

    @Test func preselectsGitOnlyAndNeverPinned() throws {
        let root = try makeRoot(dirs: ["api/.git", "cli", "web/.git"])
        let pinned = Workspace(name: "web", projectFolder: "\(root)/web")
        let preselected = ProjectFolderScan.candidates(in: root, workspaces: [pinned]).map(\.preselected)
        #expect(preselected == [true, false, false])
    }

    @Test func defaultRootPrefersProjects() throws {
        let home = try makeRoot(dirs: ["code", "Projects"])
        #expect(ProjectFolderScan.defaultRoot(home: home) == "\(home)/Projects")
        let bare = try makeRoot(dirs: ["src"], files: ["Projects"])
        #expect(ProjectFolderScan.defaultRoot(home: bare) == "\(bare)/src")
        let empty = try makeRoot()
        #expect(ProjectFolderScan.defaultRoot(home: empty) == empty)
    }
}
