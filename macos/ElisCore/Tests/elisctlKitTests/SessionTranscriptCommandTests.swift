import ArgumentParser
import Testing
import ElisCore
@testable import elisctlKit

@Suite(.outsidePane)
struct SessionTranscriptCommandTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let command = try #require(try Elisctl.parseAsRoot(argv) as? any RequestCommand)
        return try command.makeRequest()
    }

    private func validationMessage(_ argv: [String]) -> String? {
        do {
            _ = try Elisctl.parseAsRoot(argv)
            return nil
        } catch {
            return Elisctl.message(for: error)
        }
    }

    @Test func transcriptBuildsRequest() throws {
        var args = ControlArgs(pane: "right", after: "10")
        args.transcript = "c1"
        args.maxBytes = 500
        let expected = ControlRequest(cmd: .sessionTranscript, target: "active", args: args)
        #expect(try request(["session", "transcript", "--pane", "right", "--after", "10", "--transcript", "c1", "--max-bytes", "500"])
                == expected)
    }

    @MainActor @Test func transcriptForwardWordsParse() throws {
        var args = ControlArgs(paneID: "-p", before: "7")
        args.transcript = "-c"
        args.maxBytes = 9
        let arguments = try ControlDispatcher.transcriptArguments(args).get()
        let words = TranscriptForward.words(session: "s1", paneID: "-p", pane: nil, arguments: arguments)
        #expect(try request(words) == ControlRequest(cmd: .sessionTranscript, target: "s1", args: args))
    }

    @Test func afterAndBeforeAreExclusiveAtParse() {
        #expect(validationMessage(["session", "transcript", "--after", "1", "--before", "2"]) == "use either --after or --before, not both")
    }

    @Test func offsetsMustBeNonNegative() {
        #expect(validationMessage(["session", "transcript", "--after=-1"]) == "--after and --before must be 0 or greater")
        #expect(validationMessage(["session", "transcript", "--max-bytes", "0"]) == "--max-bytes must be greater than 0")
    }

    @Test func humanOutputListsItems() {
        var meta = ControlTranscriptMeta()
        meta.title = "Fix tests"
        meta.model = "opus"
        var user = ControlTranscriptItem(kind: "user", uuid: "u1", at: 0)
        user.text = "hello"
        var tool = ControlTranscriptItem(kind: "tool", uuid: "u2", at: 20)
        tool.name = "Bash"
        tool.arg = "Run tests"
        tool.mark = "ok"
        var result = ControlResult()
        result.items = [user, tool, ControlTranscriptItem(kind: "interrupted", uuid: "u3", at: 30)]
        result.meta = meta
        result.next = 42
        #expect(SocketClient.formatResponse(ControlResponse(ok: true, result: result)) == """
        title: Fix tests
        model: opus
        user  hello
        tool  Bash Run tests ok
        interrupted
        next 42
        """)
    }
}
