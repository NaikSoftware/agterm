import Foundation
import Testing
@testable import ElisServerKit
import ElisCore

@MainActor
struct ServerAttachTests {
    private let harness: ServerHarness

    init() throws { harness = try ServerHarness() }

    private func newSession() throws -> Session {
        try harness.session(harness.actions.createSession(ControlSessionCreateOptions(
            window: nil, cwd: nil, workspace: nil, workspaceName: nil, createWorkspace: nil, command: nil, wait: nil,
            name: nil, after: nil, before: nil, noSelect: false)))
    }

    @Test func servedAttachNamesTheServersZmxAndDaemon() async throws {
        let session = try newSession()
        _ = harness.actions.splitSession(session.id.uuidString, window: nil, mode: "on")
        let split = try #require(session.splitPaneIdentity)
        let configuration = harness.panes.configuration

        let byPane = try #require(await harness.actions.sessionAttach(target: session.id.uuidString, pane: .right,
                                                                     paneID: nil, window: nil).result?.attach)
        let byToken = try #require(await harness.actions.sessionAttach(target: session.id.uuidString, pane: .left,
                                                                      paneID: split.uuidString, window: nil).result?.attach)

        for attach in [byPane, byToken] {
            #expect(attach.paneID == split.uuidString)
            #expect(attach.argv.contains(configuration.zmxPath))
            #expect(attach.argv.contains("ZMX_DIR=" + configuration.zmxSocketDirectory))
            #expect(attach.argv.contains(ZmxSupport.daemonName(for: split)))
            #expect(attach.argv.contains("ZMX_MANAGED_FOLLOW=1"))
            #expect(attach.argv.contains("ZMX_MANAGED_SCREEN_ONLY=1"))
            #expect(attach.screen == ["/usr/bin/env", "ZMX_SESSION=", "ZMX_SESSION_PREFIX=",
                                      "ZMX_DIR=" + configuration.zmxSocketDirectory, configuration.zmxPath, "screen",
                                      ZmxSupport.daemonName(for: split)])
            #expect(!attach.remote)
            #expect(attach.origin == ControlAttachOrigin(session: session.id.uuidString, pane: split.uuidString, host: nil))
        }
        let primary = await harness.actions.sessionAttach(target: session.id.uuidString, pane: .left, paneID: nil, window: nil)
        #expect(primary.result?.attach?.paneID == session.paneIdentity.uuidString)
    }

    @Test func serverAnswersAClaimingAttach() async throws {
        let session = try newSession()

        let reply = await harness.actions.sessionAttach(target: session.id.uuidString, pane: .left, paneID: nil, claim: true, window: nil)
        let attach = try #require(reply.result?.attach, "\(reply)")

        let nonce = try #require(attach.nonce)
        #expect(attach.paneID == session.paneIdentity.uuidString)
        #expect(attach.argv.contains(ZmxSupport.daemonName(for: session.paneIdentity)))
        #expect(attach.argv.contains("ZMX_MANAGED=\(nonce)"))
        #expect(attach.argv.contains("ZMX_MANAGED_CLAIM=1"))
        #expect(!attach.argv.contains("ZMX_MANAGED_FOLLOW=1"))
        #expect(!attach.screen.isEmpty)
        #expect(attach.origin == ControlAttachOrigin(session: session.id.uuidString, pane: session.paneIdentity.uuidString, host: nil))
    }

    @Test func refusesAMissingPane() async throws {
        let session = try newSession()

        let noSplit = await harness.actions.sessionAttach(target: session.id.uuidString, pane: .right, paneID: nil, window: nil)
        let unknown = await harness.actions.sessionAttach(target: session.id.uuidString, pane: .left, paneID: "nope", window: nil)

        #expect(noSplit == ControlResponse(ok: false, error: "session has no split pane"))
        #expect(unknown == ControlResponse(ok: false, error: "unknown pane id: nope"))
    }
}

// shortcut: Swift's Glibc module hides posix_openpt/grantpt/unlockpt/ptsname, so this pty test is macOS-only;
// zmx's own tests cover patch 0007 on Linux. Add a Linux pty helper if the server end-to-end check must run there.
#if canImport(Darwin)
/// Runs the served argv against a real daemon, with the fixture `ServerLifecycleTests` uses.
@MainActor
@Suite(.serialized, .enabled(if: RealZmx.runs))
final class ServerAttachLiveTests {
    // the lifecycle suite owns the throwaway dirs and kills its daemons on deinit
    private let live: ServerLifecycleTests

    init() throws { live = try ServerLifecycleTests() }

    @Test func viewerFirstBurstHasNoScrollback() async throws {
        let server = try live.start()
        let session = try live.newSession(server)
        // printf keeps the markers out of the echoed command line
        await live.type(server, session, "printf '%s-marker\\n' scrollback; seq 1 200; printf '%s-marker\\n' visible\n")
        #expect(await eventually { self.live.screen(server, session).contains("visible-marker") })

        let reply = await server.actions.sessionAttach(target: session.id.uuidString, pane: .left, paneID: nil, window: nil)
        let argv = try #require(reply.result?.attach?.argv, "\(reply)")
        let output = await offPool { PtyCapture.untilIdle(argv) }

        #expect(!output.contains("scrollback-marker"))
        #expect(output.contains("visible-marker"), "viewer output: \(output.suffix(400))")
        // the managed client reports its role as a `zmx-role;<nonce>:<role>:<generation>` title
        #expect(output.contains(ZmxLeadNotice.prefix))
        #expect(!output.contains(":\(ZmxLeadRole.leader.rawValue):"))
    }

    private func eventually(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}

enum PtyCapture {
    /// untilIdle runs `argv` on a fresh pty and returns its output once `idle` passes with none, bounded by `limit`.
    static func untilIdle(_ argv: [String], idle: TimeInterval = 1.5, limit: TimeInterval = 20) -> String {
        let controller = posix_openpt(O_RDWR | O_NOCTTY)
        guard controller >= 0, grantpt(controller) == 0, unlockpt(controller) == 0, let name = ptsname(controller) else { return "" }
        defer { close(controller) }
        let tty = open(name, O_RDWR | O_NOCTTY)
        guard tty >= 0 else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin"]
        let handle = FileHandle(fileDescriptor: tty, closeOnDealloc: true)
        process.standardInput = handle
        process.standardOutput = handle
        process.standardError = handle
        guard (try? process.run()) != nil else { return "" }
        var output = Data()
        let deadline = Date().addingTimeInterval(limit)
        var last = Date()
        while Date() < deadline, output.isEmpty || Date().timeIntervalSince(last) < idle {
            if drain(controller, into: &output) { last = Date() }
        }
        process.terminate()
        // zmx exits through tcsetattr(TCSAFLUSH), which waits for the pty to drain
        let exitDeadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < exitDeadline { _ = drain(controller, into: &output) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return String(decoding: output, as: UTF8.self)
    }

    /// drain reads what `fd` holds within 100 ms; true when it read any.
    private static func drain(_ fd: Int32, into output: inout Data) -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, 100) > 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else { return false }
        output.append(contentsOf: buffer[0..<count])
        return true
    }
}
#endif
