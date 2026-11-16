import Foundation

extension AppStore {
    /// Records a session's terminal font size (points) and persists it, debounced so a held ⌘+/⌘− ramp
    /// coalesces into one write. No-ops when unchanged, so a DPI-change cell-size event doesn't write.
    public func setFontSize(_ sessionID: UUID, _ size: Double) {
        guard let session = session(withID: sessionID), session.fontSize != size else { return }
        session.fontSize = size
        scheduleSave()
    }

    /// Clears every per-session font-size override (no write when none was set). Called on an appearance
    /// change: the shared ghostty `update_config` resets live surfaces to the default, so the pins must match.
    public func resetSessionFontSizes() {
        var changed = false
        for workspace in workspaces {
            for session in workspace.sessions where session.fontSize != nil {
                session.fontSize = nil
                changed = true
            }
        }
        if changed { save() }
    }
}
