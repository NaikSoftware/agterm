import Foundation
import Testing
@testable import agtermCore

@MainActor
struct ControlDispatcherFilePanelTests {
    @Test(arguments: [("show", .on), ("hide", .off), ("toggle", .toggle), (nil, .toggle)] as [(String?, ControlToggleMode)])
    func filePanelRoutesTheParsedMode(_ raw: String?, _ mode: ControlToggleMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .filePanel, args: ControlArgs(mode: raw)))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.filePanelVisibility(mode)])
    }

    @Test func filePanelRejectsBadMode() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .filePanel, args: ControlArgs(mode: "bogus")))

        #expect(response == ControlResponse(ok: false, error: "invalid filepanel mode: bogus"))
        #expect(actions.calls.isEmpty)
    }

    @Test func filePanelWidthRoutesPointsAndWindow() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextFilePanelWidthResponse = ControlResponse(ok: true, result: ControlResult(filePanelWidth: 300))

        let response = await dispatcher.dispatch(
            ControlRequest(cmd: .filePanelWidth, args: ControlArgs(window: "win", filePanelWidth: 300)))

        #expect(response == ControlResponse(ok: true, result: ControlResult(filePanelWidth: 300)))
        #expect(actions.calls == [.filePanelWidth(points: 300, window: "win")])
    }

    @Test(arguments: [nil, Double.nan, Double.infinity])
    func filePanelWidthRejectsNonFinite(_ points: Double?) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(
            ControlRequest(cmd: .filePanelWidth, args: ControlArgs(filePanelWidth: points)))

        #expect(response == ControlResponse(ok: false, error: "filepanel.width requires a width in points"))
        #expect(actions.calls.isEmpty)
    }
}
