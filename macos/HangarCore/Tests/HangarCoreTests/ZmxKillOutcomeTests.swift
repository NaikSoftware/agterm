import Testing
@testable import HangarCore

struct ZmxKillOutcomeTests {
    private let name = "hangar-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    @Test(arguments: [
        ("killed session hangar-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", ZmxKillOutcome.killed),
        ("cleaned up stale session hangar-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", .staleSocket),
        ("failed to kill session=hangar-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: SessionUnresponsive\n",
         .failed("failed to kill session=hangar-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: SessionUnresponsive")),
        ("", .failed("no output")),
        ("not killed session hangar-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
         .failed("not killed session hangar-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")),
        ("killed session hangar-other\n", .failed("killed session hangar-other")),
    ])
    func onlyAnExactConfirmationLineForTheNameIsAKill(_ output: String, _ expected: ZmxKillOutcome) {
        #expect(ZmxKillOutcome.parse(output, name: name) == expected)
    }
}
