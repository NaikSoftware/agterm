import Foundation

/// Host-free policy for Help ▸ Install Companion Subagents…: the Claude Code skill that runs subagents as
/// agterm companion sessions, plus the two hooks that route the built-in Agent tool to it.
/// `CompanionSubagentsInstaller` in the app owns the copy and the settings write.
public enum CompanionSubagentsInstall {
    public static let skillName = "companion-subagents"
    public static let scriptName = "companion-agent.py"
    /// Sentinel in the bundled `SKILL.md`, so a reinstall never clobbers a user's own same-named skill.
    public static let marker = "<!-- agterm-companion-subagents -->"

    static let hooks: [(event: String, matcher: String?, action: String)] = [
        ("PreToolUse", "Agent", "pre-agent"),
        ("Stop", nil, "stop"),
    ]

    public static func skillDirectory(home: String) -> String {
        home + "/.claude/skills/" + skillName
    }

    /// Same rule as `SkillInstall.mayOverwrite`: absent is safe, an existing skill only when agterm marked it.
    public static func mayOverwrite(directoryExists: Bool, existingSKILL contents: String?) -> Bool {
        guard directoryExists else { return true }
        return contents?.contains(marker) == true
    }

    /// Merge the two hooks into Claude Code's `settings.json`, idempotently: an event whose entries already
    /// run `scriptPath` is left alone. Unrelated keys and hooks are preserved; unreadable shapes throw
    /// `AgentHooksInstall.MergeError` rather than being overwritten.
    public static func mergeClaudeSettings(existing: String?, scriptPath: String) throws -> (json: String, changed: Bool) {
        var root = try AgentHooksInstall.parsedObject(existing)
        let rawHooks: Any = root["hooks"] ?? [String: Any]()
        guard var hooksObject = rawHooks as? [String: Any] else {
            throw AgentHooksInstall.MergeError.malformedExistingSettings
        }
        var changed = false
        for hook in hooks {
            let rawEntries: Any = hooksObject[hook.event] ?? [[String: Any]]()
            guard var entries = rawEntries as? [[String: Any]] else {
                throw AgentHooksInstall.MergeError.malformedExistingSettings
            }
            if entries.contains(where: { runs($0, scriptPath) }) { continue }
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": AgentHooksInstall.shellQuote(scriptPath) + " " + hook.action]],
            ]
            entry["matcher"] = hook.matcher
            entries.append(entry)
            hooksObject[hook.event] = entries
            changed = true
        }
        guard changed else { return (existing ?? "", false) }
        root["hooks"] = hooksObject
        return (AgentHooksInstall.serialize(root), true)
    }

    private static func runs(_ entry: [String: Any], _ scriptPath: String) -> Bool {
        (entry["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(scriptPath) == true }
    }
}
