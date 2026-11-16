import Foundation
import Testing
@testable import agtermCore

@MainActor
struct AppStoreForegroundJobTests {
    private func splitSession(in store: AppStore, workspace: UUID) -> (Session, SpySurface, SpySurface) {
        let session = store.addSession(toWorkspace: workspace, cwd: "/a")!
        let primary = SpySurface(), split = SpySurface()
        session.surface = primary
        session.splitSurface = split
        session.hasSplit = true
        session.splitPaneIdentity = UUID()
        return (session, primary, split)
    }

    @Test func closingASessionEndsEachPanesForegroundJobBeforeTheTeardown() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let (session, primary, split) = splitSession(in: store, workspace: ws.id)
        let scratch = SpySurface()
        session.scratchSurface = scratch

        store.closeSession(session.id)

        #expect(primary.calls == ["endForegroundJob", "teardown"])
        #expect(split.calls == ["endForegroundJob", "teardown"])
        #expect(scratch.calls == ["endForegroundJob", "teardown"])
    }

    @Test func closingASplitEndsItsForegroundJobBeforeTheTeardown() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        let (session, primary, split) = splitSession(in: store, workspace: ws.id)

        store.closeSplit(session.id)

        #expect(split.calls == ["endForegroundJob", "teardown"])
        #expect(primary.calls == [])
    }

    @Test func aSoftClosedSessionEndsItsJobsOnlyWhenTheCloseIsFinal() {
        let store = makeStore()
        let ws = store.addWorkspace(name: "work")
        _ = store.addSession(toWorkspace: ws.id, cwd: "/b")
        let (session, primary, _) = splitSession(in: store, workspace: ws.id)

        #expect(store.softCloseSession(session.id, grace: 60))
        #expect(primary.calls == [])
        #expect(store.finalizePendingClose(ofSession: session.id))

        #expect(primary.calls == ["endForegroundJob", "teardown"])
    }

    @Test func removingAWorkspaceEndsItsSessionsForegroundJobs() {
        let store = makeStore()
        _ = store.addWorkspace(name: "keep")
        let ws = store.addWorkspace(name: "gone")
        let (_, primary, split) = splitSession(in: store, workspace: ws.id)

        store.removeWorkspace(ws.id)

        #expect(primary.calls == ["endForegroundJob", "teardown"])
        #expect(split.calls == ["endForegroundJob", "teardown"])
    }
}
