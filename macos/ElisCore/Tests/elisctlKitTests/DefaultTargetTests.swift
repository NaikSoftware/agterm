import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct DefaultTargetTests {
    private let own = "A9AC9525-0000-4000-8000-000000000000"

    private func request(_ argv: [String], env: [String: String]) throws -> ControlRequest {
        try CallerEnvironment.$values.withValue(env) {
            guard let command = try Elisctl.parseAsRoot(argv) as? any RequestCommand else {
                throw SocketClientError("parsed \(argv) is not a RequestCommand")
            }
            return try command.makeRequest()
        }
    }

    @Test(arguments: [["session", "overlay", "open", "--markdown", "/tmp/a.md"], ["session", "rename", "x"],
                      ["session", "close"], ["session", "detach"], ["session", "move", "--to", "up"], ["notify", "hi"]])
    func anUntargetedSessionCommandInsideAPaneTargetsItsOwnSession(argv: [String]) throws {
        #expect(try request(argv, env: ["ELIS_SESSION_ID": own]).target == own)
    }

    @Test(arguments: [[:], ["ELIS_SESSION_ID": ""]])
    func anUntargetedSessionCommandOutsideAPaneTargetsActive(env: [String: String]) throws {
        #expect(try request(["session", "overlay", "open", "--markdown", "/tmp/a.md"], env: env).target == "active")
        #expect(try request(["session", "close"], env: env).target == "active")
    }

    @Test(arguments: ["active", "B1"])
    func anExplicitTargetWinsInsideAPane(target: String) throws {
        let env = ["ELIS_SESSION_ID": own]
        #expect(try request(["session", "overlay", "open", "--markdown", "/tmp/a.md", "--target", target], env: env).target == target)
        #expect(try request(["session", "close", "--target", target], env: env).target == target)
    }

    @Test func aCompanionMoveInsideAPaneMovesItsOwnSession() throws {
        let move = try Session.Move.parse(["--parent", "p2"])
        #expect(CallerEnvironment.$values.withValue(["ELIS_SESSION_ID": own]) { move.companionMoveRequest().target } == own)
    }

    @Test(arguments: [["workspace", "rename", "x"], ["workspace", "tint", "red"], ["surface", "zoom"]])
    func workspaceAndSurfaceCommandsKeepActiveInsideAPane(argv: [String]) throws {
        #expect(try request(argv, env: ["ELIS_SESSION_ID": own]).target == "active")
    }
}
