import Foundation
import Testing
@testable import agtermCore

struct CompanionSubagentsInstallTests {
    private let script = "/Users/me/.claude/skills/companion-subagents/companion-agent.py"

    private func hooks(_ json: String) throws -> [String: [[String: Any]]] {
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return try #require(root["hooks"] as? [String: [[String: Any]]])
    }

    private func commands(_ entries: [[String: Any]]?) -> [String] {
        (entries ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    @Test func freshMergeAddsAgentDenyAndStopReport() throws {
        let result = try CompanionSubagentsInstall.mergeClaudeSettings(existing: nil, scriptPath: script)
        #expect(result.changed)
        let hooks = try hooks(result.json)
        #expect(hooks["PreToolUse"]?.first?["matcher"] as? String == "Agent")
        #expect(commands(hooks["PreToolUse"]) == ["'\(script)' pre-agent"])
        #expect(hooks["Stop"]?.first?["matcher"] == nil)
        #expect(commands(hooks["Stop"]) == ["'\(script)' stop"])
    }

    @Test func secondMergeIsANoOp() throws {
        let first = try CompanionSubagentsInstall.mergeClaudeSettings(existing: nil, scriptPath: script)
        let second = try CompanionSubagentsInstall.mergeClaudeSettings(existing: first.json, scriptPath: script)
        #expect(!second.changed)
        #expect(second.json == first.json)
    }

    @Test func mergeKeepsUnrelatedKeysAndHooks() throws {
        let existing = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"status.sh done"}]}]}}"#
        let result = try CompanionSubagentsInstall.mergeClaudeSettings(existing: existing, scriptPath: script)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(result.json.utf8)) as? [String: Any])
        #expect(root["model"] as? String == "opus")
        #expect(commands(try hooks(result.json)["Stop"]) == ["status.sh done", "'\(script)' stop"])
    }

    @Test(arguments: ["not json", #"{"hooks":[]}"#, #"{"hooks":{"Stop":{}}}"#])
    func unreadableShapesThrowInsteadOfOverwriting(existing: String) {
        #expect(throws: AgentHooksInstall.MergeError.self) {
            try CompanionSubagentsInstall.mergeClaudeSettings(existing: existing, scriptPath: script)
        }
    }

    @Test func overwriteOnlyAbsentOrMarkedSkill() {
        #expect(CompanionSubagentsInstall.mayOverwrite(directoryExists: false, existingSKILL: nil))
        #expect(!CompanionSubagentsInstall.mayOverwrite(directoryExists: true, existingSKILL: nil))
        #expect(!CompanionSubagentsInstall.mayOverwrite(directoryExists: true, existingSKILL: "# mine"))
        #expect(CompanionSubagentsInstall.mayOverwrite(directoryExists: true, existingSKILL: CompanionSubagentsInstall.marker))
    }

    @Test func bundledSkillCarriesTheMarkerAndScript() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("plugins/companion-subagents/skills/companion-subagents")
        let skill = try String(contentsOf: root.appendingPathComponent("SKILL.md"), encoding: .utf8)
        #expect(skill.contains(CompanionSubagentsInstall.marker))
        #expect(FileManager.default.isExecutableFile(atPath: root.appendingPathComponent(CompanionSubagentsInstall.scriptName).path))
    }
}
