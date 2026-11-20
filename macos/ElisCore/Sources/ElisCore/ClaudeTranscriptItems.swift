import Foundation

/// One decoded transcript record to its `session.transcript` items; the allowlist in the spec's
/// "Records kept as items" table is the only way in.
enum ClaudeTranscriptItems {
    static let readOnlyTools: Set<String> = ["Read", "Grep", "Glob", "LS", "WebSearch"]
    static let clipBytes = 4096
    static let itemCap = 16384
    /// Shared by every rejection Claude Code 2.1.329 writes: a permission "No" with or without a reason,
    /// a rejected plan, and AskUserQuestion's "Chat about this".
    static let rejectionPrefix = "The user doesn't want to proceed with this tool use."

    private static let fileTools: Set<String> = ["Read", "Edit", "Write", "MultiEdit"]

    /// `result` is the record holding this record's `tool_result`; `spilled` reads `tool-results/<tool_use id>.txt`.
    static func items(record: [String: Any], at offset: Int, result: [String: Any]?,
                      spilled: (String) -> Data?) -> [ControlTranscriptItem] {
        guard let uuid = record["uuid"] as? String else { return [] }
        let made: [ControlTranscriptItem]
        switch record["type"] as? String {
        case "user": made = userItems(record)
        case "assistant": made = assistantItems(record, result: result, spilled: spilled)
        case "system": made = systemItems(record)
        case "attachment": made = hookItems(record)
        default: made = []
        }
        let time = record["timestamp"] as? String
        return made.enumerated().map { index, item in
            var item = item
            item.uuid = index == 0 ? uuid : "\(uuid)#\(index)"
            item.at = offset
            item.time = time
            return capped(item)
        }
    }

    // MARK: - Records

    private static func item(_ kind: String, text: String? = nil) -> ControlTranscriptItem {
        var item = ControlTranscriptItem(kind: kind, uuid: "", at: 0)
        item.text = text
        return item
    }

    private static func userItems(_ record: [String: Any]) -> [ControlTranscriptItem] {
        if record["isMeta"] as? Bool == true { return [] }
        let content = (record["message"] as? [String: Any])?["content"]
        let blocks = content.flatMap { $0 as? String }.map { [["type": "text", "text": $0]] } ?? content as? [[String: Any]] ?? []
        if record["isCompactSummary"] as? Bool == true {
            return [item("compactSummary", text: blocks.compactMap { $0["text"] as? String }.joined(separator: "\n"))]
        }
        return blocks.flatMap { block -> [ControlTranscriptItem] in
            switch block["type"] as? String {
            case "text": return textItems(block["text"] as? String ?? "", record: record)
            case "image": return [imageItem(block)]
            default: return []
            }
        }
    }

    private static func textItems(_ text: String, record: [String: Any]) -> [ControlTranscriptItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[Request interrupted") { return [item("interrupted")] }
        if trimmed.hasPrefix("<task-notification>") { return [item("taskNotification", text: trimmed)] }
        if let tagged = tagItems(text) { return tagged }
        let typed = stripping("system-reminder", from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return [] }
        var user = item("user", text: typed)
        user.promptSource = record["promptSource"] as? String
        user.origin = (record["origin"] as? [String: Any])?["kind"] as? String
        return [user]
    }

    /// Slash-command, local-command and `!` shell wrappers; nil when the text carries none of them.
    private static func tagItems(_ text: String) -> [ControlTranscriptItem]? {
        if let name = tag("command-name", in: text) {
            var command = item("command")
            command.name = name.hasPrefix("/") ? String(name.dropFirst()) : name
            command.args = tag("command-args", in: text).flatMap { $0.isEmpty ? nil : $0 }
            return [command]
        }
        if let input = tag("bash-input", in: text) { return [item("bash", text: input)] }
        for pair in [("local-command-stdout", "local-command-stderr"), ("bash-stdout", "bash-stderr")] {
            let out = tag(pair.0, in: text), err = tag(pair.1, in: text)
            if out != nil || err != nil {
                return [item("commandOutput", text: [out, err].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"))]
            }
        }
        return nil
    }

    private static func imageItem(_ block: [String: Any]) -> ControlTranscriptItem {
        let source = block["source"] as? [String: Any]
        let data = source?["data"] as? String ?? ""
        var image = item("image")
        image.mediaType = source?["media_type"] as? String
        image.bytes = data.utf8.count / 4 * 3 - data.suffix(2).filter { $0 == "=" }.count
        image.data = data.isEmpty ? nil : data
        return image
    }

    private static func assistantItems(_ record: [String: Any], result: [String: Any]?,
                                       spilled: (String) -> Data?) -> [ControlTranscriptItem] {
        let message = record["message"] as? [String: Any]
        let blocks = message?["content"] as? [[String: Any]] ?? []
        if record["isApiErrorMessage"] as? Bool == true {
            return [item("error", text: blocks.compactMap { $0["text"] as? String }.joined(separator: "\n"))]
        }
        var made: [ControlTranscriptItem] = blocks.compactMap { block in
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.isEmpty else { return nil }
                var item = item("text", text: text)
                item.message = message?["id"] as? String
                return item
            case "thinking":
                var item = item("thinking")
                item.durationMs = record["thinkingDurationMs"] as? Int
                return item
            case "tool_use": return toolItem(block, result: result, spilled: spilled)
            default: return nil
            }
        }
        if record["isAbortedMidStream"] as? Bool == true { made.append(item("interrupted")) }
        return made
    }

    private static func systemItems(_ record: [String: Any]) -> [ControlTranscriptItem] {
        let content = record["content"] as? String
        switch record["subtype"] as? String {
        case "compact_boundary":
            var compact = item("compact")
            compact.trigger = (record["compactMetadata"] as? [String: Any])?["trigger"] as? String
            return [compact]
        case "informational" where record["level"] as? String == "warning", "away_summary":
            var notice = item("notice", text: content)
            notice.level = record["level"] as? String
            return [notice]
        case "stop_hook_summary":
            let errors = record["hookErrors"] as? [String] ?? []
            return errors.isEmpty ? [] : [item("hook", text: errors.joined(separator: "\n"))]
        // 2.1.329 writes a slash command and its output as `local_command` system records, not user records.
        case "local_command": return content.flatMap(tagItems) ?? []
        default: return []
        }
    }

    private static func hookItems(_ record: [String: Any]) -> [ControlTranscriptItem] {
        guard let attachment = record["attachment"] as? [String: Any],
              (attachment["type"] as? String)?.hasPrefix("hook_") == true,
              let exitCode = attachment["exitCode"] as? Int, exitCode != 0
        else { return [] }
        let body = ["stderr", "stdout", "content"].lazy.compactMap { attachment[$0] as? String }.first { !$0.isEmpty } ?? ""
        let name = attachment["hookName"] as? String
        return [item("hook", text: name.map { "\($0): \(body)" } ?? body)]
    }

    // MARK: - Tools

    private static func toolItem(_ block: [String: Any], result: [String: Any]?, spilled: (String) -> Data?) -> ControlTranscriptItem {
        let id = block["id"] as? String ?? ""
        let name = block["name"] as? String ?? ""
        let input = block["input"] as? [String: Any] ?? [:]
        var tool = item("tool")
        tool.id = id
        tool.name = name
        tool.arg = shortArgument(name: name, input: input)
        if fileTools.contains(name) { tool.file = input["file_path"] as? String }
        if readOnlyTools.contains(name) { tool.readOnly = true }
        if name == "Agent" || name == "Task" {
            tool.agentType = input["subagent_type"] as? String
            tool.agentName = input["name"] as? String
        }
        let resultBlocks = (result?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        guard let answer = resultBlocks.first(where: { $0["type"] as? String == "tool_result" && $0["tool_use_id"] as? String == id })
        else {
            tool.running = true
            tool.mark = "running"
            return tool
        }
        let isError = answer["is_error"] as? Bool == true
        var text = outputText(answer["content"])
        var clipped = false
        if text.hasPrefix("<persisted-output>"), let data = spilled(id) {
            // the extra bytes let a scalar cut by the prefix decode to U+FFFD past the clip point, where clip drops it
            text = String(decoding: data.prefix(clipBytes + 4), as: UTF8.self)
            clipped = data.count > clipBytes
        }
        let (output, cut) = clip(text, clipBytes)
        tool.output = output
        tool.clipped = clipped || cut ? true : nil
        if isError {
            tool.isError = true
            if text.hasPrefix(rejectionPrefix) { tool.rejected = true }
        }
        tool.exitCode = exitCode(text)
        applyChange(result?["toolUseResult"] as? [String: Any], to: &tool)
        if tool.mark == nil || isError { tool.mark = mark(name: name, isError: isError, exitCode: tool.exitCode) }
        return tool
    }

    /// Edit/MultiEdit `structuredPatch` and Write `create` set the patch and the `+N −M` mark.
    private static func applyChange(_ change: [String: Any]?, to tool: inout ControlTranscriptItem) {
        let hunks = (change?["structuredPatch"] as? [[String: Any]] ?? []).map { hunk in
            ControlTranscriptHunk(oldStart: hunk["oldStart"] as? Int ?? 0, oldLines: hunk["oldLines"] as? Int ?? 0,
                                  newStart: hunk["newStart"] as? Int ?? 0, newLines: hunk["newLines"] as? Int ?? 0,
                                  lines: hunk["lines"] as? [String] ?? [])
        }
        if !hunks.isEmpty {
            let lines = hunks.flatMap(\.lines)
            tool.mark = "+\(lines.filter { $0.hasPrefix("+") }.count) \u{2212}\(lines.filter { $0.hasPrefix("-") }.count)"
            var budget = clipBytes
            var kept: [ControlTranscriptHunk] = []
            for var hunk in hunks where budget > 0 {
                let fitting = hunk.lines.prefix { line in
                    budget -= line.utf8.count + 1
                    return budget >= 0
                }
                if fitting.count < hunk.lines.count { tool.clipped = true }
                hunk.lines = Array(fitting)
                kept.append(hunk)
            }
            if kept.count < hunks.count { tool.clipped = true }
            tool.patch = kept
            tool.output = nil
        } else if change?["type"] as? String == "create", let content = change?["content"] as? String {
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            tool.mark = "+\(lines.count - (content.hasSuffix("\n") ? 1 : 0))"
        }
    }

    private static func mark(name: String, isError: Bool, exitCode: Int?) -> String? {
        switch name {
        case "Bash": return isError ? exitCode.map { "exit \($0)" } ?? "error" : "ok"
        case "Agent", "Task": return isError ? "error" : "done"
        default: return isError ? "error" : nil
        }
    }

    private static func shortArgument(name: String, input: [String: Any]) -> String? {
        func string(_ key: String) -> String? { (input[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        switch name {
        case "Bash": return string("description") ?? string("command")
        case _ where fileTools.contains(name): return string("file_path").flatMap { $0.split(separator: "/").last.map(String.init) }
        case "Agent", "Task": return string("description")
        case "WebFetch": return string("url").flatMap { URL(string: $0)?.host }
        case _ where name.hasPrefix("mcp__"):
            // shortcut: JSONSerialization drops key order, so "first" is the first key sorted; upgrade if it reads oddly
            guard let key = input.keys.min() else { return nil }
            return input[key].map { $0 as? String ?? "\($0)" }
        default: return nil
        }
    }

    private static func outputText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let blocks = content as? [[String: Any]] ?? []
        return blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func exitCode(_ text: String) -> Int? {
        guard text.hasPrefix("Exit code ") else { return nil }
        return Int(text.dropFirst("Exit code ".count).prefix { $0.isASCII && $0.isNumber })
    }

    // MARK: - Text

    /// The text inside the first `<name>…</name>`, nil when the tag is absent.
    private static func tag(_ name: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(name)>"),
              let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    private static func stripping(_ name: String, from text: String) -> String {
        var text = text
        while let open = text.range(of: "<\(name)>") {
            let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex)
            text.removeSubrange(open.lowerBound..<(close?.upperBound ?? text.endIndex))
        }
        return text
    }

    /// At most `limit` UTF-8 bytes, cut on a character boundary; true when it cut.
    static func clip(_ text: String, _ limit: Int) -> (String, Bool) {
        guard text.utf8.count > limit else { return (text, false) }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: max(0, limit))
        while end > text.startIndex, end.samePosition(in: text) == nil { text.utf8.formIndex(before: &end) }
        return (String(text[..<end]), true)
    }

    /// Shrinks the item until it encodes within `itemCap`: an image loses its data, then the longest text field is cut.
    static func capped(_ item: ControlTranscriptItem) -> ControlTranscriptItem {
        var item = item
        let encoder = JSONEncoder()
        while let size = try? encoder.encode(item).count, size > itemCap {
            if item.data != nil {
                item.data = nil
                continue
            }
            let excess = size - itemCap
            let fields: [WritableKeyPath<ControlTranscriptItem, String?>] = [\.text, \.output, \.arg, \.args]
            guard let longest = fields.max(by: { (item[keyPath: $0]?.utf8.count ?? 0) < (item[keyPath: $1]?.utf8.count ?? 0) }),
                  let value = item[keyPath: longest], !value.isEmpty
            else {
                item.patch = nil
                item.clipped = true
                break
            }
            item[keyPath: longest] = clip(value, value.utf8.count - excess).0
            item.clipped = true
        }
        return item
    }
}
