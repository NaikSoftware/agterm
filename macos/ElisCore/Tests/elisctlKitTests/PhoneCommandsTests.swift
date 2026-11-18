#if os(macOS)
import ElisCore
@testable import elisctlKit
import Testing

struct PhoneCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Elisctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
        return try command.makeRequest()
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Elisctl.parseAsRoot(argv)
            return nil
        } catch {
            return Elisctl.message(for: error)
        }
    }

    private func args(mode: String? = nil, port: Int? = nil, host: String? = nil, auto: Bool? = nil) -> ControlArgs {
        var args = ControlArgs()
        args.mode = mode
        args.port = port
        args.host = host
        args.auto = auto
        return args
    }

    @Test func eachSubcommandSendsItsRequest() throws {
        #expect(try request(["phone", "status"]) == ControlRequest(cmd: .phoneStatus))
        #expect(try request(["phone", "link"]) == ControlRequest(cmd: .phoneStatus))
        #expect(try request(["phone", "on"]) == ControlRequest(cmd: .phoneEnable, args: args(mode: "on")))
        #expect(try request(["phone", "off"]) == ControlRequest(cmd: .phoneEnable, args: args(mode: "off")))
        #expect(try request(["phone", "toggle"]) == ControlRequest(cmd: .phoneEnable, args: args(mode: "toggle")))
        #expect(try request(["phone", "port", "9000"]) == ControlRequest(cmd: .phonePort, args: args(port: 9000)))
        #expect(try request(["phone", "host", "mac.local"]) == ControlRequest(cmd: .phoneHost, args: args(host: "mac.local")))
        #expect(try request(["phone", "host", "--auto"]) == ControlRequest(cmd: .phoneHost, args: args(auto: true)))
        #expect(try request(["phone", "revoke"]) == ControlRequest(cmd: .phoneRevoke))
    }

    @Test func badArgumentsAreRefusedLocally() {
        #expect(validationMessage(["phone", "port", "1023"]) == "port must be 1024...65535")
        #expect(validationMessage(["phone", "port", "70000"]) == "port must be 1024...65535")
        #expect(validationMessage(["phone", "host"]) == "provide a host or --auto")
        #expect(validationMessage(["phone", "host", "a", "--auto"]) == "provide a host or --auto")
    }

    @Test func statusPrintsOneFactPerLineAndOmitsWhatIsAbsent() {
        let full = ControlPhoneStatus(on: true, listening: true, port: 8765, host: "10.0.0.2", hosts: ["10.0.0.2", "10.0.0.9"],
                                      lastEvent: "phone connected from 10.0.0.5", link: "elis://pair?h=10.0.0.2", bluetooth: "advertising")
        #expect(SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(phone: full))) == """
            on: yes, listening on port 8765
            host: 10.0.0.2
            hosts: 10.0.0.2, 10.0.0.9
            bluetooth: advertising
            last: phone connected from 10.0.0.5
            link: elis://pair?h=10.0.0.2
            """)
        let off = ControlPhoneStatus(on: true, listening: false, port: 8765, host: "", error: "Address already in use")
        #expect(SocketClient.formatResponse(ControlResponse(ok: true, result: ControlResult(phone: off))) == """
            on: yes, not listening
            error: Address already in use
            """)
    }

    @Test func linkPrintsTheLinkAloneOrUnderItsCode() throws {
        let status = ControlPhoneStatus(on: true, listening: true, port: 8765, host: "h", link: "elis://pair?h=h&p=1")
        #expect(try Phone.Link.render(status, qr: false) == "elis://pair?h=h&p=1")
        let lines = try Phone.Link.render(status, qr: true).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.last == "elis://pair?h=h&p=1")
        #expect(lines.first?.hasPrefix("\u{1b}[") == true)
        #expect(throws: (any Error).self) {
            try Phone.Link.render(ControlPhoneStatus(on: false, listening: false, port: 8765, host: ""), qr: false)
        }
    }
}
#endif
