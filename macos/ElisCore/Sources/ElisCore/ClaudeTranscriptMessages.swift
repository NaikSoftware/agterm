import Foundation

/// User records that another session, a teammate or a background task wrote into the conversation, as `message` items.
enum ClaudeTranscriptMessages {
    // Claude Code 2.1.329 opens a delivered message with this line and closes it with a note to the model
    static let preamble = "Another Claude session sent a message:"
    private static let channels = [("teammate-message", "teammate"), ("cross-session-message", "session")]

    /// One item per tagged block when the text opens with one, an idle notice yielding none; nil for any other text.
    static func items(_ text: String) -> [ControlTranscriptItem]? {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.hasPrefix("<task-notification>") { return [task(String(rest))] }
        if rest.hasPrefix(preamble) { rest = rest.dropFirst(preamble.count).drop(while: \.isWhitespace) }
        var made: [ControlTranscriptItem]?
        while let (name, channel) = channels.first(where: { rest.hasPrefix("<\($0.0) ") || rest.hasPrefix("<\($0.0)>") }),
              let (attributes, bodyStart) = attributes(rest.dropFirst(name.count + 1)),
              let close = rest[bodyStart...].range(of: "</\(name)>") {
            let body = rest[bodyStart..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            rest = rest[close.upperBound...].drop(while: \.isWhitespace)
            made = (made ?? []) + (message(channel: channel, attributes: attributes, body: body).map { [$0] } ?? [])
        }
        return made
    }

    private static func message(channel: String, attributes: [String: String], body: String) -> ControlTranscriptItem? {
        var item = ControlTranscriptItem(kind: "message", uuid: "", at: 0)
        item.channel = channel
        item.from = channel == "teammate" ? attributes["teammate_id"] : attributes["name"] ?? attributes["from"]
        item.summary = attributes["summary"]
        item.agentColor = attributes["color"]
        item.text = body
        // a teammate's protocol line is JSON; going idle after every turn would flood the chat
        if body.hasPrefix("{"), let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
           let type = object["type"] as? String {
            if type == "idle_notification" { return nil }
            item.text = object["message"] as? String ?? object["reason"] as? String ?? type
        }
        return item
    }

    private static func task(_ text: String) -> ControlTranscriptItem {
        var item = ControlTranscriptItem(kind: "message", uuid: "", at: 0)
        item.channel = "task"
        item.id = ClaudeTranscriptItems.tag("tool-use-id", in: text)
        item.status = ClaudeTranscriptItems.tag("status", in: text)
        item.summary = ClaudeTranscriptItems.tag("summary", in: text)
        item.text = ClaudeTranscriptItems.tag("result", in: text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return item
    }

    /// The `name="value"` pairs up to the tag's `>`, and the index after it.
    private static func attributes(_ text: Substring) -> ([String: String], Substring.Index)? {
        var attributes: [String: String] = [:]
        var at = text.startIndex
        while at < text.endIndex {
            let char = text[at]
            if char == ">" { return (attributes, text.index(after: at)) }
            if char.isWhitespace {
                at = text.index(after: at)
                continue
            }
            guard let equals = text[at...].firstIndex(of: "="), text.index(after: equals) < text.endIndex,
                  text[text.index(after: equals)] == "\"",
                  let end = text[text.index(equals, offsetBy: 2)...].firstIndex(of: "\"")
            else { return nil }
            attributes[String(text[at..<equals])] = String(text[text.index(equals, offsetBy: 2)..<end])
            at = text.index(after: end)
        }
        return nil
    }
}
