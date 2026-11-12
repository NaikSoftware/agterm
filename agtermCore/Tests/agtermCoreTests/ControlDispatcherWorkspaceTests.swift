import Foundation
import Testing
@testable import agtermCore

// dispatcher tests for the `workspace.*` commands. Split out of `ControlDispatcherTests.swift` (near the
// 2000-line test-file cap); they share its `MockControlActions`, which is internal for exactly that reason.
@MainActor
struct ControlDispatcherWorkspaceTests {
    @Test func workspaceFocusRoutesToTheAction() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: "on", window: "win")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceFocus(target: "work", window: "win", .on)])
    }

    @Test(arguments: ControlWorkspaceFocusMode.allCases)
    func workspaceFocusParsesEveryMode(mode: ControlWorkspaceFocusMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: mode.rawValue)))

        #expect(actions.calls == [.workspaceFocus(target: "work", window: nil, mode)])
    }

    @Test func workspaceFocusDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFocus, target: "work"))

        #expect(actions.calls == [.workspaceFocus(target: "work", window: nil, .toggle)])
    }

    @Test func workspaceFocusRejectsUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: "pin")))

        #expect(response == ControlResponse(ok: false,
                                            error: "invalid focus mode: pin (\(ControlWorkspaceFocusMode.validNamesList))"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceFocusRejectionListsEveryAcceptedMode() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFocus, target: "work", args: ControlArgs(mode: "pin")))

        let error = response?.error ?? ""
        for mode in ControlWorkspaceFocusMode.allCases {
            #expect(error.contains(mode.rawValue))
        }
    }

    @Test func workspaceFilterRoutesModesAndKeepsExactResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextWorkspaceFilterResponse = ControlResponse(ok: true)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceFilter(window: nil, .on)])
    }

    @Test(arguments: [("on", ControlToggleMode.on), ("off", .off), ("toggle", .toggle)])
    func workspaceFilterParsesEveryMode(raw: String, expected: ControlToggleMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: raw)))

        #expect(actions.calls == [.workspaceFilter(window: nil, expected)])
    }

    @Test func workspaceFilterDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter))

        #expect(actions.calls == [.workspaceFilter(window: nil, .toggle)])
    }

    @Test func workspaceFilterCarriesTheWindowSelector() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "off", window: "win")))

        #expect(actions.calls == [.workspaceFilter(window: "win", .off)])
    }

    @Test func workspaceFilterRejectsUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "show")))

        #expect(response == ControlResponse(ok: false, error: "invalid workspace filter mode: show"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceFilterPropagatesTheActionResponse() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        actions.nextWorkspaceFilterResponse = ControlResponse(ok: false, error: "no open window")

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFilter, args: ControlArgs(mode: "on")))

        #expect(response == ControlResponse(ok: false, error: "no open window"))
    }

    @Test(arguments: [("on", ControlToggleMode.on), ("off", .off), ("toggle", .toggle)])
    func workspaceFlagRoutesEveryModeWithTargetAndWindow(raw: String, expected: ControlToggleMode) async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(
            cmd: .workspaceFlag, target: "work", args: ControlArgs(mode: raw, window: "win")))

        #expect(response == ControlResponse(ok: true, result: ControlResult(id: "work")))
        #expect(actions.calls == [.workspaceFlag(target: "work", window: "win", expected)])
    }

    @Test func workspaceFlagDecodesFromItsWireNameAndDispatches() async throws {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)
        let request = try JSONDecoder().decode(ControlRequest.self,
                                               from: Data(#"{"cmd":"workspace.flag","target":"work","args":{"mode":"off"}}"#.utf8))

        _ = await dispatcher.dispatch(request)

        #expect(actions.calls == [.workspaceFlag(target: "work", window: nil, .off)])
    }

    @Test func workspaceFlagDefaultsToToggle() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        _ = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFlag, target: "work"))

        #expect(actions.calls == [.workspaceFlag(target: "work", window: nil, .toggle)])
    }

    @Test func workspaceFlagRejectsUnknownModeWithoutCallingActions() async {
        let actions = MockControlActions()
        let dispatcher = ControlDispatcher(actions: actions)

        let response = await dispatcher.dispatch(ControlRequest(cmd: .workspaceFlag, target: "work",
                                                                args: ControlArgs(mode: "clear")))

        #expect(response == ControlResponse(ok: false, error: "invalid workspace flag mode: clear"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceNewForwardsNormalizedFolder() async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .workspaceNew, args: ControlArgs(name: "api", folder: "/tmp/proj/")))

        #expect(response == ControlResponse(ok: true))
        #expect(actions.calls == [.workspaceNewFolder("/tmp/proj"), .workspaceNew(window: nil, "api", collapsed: false)])
    }

    @Test func workspaceNewRefusesRootFolder() async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .workspaceNew, args: ControlArgs(folder: "/")))

        #expect(response == ControlResponse(ok: false, error: ProjectFolderRejection.rootOrHome.message))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceFolderSetRequiresFolder() async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .workspaceFolder, args: ControlArgs(mode: "set")))

        #expect(response == ControlResponse(ok: false, error: "workspace.folder set requires a folder"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceFolderClearRefusesFolder() async {
        let actions = MockControlActions()

        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(
            cmd: .workspaceFolder, args: ControlArgs(mode: "clear", folder: "/tmp/proj")))

        #expect(response == ControlResponse(ok: false, error: "workspace.folder clear takes no folder"))
        #expect(actions.calls.isEmpty)
    }

    @Test func workspaceFolderRejectsUnknownMode() async {
        let response = await ControlDispatcher(actions: MockControlActions()).dispatch(ControlRequest(
            cmd: .workspaceFolder, args: ControlArgs(mode: "pin")))

        #expect(response == ControlResponse(ok: false, error: "invalid folder mode: pin (set|clear)"))
    }

    @Test func workspaceFolderSetRefusesHomeBeforeTheHost() async {
        let response = await ControlDispatcher(actions: MockControlActions()).dispatch(ControlRequest(
            cmd: .workspaceFolder, args: ControlArgs(mode: "set", folder: NSHomeDirectory())))

        #expect(response == ControlResponse(ok: false, error: ProjectFolderRejection.rootOrHome.message))
    }

    @Test(arguments: [ControlArgs(mode: "set", folder: "/tmp/proj"), ControlArgs(mode: "clear")])
    func workspaceFolderDefaultHostRefuses(args: ControlArgs) async {
        let response = await ControlDispatcher(actions: MockControlActions()).dispatch(ControlRequest(
            cmd: .workspaceFolder, args: args))

        #expect(response == ControlResponse(ok: false, error: ControlActionsUnsupported.message("workspace.folder")))
    }
}
