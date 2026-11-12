import ArgumentParser
import Foundation
import Testing
import agtermCore
@testable import agtermctlKit

/// `agtermctl workspace flag` argv parsing; the other `workspace` subcommands are covered in `CommandsTests`.
struct WorkspaceCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Agtermctl.parseAsRoot(argv)
            return nil
        } catch {
            return Agtermctl.message(for: error)
        }
    }

    @Test func workspaceFlagDefaultsToggleOnTheActiveWorkspace() throws {
        #expect(try request(["workspace", "flag"]) == ControlRequest(cmd: .workspaceFlag, target: "active", args: ControlArgs(mode: "toggle")))
    }

    @Test(arguments: ["on", "off", "toggle"])
    func workspaceFlagThreadsModeTargetAndWindow(mode: String) throws {
        let expected = ControlRequest(cmd: .workspaceFlag, target: "9f3c", args: ControlArgs(mode: mode, window: "win"))
        #expect(try request(["workspace", "flag", mode, "--target", "9f3c", "--window", "win"]) == expected)
    }

    @Test func workspaceFlagRejectsBadMode() {
        #expect(validationMessage(["workspace", "flag", "clear"]) == "mode must be on, off, or toggle")
    }

    @Test func workspaceNewSendsFolder() throws {
        #expect(try request(["workspace", "new", "api", "--folder", "/tmp/proj"])
            == ControlRequest(cmd: .workspaceNew, args: ControlArgs(name: "api", folder: "/tmp/proj")))
    }

    @Test func workspaceFolderSetAndClearRequests() throws {
        #expect(try request(["workspace", "folder", "set", "/tmp/proj", "--target", "9f3c", "--window", "win"])
            == ControlRequest(cmd: .workspaceFolder, target: "9f3c", args: ControlArgs(mode: "set", window: "win", folder: "/tmp/proj")))
        #expect(try request(["workspace", "folder", "clear"])
            == ControlRequest(cmd: .workspaceFolder, target: "active", args: ControlArgs(mode: "clear")))
    }

    @Test func workspaceFolderRejectsBadMode() {
        #expect(validationMessage(["workspace", "folder", "pin"]) == "mode must be set or clear")
    }
}
