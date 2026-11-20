import ArgumentParser
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct DefaultTargetTests {
    private let own = "A9AC9525-0000-4000-8000-000000000000"
    private var pane: [String: String] {
        ["ELIS_SESSION_ID": own, "ELIS_STATE_DIR": "/tmp/elis-pane", "ELIS_SOCKET": "/tmp/elis-pane/elis.sock"]
    }

    /// Parses and builds as `Elisctl.main` runs a command: under the caller environment scoped to that command.
    private func target(_ argv: [String], env: [String: String]) throws -> String? {
        let command = try Elisctl.parseAsRoot(argv)
        return try CallerEnvironment.$values.withValue(CallerEnvironment.scoped(env, for: command)) {
            guard let request = command as? any RequestCommand else { throw SocketClientError("\(argv) is not a RequestCommand") }
            return try request.makeRequest().target
        }
    }

    @Test(arguments: [["session", "overlay", "open", "--markdown", "/tmp/a.md"], ["session", "rename", "x"],
                      ["session", "close"], ["session", "detach"], ["session", "move", "--to", "up"], ["notify", "hi"]])
    func anUntargetedSessionCommandInsideAPaneTargetsItsOwnSession(argv: [String]) throws {
        #expect(try target(argv, env: pane) == own)
    }

    @Test(arguments: [[:], ["ELIS_SESSION_ID": ""]])
    func anUntargetedSessionCommandOutsideAPaneTargetsActive(env: [String: String]) throws {
        #expect(try target(["session", "overlay", "open", "--markdown", "/tmp/a.md"], env: env) == "active")
        #expect(try target(["session", "close"], env: env) == "active")
    }

    @Test(arguments: ["active", "B1"])
    func anExplicitTargetWinsInsideAPane(explicit: String) throws {
        #expect(try target(["session", "overlay", "open", "--markdown", "/tmp/a.md", "--target", explicit], env: pane) == explicit)
        #expect(try target(["session", "close", "--target", explicit], env: pane) == explicit)
    }

    @Test func aCompanionMoveInsideAPaneMovesItsOwnSession() throws {
        let move = try Session.Move.parse(["--parent", "p2"])
        #expect(CallerEnvironment.$values.withValue(CallerEnvironment.scoped(pane, for: move)) { move.companionMoveRequest().target } == own)
    }

    @Test(arguments: [["workspace", "rename", "x"], ["workspace", "tint", "red"], ["surface", "zoom"]])
    func workspaceAndSurfaceCommandsKeepActiveInsideAPane(argv: [String]) throws {
        #expect(try target(argv, env: pane) == "active")
    }

    @Test func aTerminalAskInsideAPaneOpensInItsOwnSession() throws {
        #expect(try target(["ask", "Q?", "--button", "ok"], env: pane) == own)
        #expect(try target(["ask", "Q?", "--button", "ok"], env: [:]) == nil)
        #expect(try target(["ask", "Q?", "--button", "ok", "--style", "gui"], env: pane) == nil)
        #expect(try target(["ask", "Q?", "--button", "ok", "--target", "active"], env: pane) == "active")
    }

    @Test func aSocketOfAnotherInstanceTargetsItsActiveSession() throws {
        #expect(try target(["session", "rename", "x", "--socket", "/tmp/elis-other/elis.sock"], env: pane) == "active")
        #expect(try target(["session", "close", "--socket", "/tmp/elis-other/elis.sock"], env: pane) == "active")
        #expect(try target(["session", "rename", "x", "--socket", "/tmp/elis-pane/elis.sock"], env: pane) == own)
    }

    @Test func theOwnSocketReachedThroughASymlinkStillTargetsTheOwnSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let env = ["ELIS_SESSION_ID": own, "ELIS_SOCKET": real.appendingPathComponent("elis.sock").path]
        #expect(try target(["session", "rename", "x", "--socket", link.appendingPathComponent("elis.sock").path], env: env) == own)
    }

    @Test(arguments: [nil, "/tmp/elis-pane/elis.sock.unavailable"])
    func aPaneWithoutItsOwnSocketTargetsActive(socket: String?) throws {
        var env = pane
        env["ELIS_SOCKET"] = socket
        #expect(try target(["session", "rename", "x"], env: env) == "active")
    }

    @Test func aNamedWindowKeepsItsSelectedSession() throws {
        #expect(try target(["session", "rename", "x", "--window", "W"], env: pane) == "active")
        #expect(try target(["ask", "Q?", "--button", "ok", "--window", "W"], env: pane) == nil)
    }
}
