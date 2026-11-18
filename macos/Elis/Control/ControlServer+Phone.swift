import ElisCore

/// `phone.*` over the app's one `PhoneRelay`, the Connect a Phone window's own model. A change answers once the
/// relay listens again or failed, so the reply's `listening` and `error` describe the result, not the request.
extension ControlServer {
    static let phoneStartLimit: Duration = .seconds(10)

    /// A session's `session.grid` sizes for the tree, nil when neither pane is forced.
    static func paneGrids(_ session: Session) -> ControlPaneGrids? {
        let grid = { (surface: (any TerminalSurface)?) in
            (surface as? GhosttySurfaceView)?.forcedGrid.map { ControlGrid(columns: $0.columns, rows: $0.rows) }
        }
        let left = grid(session.surface), right = grid(session.splitSurface)
        return left == nil && right == nil ? nil : ControlPaneGrids(left: left, right: right)
    }

    func phoneStatus() -> ControlResponse {
        withPhoneRelay { ControlResponse(ok: true, result: ControlResult(phone: $0.status)) }
    }

    func setPhoneEnabled(_ mode: ControlToggleMode) async -> ControlResponse {
        guard let relay = phoneRelay else { return Self.noPhoneRelay }
        relay.setOn(mode == .toggle ? !relay.state.on : mode == .on)
        return await phoneAnswer(relay)
    }

    func setPhonePort(_ port: Int) async -> ControlResponse {
        guard let relay = phoneRelay else { return Self.noPhoneRelay }
        relay.setPort(port)
        return await phoneAnswer(relay)
    }

    func setPhoneHost(_ host: String?) -> ControlResponse {
        withPhoneRelay { relay in
            relay.setHost(host ?? "")
            return Self.phoneReply(relay.status)
        }
    }

    func revokePhone() async -> ControlResponse {
        guard let relay = phoneRelay else { return Self.noPhoneRelay }
        if let failure = await relay.revoke() { return ControlResponse(ok: false, error: failure) }
        return await phoneAnswer(relay)
    }

    private func phoneAnswer(_ relay: PhoneRelay) async -> ControlResponse {
        await relay.untilListening(within: Self.phoneStartLimit)
        var status = relay.status
        if status.on, !status.listening, status.error == nil {
            status.error = "the relay did not start within \(Self.phoneStartLimit.components.seconds) s"
        }
        return Self.phoneReply(status)
    }

    /// Every answer but `phone.status` leaves the link out: it carries the pairing token.
    private static func phoneReply(_ status: ControlPhoneStatus) -> ControlResponse {
        var status = status
        status.link = nil
        return ControlResponse(ok: true, result: ControlResult(phone: status))
    }

    private func withPhoneRelay(_ body: (PhoneRelay) -> ControlResponse) -> ControlResponse {
        phoneRelay.map(body) ?? Self.noPhoneRelay
    }

    private static let noPhoneRelay = ControlResponse(ok: false, error: "the phone relay is not available")
}
