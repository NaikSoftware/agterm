import Foundation
import Testing
@testable import ElisCore

struct ClaudeTranscriptIndexTests {
    private final class Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cti-\(UUID().uuidString)")
        var path: String { dir.appendingPathComponent("s.jsonl").path }

        init(_ lines: [String] = []) throws {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try write(lines.map { $0 + "\n" }.joined())
        }

        deinit { try? FileManager.default.removeItem(at: dir) }

        func write(_ text: String) throws { try Data(text.utf8).write(to: URL(fileURLWithPath: path)) }

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        func index() -> ClaudeTranscriptIndex {
            let index = ClaudeTranscriptIndex(path: path)
            #expect(index.extend())
            return index
        }
    }

    private func record(_ type: String, _ uuid: String?, parent: String?, extra: String = "") -> String {
        let id = uuid.map { "\"\($0)\"" } ?? "null"
        let up = parent.map { "\"\($0)\"" } ?? "null"
        return "{\"parentUuid\":\(up),\"isSidechain\":false,\"type\":\"\(type)\",\"uuid\":\(id)\(extra)}"
    }

    private func chainUUIDs(_ index: ClaudeTranscriptIndex) -> [String?] {
        index.activeChain().map { index.records[$0].uuid }
    }

    @Test func chainWalksThroughAttachmentsAndAcrossCompaction() throws {
        let fixture = try Fixture([
            record("user", "u1", parent: nil),
            record("attachment", "att", parent: "u1"),
            record("assistant", "a1", parent: "att"),
            record("system", "boundary", parent: nil, extra: ",\"subtype\":\"compact_boundary\",\"logicalParentUuid\":\"a1\""),
            record("user", "u2", parent: "boundary"),
        ])
        let index = fixture.index()
        #expect(chainUUIDs(index) == ["u1", "att", "a1", "boundary", "u2"])
        #expect(index.records[3].subtype == "compact_boundary")
        #expect(index.records[3].logicalParent == "a1")
    }

    @Test func sidechainRecordsAreDropped() throws {
        let fixture = try Fixture([
            record("user", "u1", parent: nil),
            record("assistant", "a1", parent: "u1"),
            #"{"parentUuid":"a1","isSidechain":true,"type":"assistant","uuid":"s1"}"#,
        ])
        let index = fixture.index()
        #expect(index.records[2].sidechain)
        #expect(chainUUIDs(index) == ["u1", "a1"])
    }

    @Test func leafIsLastRecordWithUUID() throws {
        let fixture = try Fixture([
            record("user", "u1", parent: nil),
            record("assistant", "a1", parent: "u1"),
            #"{"type":"custom-title","customTitle":"Named","sessionId":"s"}"#,
        ])
        #expect(chainUUIDs(fixture.index()) == ["u1", "a1"])
    }

    @Test func branchSwitchMovesTheChain() throws {
        let fixture = try Fixture([
            record("user", "u1", parent: nil),
            record("assistant", "a2", parent: "u1"),
        ])
        let index = fixture.index()
        #expect(chainUUIDs(index) == ["u1", "a2"])
        try fixture.append(record("assistant", "a2b", parent: "u1") + "\n")
        #expect(index.extend())
        #expect(chainUUIDs(index) == ["u1", "a2b"])
    }

    @Test func partialTrailingLineWaitsForItsNewline() throws {
        let first = record("user", "u1", parent: nil)
        let second = record("assistant", "a1", parent: "u1")
        let fixture = try Fixture([first])
        let half = second.utf8.count / 2
        try fixture.append(String(second.prefix(half)))
        let index = fixture.index()
        #expect(index.records.count == 1)
        #expect(index.end == first.utf8.count + 1)
        #expect(index.size == first.utf8.count + 1 + half)
        try fixture.append(String(second.dropFirst(half)) + "\n")
        #expect(index.extend())
        #expect(index.records.map(\.uuid) == ["u1", "a1"])
        #expect(index.records[1].offset == first.utf8.count + 1)
        #expect(index.end == index.size)
    }

    @Test func lineOverReadWindowBecomesOneOversizedRecord() throws {
        let paste = String(repeating: "x", count: 5 << 20)
        let big = #"{"parentUuid":"u1","isSidechain":false,"type":"user","message":{"role":"user","content":"\#(paste)"},"uuid":"big"}"#
        let fixture = try Fixture([record("user", "u1", parent: nil), big, record("assistant", "a1", parent: "big")])
        let index = fixture.index()
        #expect(index.records.count == 3)
        #expect(index.records[1].oversized)
        #expect(index.records[1].length == big.utf8.count)
        #expect(index.records[1].uuid == "big")
        #expect(index.records[1].parent == "u1")
        #expect(index.records[2].offset == index.records[1].offset + big.utf8.count + 1)
        #expect(chainUUIDs(index) == ["u1", "big", "a1"])
    }

    @Test func oversizedToolResultTakesItsTopLevelUUIDBetweenBlobs() throws {
        let blob = String(repeating: "x", count: 3 << 20)
        let big = #"{"parentUuid":"u1","isSidechain":false,"type":"user","message":{"content":[{"type":"tool_result","content":"\#(blob)"}]},"#
            + #""uuid":"big","toolUseResult":{"file":{"uuid":"nested","base64":"\"\#(blob)"}},"sourceToolAssistantUUID":"u1"}"#
        let fixture = try Fixture([record("user", "u1", parent: nil), big, record("assistant", "a1", parent: "big")])
        let index = fixture.index()
        #expect(index.records[1].oversized)
        #expect(index.records[1].uuid == "big")
        #expect(chainUUIDs(index) == ["u1", "big", "a1"])
    }

    @Test func undecodableLineCountsAsSkipped() throws {
        let fixture = try Fixture(["{not json", record("user", "u1", parent: nil)])
        let index = fixture.index()
        #expect(index.skipped == 1)
        #expect(index.records.map(\.uuid) == ["u1"])
    }

    @Test func shrinkOrChangedPrefixAsksForRebuild() throws {
        let lines = [record("user", "u1", parent: nil), record("assistant", "a1", parent: "u1")]
        let fixture = try Fixture(lines)
        let shrunk = fixture.index()
        try fixture.write(lines[0] + "\n")
        #expect(!shrunk.extend())

        try fixture.write(lines.map { $0 + "\n" }.joined())
        let changed = fixture.index()
        try fixture.write(" " + lines.map { $0 + "\n" }.joined().dropFirst())
        #expect(!changed.extend())
    }

    @Test func openCallsCloseOnToolResult() throws {
        let use = #","message":{"id":"msg_1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}"#
        let result = #","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}"#
        let fixture = try Fixture([record("user", "u1", parent: nil), record("assistant", "a1", parent: "u1", extra: use)])
        let index = fixture.index()
        #expect(index.openCalls == ["t1": 1])
        #expect(index.records[1].messageID == "msg_1")
        #expect(index.resultIndex(forToolUse: "t1") == nil)
        try fixture.append(record("user", "r1", parent: "a1", extra: result) + "\n")
        #expect(index.extend())
        #expect(index.openCalls.isEmpty)
        #expect(index.resultIndex(forToolUse: "t1") == 2)
    }

    @Test func metaFoldsLastOfEachType() throws {
        let assistant = #","effort":"medium","message":{"model":"claude-haiku-5-5","content":[]}"#
        let fixture = try Fixture([
            #"{"type":"ai-title","aiTitle":"First AI","sessionId":"s"}"#,
            #"{"type":"custom-title","customTitle":"Mine","sessionId":"s"}"#,
            #"{"type":"ai-title","aiTitle":"Second AI","sessionId":"s"}"#,
            #"{"type":"permission-mode","permissionMode":"default","sessionId":"s"}"#,
            #"{"type":"permission-mode","permissionMode":"auto","sessionId":"s"}"#,
            #"{"type":"pr-link","sessionId":"s","prNumber":988,"prUrl":"https://example.com/o/r/pull/988","prRepository":"o/r"}"#,
            #"{"type":"agent-name","agentName":"Scout","sessionId":"s"}"#,
            #"{"type":"last-prompt","lastPrompt":"fix the build","leafUuid":"a1","sessionId":"s"}"#,
            #"{"type":"last-prompt","leafUuid":"a1","sessionId":"s"}"#,
            record("assistant", "a1", parent: nil, extra: assistant),
            #"{"parentUuid":"a1","isSidechain":true,"type":"assistant","uuid":"s1","effort":"low","message":{"model":"other"}}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"assistant","uuid":"e1","message":{"model":"<synthetic>"}}"#,
        ])
        let meta = fixture.index().meta
        #expect(meta.title == "Mine")
        #expect(meta.permissionMode == "auto")
        #expect(meta.pr == ControlTranscriptPR(prNumber: 988, prRepository: "o/r", prUrl: "https://example.com/o/r/pull/988"))
        #expect(meta.agentName == "Scout")
        #expect(meta.lastPrompt == "fix the build")
        #expect(meta.model == "claude-haiku-5-5")
        #expect(meta.effort == "medium")
    }

    // Captured from Claude Code 2.1.329: the queued_command attachment is the delivery, written after its remove.
    @Test func queuedCommandsFoldWithQueueOperations() throws {
        let fixture = try Fixture([
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-19T23:33:43.008Z","sessionId":"s","content":"queued one: say delta"}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-19T23:33:52.027Z","sessionId":"s","content":"queued two: say epsilon"}"#,
        ])
        let index = fixture.index()
        #expect(index.meta.queued == ["queued one: say delta", "queued two: say epsilon"])
        try fixture.append([
            #"{"type":"queue-operation","operation":"popAll","timestamp":"2026-11-19T23:33:53.484Z","sessionId":"s","content":"queued one: say delta"}"#,
            #"{"type":"queue-operation","operation":"popAll","timestamp":"2026-11-19T23:33:53.484Z","sessionId":"s","content":"queued two: say epsilon"}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-19T23:34:12.435Z","sessionId":"s","content":"queued three: say zeta"}"#,
        ].map { $0 + "\n" }.joined())
        #expect(index.extend())
        #expect(index.meta.queued == ["queued three: say zeta"])
        try fixture.append([
            #"{"type":"queue-operation","operation":"remove","timestamp":"2026-11-19T23:34:32.622Z","sessionId":"s","content":"queued three: say zeta","#
                + #""reason":"absorbed_mid_turn","commandUuid":"c3","deliveryId":"d3"}"#,
            #"{"parentUuid":"p","isSidechain":false,"attachment":{"type":"queued_command","prompt":"queued three: say zeta","source_uuid":"c3","#
                + #""delivery_id":"d3","commandMode":"prompt","origin":{"kind":"human"},"humanTurn":true},"type":"attachment","uuid":"q3"}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-03T01:22:00.788Z","sessionId":"s"}"#,
            #"{"type":"queue-operation","operation":"enqueue","timestamp":"2026-11-03T01:22:01.000Z","sessionId":"s","content":"And pass the model"}"#,
            #"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-11-03T01:22:00.789Z","sessionId":"s"}"#,
        ].map { $0 + "\n" }.joined())
        #expect(index.extend())
        #expect(index.meta.queued == ["And pass the model"])
        try fixture.append(#"{"type":"queue-operation","operation":"dequeue","timestamp":"2026-11-03T01:22:02.000Z","sessionId":"s"}"# + "\n")
        #expect(index.extend())
        #expect(index.meta.queued == nil)
    }

    // No todo tool fired in a 2.1.329 capture, so only TodoWrite's documented shape folds.
    @Test func todosFoldToLatestState() throws {
        func todoWrite(_ uuid: String, _ todos: String) -> String {
            record("assistant", uuid, parent: nil, extra: #","message":{"content":[{"type":"tool_use","id":"t\#(uuid)","#
                + #""name":"TodoWrite","input":{"todos":\#(todos)}}]}"#)
        }
        let fixture = try Fixture([
            todoWrite("a1", #"[{"content":"Run sleep","status":"pending","activeForm":"Running sleep"}]"#),
            todoWrite("a2", #"[{"content":"Run sleep","status":"completed","activeForm":"Running sleep"},"#
                + #"{"content":"Say alpha","status":"in_progress","activeForm":"Saying alpha"}]"#),
        ])
        #expect(fixture.index().meta.todos == [
            ControlTranscriptTodo(content: "Run sleep", status: "completed", activeForm: "Running sleep"),
            ControlTranscriptTodo(content: "Say alpha", status: "in_progress", activeForm: "Saying alpha"),
        ])
    }

    @Test func continuedInIsRecorded() throws {
        let fixture = try Fixture([
            #"{"type":"continued-in","timestamp":"2026-11-05T15:11:29.676Z","sessionId":"s","continuedInSessionId":"next-1"}"#,
        ])
        #expect(fixture.index().meta.continuedIn == "next-1")
    }

    @Test func skillListingOffsetIsRecorded() throws {
        let first = record("user", "u1", parent: nil)
        let fixture = try Fixture([first, record("attachment", "k1", parent: "u1", extra: #","attachment":{"type":"skill_listing"}"#)])
        #expect(fixture.index().meta.skillsAt == first.utf8.count + 1)
    }

    @Test func claudeHomeHonorsAbsoluteConfigDir() {
        #expect(ClaudeHome.directory(environment: ["CLAUDE_CONFIG_DIR": "/x"], home: "/h") == "/x")
        #expect(ClaudeHome.directory(environment: ["CLAUDE_CONFIG_DIR": "rel"], home: "/h") == "/h/.claude")
        #expect(ClaudeHome.directory(environment: [:], home: "/h") == "/h/.claude")
    }

    @Test func jsonValueKeepsBoolsApartFromNumbers() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"a":true,"b":1,"c":[null,"s"]}"#.utf8))
        #expect(JSONValue(any: object) == .object(["a": .bool(true), "b": .number(1), "c": .array([.null, .string("s")])]))
    }
}
