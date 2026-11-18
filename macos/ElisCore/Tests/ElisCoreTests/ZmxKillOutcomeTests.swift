import Testing
@testable import ElisCore

struct ZmxKillOutcomeTests {
    private let name = "elis-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    @Test(arguments: [
        ("killed session elis-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", ZmxKillOutcome.killed),
        ("cleaned up stale session elis-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", .staleSocket),
        ("failed to kill session=elis-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: SessionUnresponsive\n",
         .failed("failed to kill session=elis-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: SessionUnresponsive")),
        ("", .failed("no output")),
        ("not killed session elis-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
         .failed("not killed session elis-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
        ("killed session elis-other\n", .failed("killed session elis-other")),
    ])
    func onlyAnExactConfirmationLineForTheNameIsAKill(_ output: String, _ expected: ZmxKillOutcome) {
        #expect(ZmxKillOutcome.parse(output, name: name) == expected)
    }
}
