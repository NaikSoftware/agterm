import Foundation

/// Claude Code's config directory and its per-process session files.
public enum ClaudeHome {
    /// `CLAUDE_CONFIG_DIR` when it is absolute, else `<home>/.claude`.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let configured = environment["CLAUDE_CONFIG_DIR"], configured.hasPrefix("/") { return configured }
        return (home as NSString).appendingPathComponent(".claude")
    }

    /// The `sessions/<pid>.json` Claude Code writes for a running process.
    public static func sessionJSON(pid: Int32, directory: String) -> Data? {
        FileManager.default.contents(atPath: (directory as NSString).appendingPathComponent("sessions/\(pid).json"))
    }
}
