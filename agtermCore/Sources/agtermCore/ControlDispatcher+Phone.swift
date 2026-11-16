import Foundation

extension ControlDispatcher {
    /// `phone.*` drive the app's one phone relay, so a target or `--window` is refused like `hooks.*`.
    func dispatchPhoneCommand(_ request: ControlRequest) async -> ControlResponse {
        if request.target != nil || request.args?.window != nil {
            return ControlResponse(ok: false, error: "\(request.cmd.rawValue) takes no target or --window")
        }
        let args = request.args
        switch request.cmd {
        case .phoneStatus:
            return actions.phoneStatus()
        case .phoneEnable:
            guard let mode = ControlToggleMode.parse(args?.mode) else {
                return ControlResponse(ok: false, error: "phone.enable requires on|off|toggle")
            }
            return await actions.setPhoneEnabled(mode)
        case .phonePort:
            guard let port = args?.port, PhoneDesktopState.portRange.contains(port) else {
                return ControlResponse(ok: false, error: PhoneDesktopState.portError)
            }
            return await actions.setPhonePort(port)
        case .phoneHost:
            let auto = args?.auto == true
            guard auto != (args?.host != nil), args?.auto != false else {
                return ControlResponse(ok: false, error: "phone.host takes a host or auto")
            }
            if auto { return actions.setPhoneHost(nil) }
            let host = args?.host?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !host.isEmpty, host.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0) }) else {
                return ControlResponse(ok: false, error: "phone.host requires a host without spaces or control characters")
            }
            return actions.setPhoneHost(host)
        case .phoneRevoke:
            return await actions.revokePhone()
        default:
            preconditionFailure("unexpected phone command: \(request.cmd.rawValue)")
        }
    }
}
