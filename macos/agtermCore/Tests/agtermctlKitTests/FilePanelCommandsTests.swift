import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlKit

struct FilePanelCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Agtermctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    @Test func filePanelHide() throws {
        #expect(try request(["filepanel", "hide"]) == ControlRequest(cmd: .filePanel, args: ControlArgs(mode: "hide")))
    }

    @Test func filePanelDefaultsToggle() throws {
        #expect(try request(["filepanel"]) == ControlRequest(cmd: .filePanel, args: ControlArgs(mode: "toggle")))
    }

    @Test func filePanelWidth() throws {
        #expect(try request(["filepanel", "width", "300"]) == ControlRequest(cmd: .filePanelWidth, args: ControlArgs(filePanelWidth: 300)))
    }

    @Test func filePanelWidthWithWindow() throws {
        #expect(try request(["filepanel", "width", "300", "--window", "abc"]) ==
            ControlRequest(cmd: .filePanelWidth, args: ControlArgs(window: "abc", filePanelWidth: 300)))
    }

    @Test func filePanelWidthRejectsNonFinitePoints() {
        #expect(throws: (any Error).self) { try Agtermctl.parseAsRoot(["filepanel", "width", "nan"]) }
    }
}
