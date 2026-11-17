import Foundation

/// Pure builders for the hangar identity and `HANGAR_*` values injected into spawned shells.
/// The platform surface owns shell creation; this keeps the variable set testable.
public enum SurfaceEnvironment {
    /// Environment for a session-owned surface: main pane, split pane, overlay, or scratch. `pane`, when
    /// non-nil, adds `HANGAR_PANE` so the hook wrapper can forward `--pane` and a status set from a
    /// background pane records which surface blocked; overlay surfaces pass nil (nil→main). `paneToken`,
    /// when non-empty, adds `HANGAR_PANE_ID` — the surface's STABLE spawn identity
    /// (`TerminalSurface.paneToken`), which the hook forwards as `--pane-id` so the status handler resolves
    /// the LIVE role instead of the stale baked `HANGAR_PANE` after a promote + re-split (#199).
    /// `socketPath` is always emitted, never omitted: consumers treat an absent `HANGAR_SOCKET` as
    /// "resolve the default", which is another instance's. `ControlServer` supplies an unbindable path
    /// when it does not own one.
    public static func session(sessionID: UUID, windowID: UUID?, workspaceID: UUID?,
                               socketPath: String, programVersion: String,
                               pane: StatusPane? = nil, paneToken: String? = nil) -> [String: String] {
        var env = terminalIdentity(programVersion: programVersion).merging([
            "HANGAR_ENABLED": "1",
            "HANGAR_SESSION_ID": sessionID.uuidString,
            "HANGAR_SOCKET": socketPath,
        ]) { _, hangarValue in hangarValue }
        if let windowID {
            env["HANGAR_WINDOW_ID"] = windowID.uuidString
        }
        if let workspaceID {
            env["HANGAR_WORKSPACE_ID"] = workspaceID.uuidString
        }
        if let pane {
            env["HANGAR_PANE"] = pane.rawValue
        }
        if let paneToken, !paneToken.isEmpty {
            env["HANGAR_PANE_ID"] = paneToken
        }
        return env
    }

    /// Environment for the quick terminal, which is neither part of the session tree nor owned by a window —
    /// it is one detached panel per app, so it carries no window id and an untargeted `hangarctl` run from it
    /// resolves the active window like any other caller.
    public static func quickTerminal(socketPath: String, programVersion: String) -> [String: String] {
        terminalIdentity(programVersion: programVersion).merging([
            "HANGAR_ENABLED": "1",
            "HANGAR_SOCKET": socketPath,
        ]) { _, hangarValue in hangarValue }
    }

    private static func terminalIdentity(programVersion: String) -> [String: String] {
        // embedded libghostty defaults these to Ghostty, then reapplies the surface env as overrides.
        // identify the actual host so Ghostty-aware shell tools do not invoke a standalone Ghostty.app.
        [
            "TERM_PROGRAM": "hangar",
            "TERM_PROGRAM_VERSION": programVersion,
        ]
    }
}
