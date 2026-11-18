extension ControlDispatcher {
    func dispatchSessionAttach(_ request: ControlRequest) async -> ControlResponse {
        switch parseGridPane(request.args?.pane) {
        case .pane(let parsed):
            return await actions.sessionAttach(target: request.target, pane: parsed ?? .left,
                                               paneID: request.args?.paneID, window: request.args?.window)
        case .rejected(let rejection): return rejection
        }
    }
}
