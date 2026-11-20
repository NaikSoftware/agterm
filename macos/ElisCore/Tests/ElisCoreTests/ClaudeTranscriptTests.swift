import Foundation
import Testing
@testable import ElisCore

struct ClaudeTranscriptTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ct-\(UUID().uuidString)")
        let id = "s1"
        var project: URL { root.appendingPathComponent("projects/-proj") }
        var path: String { project.appendingPathComponent("\(id).jsonl").path }
        var sessionDirectory: URL { project.appendingPathComponent(id) }
        lazy var reader = ClaudeTranscript(claudeDirectory: root.path)

        init(_ lines: [String] = []) throws {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: path))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func append(_ text: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }

        func append(lines: [String]) throws { try append(lines.map { $0 + "\n" }.joined()) }

        func write(_ name: String, _ text: String) throws {
            let url = sessionDirectory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func page(after: Int? = nil, before: Int? = nil, held: String? = nil, maxBytes: Int = ClaudeTranscript.pageBudget) throws -> ClaudeTranscriptPage {
            try reader.page(ClaudeTranscriptRequest(sessionID: id, after: after, before: before, held: held, maxBytes: maxBytes)).get()
        }

        var size: Int { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1 }
    }

    private static func quoted(_ value: String?) -> String { value.map { "\"\($0)\"" } ?? "null" }

    private func user(_ uuid: String, parent: String?, _ text: String = "hi", sidechain: Bool = false) -> String {
        #"{"type":"user","uuid":"\#(uuid)","parentUuid":\#(Self.quoted(parent)),"isSidechain":\#(sidechain),"timestamp":"T","# +
            #""message":{"role":"user","content":"\#(text)"}}"#
    }

    private func text(_ uuid: String, parent: String?, message: String, _ text: String) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","parentUuid":\#(Self.quoted(parent)),"isSidechain":false,"timestamp":"T","# +
            #""message":{"id":"\#(message)","model":"m","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    private func toolUse(_ uuid: String, parent: String?, id: String, name: String = "Bash", input: String = #"{"command":"ls"}"#,
                         message: String? = nil, sidechain: Bool = false) -> String {
        #"{"type":"assistant","uuid":"\#(uuid)","parentUuid":\#(Self.quoted(parent)),"isSidechain":\#(sidechain),"timestamp":"T","# +
            #""message":{"id":"\#(message ?? "m-\(uuid)")","model":"m","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","# +
            #""input":\#(input)}]}}"#
    }

    private func toolResult(_ uuid: String, parent: String?, id: String, _ content: String = "done") -> String {
        #"{"type":"user","uuid":"\#(uuid)","parentUuid":\#(Self.quoted(parent)),"isSidechain":false,"timestamp":"T","# +
            #""message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(content)"}]}}"#
    }

    private func skillListing(_ uuid: String, parent: String?, initial: Bool, names: [String], content: String) -> String {
        let list = names.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"attachment","uuid":"\#(uuid)","parentUuid":\#(Self.quoted(parent)),"isSidechain":false,"# +
            #""attachment":{"type":"skill_listing","isInitial":\#(initial),"names":[\#(list)],"content":"\#(content)"}}"#
    }

    private func users(_ count: Int, from start: Int = 0, parent: String? = nil, bytes: Int = 1000) -> [String] {
        (start..<start + count).map { user("u\($0)", parent: $0 == start ? parent : "u\($0 - 1)", String(repeating: "x", count: bytes)) }
    }

    private func encodedSize(_ items: [ControlTranscriptItem]) -> Int { (try? JSONEncoder().encode(items).count) ?? 0 }

    // MARK: - Pages

    @Test func tailPageFitsTheBudgetAndCarriesCommands() throws {
        let fixture = try Fixture(users(200))
        let page = try fixture.page()
        #expect(encodedSize(page.items) <= ClaudeTranscript.pageBudget)
        #expect(page.items.count > 10 && page.items.count < 200)
        #expect(page.items.last?.uuid == "u199")
        #expect(page.start == page.items.first?.at)
        #expect(page.next == fixture.size && page.size == fixture.size)
        #expect(page.transcript == "s1" && !page.reset)
        #expect(page.commands != nil)
    }

    @Test func afterPageReturnsOnlyNewRecords() throws {
        let fixture = try Fixture(users(3, bytes: 5))
        let tail = try fixture.page()
        try fixture.append(lines: [user("u3", parent: "u2", "new")])
        let poll = try fixture.page(after: tail.next)
        #expect(poll.items.map(\.uuid) == ["u3"])
        #expect(poll.items.first?.text == "new")
        #expect(poll.next == fixture.size && !poll.reset && poll.commands == nil)
    }

    @Test func appendBetweenPollsIsNeverHalfRead() throws {
        let fixture = try Fixture(users(1, bytes: 5))
        let tail = try fixture.page()
        let line = user("u1", parent: "u0", "later")
        try fixture.append(String(line.prefix(30)))
        let half = try fixture.page(after: tail.next)
        #expect(half.items.isEmpty && half.next == tail.next)
        try fixture.append(String(line.dropFirst(30)) + "\n")
        let whole = try fixture.page(after: half.next)
        #expect(whole.items.map(\.uuid) == ["u1"])
    }

    @Test func afterPageStopsAtBudgetAndNextIsBehindSize() throws {
        let fixture = try Fixture(users(1, bytes: 5))
        let tail = try fixture.page()
        try fixture.append(lines: users(100, from: 1, parent: "u0", bytes: 1024))
        var cursor = tail.next
        var seen: [String] = []
        var polls = 0
        repeat {
            let poll = try fixture.page(after: cursor)
            #expect(encodedSize(poll.items) <= ClaudeTranscript.pageBudget)
            if polls == 0 { #expect(poll.next < poll.size) }
            seen += poll.items.map(\.uuid)
            cursor = poll.next
            polls += 1
        } while cursor < fixture.size && polls < 10
        #expect(polls > 1)
        #expect(seen == (1...100).map { "u\($0)" })
    }

    @Test func beforePageWalksBackAndEchoesBefore() throws {
        let fixture = try Fixture(users(200))
        let tail = try fixture.page()
        let older = try fixture.page(before: tail.start)
        #expect(!older.items.isEmpty)
        #expect(older.items.allSatisfy { $0.at < tail.start })
        #expect(older.start == older.items.first?.at && older.next == tail.start)
        let first = try #require(tail.items.first.flatMap { Int($0.uuid.dropFirst()) })
        #expect(older.items.last?.uuid == "u\(first - 1)")
        #expect(older.commands == nil)
    }

    @Test func toolResultReEmitsTheToolItem() throws {
        let fixture = try Fixture([user("u1", parent: nil), toolUse("a1", parent: "u1", id: "t1")])
        let first = try fixture.page()
        #expect(first.items.last?.uuid == "a1" && first.items.last?.running == true)
        try fixture.append(lines: [toolResult("r1", parent: "a1", id: "t1")])
        let poll = try fixture.page(after: first.next)
        #expect(poll.items.count == 1)
        #expect(poll.items.first?.uuid == "a1" && poll.items.first?.mark == "ok" && poll.items.first?.running == nil)
    }

    @Test func laterTextBlockReEmitsTheMessage() throws {
        let fixture = try Fixture([user("u1", parent: nil), text("a1", parent: "u1", message: "m1", "Hello")])
        let first = try fixture.page()
        try fixture.append(lines: [text("a2", parent: "a1", message: "m1", "world")])
        let poll = try fixture.page(after: first.next)
        #expect(poll.items.map(\.uuid) == ["a1"])
        #expect(poll.items.first?.at == first.items.last?.at)
        #expect(poll.items.first?.text?.contains("Hello") == true && poll.items.first?.text?.contains("world") == true)
    }

    @Test func parallelToolCallsOffTheChainStillPage() throws {
        // Claude Code chains each parallel tool_use off the previous one and each result off its own call.
        let fixture = try Fixture([
            user("u1", parent: nil),
            toolUse("a1", parent: "u1", id: "t1", message: "m"),
            toolUse("a2", parent: "a1", id: "t2", message: "m"),
            toolResult("r2", parent: "a2", id: "t2"),
            toolResult("r1", parent: "a1", id: "t1"),
        ])
        let page = try fixture.page()
        #expect(page.items.compactMap(\.id) == ["t1", "t2"])
        #expect(page.items.allSatisfy { $0.running == nil })
    }

    @Test func parallelResultsOffTheChainCloseTheirCallsOnAnAfterPage() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            toolUse("a1", parent: "u1", id: "t1", message: "m"),
            toolUse("a2", parent: "a1", id: "t2", message: "m"),
            toolUse("a3", parent: "a2", id: "t3", message: "m"),
        ])
        let tail = try fixture.page()
        #expect(tail.items.filter { $0.running == true }.compactMap(\.id) == ["t1", "t2", "t3"])
        try fixture.append(lines: [
            toolResult("r3", parent: "a3", id: "t3"),
            toolResult("r2", parent: "a2", id: "t2"),
            toolResult("r1", parent: "a1", id: "t1"),
            text("x", parent: "r1", message: "m2", "done"),
        ])
        let poll = try fixture.page(after: tail.next)
        #expect(!poll.reset)
        #expect(Set(poll.items.compactMap(\.id)) == ["t1", "t2", "t3"])
        #expect(poll.items.allSatisfy { $0.running == nil })
    }

    // MARK: - Reset

    @Test func heldIDMismatchResets() throws {
        let fixture = try Fixture(users(3, bytes: 5))
        let page = try fixture.page(after: 0, held: "other")
        #expect(page.reset && page.items.map(\.uuid) == ["u0", "u1", "u2"] && page.commands != nil)
        #expect(try !fixture.page(after: page.next, held: "s1").reset)
    }

    @Test func shrunkFileResets() throws {
        let fixture = try Fixture(users(3, bytes: 5))
        let tail = try fixture.page()
        let page = try fixture.page(after: tail.size + 10)
        #expect(page.reset && page.items.count == 3)
    }

    @Test func branchSwitchResets() throws {
        let fixture = try Fixture([user("u1", parent: nil), text("a2", parent: "u1", message: "m2", "first")])
        let held = try fixture.page()
        try fixture.append(lines: [text("a2b", parent: "u1", message: "m3", "retry")])
        let poll = try fixture.page(after: held.next)
        #expect(poll.reset)
        #expect(poll.items.map(\.uuid) == ["u1", "a2b"])
    }

    @Test func compactionKeepsPreBoundaryHistory() throws {
        let fixture = try Fixture([
            user("u1", parent: nil, "before"),
            text("a1", parent: "u1", message: "m1", "answer"),
            #"{"type":"system","subtype":"compact_boundary","uuid":"b","parentUuid":null,"logicalParentUuid":"a1","isSidechain":false,"# +
                #""compactMetadata":{"trigger":"manual"}}"#,
            user("u2", parent: "b", "after"),
            text("a3", parent: "u2", message: "m3", "later"),
        ])
        var page = try fixture.page(maxBytes: 150)
        var uuids = page.items.map(\.uuid)
        var steps = 0
        while !page.items.isEmpty && steps < 10 {
            page = try fixture.page(before: page.start, maxBytes: 150)
            uuids = page.items.map(\.uuid) + uuids
            steps += 1
        }
        #expect(steps > 1)
        #expect(uuids == ["u1", "a1", "b", "u2", "a3"])
    }

    @Test func unknownTypesAndApiRequestsNeverAppear() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            #"{"type":"api-request","uuid":"x","parentUuid":"u1","isSidechain":false}"#,
            #"{"type":"mystery","uuid":"y","parentUuid":"x","isSidechain":false,"text":"secret"}"#,
            text("a1", parent: "y", message: "m1", "ok"),
        ])
        #expect(try fixture.page().items.map(\.uuid) == ["u1", "a1"])
    }

    @Test func skippedCountsBadLines() throws {
        let fixture = try Fixture([user("u1", parent: nil), "{not json", user("u2", parent: "u1")])
        let page = try fixture.page()
        #expect(page.skipped == 1 && page.items.map(\.uuid) == ["u1", "u2"])
    }

    @Test func oversizedResultClosesTheToolItem() throws {
        let big = String(repeating: "y", count: 5 << 20)
        let fixture = try Fixture([
            user("u1", parent: nil),
            toolUse("a1", parent: "u1", id: "t1"),
            #"{"type":"user","uuid":"r1","parentUuid":"a1","sourceToolAssistantUUID":"a1","message":{"content":"\#(big)"}}"#,
        ])
        let page = try fixture.page()
        let tool = try #require(page.items.first { $0.kind == "tool" })
        #expect(tool.running == nil && tool.clipped == true)
        #expect(page.items.last?.kind == "oversized" && page.items.last?.uuid == "r1")
    }

    // MARK: - Pending

    @Test func pendingListsOpenMainCalls() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            toolUse("a1", parent: "u1", id: "t1", name: "AskUserQuestion", input: #"{"questions":[{"question":"Q?"}]}"#),
        ])
        let pending = try fixture.page().pending
        #expect(pending.count == 1)
        #expect(pending.first?.id == "t1" && pending.first?.uuid == "a1" && pending.first?.source == "main")
        #expect(pending.first?.name == "AskUserQuestion" && pending.first?.agentType == nil)
        guard case .object(let input)? = pending.first?.input else { Issue.record("input is not an object"); return }
        #expect(input["questions"] != nil)
    }

    @Test func pendingIncludesOpenSubagentCalls() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            toolUse("a1", parent: "u1", id: "t9", name: "Agent", input: #"{"name":"scout","subagent_type":"general-purpose","description":"d"}"#),
        ])
        try fixture.write("subagents/agent-abc.meta.json", #"{"agentType":"general-purpose","toolUseId":"t9"}"#)
        try fixture.write("subagents/agent-abc.jsonl", [
            user("s1", parent: nil, sidechain: true),
            toolUse("s2", parent: "s1", id: "b1", sidechain: true),
        ].joined(separator: "\n") + "\n")
        let pending = try fixture.page().pending
        #expect(pending == [ControlTranscriptPending(id: "b1", uuid: "s2", source: "abc", agentType: "general-purpose", agentName: "scout",
                                                     name: "Bash", input: .object(["command": .string("ls")]))])
    }

    @Test func pendingInputOverCapIsClipped() throws {
        let long = String(repeating: "z", count: 20 << 10)
        let fixture = try Fixture([user("u1", parent: nil), toolUse("a1", parent: "u1", id: "t1", input: #"{"command":"\#(long)"}"#)])
        let pending = try #require(try fixture.page().pending.first)
        #expect(pending.input == nil && pending.clipped == true)
    }

    @Test func sidecarNamesWithSlashOrDotsAreSkipped() throws {
        let fixture = try Fixture([
            user("u1", parent: nil),
            toolUse("a1", parent: "u1", id: "t9", name: "Agent", input: #"{"description":"d"}"#),
            toolUse("a2", parent: "a1", id: "../../etc", message: "m-a1"),
            toolResult("r2", parent: "a2", id: "../../etc", "<persisted-output>preview</persisted-output>"),
        ])
        try Data("SECRET".utf8).write(to: fixture.project.appendingPathComponent("etc.txt"))
        try fixture.write("subagents/agent-..%2F.meta.json", #"{"toolUseId":"t9"}"#)
        try fixture.write("subagents/agent-..%2F.jsonl", toolUse("x1", parent: nil, id: "bad", sidechain: true) + "\n")
        try fixture.write("subagents/agent-good.meta.json", #"{"agentId":"../x","toolUseId":"t9"}"#)
        try fixture.write("subagents/agent-good.jsonl", toolUse("g1", parent: nil, id: "ok", sidechain: true) + "\n")
        let page = try fixture.page()
        #expect(page.pending.map(\.source) == ["good"])
        #expect(page.items.allSatisfy { $0.output?.contains("SECRET") != true })
    }

    @Test func idWithSlashIsNotFound() throws {
        let fixture = try Fixture()
        try Data((user("u1", parent: nil) + "\n").utf8).write(to: fixture.root.appendingPathComponent("projects/x.jsonl"))
        #expect(fixture.reader.page(ClaudeTranscriptRequest(sessionID: "../x", maxBytes: 1000)) == .failure(.notFound))
    }

    @Test func missingTranscriptIsNotFound() throws {
        let fixture = try Fixture()
        #expect(fixture.reader.page(ClaudeTranscriptRequest(sessionID: "nope", maxBytes: 1000)) == .failure(.notFound))
        #expect(ClaudeTranscriptError.notFound.description == "transcript not found")
    }

    // MARK: - Commands

    @Test func skillListingsFoldSinceLastInitial() {
        let first = ClaudeCommandCatalog.skills(listings: [
            (isInitial: true, names: ["a", "p:b"], content: "- a: A\n- p:b: B"),
            (isInitial: false, names: ["c"], content: "- c: C"),
        ])
        #expect(first.map { "\($0.name)=\($0.description)" } == ["a=A", "p:b=B", "c=C"])
        #expect(first.allSatisfy { $0.source == "skill" && $0.panel == nil })
        let later = ClaudeCommandCatalog.skills(listings: [
            (isInitial: true, names: ["a"], content: "- a: A"),
            (isInitial: true, names: ["d"], content: "- e: E"),
        ])
        #expect(later.map { "\($0.name)=\($0.description)" } == ["d="])
    }

    @Test func commandsRideAnAfterPageOnlyWhenSkillsAtIsInIt() throws {
        let fixture = try Fixture([user("u1", parent: nil), skillListing("l1", parent: "u1", initial: true, names: ["a"], content: "- a: A")])
        let tail = try fixture.page()
        #expect(tail.commands?.contains { $0.name == "a" && $0.source == "skill" } == true)
        try fixture.append(lines: [user("u2", parent: "l1")])
        let plain = try fixture.page(after: tail.next)
        #expect(plain.commands == nil)
        try fixture.append(lines: [skillListing("l2", parent: "u2", initial: false, names: ["c"], content: "- c: C")])
        let listed = try fixture.page(after: plain.next)
        let names = try #require(listed.commands).map(\.name)
        #expect(names.contains("a") && names.contains("c") && names.contains("model"))
        #expect(listed.meta.skillsAt.map { $0 >= plain.next } == true)
    }

    @Test func builtinCatalogPinsPanelSetAndUniqueNames() {
        let names = ClaudeCommandCatalog.builtins.map(\.name)
        #expect(names == names.sorted() && Set(names).count == names.count)
        #expect(ClaudeCommandCatalog.builtins.filter { $0.panel == true }.map(\.name) == ["config", "model", "resume", "rewind", "tasks", "usage"])
        #expect(ClaudeCommandCatalog.builtins.allSatisfy { $0.source == "builtin" && !$0.description.isEmpty })
    }

    @Test func skillDescriptionsAreClipped() {
        let long = String(repeating: "d", count: 500)
        let skills = ClaudeCommandCatalog.skills(listings: [(isInitial: true, names: ["s"], content: "- s: \(long)")])
        #expect(skills.first?.description.count == 160)
    }

    @Test func indexIsReusedAcrossPolls() throws {
        let fixture = try Fixture(users(3, bytes: 5))
        let first = try fixture.page()
        _ = try fixture.page(after: first.next)
        _ = try fixture.page()
        #expect(fixture.reader.scans == 1)
    }

    @Test func subagentFanOutKeepsTheMainIndex() throws {
        let agents = 0..<10
        let fixture = try Fixture([user("u1", parent: nil)] + agents.map { at in
            toolUse("a\(at)", parent: at == 0 ? "u1" : "a\(at - 1)", id: "t\(at)", name: "Agent", input: #"{"description":"d"}"#, message: "m")
        })
        for at in agents {
            try fixture.write("subagents/agent-x\(at).meta.json", #"{"toolUseId":"t\#(at)"}"#)
            try fixture.write("subagents/agent-x\(at).jsonl", toolUse("s\(at)", parent: nil, id: "b\(at)", sidechain: true) + "\n")
        }
        #expect(try fixture.page().pending.count == 10)
        #expect(try fixture.page().pending.count == 10)
        #expect(fixture.reader.scans == 11)
    }

    @Test func instanceIsSharedPerDirectory() {
        #expect(ClaudeTranscript.instance(directory: "/tmp/a") === ClaudeTranscript.instance(directory: "/tmp/a"))
        #expect(ClaudeTranscript.instance(directory: "/tmp/a") !== ClaudeTranscript.instance(directory: "/tmp/b"))
    }
}
