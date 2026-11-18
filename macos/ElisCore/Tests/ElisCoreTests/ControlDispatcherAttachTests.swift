import Foundation
import Testing
@testable import ElisCore

@MainActor
struct ControlDispatcherAttachTests {
    private func dispatch(_ args: ControlArgs?, target: String? = "s") async -> (ControlResponse?, MockControlActions) {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions)
            .dispatch(ControlRequest(cmd: .sessionAttach, target: target, args: args))
        return (response, actions)
    }

    @Test func passesTargetPaneAndWindow() async {
        let (_, split) = await dispatch(ControlArgs(window: "w", pane: "split", paneID: "p1"))
        let (_, primary) = await dispatch(nil)
        #expect(split.calls == [.sessionAttach(target: "s", pane: .right, paneID: "p1", window: "w")])
        #expect(primary.calls == [.sessionAttach(target: "s", pane: .left, paneID: nil, window: nil)])
    }

    @Test(arguments: ["scratch", "middle"])
    func rejectsAnUnknownPaneValue(pane: String) async {
        let (response, actions) = await dispatch(ControlArgs(pane: pane))
        #expect(response == ControlResponse(ok: false, error: "invalid pane: \(pane)"))
        #expect(actions.calls.isEmpty)
    }

    @Test func attachRoundTripsThroughTheProtocol() throws {
        let response = ControlResponse(ok: true, result: ControlResult(attach: ControlAttach(argv: ["zmx", "attach", "d"], paneID: "p1")))
        let decoded = try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response))
        #expect(decoded == response)
        #expect(Command.sessionAttach.rawValue == "session.attach")
    }

    @Test func aPageSessionRefusesAttach() {
        let refusal = PageSessionRefusal.refusal(ControlRequest(cmd: .sessionAttach, target: "s")) { _, _ in true }
        #expect(refusal == ControlResponse(ok: false, error: "session.attach: not available on a page session"))
    }
}
