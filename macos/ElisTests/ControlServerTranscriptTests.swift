import XCTest
@testable import Elis
import ElisCore

@MainActor
final class ControlServerTranscriptTests: XCTestCase {
    private static let endpoint = ControlZmxEndpoint(executable: "/Applications/Elis.app/zmx", socketDirectory: "/tmp/elis-zmx-abc")
    private let originLeft = UUID()
    private var stateDir: URL!
    private var library: WindowLibrary!
    private var server: ControlServer!
    private var runner: Runner!
    private var transport: Transport!
    private struct Timeout: Error {}

    private final class Runner: RemoteCommandRunner, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        var reply = ""

        var reads: [[String]] { lock.withLock { recorded } }

        func run(_ argv: [String], deadline _: TimeInterval) async -> RemoteCommandResult {
            if argv.contains("-O") { return RemoteCommandResult(status: 0, stdout: "Master running\n", stderr: "") }
            let line = Self.line(argv)
            if line.contains("elisctl version") {
                var result = ControlResult()
                result.versions = CatalogVersions(server: "1", protocolVersion: 1, catalog: 1)
                let data = (try? JSONEncoder().encode(ControlResponse(ok: true, result: result))) ?? Data()
                return RemoteCommandResult(status: 0, stdout: String(decoding: data, as: UTF8.self), stderr: "")
            }
            guard line.contains("session transcript") else { return RemoteCommandResult(status: 0, stdout: "", stderr: "") }
            return lock.withLock {
                recorded.append(argv)
                return RemoteCommandResult(status: 0, stdout: reply, stderr: "")
            }
        }

        static func line(_ argv: [String]) -> String {
            (argv.last ?? "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\\", with: "")
        }
    }

    private final class Transport: RemotePresentationTransport {
        final class Link: RemotePresentationLink {
            func send(_: Data) {}
            func stop() {}
        }

        var catalog: (@MainActor (Data) -> Void)?

        func open(_ argv: [String], onLine: @escaping @MainActor (Data) -> Void,
                  onClose _: @escaping @MainActor (String) -> Void) -> RemotePresentationLink {
            if argv.last?.contains("catalog subscribe") == true { catalog = onLine }
            return Link()
        }
    }

    override func setUp() async throws {
        try await super.setUp()
        stateDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("elis-transcript-tests-\(UUID().uuidString)", isDirectory: true)
        library = WindowLibrary(directory: stateDir)
        runner = Runner()
        transport = Transport()
        server = ControlServer(library: library, actions: AppActions(library: library),
                               settingsModel: SettingsModel(library: library, settingsStore: SettingsStore(directory: stateDir)),
                               identity: AppIdentity(version: "9.9.9", commit: "testsha"), remoteRunner: runner,
                               socketPath: stateDir.appendingPathComponent("control-\(UUID().uuidString).sock").path)
        server.remoteTransport = transport
        server.claudeDirectory = stateDir.appendingPathComponent("claude").path
    }

    override func tearDown() async throws {
        server?.stopRemoteCatalogs()
        server?.stop()
        server = nil
        library?.finalizeAllPendingCloses()
        library = nil
        try? FileManager.default.removeItem(at: stateDir)
        stateDir = nil
        try await super.tearDown()
    }

    func testLocalRowReadsThroughTheDispatcher() async throws {
        let file = stateDir.appendingPathComponent("claude/projects/x/c1.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":false,"timestamp":"T","#
            + #""message":{"role":"user","content":"hello"}}"# + "\n").utf8).write(to: file)
        let row = try localRow()
        let store = try XCTUnwrap(library.activeStore)
        store.setRunningAgent(.claude, pane: .left, forSession: row.id)
        store.setAgentSessionID("c1", forSession: row.id)

        let reply = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: row.id.uuidString))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reply.result?.transcript, "c1")
        XCTAssertEqual(reply.result?.items?.map(\.uuid), ["u1"])
        XCTAssertTrue(runner.reads.isEmpty)
    }

    func testLocalRowWithoutClaudeAnswersNoAdapter() async throws {
        let row = try localRow()

        let reply = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: row.id.uuidString))

        XCTAssertEqual(reply.error, "no adapter")
    }

    func testAttachedRowForwardsToOriginWithItsPaneToken() async throws {
        let printed = #"{"ok":true,"result":{"transcript":"c9","size":7,"start":0,"next":7,"items":[]}}"#
        runner.reply = printed
        let row = try attachedRow()
        var args = ControlArgs(paneID: row.paneIdentity.uuidString)
        args.after = "5"

        let reply = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: row.id.uuidString, args: args))

        XCTAssertEqual(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self),
                       String(decoding: try JSONEncoder().encode(JSONDecoder().decode(ControlResponse.self, from: Data(printed.utf8))),
                              as: UTF8.self))
        let argv = try XCTUnwrap(runner.reads.first)
        let line = Runner.line(argv)
        XCTAssertTrue(line.contains("session transcript --target origin-1 --pane-id=\(originLeft.uuidString) --after=5"), line)
        XCTAssertTrue(argv.contains { $0.hasPrefix("ControlPath=") })
        XCTAssertTrue(argv.contains("buildbox"))
    }

    func testAttachedRowPassesTheOriginsRefusalOn() async throws {
        runner.reply = #"{"ok":false,"error":"transcript not found"}"#
        let row = try attachedRow()

        let reply = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: row.id.uuidString,
                                                         args: ControlArgs(pane: "left")))

        XCTAssertEqual(reply.error, "transcript not found")
        XCTAssertTrue(Runner.line(try XCTUnwrap(runner.reads.first)).contains("--pane left"))
    }

    func testServerRowForwardsWithRowIDAndPooledPath() async throws {
        runner.reply = #"{"ok":true,"result":{"transcript":"c2","size":0,"start":0,"next":0,"items":[]}}"#
        let rowID = try await serverRow()

        let reply = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: rowID.uuidString,
                                                         args: ControlArgs(paneID: "p7")))

        XCTAssertTrue(reply.ok, reply.error ?? "")
        XCTAssertEqual(reply.result?.transcript, "c2")
        let argv = try XCTUnwrap(runner.reads.first)
        XCTAssertTrue(argv.contains { $0.hasPrefix("ControlPath=") })
        XCTAssertTrue(Runner.line(argv).contains("session transcript --target \(rowID.uuidString) --pane-id=p7"), Runner.line(argv))
    }

    func testOriginTooOldIsNamed() async throws {
        runner.reply = #"{"ok":false,"error":"invalid request: Cannot initialize Command from invalid String value session.transcript"}"#
        let row = try attachedRow()

        let reply = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: row.id.uuidString))

        XCTAssertEqual(reply.error, "the Elis on buildbox is too old for session.transcript")
    }

    func testUndecodableOriginReplyIsTooOld() async throws {
        runner.reply = "not json"
        let row = try attachedRow()

        let reply = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: row.id.uuidString))

        XCTAssertEqual(reply.error, "the Elis on buildbox is too old for session.transcript")
    }

    func testTranscriptLeavesWindowCacheAlone() async throws {
        runner.reply = #"{"ok":false,"error":"no adapter"}"#
        let local = try localRow()
        let row = try attachedRow()
        server.refreshWindowCache()
        let cached = server.cachedWindows().count
        _ = library.newRemoteWindow(host: "otherbox")

        _ = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: local.id.uuidString))
        _ = await server.dispatch(ControlRequest(cmd: .sessionTranscript, target: row.id.uuidString))

        XCTAssertEqual(runner.reads.count, 1)
        XCTAssertEqual(server.cachedWindows().count, cached)
        server.refreshWindowCache()
        XCTAssertEqual(server.cachedWindows().count, cached + 1)
    }

    private func localRow() throws -> Session {
        let store = try XCTUnwrap(library.activeStore)
        return try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory()))
    }

    private func attachedRow() throws -> Session {
        let store = try XCTUnwrap(library.activeStore)
        let row = try XCTUnwrap(store.addSession(toWorkspace: try XCTUnwrap(store.currentWorkspaceID), cwd: NSHomeDirectory(),
                                                 remoteHost: "buildbox"))
        store.bindRemote(RemoteBinding(remoteSessionID: "origin-1", daemonsByLocalPane: [row.paneIdentity: ZmxSupport.daemonName(for: originLeft)],
                                       presentationVersion: 1,
                                       origin: RemoteBinding.Origin(host: "buildbox", endpoint: Self.endpoint, sessionName: "c")),
                         forSession: row.id)
        return row
    }

    private func serverRow() async throws -> UUID {
        server.wireRemoteCatalogs()
        _ = library.newRemoteWindow(host: "box")
        try await until { self.transport.catalog != nil }
        let rowID = UUID()
        let pane = CatalogPane(identity: UUID(), daemon: "elis-\(UUID().uuidString)", endpoint: Self.endpoint)
        var line = try CatalogCodec.encode(.snapshot(CatalogSnapshot(
            epoch: "e1", rev: 0, catalogID: UUID(), versions: CatalogVersions(server: "1", protocolVersion: 1, catalog: 1),
            workspaces: [CatalogWorkspace(id: UUID(), name: "main", sessions: [CatalogSession(
                fields: CatalogSessionFields(id: rowID, name: "build", parent: nil, cwd: "/srv", primary: pane.identity,
                                             axis: nil, shown: false, lifecycle: .live),
                panes: [pane])])])))
        if line.last == UInt8(ascii: "\n") { line.removeLast() }
        transport.catalog?(line)
        XCTAssertNotNil(server.catalogPool(forSession: rowID))
        return rowID
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Timeout()
    }
}
