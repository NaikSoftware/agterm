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

    @Test func claimFlagSendsClaim() throws {
        var args = ControlArgs(pane: "right")
        args.claim = true
        let expected = ControlRequest(cmd: .sessionAttach, target: "9f3c", args: args)
        #expect(try parse(["session", "attach", "--target", "9f3c", "--pane", "right", "--claim"]).makeRequest() == expected)
        #expect(try parse(["session", "attach", "--target", "9f3c"]).makeRequest().args?.claim == nil)

        let attach = ControlAttach(argv: ["zmx", "attach", "d1"], paneID: "p1", nonce: "n")
        let action = Session.Attach.decide(try reply(ControlResponse(ok: true, result: ControlResult(attach: attach))), json: false, callerPaneID: "p1")
        #expect(action == .fail("error: cannot attach a pane to itself"))
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Elisctl.parseAsRoot(argv)
            return nil
        } catch {
            return Elisctl.message(for: error)
        }
    }

    @Test func rejectsAnUnknownPane() {
        #expect(validationMessage(["session", "attach", "--pane", "middle"]) == "--pane must be left, right, or scratch")
    }

    @Test func refusesTheScratchPane() {
        #expect(validationMessage(["session", "attach", "--pane", "scratch"]) == "invalid pane: scratch")
    }

    @Test func jsonRefusalPrintsToStdoutThenFails() throws {
        let r = try reply(ControlResponse(ok: false, error: "no live pane"))
        #expect(Session.Attach.decide(r, json: true, callerPaneID: nil) == .printThenFail(r.line))
    }

    @Test func aRefusalExitsNonzeroWithTheError() throws {
        let action = Session.Attach.decide(try reply(ControlResponse(ok: false, error: "no live pane")), json: false, callerPaneID: nil)
        #expect(action == .fail("error: no live pane"))
    }

    @Test func anAttachExecsItsArgv() throws {
        let attach = ControlAttach(argv: ["zmx", "attach", "d1"], paneID: "p1")
        let action = Session.Attach.decide(try reply(ControlResponse(ok: true, result: ControlResult(attach: attach))), json: false, callerPaneID: "p2")
        #expect(action == .exec(["zmx", "attach", "d1"]))
    }

    @Test func jsonPrintsTheResponseAndDoesNotExec() throws {
        let attach = ControlAttach(argv: ["zmx"], paneID: "p1")
        let r = try reply(ControlResponse(ok: true, result: ControlResult(attach: attach)))
        #expect(Session.Attach.decide(r, json: true, callerPaneID: nil) == .print(r.line))
    }

    @Test func refusesToAttachThePaneItRunsIn() throws {
        let attach = ControlAttach(argv: ["zmx", "attach", "d1"], paneID: "p1")
        let action = Session.Attach.decide(try reply(ControlResponse(ok: true, result: ControlResult(attach: attach))), json: false, callerPaneID: "p1")
        #expect(action == .fail("error: cannot attach a pane to itself"))
    }

    @Test func aReplyWithoutAnAttachFails() throws {
        let action = Session.Attach.decide(try reply(ControlResponse(ok: true)), json: false, callerPaneID: nil)
        #expect(action == .fail("error: the response carries no attach command"))
    }
}
