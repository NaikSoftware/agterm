#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

/// One claim channel on channel 4, with a manual clock, fake claiming attaches that print role titles, and a phone
/// whose CREDIT frames go out only when the test says so.
struct PhoneLinkClaimTests {
    static func role(_ role: String, nonce: String = "n1", generation: Int = 1) -> String {
        #"printf '\033]2;zmx-role;\#(nonce):\#(role):\#(generation)\007'; "#
    }

    @Test func opensAfterTheLeaderReport() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(Self.role("leader") + "stty size > '\(harness.dir)/size'; exec cat >/dev/null", cols: 100, rows: 30)
        #expect(harness.wait { harness.events().count >= 3 })
        #expect(harness.events().prefix(3) == [.opened(100, 30), .lead("leader"), .leadChanged("pane-1")])
        #expect(harness.lines.all() == ["phone leads from mem:1 pane pane-1"])
        #expect(harness.wait { harness.file("size") == "30 100\n" })
        #expect(harness.server.requests() == [#"{"args":{"claim":true,"pane":"left"},"cmd":"session.attach","target":"S1"}"#])
    }

    @Test func splitRoleReportOpens() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(#"printf '\033]2;zmx-ro'; sleep 0.2; printf 'le;n1:lea'; sleep 0.2; printf 'der:1\007'; exec cat >/dev/null"#)
        #expect(harness.wait { harness.events().count >= 3 })
        #expect(harness.events().prefix(3) == [.opened(80, 24), .lead("leader"), .leadChanged("pane-1")])
    }

    @Test func inputBeforeOpenedIsDropped() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(harness.waitGate("lead") + Self.role("leader") + "exec cat > '\(harness.dir)/in'")
        #expect(harness.wait { harness.timers() == 1 }) // the attach runs
        harness.queueSync { harness.claim?.input(Data("early".utf8)) }
        harness.open("lead")
        #expect(harness.wait { harness.events().contains(.lead("leader")) })
        harness.queueSync { harness.claim?.input(Data("late\n".utf8)) }
        #expect(harness.wait { harness.file("in")?.hasSuffix("\n") == true })
        #expect(harness.file("in") == "late\n")
        #expect(harness.wait { harness.credits() == [5] })
    }

    @Test func resizeBeforeOpenedIsReported() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(harness.waitGate("lead") + Self.role("leader") + "stty size > '\(harness.dir)/size'; exec cat >/dev/null")
        #expect(harness.wait { harness.timers() == 1 })
        harness.queueSync { harness.claim?.resize(cols: 100, rows: 40) }
        harness.open("lead")
        #expect(harness.wait { harness.events().contains(.lead("leader")) })
        #expect(harness.events().first == .opened(100, 40))
        #expect(harness.wait { harness.file("size") == "40 100\n" })
    }

    @Test func appWithoutClaimIsRefused() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(answer: ControlResponse(ok: true, result: ControlResult(attach: RawStubServer.fakeAttach("exec cat"))))
        #expect(harness.wait { harness.events().contains(.ended) })
        #expect(harness.events() == [.refused("Elis gave no claiming attach for this pane"), .ended])
    }

    @Test func noRoleReportRefuses() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        let token = PhoneLinkTerminalTests.token()
        harness.start("exec cat; : \(token)")
        #expect(harness.wait { harness.timers() == 1 })
        harness.advance(by: 9.9)
        #expect(harness.events().isEmpty)
        harness.advance(by: 0.1)
        #expect(harness.events() == [.refused("this host's zmx cannot hand over the lead; update Elis there"), .ended])
        #expect(PhoneLinkTerminalTests.waitGone(token))
        #expect(harness.lines.all().isEmpty)
    }

    @Test func forgedRoleIsIgnored() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(Self.role("leader", nonce: "forged") + "exec cat >/dev/null")
        #expect(harness.wait { harness.timers() == 1 })
        usleep(300_000) // the forged report has been read by now
        #expect(harness.events().isEmpty)
        harness.advance(by: 10)
        #expect(harness.events() == [.refused("this host's zmx cannot hand over the lead; update Elis there"), .ended])
    }

    @Test func leadLostSendsLeadThenClose() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        let token = PhoneLinkTerminalTests.token()
        harness.start(Self.role("leader") + harness.waitGate("lost") + Self.role("follower", generation: 2) + "exec cat >/dev/null; : \(token)")
        #expect(harness.wait { harness.events().contains(.lead("leader")) })
        harness.open("lost")
        #expect(harness.wait { harness.events().contains(.ended) })
        #expect(Array(harness.events().suffix(4))
            == [.lead("follower"), .close("the computer took the lead back"), .ended, .leadChanged("pane-1")])
        #expect(harness.lines.all() == ["phone leads from mem:1 pane pane-1", "phone released from mem:1 pane pane-1"])
        #expect(!harness.events().contains(.released("pane-1")))
        #expect(PhoneLinkTerminalTests.waitGone(token))
    }

    @Test func claimExitClosesSessionEnded() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(Self.role("leader") + harness.waitGate("exit"))
        #expect(harness.wait { harness.events().contains(.lead("leader")) })
        harness.open("exit")
        #expect(harness.wait { harness.events().contains(.ended) })
        #expect(Array(harness.events().suffix(3)) == [.released("pane-1"), .close("session ended"), .ended])
        #expect(harness.lines.all().last == "phone released from mem:1 pane pane-1")
    }

    @Test func exitBeforeAnyRoleRefuses() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start("exit 0")
        #expect(harness.wait { harness.events().contains(.ended) })
        #expect(harness.events() == [.refused("could not take over: the attach ended"), .ended])
        #expect(harness.lines.all().isEmpty)
    }

    /// A phone that reads no CREDIT yet: whatever the pty takes meanwhile waits in the one CREDIT still to go.
    @Test func creditIsCoalesced() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(Self.role("leader") + "exec cat >/dev/null")
        #expect(harness.wait { harness.events().contains(.lead("leader")) })
        harness.queueSync { for _ in 0..<100 { harness.claim?.input(Data("x".utf8)) } }
        #expect(harness.wait { harness.credits().count == 1 })
        usleep(300_000) // every write has completed by now
        #expect(harness.credits().count == 1)
        harness.sendCredits()
        #expect(harness.wait { harness.credits().reduce(0, +) == 100 })
        #expect(harness.credits().count == 2)
    }

    @Test func creditFollowsPtyWrites() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(Self.role("leader") + "stty raw -echo; touch '\(harness.dir)/ready'; " + harness.waitGate("read") + "exec cat >/dev/null")
        #expect(harness.wait { harness.file("ready") != nil })
        harness.queueSync { harness.claim?.input(Data(repeating: 0x78, count: 16384)) }
        usleep(300_000)
        #expect(harness.credits().isEmpty) // the program reads nothing yet, so the write is not done
        harness.open("read")
        #expect(harness.wait { harness.credits() == [16384] })
    }

    @Test func inputBeyondTheWindowCloses() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(Self.role("leader") + "stty raw -echo; touch '\(harness.dir)/ready'; exec sleep 60")
        #expect(harness.wait { harness.file("ready") != nil })
        harness.queueSync { harness.claim?.input(Data(repeating: 0x78, count: PhoneLinkClaim.window)) }
        #expect(!harness.events().contains(.ended))
        harness.queueSync { harness.claim?.input(Data("x".utf8)) }
        #expect(Array(harness.events().suffix(3)) == [.released("pane-1"), .close("input overflow"), .ended])
    }

    @Test func resizeOutOfRangeIsIgnored() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        let dir = harness.dir
        harness.start(Self.role("leader") + harness.waitGate("one") + "stty size > '\(dir)/one'; " + harness.waitGate("two")
            + "stty size > '\(dir)/two'; exec cat >/dev/null")
        #expect(harness.wait { harness.events().contains(.lead("leader")) })
        harness.queueSync {
            harness.claim?.resize(cols: 0, rows: 10)
            harness.claim?.resize(cols: 1001, rows: 30)
        }
        harness.open("one")
        #expect(harness.wait { harness.file("one") == "24 80\n" })
        harness.queueSync { harness.claim?.resize(cols: 1000, rows: 1) }
        harness.open("two")
        #expect(harness.wait { harness.file("two") == "1 1000\n" })
    }

    @Test(arguments: [(UInt16?.none, UInt16?.some(24)), (0, 24), (80, 1001)])
    func badSizeIsRefused(_ cols: UInt16?, _ rows: UInt16?) throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start("exec cat", cols: cols, rows: rows)
        #expect(harness.events() == [.refused("bad size"), .ended])
        #expect(harness.server.requests().isEmpty)
    }

    @Test func appRefusalIsPassedOn() throws {
        let harness = try ClaimHarness()
        defer { harness.finish() }
        harness.start(answer: ControlResponse(ok: false, error: "session not realized"))
        #expect(harness.wait { harness.events().contains(.ended) })
        #expect(harness.events() == [.refused("session not realized"), .ended])
    }
}

private final class ClaimHarness: @unchecked Sendable {
    enum Event: Equatable {
        case opened(UInt16, UInt16), refused(String), lead(String), close(String), ended, leadChanged(String), released(String)
    }

    let server = RawStubServer()
    let dir: String
    let lines = LogLines()
    private let queue = DispatchQueue(label: "test.claim")
    private let lock = NSLock()
    private var recorded: [Event] = []
    private var credited: [UInt32] = []
    // relay queue only
    private var unsent: [() -> Void] = []
    private var pending: [(at: TimeInterval, work: @Sendable () -> Void)] = []
    private var now: TimeInterval = 0
    private var timerCount = 0
    private(set) var claim: PhoneLinkClaim?

    init() throws {
        dir = NSTemporaryDirectory() + "elis-claim-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try server.start()
    }

    func start(_ script: String, cols: UInt16? = 80, rows: UInt16? = 24) {
        start(answer: ControlResponse(ok: true, result: ControlResult(attach: RawStubServer.fakeAttach(script, nonce: "n1"))), cols: cols, rows: rows)
    }

    func start(answer: ControlResponse, cols: UInt16? = 80, rows: UInt16? = 24) {
        server.answerAttach(answer)
        let link = PhoneLinkClaim.Link(
            frame: { [self] frame in record(Self.event(frame)) },
            credit: { [self] bytes, sent in
                lock.withLock { credited.append(bytes) }
                unsent.append(sent)
            },
            ended: { [self] in record(.ended) },
            leadChanged: { [self] pane in record(.leadChanged(pane)) },
            released: { [self] pane in record(.released(pane)) })
        let claim = PhoneLinkClaim(
            channel: 4, request: PhoneLinkOpen(type: "vt", target: "S1", pane: "left", claim: true, cols: cols, rows: rows),
            socketPath: server.path, queue: queue, peer: "mem:1", log: { [lines] in lines.append($0) },
            after: { [self] delay, work in
                timerCount += 1
                pending.append((now + delay, work))
            }, link: link)
        queue.sync {
            self.claim = claim
            claim.start()
        }
    }

    func queueSync(_ work: () -> Void) { queue.sync(execute: work) }

    func advance(by seconds: TimeInterval) {
        queue.sync {
            now += seconds
            let due = pending.filter { $0.at <= now }
            pending.removeAll { $0.at <= now }
            due.forEach { $0.work() }
        }
    }

    /// The phone's transport takes every CREDIT frame held so far.
    func sendCredits() {
        queue.sync {
            let sent = unsent
            unsent = []
            sent.forEach { $0() }
        }
    }

    func timers() -> Int { queue.sync { timerCount } }
    func events() -> [Event] { lock.withLock { recorded } }
    func credits() -> [UInt32] { lock.withLock { credited } }
    func file(_ name: String) -> String? { try? String(contentsOfFile: "\(dir)/\(name)", encoding: .utf8) }
    func waitGate(_ name: String) -> String { "while [ ! -e '\(dir)/\(name)' ]; do sleep 0.02; done; " }
    func open(_ name: String) { FileManager.default.createFile(atPath: "\(dir)/\(name)", contents: nil) }

    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    func finish() {
        queue.sync { claim?.stop() }
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func record(_ event: Event) { lock.withLock { recorded.append(event) } }

    private static func event(_ frame: PhoneLinkFrame) -> Event {
        switch frame.kind {
        case .opened:
            let opened = try? frame.decodeJSON(PhoneLinkOpened.self)
            if let error = opened?.error { return .refused(error) }
            return .opened(opened?.cols ?? 0, opened?.rows ?? 0)
        case .lead: return .lead((try? frame.decodeJSON(PhoneLinkLead.self))?.role ?? "")
        case .close: return .close((try? frame.decodeJSON(PhoneLinkClose.self))?.reason ?? "")
        default: return .close("unexpected \(frame.kind)")
        }
    }
}
#endif
