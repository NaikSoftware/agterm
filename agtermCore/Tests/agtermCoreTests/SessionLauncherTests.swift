import agtermCore
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

    @Test func availableKeepsTerminalWithNothingInstalled() {
        #expect(SessionLauncher.available(path: "") { _ in true } == [.terminal])
    }
}
