import Dispatch
import Foundation

public struct ClaudeTranscriptRequest: Sendable, Equatable {
    public var sessionID: String
    public var after: Int?
    public var before: Int?
    /// The Claude session id the caller holds; only compared.
    public var held: String?
    public var maxBytes: Int

    public init(sessionID: String, after: Int? = nil, before: Int? = nil, held: String? = nil, maxBytes: Int = ClaudeTranscript.pageBudget) {
        self.sessionID = sessionID
        self.after = after
        self.before = before
        self.held = held
        self.maxBytes = maxBytes
    }
}

/// One `session.transcript` page; the cursor contract lives in control-api.md.
public struct ClaudeTranscriptPage: Sendable, Equatable {
    public var transcript: String
    public var size: Int
    public var start: Int
    public var next: Int
    public var reset: Bool
    public var items: [ControlTranscriptItem]
    public var pending: [ControlTranscriptPending]
    public var meta: ControlTranscriptMeta
    public var commands: [ControlTranscriptCommand]?
    public var skipped: Int

    public init(transcript: String, size: Int, start: Int, next: Int, reset: Bool = false, items: [ControlTranscriptItem] = [],
                pending: [ControlTranscriptPending] = [], meta: ControlTranscriptMeta = ControlTranscriptMeta(),
                commands: [ControlTranscriptCommand]? = nil, skipped: Int = 0) {
        self.transcript = transcript
        self.size = size
        self.start = start
        self.next = next
        self.reset = reset
        self.items = items
        self.pending = pending
        self.meta = meta
        self.commands = commands
        self.skipped = skipped
    }
}

public enum ClaudeTranscriptError: Error, Equatable, CustomStringConvertible {
    case notFound

    public var description: String { "transcript not found" }
}

/// Pages of `<claudeDirectory>/projects/*/<id>.jsonl`, each file indexed once and extended per poll.
public final class ClaudeTranscript: @unchecked Sendable {
    public static let pageBudget = 49152, clipBytes = ClaudeTranscriptItems.clipBytes, itemCap = ClaudeTranscriptItems.itemCap

    private static let instances = Locked<[String: ClaudeTranscript]>([:])

    public static func instance(directory: String) -> ClaudeTranscript {
        instances.withLock { all in
            if let known = all[directory] { return known }
            let made = ClaudeTranscript(claudeDirectory: directory)
            all[directory] = made
            return made
        }
    }

    private struct Cache {
        var paths: [String: String] = [:]
        // least recently used first; each index has its own lock so one session's first scan never stalls another's poll
        var indexes: [(path: String, index: Locked<ClaudeTranscriptIndex>)] = []
    }

    let claudeDirectory: String
    let cacheLimit: Int
    private let cache = Locked(Cache())
    private let scanCount = Locked(0)

    /// How many indexes were built from scratch.
    var scans: Int { scanCount.withLock { $0 } }

    public init(claudeDirectory: String, cacheLimit: Int = 8) {
        self.claudeDirectory = claudeDirectory
        self.cacheLimit = cacheLimit
    }

    /// Blocking file reads; never call it on the main thread.
    public func page(_ request: ClaudeTranscriptRequest) -> Result<ClaudeTranscriptPage, ClaudeTranscriptError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let id = SessionLauncher.plainSessionID(request.sessionID), let path = path(for: id) else { return .failure(.notFound) }
        let sessionDirectory = String(path.dropLast(".jsonl".count))
        let built = index(path, keepsSidechains: false).withLock { index -> (ClaudeTranscriptPage, [String: String?])? in
            guard refresh(&index), let reader = RecordReader(index: index, sessionDirectory: sessionDirectory) else { return nil }
            return PageBuilder(reader: reader).page(request, id: id)
        }
        guard let (found, agents) = built else {
            _ = cache.withLock { $0.paths.removeValue(forKey: id) }
            return .failure(.notFound)
        }
        var page = found
        if !agents.isEmpty { page.pending += subagentPending(agents, sessionDirectory: sessionDirectory) }
        return .success(page)
    }

    private func path(for id: String) -> String? {
        let fileManager = FileManager.default
        if let known = cache.withLock({ $0.paths[id] }), fileManager.fileExists(atPath: known) { return known }
        let projects = (claudeDirectory as NSString).appendingPathComponent("projects")
        let found = ((try? fileManager.contentsOfDirectory(atPath: projects)) ?? []).sorted().lazy
            .map { "\(projects)/\($0)/\(id).jsonl" }
            .first { fileManager.fileExists(atPath: $0) }
        cache.withLock { $0.paths[id] = found }
        return found
    }

    private func index(_ path: String, keepsSidechains: Bool) -> Locked<ClaudeTranscriptIndex> {
        cache.withLock { cache in
            if let at = cache.indexes.firstIndex(where: { $0.path == path }) {
                let entry = cache.indexes.remove(at: at)
                cache.indexes.append(entry)
                return entry.index
            }
            scanCount.withLock { $0 += 1 }
            let made = Locked(ClaudeTranscriptIndex(path: path, keepsSidechains: keepsSidechains))
            cache.indexes.append((path, made))
            if cache.indexes.count > cacheLimit { cache.indexes.removeFirst() }
            return made
        }
    }

    /// Extends the index, rebuilding it when the file shrank or changed its head; false when the file is gone.
    private func refresh(_ index: inout ClaudeTranscriptIndex) -> Bool {
        if index.extend() { return true }
        scanCount.withLock { $0 += 1 }
        index = ClaudeTranscriptIndex(path: index.path, keepsSidechains: index.keepsSidechains)
        return index.extend()
    }

    /// Open calls in `subagents/agent-<id>.jsonl` whose `.meta.json` names an open Agent call; `agents` maps its id to its `name`.
    private func subagentPending(_ agents: [String: String?], sessionDirectory: String) -> [ControlTranscriptPending] {
        let directory = sessionDirectory + "/subagents"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []).sorted()
        return files.flatMap { file -> [ControlTranscriptPending] in
            guard file.hasPrefix("agent-"), file.hasSuffix(".meta.json"),
                  let agent = SessionLauncher.plainSessionID(String(file.dropFirst("agent-".count).dropLast(".meta.json".count))),
                  let data = FileManager.default.contents(atPath: "\(directory)/\(file)"),
                  let meta = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let call = meta["toolUseId"] as? String, let agentName = agents[call]
            else { return [] }
            return index("\(directory)/agent-\(agent).jsonl", keepsSidechains: true).withLock { index in
                guard refresh(&index), let reader = RecordReader(index: index, sessionDirectory: sessionDirectory) else { return [] }
                return reader.openCalls { _ in true }.compactMap { call in
                    RecordReader.isAgent(call) ? nil : reader.pending(call, source: agent, agentType: meta["agentType"] as? String, agentName: agentName)
                }
            }
        }
    }
}

/// Reads indexed records back from the file by offset.
private final class RecordReader {
    typealias OpenCall = (id: String, record: Int, block: [String: Any])

    static func isAgent(_ call: OpenCall) -> Bool { ["Agent", "Task"].contains(call.block["name"] as? String) }

    let index: ClaudeTranscriptIndex
    let sessionDirectory: String
    private let handle: FileHandle
    private var objects: [Int: [String: Any]] = [:]

    init?(index: ClaudeTranscriptIndex, sessionDirectory: String) {
        guard let handle = FileHandle(forReadingAtPath: index.path) else { return nil }
        self.index = index
        self.sessionDirectory = sessionDirectory
        self.handle = handle
    }

    deinit { try? handle.close() }

    func object(_ record: Int) -> [String: Any]? {
        if let known = objects[record] { return known }
        let entry = index.records[record]
        guard !entry.oversized, (try? handle.seek(toOffset: UInt64(entry.offset))) != nil,
              let data = try? handle.read(upToCount: entry.length),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        objects[record] = object
        return object
    }

    /// The first `clipBytes` and a few more of a spilled `tool-results/<id>.txt`, so the clip can tell it was cut.
    func spilled(_ id: String) -> Data? {
        guard let name = SessionLauncher.plainSessionID(id),
              let file = FileHandle(forReadingAtPath: "\(sessionDirectory)/tool-results/\(name).txt")
        else { return nil }
        defer { try? file.close() }
        return try? file.read(upToCount: ClaudeTranscript.clipBytes + 8)
    }

    func openCalls(where keep: (Int) -> Bool) -> [OpenCall] {
        index.openCalls.filter { keep($0.value) }.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.compactMap { id, record in
            let content = (object(record)?["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            guard let block = content.first(where: { $0["type"] as? String == "tool_use" && $0["id"] as? String == id }) else { return nil }
            return (id, record, block)
        }
    }

    func pending(_ call: OpenCall, source: String, agentType: String? = nil, agentName: String? = nil) -> ControlTranscriptPending {
        let input = call.block["input"].flatMap(JSONValue.init(any:))
        let fits = input.flatMap { try? JSONEncoder().encode($0).count }.map { $0 <= ClaudeTranscript.itemCap } ?? true
        return ControlTranscriptPending(id: call.id, uuid: index.records[call.record].uuid ?? "", source: source, agentType: agentType,
                                        agentName: agentName, name: call.block["name"] as? String ?? "",
                                        input: fits ? input : nil, clipped: fits ? nil : true)
    }
}

/// One page over the active records: budget walk, reset, re-emission, text groups, main pending and commands.
private final class PageBuilder {
    private let reader: RecordReader
    private var index: ClaudeTranscriptIndex { reader.index }
    private let active: [Int]
    private var rawItems: [Int: [ControlTranscriptItem]] = [:]
    private lazy var messageMembers: [String: [Int]] = active.reduce(into: [:]) { members, record in
        if let message = index.records[record].messageID { members[message, default: []].append(record) }
    }
    private let encoder = JSONEncoder()

    init(reader: RecordReader) {
        self.reader = reader
        active = reader.index.activeRecords()
    }

    func page(_ request: ClaudeTranscriptRequest, id: String) -> (ClaudeTranscriptPage, [String: String?]) {
        let budget = min(request.maxBytes, ClaudeTranscript.pageBudget)
        var page = ClaudeTranscriptPage(transcript: id, size: index.size, start: index.end, next: index.end,
                                        meta: index.meta, skipped: index.skipped)
        page.reset = request.held.map { $0 != id } == true || request.after.map { $0 > index.size || leftChain(before: $0) } == true
        if let after = request.after, !page.reset {
            (page.items, page.next) = forward(from: after, budget: budget)
            page.start = after
            if let skillsAt = index.meta.skillsAt, (after..<page.next).contains(skillsAt) { page.commands = commands() }
        } else {
            let before = page.reset ? nil : request.before
            page.items = backward(before: before ?? index.end + 1, budget: budget)
            page.start = page.items.first?.at ?? before ?? index.end
            page.next = before ?? index.end
            if before == nil { page.commands = commands() }
        }
        var agents: [String: String?] = [:]
        for call in reader.openCalls(where: isActive) {
            if RecordReader.isAgent(call) {
                agents[call.id] = (call.block["input"] as? [String: Any])?["name"] as? String
            } else {
                page.pending.append(reader.pending(call, source: "main"))
            }
        }
        return (page, agents)
    }

    // MARK: - Walks

    private func forward(from after: Int, budget: Int) -> ([ControlTranscriptItem], Int) {
        var items: [ControlTranscriptItem] = [], emitted = Set<String>(), used = 1, next = index.end
        for record in active[firstActive(atOrAfter: after)...] {
            let made = (reemitted(by: record, after: after) + self.items(of: record, after: after)).filter { !emitted.contains($0.uuid) }
            let cost = made.reduce(0) { $0 + size($1) + 1 }
            if !items.isEmpty, used + cost > budget {
                next = index.records[record].offset
                break
            }
            used += cost
            items += made
            emitted.formUnion(made.map(\.uuid))
        }
        return (items, next)
    }

    private func backward(before: Int, budget: Int) -> [ControlTranscriptItem] {
        var items: [ControlTranscriptItem] = [], used = 1
        for record in active[..<firstActive(atOrAfter: before)].reversed() {
            let made = self.items(of: record, after: nil)
            let cost = made.reduce(0) { $0 + size($1) + 1 }
            if !items.isEmpty, used + cost > budget { break }
            used += cost
            items.insert(contentsOf: made, at: 0)
        }
        return items
    }

    /// True when the last item-bearing record before `after` left the active records (rewind, retry).
    private func leftChain(before after: Int) -> Bool {
        var record = firstRecord(atOrAfter: after) - 1
        while record >= 0 {
            let entry = index.records[record]
            if entry.uuid != nil, !entry.sidechain {
                if isActive(record) { return false }
                if !raw(record).isEmpty { return true }
            }
            record -= 1
        }
        return false
    }

    // MARK: - Items

    /// The record's items with text folded into its message's first text item; on an `after` page a later block of a
    /// message that began before `after` yields that first item again.
    private func items(of record: Int, after: Int?) -> [ControlTranscriptItem] {
        raw(record).compactMap { item in
            guard item.kind == "text", let message = item.message else { return item }
            guard let head = group(message), head.uuid != item.uuid else { return group(message) }
            if let after, head.at < after, index.records[record].offset >= after { return head }
            return nil
        }
    }

    /// Tool items whose call sits before `after` and whose result is this record.
    private func reemitted(by record: Int, after: Int) -> [ControlTranscriptItem] {
        (index.closers[record] ?? []).flatMap { id -> [ControlTranscriptItem] in
            guard let call = index.toolUses[id], index.records[call].offset < after, isActive(call) else { return [] }
            return raw(call).filter { $0.kind == "tool" && $0.id == id }
        }
    }

    /// The message's text blocks merged into its first text item.
    private func group(_ message: String) -> ControlTranscriptItem? {
        let texts = (messageMembers[message] ?? []).flatMap { raw($0).filter { $0.kind == "text" && $0.message == message } }
        guard var head = texts.first else { return nil }
        guard texts.count > 1 else { return head }
        head.text = texts.compactMap(\.text).joined(separator: "\n\n")
        if texts.contains(where: { $0.clipped == true }) { head.clipped = true }
        return ClaudeTranscriptItems.capped(head)
    }

    private func raw(_ record: Int) -> [ControlTranscriptItem] {
        if let known = rawItems[record] { return known }
        let entry = index.records[record]
        var made: [ControlTranscriptItem] = []
        if entry.oversized {
            if let uuid = entry.uuid {
                var item = ControlTranscriptItem(kind: "oversized", uuid: uuid, at: entry.offset)
                item.bytes = entry.length
                made = [item]
            }
        } else if let object = reader.object(record) {
            made = decoded(object, at: entry.offset)
        }
        rawItems[record] = made
        return made
    }

    // shortcut: one result record per tool record, as Claude Code writes one tool_use per record; upgrade if that changes
    private func decoded(_ object: [String: Any], at offset: Int) -> [ControlTranscriptItem] {
        let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        guard let id = content.first(where: { $0["type"] as? String == "tool_use" })?["id"] as? String,
              let result = index.resultIndex(forToolUse: id)
        else { return ClaudeTranscriptItems.items(record: object, at: offset, result: nil, spilled: reader.spilled) }
        guard index.records[result].oversized else {
            return ClaudeTranscriptItems.items(record: object, at: offset, result: reader.object(result), spilled: reader.spilled)
        }
        // a result too big to read still closes its call
        let stub: [String: Any] = ["message": ["content": [["type": "tool_result", "tool_use_id": id, "content": ""]]]]
        return ClaudeTranscriptItems.items(record: object, at: offset, result: stub, spilled: reader.spilled).map { item in
            var item = item
            if item.kind == "tool", item.id == id { item.clipped = true }
            return item
        }
    }

    private func commands() -> [ControlTranscriptCommand] {
        let listings = index.skillListings.compactMap { record -> (isInitial: Bool, names: [String], content: String)? in
            guard let attachment = reader.object(record)?["attachment"] as? [String: Any] else { return nil }
            return (attachment["isInitial"] as? Bool ?? false, attachment["names"] as? [String] ?? [], attachment["content"] as? String ?? "")
        }
        let builtins = ClaudeCommandCatalog.builtins
        let taken = Set(builtins.map(\.name))
        return builtins + ClaudeCommandCatalog.skills(listings: listings).filter { !taken.contains($0.name) }
    }

    // MARK: - Lookup

    private func size(_ item: ControlTranscriptItem) -> Int { (try? encoder.encode(item).count) ?? 0 }

    private func isActive(_ record: Int) -> Bool {
        let at = lowerBound(active.count) { active[$0] < record }
        return at < active.count && active[at] == record
    }

    private func firstActive(atOrAfter offset: Int) -> Int { lowerBound(active.count) { index.records[active[$0]].offset < offset } }

    private func firstRecord(atOrAfter offset: Int) -> Int { lowerBound(index.records.count) { index.records[$0].offset < offset } }

    private func lowerBound(_ count: Int, _ below: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if below(mid) { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
