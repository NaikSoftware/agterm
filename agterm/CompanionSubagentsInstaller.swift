import AppKit
import agtermCore

/// Help ▸ Install Companion Subagents…: copies the bundled skill to `~/.claude/skills/companion-subagents` and
/// merges its two hooks into `~/.claude/settings.json`. Policy is `agtermCore.CompanionSubagentsInstall`.
@MainActor
enum CompanionSubagentsInstaller {
    private struct InstallError: Error { let message: String }

    static func run() {
        do {
            let settingsSkipped = try install()
            present(style: settingsSkipped ? .warning : .informational,
                    title: settingsSkipped ? "Skill Installed, Hooks Not Merged" : "Companion Subagents Installed",
                    text: message(settingsSkipped: settingsSkipped))
        } catch let error as InstallError {
            present(style: .warning, title: "Install Failed", text: error.message)
        } catch {
            present(style: .warning, title: "Install Failed", text: error.localizedDescription)
        }
    }

    // returns true when ~/.claude/settings.json was left untouched because it could not be read or parsed
    private static func install() throws -> Bool {
        let fm = FileManager.default
        guard let source = Bundle.main.resourceURL?.appendingPathComponent(CompanionSubagentsInstall.skillName),
              fm.fileExists(atPath: source.path) else {
            throw InstallError(message: "Companion subagents are not bundled in this build.")
        }
        let destination = URL(fileURLWithPath: CompanionSubagentsInstall.skillDirectory(home: fm.homeDirectoryForCurrentUser.path))
        // lstat semantics, so a symlink at the destination counts as present, as in `SkillInstaller`
        let directoryExists = (try? fm.attributesOfItem(atPath: destination.path)) != nil
        let existingSKILL = try? String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8)
        guard CompanionSubagentsInstall.mayOverwrite(directoryExists: directoryExists, existingSKILL: existingSKILL) else {
            throw InstallError(message: "A different '\(CompanionSubagentsInstall.skillName)' skill is already at "
                + "\(destination.path). It was left untouched.")
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: destination) // a prior agterm install
        try fm.copyItem(at: source, to: destination)
        let script = destination.appendingPathComponent(CompanionSubagentsInstall.scriptName).path
        return try AgentHooksInstaller.rewriteClaudeSettings { existing in
            try CompanionSubagentsInstall.mergeClaudeSettings(existing: existing, scriptPath: script)
        }
    }

    private static func message(settingsSkipped: Bool) -> String {
        let skill = "Skill: ~/.claude/skills/\(CompanionSubagentsInstall.skillName)."
        if settingsSkipped {
            return skill + " ~/.claude/settings.json could not be read as JSON, so it was left as is and the "
                + "built-in Agent tool still runs. Fix the file and install again."
        }
        return skill + " Inside agterm, Claude Code now runs each subagent as a companion session under its own row "
            + "and gets the reply over the message bus. Start claude with AGTERM_COMPANIONS=off to keep the built-in "
            + "Agent tool for one session. Restart running Claude Code sessions to pick up the hooks."
    }

    private static func present(style: NSAlert.Style, title: String, text: String) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
