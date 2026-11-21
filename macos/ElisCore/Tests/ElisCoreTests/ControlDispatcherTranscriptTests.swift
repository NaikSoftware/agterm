import Foundation
import Testing
@testable import ElisCore

@MainActor
struct ControlDispatcherTranscriptTests {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cdt-\(UUID().uuidString)")
        var path: String { root.appendingPathComponent("projects/-proj/c1.jsonl").path }
        var size: Int { (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? -1 }

        init(prompt: String = "hello") throws {
            try write("projects/-proj/c1.jsonl", prompt: prompt, uuid: "u1")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ relative: String, prompt: String, uuid: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let line = #"{"type":"user","uuid":"\#(uuid)","parentUuid":null,"isSidechain":false,"timestamp":"T","# +
                #""message":{"role":"user","content":"\#(prompt)"}}"# + "\n"
            try Data(line.utf8).write(to: url)
        }

        var source: ControlTranscriptLookup {
            .source(ControlTranscriptSource(claudeSessionID: "c1", pane: .left, claudeDirectory: root.path))
        }
    }

    private func dispatch(_ args: ControlArgs?, actions: MockControlActions = MockControlActions()) async -> ControlResponse? {
        await ControlDispatcher(actions: actions).dispatch(ControlRequest(cmd: .sessionTranscript, target: "s", args: args))
    }

    private func error(_ args: ControlArgs) async -> String? {
        await dispatch(args)?.error
    }

    private func args(after: String? = nil, before: String? = nil, transcript: String? = nil, maxBytes: Int? = nil,
                      pane: String? = nil) -> ControlArgs {
        var args = ControlArgs(pane: pane)
        args.after = after
        args.before = before
        args.transcript = transcript
        args.maxBytes = maxBytes
        return args
    }

    @Test func transcriptRequestRoundTrips() throws {
        let request = ControlRequest(cmd: .sessionTranscript, target: "s", args: args(after: "12", transcript: "abc", maxBytes: 100))

        let decoded = try JSONDecoder().decode(ControlRequest.self, from: JSONEncoder().encode(request))

        #expect(decoded == request)
        #expect(Command.sessionTranscript.rawValue == "session.transcript")
    }

    @Test func transcriptResultOmitsNilFields() throws {
        var result = ControlResult()
        result.items = [ControlTranscriptItem(kind: "user", uuid: "u1", at: 0)]

        let json = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)

        #expect(json.contains(#""items""#))
        for key in ["reset", "pending", "skipped", "commands"] { #expect(!json.contains("\"\(key)\""), "\(key)") }
    }

    @Test func afterAndBeforeAreExclusive() async {
        #expect(await error(args(after: "1", before: "2")) == "use either --after or --before, not both")
    }

    @Test func offsetMustBeADecimal() async {
        #expect(await error(args(after: "x")) == "after must be a byte offset")
        #expect(await error(args(before: "-1")) == "before must be a byte offset")
    }

    @Test func maxBytesClampsAndRejectsNonPositive() async throws {
        #expect(try ControlDispatcher.transcriptArguments(args(maxBytes: 1_000_000)).get().maxBytes == 49152)
        #expect(try ControlDispatcher.transcriptArguments(args()).get().maxBytes == 49152)
        #expect(try ControlDispatcher.transcriptArguments(args(maxBytes: 100)).get().maxBytes == 100)
        #expect(await error(args(maxBytes: 0)) == "max-bytes must be greater than 0")
    }

    @Test func paneAliasesResolveAsInSessionText() async {
        let actions = MockControlActions()
        var byID = args(pane: "bottom")
        byID.paneID = "p1"

        _ = await dispatch(args(pane: "top"), actions: actions)
        _ = await dispatch(byID, actions: actions)
        _ = await dispatch(nil, actions: actions)

        #expect(actions.calls == [
            .transcriptSource(target: "s", window: nil, pane: .left, paneID: nil),
            .transcriptSource(target: "s", window: nil, pane: .right, paneID: "p1"),
            .transcriptSource(target: "s", window: nil, pane: nil, paneID: nil),
        ])
        #expect(await error(args(pane: "x")) == "invalid pane: x")
    }

    @Test func scratchPaneIsRefused() async {
        let actions = MockControlActions()
        #expect(await dispatch(args(pane: "scratch"), actions: actions)?.error == "session.transcript reads --pane left or right")
        #expect(actions.calls.isEmpty)
    }

    @Test func lookupRefusalPassesThrough() async {
        let actions = MockControlActions()
        actions.nextTranscriptLookup = .refused(ControlResponse(ok: false, error: "no adapter"))
        #expect(await dispatch(nil, actions: actions) == ControlResponse(ok: false, error: "no adapter"))
    }

    // the mock's unset lookup is the same constant the protocol default returns
    @Test func defaultRefusalReadsAsTooOld() async {
        #expect(await dispatch(nil) == ControlResponse(ok: false, error: "the Elis on this host is too old for session.transcript"))
    }

    @Test func readerRunsOffTheMainThread() async throws {
        let fixture = try Fixture()
        let actions = MockControlActions()
        actions.nextTranscriptLookup = fixture.source

        #expect(await dispatch(nil, actions: actions)?.ok == true)
    }

    @Test func missingFileIsTranscriptNotFound() async throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(atPath: fixture.path)
        let actions = MockControlActions()
        actions.nextTranscriptLookup = fixture.source

        #expect(await dispatch(nil, actions: actions) == ControlResponse(ok: false, error: "transcript not found"))
    }

    @Test func heldTranscriptIsOnlyCompared() async throws {
        let fixture = try Fixture()
        try fixture.write("projects/x.jsonl", prompt: "decoy", uuid: "d1")
        let actions = MockControlActions()
        actions.nextTranscriptLookup = fixture.source

        let result = try #require(await dispatch(args(after: "0", transcript: "../x"), actions: actions)?.result)

        #expect(result.reset == true)
        #expect(result.items?.map(\.text) == ["hello"])
    }

    @Test func pageFieldsLandFlatOnResult() async throws {
        let fixture = try Fixture()
        let actions = MockControlActions()
        actions.nextTranscriptLookup = fixture.source

        let result = try #require(await dispatch(nil, actions: actions)?.result)

        #expect(result.transcript == "c1")
        #expect(result.size == fixture.size)
        #expect(result.start == 0)
        #expect(result.next == fixture.size)
        #expect(result.items?.map(\.uuid) == ["u1"])
        #expect(result.items?.map(\.text) == ["hello"])
        #expect(result.meta != nil)
        #expect(result.reset == nil)
        #expect(result.skipped == nil)
    }

    @Test func pageRowRefusesTranscript() {
        let refusal = PageSessionRefusal.refusal(ControlRequest(cmd: .sessionTranscript, target: "s")) { _, _ in true }
        #expect(refusal == ControlResponse(ok: false, error: "session.transcript: not available on a page session"))
    }
}
