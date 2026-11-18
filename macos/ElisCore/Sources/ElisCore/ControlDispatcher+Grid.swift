extension ControlDispatcher {
    func dispatchSessionGrid(_ request: ControlRequest) -> ControlResponse {
        let pane: StatusPane
        switch parseGridPane(request.args?.pane) {
        case .pane(let parsed): pane = parsed ?? .left
        case .rejected(let rejection): return rejection
        }
        let args = request.args
        let reset = args?.reset == true
        guard reset != (args?.columns != nil || args?.rows != nil) else {
            return ControlResponse(ok: false, error: "session.grid takes columns and rows, or reset")
        }
        if reset {
            return actions.setSessionGrid(request.target, window: args?.window, pane: pane, grid: nil)
        }
        guard let columns = args?.columns, let rows = args?.rows,
              ControlGrid.columnRange.contains(columns), ControlGrid.rowRange.contains(rows) else {
            return ControlResponse(ok: false, error: "session.grid: columns must be 20...1000 and rows 5...1000")
        }
        return actions.setSessionGrid(request.target, window: args?.window, pane: pane,
                                      grid: ControlGrid(columns: columns, rows: rows))
    }

    func dispatchSessionScroll(_ request: ControlRequest) -> ControlResponse {
        let pane: StatusPane
        switch parseGridPane(request.args?.pane) {
        case .pane(let parsed): pane = parsed ?? .left
        case .rejected(let rejection): return rejection
        }
        guard let lines = request.args?.lines, lines != 0, (-1000...1000).contains(lines) else {
            return ControlResponse(ok: false, error: "session.scroll: lines must be -1000...1000 and not 0")
        }
        return actions.scrollSession(request.target, window: request.args?.window, pane: pane, lines: lines)
    }

    /// The surface selector without scratch: grid and scroll serve a phone's view of a split pane.
    private func parseGridPane(_ raw: String?) -> PaneSelection<StatusPane> {
        if case .pane(.scratch) = parseSurfacePane(raw) {
            return .rejected(ControlResponse(ok: false, error: "invalid pane: \(raw ?? "")"))
        }
        return parseSurfacePane(raw)
    }
}
