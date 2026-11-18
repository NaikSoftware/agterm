import Foundation
import ElisCore
@testable import elisctlKit
import Testing

struct SessionAttachCommandsTests {
    private func parse(_ argv: [String]) throws -> any RequestCommand {
        let parsed = try Elisctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else { throw SocketClientError("not a RequestCommand: \(argv)") }
        return command
    }

    private func reply(_ response: ControlResponse) throws -> SocketReply {
        SocketReply(response: response, raw: try JSONEncoder().encode(response))
    }

    @Test func makeRequestCarriesTargetAndPane() throws {
        let expected = ControlRequest(cmd: .sessionAttach, target: "9f3c", args: ControlArgs(pane: "right"))
        #expect(try parse(["session", "attach", "--target", "9f3c", "--pane", "right"]).makeRequest() == expected)
    }

    @Test func rejectsAnUnknownPane() {
        #expect(throws: (any Error).self) { try Elisctl.parseAsRoot(["session", "attach", "--pane", "middle"]) }
    }

    @Test func refusesTheScratchPane() {
        #expect(throws: (any Error).self) { try Elisctl.parseAsRoot(["session", "attach", "--pane", "scratch"]) }
    }

    @Test func aRefusalExitsNonzeroWithTheError() throws {
        let action = Session.Attach.decide(try reply(ControlResponse(ok: false, error: "no live pane")), json: false)
        #expect(action == .fail("error: no live pane"))
    }

    @Test func anAttachExecsItsArgv() throws {
        let attach = ControlAttach(argv: ["zmx", "attach", "d1"], paneID: "p1")
        let action = Session.Attach.decide(try reply(ControlResponse(ok: true, result: ControlResult(attach: attach))), json: false)
        #expect(action == .exec(["zmx", "attach", "d1"]))
    }

    @Test func jsonPrintsTheResponseAndDoesNotExec() throws {
        let attach = ControlAttach(argv: ["zmx"], paneID: "p1")
        let r = try reply(ControlResponse(ok: true, result: ControlResult(attach: attach)))
        #expect(Session.Attach.decide(r, json: true) == .print(r.line))
    }

    @Test func aReplyWithoutAnAttachFails() throws {
        let action = Session.Attach.decide(try reply(ControlResponse(ok: true)), json: false)
        #expect(action == .fail("error: the response carries no attach command"))
    }
}
