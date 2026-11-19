import Foundation

/// The index fields of one transcript line; record bodies are reread from the file by offset.
struct TranscriptRecord: Equatable {
    var uuid: String?
    var parent: String?
    var logicalParent: String?
    var offset: Int
    var length: Int
    var type: String
    var subtype: String?
    var sidechain: Bool
    var messageID: String?
    var oversized: Bool
}

/// A Claude Code transcript JSONL indexed once and extended per poll; only whole lines count.
final class ClaudeTranscriptIndex {
    static let chunk = 1 << 20
    static let lineWindow = 4 << 20
    static let prefixLength = 4096

    let path: String
    private(set) var end = 0
    private(set) var size = 0
    private(set) var records: [TranscriptRecord] = []
    private(set) var skipped = 0
    private(set) var openCalls: [String: Int] = [:]
    private(set) var meta = ControlTranscriptMeta()

    private var prefix = Data()
    private var byUUID: [String: Int] = [:]
    private var results: [String: Int] = [:]
    private var customTitle: String?
    private var aiTitle: String?
    // nil holds the place of a content-less enqueue, which a later dequeue takes
    private var queue: [String?] = []
    private var chainCache: (count: Int, chain: [Int])?

    init(path: String) { self.path = path }

    /// Indexes lines appended since the last call; false when the file shrank, changed its head or is unreadable.
    func extend() -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), Int(fileSize) >= size else { return false }
        if !prefix.isEmpty {
            try? handle.seek(toOffset: 0)
            guard (try? handle.read(upToCount: prefix.count)) == prefix else { return false }
        }
        if prefix.count < Self.prefixLength, Int(fileSize) > prefix.count {
            try? handle.seek(toOffset: 0)
            prefix = (try? handle.read(upToCount: min(Self.prefixLength, Int(fileSize)))) ?? prefix
        }
        size = Int(fileSize)
        scan(handle)
        return true
    }

    func resultIndex(forToolUse id: String) -> Int? { results[id] }

    /// The record indices from the root to the leaf, the last non-sidechain record with a uuid.
    func activeChain() -> [Int] {
        if let cache = chainCache, cache.count == records.count { return cache.chain }
        var chain: [Int] = []
        var visited = Set<Int>()
        var next = records.lastIndex { $0.uuid != nil && !$0.sidechain }
        while let index = next, visited.insert(index).inserted {
            let record = records[index]
            if !record.sidechain { chain.append(index) }
            next = (record.parent ?? record.logicalParent).flatMap { byUUID[$0] }
        }
        chain.reverse()
        chainCache = (records.count, chain)
        return chain
    }

    private func scan(_ handle: FileHandle) {
        try? handle.seek(toOffset: UInt64(end))
        var buffer: [UInt8] = []
        var lineStart = end
        // an oversized line is streamed through a field scanner to its newline instead of being held
        var skipping: (fields: TopLevelFieldScanner, length: Int)?
        while let data = try? handle.read(upToCount: Self.chunk), !data.isEmpty {
            buffer.append(contentsOf: data)
            var from = 0
            while let newline = buffer[from...].firstIndex(of: 0x0A) {
                if var skip = skipping {
                    skip.fields.feed(buffer[from..<newline])
                    skip.length += newline - from
                    addOversized(skip.fields, offset: lineStart, length: skip.length)
                    lineStart += skip.length + 1
                    skipping = nil
                } else {
                    add(line: buffer[from..<newline], offset: lineStart)
                    lineStart += newline - from + 1
                }
                from = newline + 1
            }
            buffer.removeFirst(from)
            if skipping == nil, buffer.count > Self.lineWindow { skipping = (TopLevelFieldScanner(), 0) }
            if var skip = skipping {
                skip.fields.feed(buffer)
                skip.length += buffer.count
                skipping = skip
                buffer.removeAll(keepingCapacity: true)
            }
        }
        end = lineStart
    }

    private func add(line: ArraySlice<UInt8>, offset: Int) {
        guard !line.isEmpty else { return }
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
            skipped += 1
            return
        }
        let message = object["message"] as? [String: Any]
        append(TranscriptRecord(
            uuid: object["uuid"] as? String, parent: object["parentUuid"] as? String,
            logicalParent: object["logicalParentUuid"] as? String, offset: offset, length: line.count,
            type: object["type"] as? String ?? "", subtype: object["subtype"] as? String,
            sidechain: object["isSidechain"] as? Bool ?? false, messageID: message?["id"] as? String, oversized: false
        ))
        fold(object, message: message, index: records.count - 1)
    }

    private func addOversized(_ fields: TopLevelFieldScanner, offset: Int, length: Int) {
        append(TranscriptRecord(
            uuid: fields.strings["uuid"], parent: fields.strings["parentUuid"], logicalParent: fields.strings["logicalParentUuid"],
            offset: offset, length: length, type: "", subtype: nil, sidechain: fields.sidechain, messageID: nil, oversized: true
        ))
        // a tool_result too big to parse closes the calls of the assistant record it names
        guard !fields.sidechain, let source = fields.strings["sourceToolAssistantUUID"].flatMap({ byUUID[$0] }) else { return }
        for (id, call) in openCalls where call == source {
            results[id] = records.count - 1
            openCalls[id] = nil
        }
    }

    private func append(_ record: TranscriptRecord) {
        if let uuid = record.uuid { byUUID[uuid] = records.count }
        records.append(record)
    }

    private func fold(_ object: [String: Any], message: [String: Any]?, index: Int) {
        let sidechain = object["isSidechain"] as? Bool ?? false
        switch object["type"] as? String {
        case "custom-title": customTitle = object["customTitle"] as? String ?? customTitle
        case "ai-title": aiTitle = object["aiTitle"] as? String ?? aiTitle
        case "last-prompt": meta.lastPrompt = object["lastPrompt"] as? String ?? meta.lastPrompt
        case "permission-mode": meta.permissionMode = object["permissionMode"] as? String ?? meta.permissionMode
        case "agent-name": meta.agentName = object["agentName"] as? String ?? meta.agentName
        case "continued-in": meta.continuedIn = object["continuedInSessionId"] as? String ?? meta.continuedIn
        case "pr-link":
            meta.pr = ControlTranscriptPR(prNumber: object["prNumber"] as? Int, prRepository: object["prRepository"] as? String,
                                          prUrl: object["prUrl"] as? String)
        case "queue-operation": foldQueue(object)
        case "attachment" where !sidechain:
            if (object["attachment"] as? [String: Any])?["type"] as? String == "skill_listing" { meta.skillsAt = records[index].offset }
        case "assistant" where !sidechain:
            if let model = message?["model"] as? String, model != "<synthetic>" {
                meta.model = model
                meta.effort = object["effort"] as? String ?? meta.effort
            }
            for block in Self.blocks(message, type: "tool_use") {
                guard let id = block["id"] as? String else { continue }
                if results[id] == nil { openCalls[id] = index }
                if block["name"] as? String == "TodoWrite", let todos = (block["input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                    let folded = todos.compactMap { todo in
                        (todo["content"] as? String).map {
                            ControlTranscriptTodo(content: $0, status: todo["status"] as? String ?? "pending",
                                                  activeForm: todo["activeForm"] as? String)
                        }
                    }
                    meta.todos = folded.isEmpty ? nil : folded
                }
            }
        case "user" where !sidechain:
            for block in Self.blocks(message, type: "tool_result") {
                guard let id = block["tool_use_id"] as? String else { continue }
                results[id] = index
                openCalls[id] = nil
            }
        default: break
        }
        meta.title = customTitle ?? aiTitle
    }

    // Claude Code 2.1.329 writes the queue only as these operations; its queued_command attachment is the delivery.
    private func foldQueue(_ object: [String: Any]) {
        let content = object["content"] as? String
        switch object["operation"] as? String {
        case "enqueue": queue.append(content)
        case "dequeue": if !queue.isEmpty { queue.removeFirst() }
        case "remove", "popAll":
            if let at = queue.firstIndex(where: { $0 == content }) ?? queue.firstIndex(where: { $0 == nil }) { queue.remove(at: at) }
        default: break
        }
        let queued = queue.compactMap { $0 }
        meta.queued = queued.isEmpty ? nil : queued
    }

    private static func blocks(_ message: [String: Any]?, type: String) -> [[String: Any]] {
        (message?["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == type }
    }
}

/// The short top-level string fields and `isSidechain` of one JSON object fed in pieces; nested keys never match.
struct TopLevelFieldScanner {
    private(set) var strings: [String: String] = [:]
    private(set) var sidechain = false
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var expectsKey = true
    private var key: String?
    // nil while the current string is nested or too long to be an id
    private var token: [UInt8]?

    mutating func feed(_ bytes: some Sequence<UInt8>) {
        for byte in bytes {
            if inString {
                if escaped || byte != 0x22 {
                    escaped = !escaped && byte == 0x5C
                    if token != nil { token = token!.count < 256 ? token! + [byte] : nil }
                } else {
                    inString = false
                    closeString()
                }
                continue
            }
            switch byte {
            case 0x22: inString = true; token = depth == 1 ? [] : nil
            case 0x7B, 0x5B: depth += 1
            case 0x7D, 0x5D: depth -= 1
            case 0x3A where depth == 1: expectsKey = false
            case 0x2C where depth == 1: expectsKey = true; key = nil
            case 0x74 where depth == 1 && !expectsKey && key == "isSidechain": sidechain = true; key = nil
            default: break
            }
        }
    }

    private mutating func closeString() {
        guard let token, depth == 1 else { return }
        let text = String(decoding: token, as: UTF8.self)
        if expectsKey { key = text } else if let key { strings[key] = text }
        key = expectsKey ? key : nil
    }
}
