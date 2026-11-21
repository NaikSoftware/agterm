import Foundation
import Testing
@testable import ElisCore

struct ClaudeTranscriptAgentsTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cta-\(UUID().uuidString)")
        var project: URL { root.appendingPathComponent("projects/-proj") }
        var path: String { project.appendingPathComponent("s1.jsonl").path }
        var subagents: URL { project.appendingPathComponent("s1/subagents") }
        let clock = Locked(Date(timeIntervalSince1970: 1_800_000_000))
        lazy var reader = ClaudeTranscript(claudeDirectory: root.path, now: { [clock] in clock.withLock { $0 } })

        init(_ lines: [String]) throws {
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            try write(lines, to: path)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ lines: [String], to path: String) throws {
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: path))
        }

        func append(_ lines: [String]) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        }

        /// Writes `subagents/agent-<id>.jsonl`, last modified `age` seconds before the clock.
        func agentFile(_ id: String, _ lines: [String], age: TimeInterval = 5) throws {
            let file = subagents.appendingPathComponent("agent-\(id).jsonl").path
            try write(lines, to: file)
            let stamp = clock.withLock { $0 }.addingTimeInterval(-age)
            try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: file)
        }

        var agents: [ControlTranscriptAgent] {
            get throws { try reader.page(ClaudeTranscriptRequest(sessionID: "s1")).get().meta.agents ?? [] }
        }
    }

    private static let start = "2026-11-21T08:00:00.000Z"

    private func user(_ uuid: String, parent: String?) -> String {
        #"{"type":"user","uuid":"\#(uuid)","parentUuid":\#(parent.map { "\"\($0)\"" } ?? "null"),"isSidechain":false,"# +
            #""timestamp":"\#(Self.start)","message":{"role":"user","content":"go"}}"#
    }

    private func agentCall(_ uuid: String, parent: String, id: String, input: String, time: String = start) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","parentUuid":"\#(parent)","isSidechain":false,"timestamp":"\#(time)","# +
            #""message":{"id":"m-\#(uuid)","model":"m","content":[{"type":"tool_use","id":"\#(id)","name":"Agent","input":\#(input)}]}}"#
    }

    private func agentResult(_ uuid: String, parent: String, id: String, result: String = "null", isError: Bool = false,
                             time: String = start) -> String {
        #"{"type":"user","uuid":"\#(uuid)","parentUuid":"\#(parent)","isSidechain":false,"timestamp":"\#(time)","# +
            #""toolUseResult":\#(result),"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","# +
            #""is_error":\#(isError),"content":"ok"}]}}"#
    }

    private func notification(_ uuid: String, parent: String, task: String, call: String, status: String) -> String {
        #"{"type":"user","uuid":"\#(uuid)","parentUuid":"\#(parent)","isSidechain":false,"timestamp":"\#(Self.start)","# +
            #""origin":{"kind":"task-notification"},"message":{"role":"user","content":"<task-notification>\n<task-id>\#(task)</task-id>\n"# +
            #"<tool-use-id>\#(call)</tool-use-id>\n<status>\#(status)</status>\n<summary>s</summary>\n</task-notification>"}}"#
    }

    private func launched(_ agentID: String) -> String { #"{"status":"async_launched","agentId":"\#(agentID)"}"# }

    private static let working = #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"b1","name":"Bash","input":{}}]}}"#
    private static let ended = #"{"type":"assistant","isSidechain":true,"message":{"stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#
    private static let request = #"{"type":"api-request","timestamp":"T"}"#
    private static let prompt = #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"more"}}"#

    @Test func foregroundAgentRunsWhileItsCallIsOpen() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"Find callers","subagent_type":"Explore","prompt":"p"}"#),
        ])
        var agent = ControlTranscriptAgent(id: "t1", state: "running")
        agent.agentType = "Explore"
        agent.description = "Find callers"
        agent.startedAt = Self.start
        #expect(try fixture.agents == [agent])
        try fixture.append([agentResult("r1", parent: "a1", id: "t1")])
        agent.state = "done"
        #expect(try fixture.agents == [agent])
    }

    @Test func failedForegroundCallReadsFailed() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"d"}"#),
            agentResult("r1", parent: "a1", id: "t1", isError: true),
        ])
        #expect(try fixture.agents.map(\.state) == ["failed"])
    }

    @Test func backgroundAgentRunsUntilItsTaskNotification() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"d","run_in_background":true}"#),
            agentResult("r1", parent: "a1", id: "t1", result: launched("abc")),
        ])
        try fixture.agentFile("abc", [Self.working, Self.request])
        #expect(try fixture.agents.map(\.state) == ["running"])
        try fixture.append([notification("n1", parent: "r1", task: "abc", call: "t1", status: "failed")])
        #expect(try fixture.agents.map(\.state) == ["failed"])
    }

    @Test func taskMessageComesFromItsAgent() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"Map callers","name":"scout"}"#),
            agentResult("r1", parent: "a1", id: "t1", result: launched("abc")),
            notification("n1", parent: "r1", task: "abc", call: "t1", status: "completed"),
        ])
        let page = try fixture.reader.page(ClaudeTranscriptRequest(sessionID: "s1")).get()
        let message = try #require(page.items.first { $0.kind == "message" })
        #expect(message.channel == "task" && message.from == "scout" && message.status == "completed")
    }

    @Test func queuedNotificationEndsTheAgentBeforeItIsDelivered() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"d"}"#),
            agentResult("r1", parent: "a1", id: "t1", result: launched("abc")),
            #"{"type":"queue-operation","operation":"enqueue","content":"<task-notification><task-id>abc</task-id><tool-use-id>t1</tool-use-id><status>killed</status></task-notification>"}"#,
        ])
        try fixture.agentFile("abc", [Self.working])
        #expect(try fixture.agents.map(\.state) == ["stopped"])
    }

    @Test func notificationTextOutsideAUserRecordIsIgnored() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"d"}"#),
            agentResult("r1", parent: "a1", id: "t1", result: launched("abc")),
            #"{"type":"last-prompt","lastPrompt":"<task-notification><tool-use-id>t1</tool-use-id><status>completed</status>"}"#,
        ])
        try fixture.agentFile("abc", [Self.working])
        #expect(try fixture.agents.map(\.state) == ["running"])
    }

    @Test func backgroundAgentWhoseFileEndsATurnIsDone() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"d"}"#),
            agentResult("r1", parent: "a1", id: "t1", result: launched("abc")),
        ])
        try fixture.agentFile("abc", [Self.working, Self.ended, Self.request])
        #expect(try fixture.agents.map(\.state) == ["done"])
    }

    @Test func backgroundAgentSilentPastTheBoundIsNotListed() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"d"}"#),
            agentResult("r1", parent: "a1", id: "t1", result: launched("abc")),
        ])
        try fixture.agentFile("abc", [Self.working], age: ClaudeTranscript.agentSilence + 1)
        #expect(try fixture.agents.isEmpty)
        try fixture.agentFile("abc", [Self.working], age: ClaudeTranscript.agentSilence - 1)
        #expect(try fixture.agents.map(\.state) == ["running"])
    }

    @Test func backgroundAgentWithoutItsFileIsNotListed() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"d"}"#),
            agentResult("r1", parent: "a1", id: "t1", result: launched("../abc")),
        ])
        try fixture.agentFile("abc", [Self.working])
        #expect(try fixture.agents.isEmpty)
    }

    @Test func teammateCarriesItsColourAndWakesFromIdle() throws {
        let spawned = #"{"status":"teammate_spawned","agentId":"ascout-1","agent_type":"Explore","color":"green","name":"scout"}"#
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"Scout","name":"scout"}"#),
            agentResult("r1", parent: "a1", id: "t1", result: spawned),
        ])
        try fixture.agentFile("ascout-1", [Self.working, Self.ended])
        var agent = ControlTranscriptAgent(id: "t1", state: "done")
        agent.agentType = "Explore"
        agent.name = "scout"
        agent.color = "green"
        agent.description = "Scout"
        agent.startedAt = Self.start
        #expect(try fixture.agents == [agent])
        try fixture.agentFile("ascout-1", [Self.working, Self.ended, Self.prompt])
        #expect(try fixture.agents.map(\.state) == ["running"])
    }

    @Test func runningComeFirstThenTheThreeLatestFinished() throws {
        var lines = [user("u1", parent: nil)]
        var parent = "u1"
        for at in 0..<5 {
            lines.append(agentCall("a\(at)", parent: parent, id: "t\(at)", input: #"{"description":"d\#(at)"}"#))
            lines.append(agentResult("r\(at)", parent: "a\(at)", id: "t\(at)", time: "2026-11-21T08:0\(at):00.000Z"))
            parent = "r\(at)"
        }
        lines.append(agentCall("a9", parent: parent, id: "t9", input: #"{"description":"open"}"#))
        let fixture = try Fixture(lines)
        #expect(try fixture.agents.map(\.id) == ["t9", "t4", "t3", "t2"])
    }

    @Test func agentOffTheActiveChainIsNotListed() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            agentCall("a1", parent: "u1", id: "t1", input: #"{"description":"rewound"}"#),
            user("u2", parent: "u1"),
        ])
        #expect(try fixture.agents.isEmpty)
    }
}
