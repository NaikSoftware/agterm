import ElisCore
@testable import elisctlKit
import Testing

@Suite(.outsidePane)
struct SessionGridCommandsTests {
    private func request(_ argv: [String]) throws -> ControlRequest {
        let parsed = try Elisctl.parseAsRoot(argv)
        guard let command = parsed as? any RequestCommand else {
            throw SocketClientError("parsed \(argv) is not a RequestCommand")
        }
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

    private func gridArgs(columns: Int? = nil, rows: Int? = nil, reset: Bool? = nil, pane: String? = nil) -> ControlArgs {
        var args = ControlArgs(pane: pane)
        args.columns = columns
        args.rows = rows
        args.reset = reset
        return args
    }

    @Test func gridSetsColumnsAndRowsOnAPane() throws {
        let expected = ControlRequest(cmd: .sessionGrid, target: "active", args: gridArgs(columns: 80, rows: 24, pane: "right"))
        #expect(try request(["session", "grid", "80x24", "--pane", "right"]) == expected)
    }

    @Test func gridResetSendsReset() throws {
        let expected = ControlRequest(cmd: .sessionGrid, target: "9f3c", args: gridArgs(reset: true))
        #expect(try request(["session", "grid", "--reset", "--target", "9f3c"]) == expected)
    }

    @Test(arguments: [["80x"], ["x24"], ["80"], ["80x24x1"], ["axb"]])
    func gridRejectsAMalformedSize(size: [String]) {
        #expect(validationMessage(["session", "grid"] + size) == "size must be <columns>x<rows>, such as 80x24")
    }

    @Test(arguments: [["80x24", "--reset"], []])
    func gridTakesASizeOrResetButNotBoth(argv: [String]) {
        #expect(validationMessage(["session", "grid"] + argv) == "provide <columns>x<rows> or --reset")
    }

    @Test func scrollSendsNegativeLines() throws {
        let expected = ControlRequest(cmd: .sessionScroll, target: "active", args: ControlArgs(lines: -3))
        #expect(try request(["session", "scroll", "-3"]) == expected)
    }

    @Test(arguments: [[], ["3", "4"], ["three"], ["--bogus"]])
    func scrollTakesOneWholeNumber(argv: [String]) {
        #expect(validationMessage(["session", "scroll"] + argv) == "provide one whole number of lines")
    }

    @Test func scrollSendsLinesOnAPane() throws {
        let expected = ControlRequest(cmd: .sessionScroll, target: "active", args: ControlArgs(pane: "split", lines: 5))
        #expect(try request(["session", "scroll", "5", "--pane", "split"]) == expected)
    }

    @Test(arguments: [["grid", "80x24"], ["grid", "--reset"], ["scroll", "3"]])
    func gridAndScrollRefuseTheScratchPane(argv: [String]) {
        #expect(validationMessage(["session"] + argv + ["--pane", "scratch"]) == "invalid pane: scratch")
    }
}
