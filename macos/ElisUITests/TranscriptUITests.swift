import XCTest

@MainActor
final class TranscriptUITests: ControlAPITestCase {
    override var launchEnvironmentOverrides: [String: String] { ["CLAUDE_CONFIG_DIR": claudeDirectory.path] }

    private var claudeDirectory: URL { stateDir.appendingPathComponent("claude", isDirectory: true) }

    func testTranscriptFollowsAFakeClaude() throws {
        let projectDir = claudeDirectory.appendingPathComponent("projects/-e2e", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("e2e-1.jsonl")
        try append([
            #"{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":false,"timestamp":"T1","message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","uuid":"a1","parentUuid":"u1","isSidechain":false,"timestamp":"T2","# +
                #""message":{"id":"msg_1","model":"m","content":[{"type":"text","text":"hi there"}]}}"#,
        ], to: file)

        let id = try activeSessionID()
        let fake = #"zsh -c 'mkdir -p "$CLAUDE_CONFIG_DIR/sessions"; print -r -- "{\"sessionId\":\"e2e-1\"}" > "#
            + #""$CLAUDE_CONFIG_DIR/sessions/$$.json"; exec -a claude sleep 90'"# + "\n"
        let typed = try sendCommand(typeRequest(text: fake, target: id, select: false))
        XCTAssertEqual(typed["ok"] as? Bool, true, "typing the fake claude should succeed: \(typed)")
        addTeardownBlock { [self] in _ = try? sendCommand(typeRequest(text: "\u{3}", target: id, select: false)) }

        var node: [String: Any]?
        let detected = poll(until: {
            node = (try? sessionNodeIfPresent(id: id)) ?? nil
            return node?["agent"] as? String == "claude" && node?["agentSessionId"] as? String == "e2e-1"
                && node?["agentPane"] as? String == "left"
        }(), timeout: 15)
        XCTAssertTrue(detected, "the tree should name claude, session e2e-1, pane left: \(String(describing: node))")

        let tail = try transcript(target: id)
        XCTAssertEqual(tail["transcript"] as? String, "e2e-1", "\(tail)")
        XCTAssertEqual(kinds(tail), ["user", "text"], "\(tail)")
        let next = try XCTUnwrap(tail["next"] as? Int, "the tail page should carry next: \(tail)")

        try append([
            #"{"type":"assistant","uuid":"a2","parentUuid":"a1","isSidechain":false,"timestamp":"T3","# +
                #""message":{"id":"msg_2","model":"m","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"false"}}]}}"#,
            #"{"type":"user","uuid":"r1","parentUuid":"a2","isSidechain":false,"timestamp":"T4","# +
                #""message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"Exit code 1","is_error":true}]}}"#,
        ], to: file)
        let page = try transcript(target: id, after: next)
        XCTAssertEqual(kinds(page), ["tool"], "\(page)")
        let tool = try XCTUnwrap((page["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(tool["mark"] as? String, "exit 1", "\(tool)")
    }

    private func append(_ lines: [String], to file: URL) throws {
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        guard let handle = try? FileHandle(forWritingTo: file) else { return try data.write(to: file) }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func transcript(target: String, after: Int? = nil) throws -> [String: Any] {
        var args: [String: Any] = ["transcript": "e2e-1"]
        if let after { args["after"] = String(after) }
        let line = try JSONSerialization.data(withJSONObject: ["cmd": "session.transcript", "target": target, "args": args])
        let response = try sendCommand(String(decoding: line, as: UTF8.self))
        XCTAssertEqual(response["ok"] as? Bool, true, "session.transcript should succeed: \(response)")
        return try XCTUnwrap(response["result"] as? [String: Any], "\(response)")
    }

    private func kinds(_ result: [String: Any]) -> [String] {
        (result["items"] as? [[String: Any]] ?? []).compactMap { $0["kind"] as? String }
    }
}
