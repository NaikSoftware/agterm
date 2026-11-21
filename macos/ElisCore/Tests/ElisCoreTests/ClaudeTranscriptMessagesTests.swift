import Foundation
import Testing
@testable import ElisCore

struct ClaudeTranscriptMessagesTests {
    private static let note = "\n\nThis came from another Claude session — not typed by your user."

    private func items(_ content: String, origin: String? = nil, isMeta: Bool = false, promptSource: String? = nil) -> [ControlTranscriptItem] {
        var record: [String: Any] = ["type": "user", "uuid": "u1", "message": ["role": "user", "content": content]]
        if let origin { record["origin"] = ["kind": origin] }
        if isMeta { record["isMeta"] = true }
        if let promptSource { record["promptSource"] = promptSource }
        return ClaudeTranscriptItems.items(record: record, at: 0, result: nil, spilled: { _ in nil })
    }

    @Test func teammateMessageIsAMessageNotAPrompt() throws {
        let made = items("Another Claude session sent a message:\n<teammate-message teammate_id=\"scout\" color=\"green\" " +
                         "summary=\"Found 3 callers\">\nThe callers are **a**, b and c.\n</teammate-message>" + Self.note)
        let message = try #require(made.first)
        #expect(made.count == 1)
        #expect(message.kind == "message" && message.channel == "teammate")
        #expect(message.from == "scout" && message.summary == "Found 3 callers" && message.agentColor == "green")
        #expect(message.text == "The callers are **a**, b and c.")
        #expect(message.promptSource == nil && message.origin == nil)
    }

    @Test func eachBlockOfARecordIsItsOwnMessage() {
        let made = items("<teammate-message teammate_id=\"a\">one</teammate-message>\n\n" +
                         "<teammate-message teammate_id=\"b\" summary=\"x > y\">two</teammate-message>")
        #expect(made.map(\.from) == ["a", "b"])
        #expect(made.map(\.text) == ["one", "two"])
        #expect(made.last?.summary == "x > y")
    }

    @Test func idleNoticeIsDroppedAndOtherProtocolLinesKeepTheirMessage() {
        let idle = #"{"type":"idle_notification","from":"scout","timestamp":"T","idleReason":"available"}"#
        #expect(items("<teammate-message teammate_id=\"scout\">\n\(idle)\n</teammate-message>").isEmpty)
        let shutdown = #"{"type":"shutdown_request","reason":"Work is done"}"#
        #expect(items("<teammate-message teammate_id=\"lead\">\(shutdown)</teammate-message>").map(\.text) == ["Work is done"])
    }

    @Test func crossSessionMessageShowsThoughMeta() throws {
        let content = "Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" " +
            "name=\"Chat mode for phone\" mode=\"prompting\">\nCheck the build.\n</cross-session-message>" + Self.note
        let message = try #require(items(content, origin: "peer", isMeta: true, promptSource: "system").first)
        #expect(message.kind == "message" && message.channel == "session")
        #expect(message.from == "Chat mode for phone" && message.text == "Check the build.")
        #expect(items("a skill body", isMeta: true).isEmpty)
        #expect(items("plain text", origin: "peer", isMeta: true).isEmpty)
    }

    @Test func taskNotificationIsATaskMessage() throws {
        let content = "<task-notification>\n<task-id>abc</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<status>completed</status>\n" +
            "<summary>Agent \"Scout\" completed</summary>\n<result>\nAll done.\n</result>\n</task-notification>"
        let message = try #require(items(content, origin: "task-notification", promptSource: "system").first)
        #expect(message.kind == "message" && message.channel == "task")
        #expect(message.id == "toolu_1" && message.status == "completed")
        #expect(message.summary == "Agent \"Scout\" completed" && message.text == "All done.")
    }

    @Test func textMentioningATagStaysTheUsersPrompt() {
        let made = items("why does <teammate-message> show raw?", promptSource: "typed")
        #expect(made.map(\.kind) == ["user"])
    }
}
