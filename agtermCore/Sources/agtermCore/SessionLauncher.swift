/// SessionLauncher is what a workspace row's "+" menu starts: a plain shell, or a coding agent typed into one.
public enum SessionLauncher: String, CaseIterable, Sendable {
    case terminal, claude, codex, opencode, antigravity

    public var title: String {
        switch self {
        case .terminal: "Terminal"
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .antigravity: "Antigravity"
        }
    }

    /// The line typed into the new shell; nil for a plain terminal.
    public var command: String? {
        switch self {
        case .terminal: nil
        case .claude: "claude"
        case .codex: "codex"
        case .opencode: "opencode"
        case .antigravity: "agy"
        }
    }

    /// The agent a pane's foreground argv runs, nil for anything else. A script-based install runs as
    /// `node /path/claude`, so the first argument is checked after an interpreter.
    public static func agent(argv: [String]) -> SessionLauncher? {
        func named(_ arg: String) -> SessionLauncher? {
            let name = String(arg.split(separator: "/").last ?? "")
            return allCases.first { $0.command == name }
        }
        guard let first = argv.first else { return nil }
        if let agent = named(first) { return agent }
        let interpreters: Set = ["node", "bun", "deno"]
        guard interpreters.contains(String(first.split(separator: "/").last ?? "")) else { return nil }
        return argv.dropFirst().first { !$0.hasPrefix("-") }.flatMap(named)
    }

    /// The first agent among a foreground process group's argvs, leader first. A script shell does no job control,
    /// so an agent it starts shares the script's group without leading it.
    public static func agent(group: [[String]]) -> SessionLauncher? {
        group.lazy.compactMap { agent(argv: CommandRestore.stripLoginDash($0)) }.first
    }

    /// Terminal plus every agent whose command is an executable in one of `path`'s directories.
    public static func available(path: String, isExecutable: (String) -> Bool) -> [SessionLauncher] {
        let directories = path.split(separator: ":").map(String.init)
        return allCases.filter { launcher in
            guard let command = launcher.command else { return true }
            return directories.contains { isExecutable($0 + "/" + command) }
        }
    }
}
