import agtermCore
import Foundation
import Testing

struct SessionLauncherTests {
    @Test func availableListsTerminalAndAgentsFoundOnPath() {
        let installed: Set = ["/opt/homebrew/bin/codex", "/Users/me/.local/bin/claude", "/usr/bin/agy"]
        let found = SessionLauncher.available(path: "/usr/bin::/Users/me/.local/bin:/opt/homebrew/bin") {
            installed.contains($0)
        }
        #expect(found == [.terminal, .claude, .codex, .antigravity])
    }

    @Test(arguments: [
        (["claude"], SessionLauncher.claude),
        (["/Users/me/.local/bin/claude", "--resume"], .claude),
        (["node", "--no-warnings", "/opt/homebrew/bin/codex"], .codex),
        (["agy"], .antigravity),
        (["opencode", "run"], .opencode),
        (["vim", "claude"], nil),
        (["node", "server.js"], nil),
        ([], nil)
    ])
    func agentMatchesForegroundArgv(argv: [String], expected: SessionLauncher?) {
        #expect(SessionLauncher.agent(argv: argv) == expected)
    }

    @Test(arguments: [
        ([["/bin/zsh", "-l", "/tmp/PR-1.command"], ["claude", "review"]], SessionLauncher.claude),
        ([["-claude"]], .claude),
        ([["make"], ["cc", "a.c"]], nil),
        ([], nil)
    ])
    func agentFoundAnywhereInForegroundGroup(group: [[String]], expected: SessionLauncher?) {
        #expect(SessionLauncher.agent(group: group) == expected)
    }

    @Test func availableKeepsTerminalWithNothingInstalled() {
        #expect(SessionLauncher.available(path: "") { _ in true } == [.terminal])
    }

    @Test(arguments: [
        (#"{"pid":1,"sessionId":"ab-12_C","cwd":"/Users/me/it's here"}"#, #"cd '/Users/me/it'\''s here' && claude --resume ab-12_C"#),
        (#"{"sessionId":"ab12"}"#, "claude --resume ab12"),
        (#"{"sessionId":"ab12","cwd":""}"#, "claude --resume ab12"),
        (#"{"sessionId":"ab;rm -rf ~","cwd":"/tmp"}"#, nil),
        (#"{"sessionId":"","cwd":"/tmp"}"#, nil),
        (#"{"sessionId":"абв","cwd":"/tmp"}"#, nil),
        (#"{"sessionId":"ab12","cwd":"/tmp/x\u0003\nrm -rf ~"}"#, nil),
        (#"{"sessionId":"ab12","cwd":"/tmp/a\\';touch x #"}"#, nil),
        (#"{"cwd":"/tmp"}"#, nil),
        ("not json", nil)
    ] as [(String, String?)])
    func claudeResumeLineQuotesTheFolderAndRefusesAnUnsafeID(json: String, expected: String?) {
        #expect(SessionLauncher.claudeResumeLine(json: Data(json.utf8)) == expected)
    }
}

struct TitleSpinnerTests {
    @Test(arguments: [
        ("✳ Agterm workspace", "Agterm workspace"),
        ("◑ Agterm workspace", "Agterm workspace"),
        ("⠂ Fix tests", "Fix tests"),
        ("· ✶ Thinking", "Thinking"),
        ("vim notes.md", "vim notes.md"),
        ("✳", "✳")
    ])
    func stripsLeadingSpinnerGlyphs(title: String, expected: String) {
        #expect(Session.strippingTitleSpinner(title) == expected)
    }
}
