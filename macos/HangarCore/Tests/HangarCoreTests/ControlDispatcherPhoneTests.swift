import Foundation
import Testing
@testable import HangarCore

@MainActor
struct ControlDispatcherPhoneTests {
    private func dispatch(_ cmd: Command, _ args: ControlArgs? = nil, target: String? = nil) async
        -> (ControlResponse?, MockControlActions) {
        let actions = MockControlActions()
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: cmd, target: target, args: args))
        return (response, actions)
    }

    private func args(mode: String? = nil, port: Int? = nil, host: String? = nil, auto: Bool? = nil) -> ControlArgs {
        var args = ControlArgs()
        args.mode = mode
        args.port = port
        args.host = host
        args.auto = auto
        return args
    }

    @Test func eachCommandRoutesToItsAction() async {
        let cases: [(Command, ControlArgs?, MockControlActions.Call)] = [
            (.phoneStatus, nil, .phoneStatus),
            (.phoneEnable, args(mode: "on"), .phoneEnable(.on)),
            (.phoneEnable, args(mode: "off"), .phoneEnable(.off)),
            (.phoneEnable, nil, .phoneEnable(.toggle)),
            (.phonePort, args(port: 1024), .phonePort(1024)),
            (.phonePort, args(port: 65535), .phonePort(65535)),
            (.phoneHost, args(host: " mac.local "), .phoneHost("mac.local")),
            (.phoneHost, args(auto: true), .phoneHost(nil)),
            (.phoneRevoke, nil, .phoneRevoke),
        ]
        for (cmd, args, call) in cases {
            let (_, actions) = await dispatch(cmd, args)
            #expect(actions.calls == [call])
        }
    }

    @Test func theActionAnswerIsTheReply() async {
        let actions = MockControlActions()
        let status = ControlPhoneStatus(on: true, listening: true, port: 8765, host: "10.0.0.2", link: "hangar://pair?h=x")
        actions.nextPhoneResponse = ControlResponse(ok: true, result: ControlResult(phone: status))
        let response = await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .phoneStatus))
        #expect(response == actions.nextPhoneResponse)
    }

    @Test(arguments: [Command.phoneStatus, .phoneEnable, .phonePort, .phoneHost, .phoneRevoke])
    func aTargetOrWindowIsRefused(cmd: Command) async {
        var window = ControlArgs()
        window.window = "w"
        for (target, args) in [("s", nil), (nil, window)] as [(String?, ControlArgs?)] {
            let (response, actions) = await dispatch(cmd, args, target: target)
            #expect(response == ControlResponse(ok: false, error: "\(cmd.rawValue) takes no target or --window"))
            #expect(actions.calls.isEmpty)
        }
    }

    @Test func badArgumentsAreRefusedBeforeAnyAction() async {
        let cases: [(Command, ControlArgs?, String)] = [
            (.phoneEnable, args(mode: "maybe"), "phone.enable requires on|off|toggle"),
            (.phonePort, nil, "port must be 1024...65535"),
            (.phonePort, args(port: 1023), "port must be 1024...65535"),
            (.phonePort, args(port: 65536), "port must be 1024...65535"),
            (.phoneHost, nil, "phone.host takes a host or auto"),
            (.phoneHost, args(host: "a", auto: true), "phone.host takes a host or auto"),
            (.phoneHost, args(auto: false), "phone.host takes a host or auto"),
            (.phoneHost, args(host: "  "), "phone.host requires a host without spaces or control characters"),
            (.phoneHost, args(host: "my mac"), "phone.host requires a host without spaces or control characters"),
            (.phoneHost, args(host: "mac\u{1b}"), "phone.host requires a host without spaces or control characters"),
        ]
        for (cmd, args, error) in cases {
            let (response, actions) = await dispatch(cmd, args)
            #expect(response == ControlResponse(ok: false, error: error))
            #expect(actions.calls.isEmpty)
        }
    }

    @Test func statusEncodesItsLinkButTheTreeReadbackDropsIt() throws {
        let status = ControlPhoneStatus(on: true, listening: false, port: 9000, host: "h", hosts: ["h", "i"],
                                        lastEvent: "phone connected from 1.2.3.4", error: "boom", link: "hangar://pair?t=T",
                                        bluetooth: "busy")
        let full = try #require(String(data: JSONEncoder().encode(status), encoding: .utf8))
        #expect(full.contains("\"link\""))
        #expect(status.readback == ControlPhoneStatus(on: true, listening: false, port: 9000, host: "h", bluetooth: "busy"))
        var tree = ControlTree(workspaces: [])
        let bare = try #require(String(data: JSONEncoder().encode(tree), encoding: .utf8))
        #expect(!bare.contains("phone"))
        tree.phone = status.readback
        let decoded = try JSONDecoder().decode(ControlTree.self, from: JSONEncoder().encode(tree))
        #expect(decoded.phone == status.readback)
        let encoded = try #require(String(data: JSONEncoder().encode(tree), encoding: .utf8))
        #expect(!encoded.contains("link") && !encoded.contains("hosts") && !encoded.contains("lastEvent"))
        #expect(encoded.contains("\"bluetooth\":\"busy\""))
    }

    @Test func relayLinesBecomePhoneEvents() {
        #expect(PhoneRelayLine.controlEvent("phone connected from 192.168.0.7")! == (.phoneConnected, "192.168.0.7"))
        #expect(PhoneRelayLine.controlEvent("phone disconnected from fe80::1")! == (.phoneDisconnected, "fe80::1"))
        #expect(PhoneRelayLine.controlEvent("refused ::1: wrong token")! == (.phoneRefused, "::1"))
        #expect(PhoneRelayLine.controlEvent("refused 10.0.0.3: wrong token")! == (.phoneRefused, "10.0.0.3"))
        #expect(PhoneRelayLine.controlEvent("cannot listen on *:8765: Address already in use") == nil)
        #expect(PhoneRelayLine.controlEvent("phone connected from ") == nil)
    }
}
