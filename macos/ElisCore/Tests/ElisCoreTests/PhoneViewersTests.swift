import Foundation
import Testing
@testable import ElisCore

struct PhoneViewersTests {
    @Test func attachCountsPerPane() {
        var viewers = PhoneViewers()
        viewers.attach(paneID: "a")
        viewers.attach(paneID: "a")
        viewers.attach(paneID: "b")

        #expect(viewers.count(paneID: "a") == 2)
        #expect(viewers.count(paneID: "b") == 1)
        #expect(viewers.count(paneID: "c") == 0)
    }

    @Test func unmatchedDetachIsIgnored() {
        var viewers = PhoneViewers()
        viewers.attach(paneID: "a")

        let results = [viewers.detach(paneID: "b"), viewers.detach(paneID: "a"), viewers.detach(paneID: "a")]
        #expect(results == [false, true, false])
        #expect(viewers.count(paneID: "a") == 0)
        #expect(viewers == PhoneViewers())
    }

    @Test func relayExitDetachesEveryViewer() {
        var viewers = PhoneViewers()
        viewers.attach(paneID: "a")
        viewers.attach(paneID: "a")
        viewers.attach(paneID: "b")

        let detached = viewers.reset()
        #expect(detached.sorted() == ["a", "a", "b"])
        #expect(viewers.count(paneID: "a") == 0)
        #expect(viewers.count(paneID: "b") == 0)
        let again = viewers.reset()
        #expect(again.isEmpty)
    }

    @MainActor @Test func phoneViewersOmittedAtZero() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/w"))
        session.surface = SpySurface(paneToken: session.paneIdentity.uuidString)
        let token = session.paneIdentity.uuidString

        let surfaces = { try #require(store.controlTree(paneForeground: { _ in nil }).workspaces
            .flatMap(\.sessions).first { $0.id == session.id.uuidString }?.surfaces) }
        #expect(try surfaces().first { $0.paneID == token }?.phoneViewers == nil)

        store.phoneViewerCount = { $0 == token ? 2 : 0 }
        #expect(try surfaces().first { $0.paneID == token }?.phoneViewers == 2)
    }

    @MainActor @Test func phoneLeadOmittedUnlessThePhoneLeads() throws {
        let store = makeStore()
        let work = store.addWorkspace(name: "work")
        let session = try #require(store.addSession(toWorkspace: work.id, cwd: "/w"))
        session.surface = SpySurface(paneToken: session.paneIdentity.uuidString)
        let token = session.paneIdentity.uuidString

        let surfaces = { try #require(store.controlTree(paneForeground: { _ in nil }).workspaces
            .flatMap(\.sessions).first { $0.id == session.id.uuidString }?.surfaces) }
        #expect(try surfaces().first { $0.paneID == token }?.phoneLead == nil)

        store.phoneLeads = { $0 == token }
        #expect(try surfaces().first { $0.paneID == token }?.phoneLead == true)
    }
}
