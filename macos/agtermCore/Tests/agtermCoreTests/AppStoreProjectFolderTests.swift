import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreProjectFolderTests {
    @Test func ownsExactFolder() {
        let store = makeStore()
        let web = store.addWorkspace(name: "web", projectFolder: "/p/web-app")
        #expect(store.workspaceID(owningFolder: "/p/web-app") == web.id)
    }

    @Test func ownsDescendant() {
        let store = makeStore()
        let web = store.addWorkspace(name: "web", projectFolder: "/p/web-app")
        #expect(store.workspaceID(owningFolder: "/p/web-app/src/lib") == web.id)
        #expect(store.workspaceID(owningFolder: "/p") == nil)
    }

    @Test func siblingWithSharedPrefixDoesNotMatch() {
        let store = makeStore()
        _ = store.addWorkspace(name: "web", projectFolder: "/p/web-app")
        #expect(store.workspaceID(owningFolder: "/p/web-app2") == nil)
    }

    @Test func longestPinWins() {
        let store = makeStore()
        _ = store.addWorkspace(name: "mono", projectFolder: "/p/mono")
        let api = store.addWorkspace(name: "api", projectFolder: "/p/mono/api")
        #expect(store.workspaceID(owningFolder: "/p/mono/api/src") == api.id)
    }

    @Test func tieKeepsSidebarOrder() {
        let store = makeStore()
        let first = store.addWorkspace(name: "first", projectFolder: "/p/web")
        _ = store.addWorkspace(name: "second", projectFolder: "/p/web")
        #expect(store.workspaceID(owningFolder: "/p/web/src") == first.id)
    }

    @Test func normalizesTrailingSlashAndTilde() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        #expect(store.setProjectFolder("~/proj/", ofWorkspace: work.id))
        #expect(store.workspaces.first?.projectFolder == "\(NSHomeDirectory())/proj")
        #expect(store.workspaceID(owningFolder: "~/proj/src/") == work.id)
        let added = store.addWorkspace(name: "added", projectFolder: "/a/./b/")
        #expect(added.projectFolder == "/a/b")
    }

    @Test func setRefusesRootAndHome() {
        #expect(Workspace.validatedProjectFolder("  ", home: "/Users/me") == .failure(.blank))
        #expect(Workspace.validatedProjectFolder("/", home: "/Users/me") == .failure(.rootOrHome))
        #expect(Workspace.validatedProjectFolder("/Users/me/", home: "/Users/me") == .failure(.rootOrHome))
        #expect(Workspace.validatedProjectFolder("/Users/me/proj/", home: "/Users/me") == .success("/Users/me/proj"))
        #expect(ProjectFolderRejection.blank.message == "project folder must not be blank")
        #expect(ProjectFolderRejection.rootOrHome.message == "project folder must not be / or the home folder")
    }

    @Test func setNilClears() {
        let store = makeStore()
        let work = store.addWorkspace(name: "work", projectFolder: "/p/web")
        #expect(store.setProjectFolder(nil, ofWorkspace: work.id))
        #expect(store.workspaces.first?.projectFolder == nil)
        #expect(store.workspaceID(owningFolder: "/p/web") == nil)
        #expect(!store.setProjectFolder("/p/x", ofWorkspace: UUID()))
    }

    @Test func snapshotRoundTripKeepsFolder() throws {
        let store = makeStore()
        _ = store.addWorkspace(name: "web", projectFolder: "/p/web")
        _ = store.addWorkspace(name: "empty")

        let data = try JSONEncoder().encode(store.snapshot())
        #expect(String(decoding: data, as: UTF8.self).components(separatedBy: "projectFolder").count == 2)

        let restored = makeStore()
        restored.restore(from: try JSONDecoder().decode(Snapshot.self, from: data))
        #expect(restored.workspaces.map(\.projectFolder) == ["/p/web", nil])
    }

    @Test func legacySnapshotDecodesNil() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"w","sessions":[]}"#
        let legacy = try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(json.utf8))
        #expect(legacy.projectFolder == nil)
        let lossy = #"{"id":"\#(UUID().uuidString)","name":"w","sessions":[],"projectFolder":7}"#
        #expect(try JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(lossy.utf8)).projectFolder == nil)
    }

    @Test func undoCloseRestoresFolder() throws {
        let (store, recentClosed, _) = makeStoreWithRecentClosed()
        let keep = store.addWorkspace(name: "keep")
        _ = try #require(store.addSession(toWorkspace: keep.id, cwd: "/a"))
        let work = store.addWorkspace(name: "work", projectFolder: "/p/web")
        let stray = try #require(store.addSession(toWorkspace: work.id, cwd: "/b", select: false))
        _ = try #require(store.addSession(toWorkspace: work.id, cwd: "/c", select: false))

        #expect(store.softCloseSession(stray.id, grace: 60))
        let sessionCloseID = try #require(store.pendingCloseSummary?.id)
        #expect(store.softRemoveWorkspace(work.id, grace: 60))
        #expect(store.undoPendingClose(sessionCloseID))
        #expect(store.workspaces.first { $0.id == work.id }?.projectFolder == "/p/web")

        let api = store.addWorkspace(name: "api", projectFolder: "/p/api")
        let lone = try #require(store.addSession(toWorkspace: api.id, cwd: "/d", select: false))
        _ = try #require(store.addSession(toWorkspace: api.id, cwd: "/e", select: false))
        #expect(store.softCloseSession(lone.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        #expect(store.softRemoveWorkspace(api.id, grace: 60))
        store.finalizePendingClose(try #require(store.pendingCloseSummary?.id))
        let item = try #require(recentClosed.load().first { $0.session?.snapshot.id == lone.id })
        #expect(store.restoreRecentClosed(item))
        #expect(store.workspaces.first { $0.id == api.id }?.projectFolder == "/p/api")
    }

    @Test func projectionReportsFolderAndOmitsNil() throws {
        let store = makeStore()
        _ = store.addWorkspace(name: "web", projectFolder: "/p/web")
        _ = store.addWorkspace(name: "empty")

        let nodes = store.controlTree().workspaces
        #expect(nodes.map(\.projectFolder) == ["/p/web", nil])
        #expect(!String(decoding: try JSONEncoder().encode(nodes[1]), as: UTF8.self).contains("projectFolder"))
    }

    @Test func importCreatesLinksAndSkips() {
        let store = makeStore()
        let named = store.addWorkspace(name: "api")
        let pinned = store.addWorkspace(name: "pinned", projectFolder: "/p/web")
        let candidates = [
            ProjectCandidate(name: "api", path: "/p/api", isGitRepository: true, existing: .named(named.id, "api")),
            ProjectCandidate(name: "cli", path: "/p/cli", isGitRepository: false, existing: .none),
            ProjectCandidate(name: "web", path: "/p/web", isGitRepository: true, existing: .pinned(pinned.id)),
        ]

        #expect(store.importProjects(candidates) == 2)
        #expect(store.workspaces.map(\.name) == ["api", "pinned", "cli"])
        #expect(store.workspaces.map(\.projectFolder) == ["/p/api", "/p/web", "/p/cli"])
    }

    @Test func importNeverMovesAPinGainedAfterTheScan() {
        let store = makeStore()
        let api = store.addWorkspace(name: "api")
        let candidate = ProjectCandidate(name: "api", path: "/p/api", isGitRepository: true, existing: .named(api.id, "api"))
        store.setProjectFolder("/elsewhere/api", ofWorkspace: api.id)

        #expect(store.importProjects([candidate]) == 1)
        #expect(store.workspaces.map(\.projectFolder) == ["/elsewhere/api", "/p/api"])
    }

    @Test func importRevealsNewWorkspacesIntoAnAppliedFocusSetWithoutRetargeting() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/a"))
        store.selectSession(session.id)
        store.setFocusedWorkspace(work.id)

        store.importProjects([ProjectCandidate(name: "cli", path: "/p/cli", isGitRepository: true, existing: .none)])

        #expect(store.visibleWorkspaces.map(\.name) == ["work", "cli"])
        #expect(store.selectedSessionID == session.id && store.currentWorkspaceID == work.id)
    }
}
