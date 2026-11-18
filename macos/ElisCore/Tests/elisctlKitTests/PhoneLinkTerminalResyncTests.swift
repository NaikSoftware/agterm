#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

/// The time rules of a vt channel, on a manual clock: resync, grid poll and the stall watchdog.
struct PhoneLinkTerminalResyncTests {
    /// A viewer that sends 900 KiB, over the 256 KiB window plus the 512 KiB relay buffer, then reads.
    private static let burst = "head -c 921600 /dev/zero | tr '\\0' x; exec cat"

    /// A program that floods a phone that keeps granting: each overflow within 10 s of the last re-attach doubles the
    /// wait, up to 30 s. The channel stays open and the queue bounded; the relay's own wait is no stall.
    @Test func floodBacksOffResyncs() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        harness.start(RawStubServer.fakeAttach("exec yes flood"))
        for (round, wait) in [1.0, 2, 4, 8, 16, 30, 30].enumerated() {
            #expect(harness.waitOverflow(count: round + 1))
            harness.credit() // for what reached it before the overflow
            harness.advance(by: wait - 0.1)
            usleep(200_000)
            #expect(harness.attaches() == round + 1, "round \(round): re-attached before \(wait) s")
            harness.advance(by: 0.1)
            #expect(harness.wait { harness.events().filter { $0 == .resync }.count == round + 1 })
        }
        #expect(!harness.events().contains { if case .close = $0 { true } else { false } })
        #expect(harness.maxPending() <= PhoneLinkSession.bufferLimit)
        #expect(harness.lines.all().filter { $0.hasPrefix("phone") } == ["phone attached from mem:1 pane pane-1"])
    }

    @Test func noOldBytesAfterResync() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        let marker = harness.dir + "/once"
        harness.start(RawStubServer.fakeAttach("if [ -e '\(marker)' ]; then printf new; exec cat; else touch '\(marker)'; exec yes old; fi"))
        #expect(harness.waitOverflow())
        harness.advance(by: 1)
        #expect(harness.wait { harness.textAfterResync().contains("new") })
        usleep(300_000) // late bytes from the old attach would land by now
        #expect(!harness.textAfterResync().contains("old"))
        #expect(harness.lines.all().filter { $0.hasPrefix("phone") } == ["phone attached from mem:1 pane pane-1"])
    }

    /// 10 s without an overflow after a re-attach puts the wait back to 1 s.
    @Test func backoffResetsAfterQuiet() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        // each attach waits for its own go file, so the test decides when it overflows
        let gate = harness.dir + "/go"
        harness.start(RawStubServer.fakeAttach(
            "n=$(ls '\(harness.dir)' | grep -c '^started'); touch '\(harness.dir)/started'$n; "
                + "while [ ! -e '\(gate)'$n ]; do sleep 0.02; done; " + Self.burst))
        #expect(harness.wait { harness.events().contains(.opened(80, 24)) })
        FileManager.default.createFile(atPath: "\(gate)0", contents: nil)
        #expect(harness.waitOverflow())
        harness.advance(by: 1)
        #expect(harness.wait { harness.events().contains(.resync) })
        // an overflow right away would wait 2 s; this one comes after 10 s of quiet
        harness.advance(by: 10)
        FileManager.default.createFile(atPath: "\(gate)1", contents: nil)
        #expect(harness.waitOverflow(count: 2))
        harness.advance(by: 0.9)
        usleep(200_000)
        #expect(harness.attaches() == 2)
        harness.advance(by: 0.1)
        #expect(harness.wait { harness.events().filter { $0 == .resync }.count == 2 })
    }

    /// A phone that takes bytes but never grants: resyncs refill the window and backoff waits pass, yet 30 s after the
    /// first full window went out the channel closes.
    @Test func noCreditPhoneIsStalledDespiteResyncs() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        harness.start(RawStubServer.fakeAttach("exec yes flood"))
        for (round, wait) in [1.0, 2, 4, 8].enumerated() { // re-attaches at 1, 3, 7 and 15 s
            #expect(harness.waitOverflow(count: round + 1))
            harness.advance(by: wait)
            #expect(harness.wait { harness.events().filter { $0 == .resync }.count == round + 1 })
        }
        #expect(harness.waitOverflow(count: 5)) // the next re-attach waits 16 s, until 31 s
        // the 1 s tick first sees the window spent at 1 s, so the 30 s run out at 31 s
        harness.advance(by: 15)
        #expect(!harness.events().contains(.close("stalled")))
        harness.advance(by: 1)
        #expect(harness.events().contains(.close("stalled")))
        #expect(harness.events().last == .ended)
    }

    @Test func failedReattachClosesWithTheAppError() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        harness.start(RawStubServer.fakeAttach(Self.burst))
        #expect(harness.waitOverflow())
        harness.server.answerAttach(ControlResponse(ok: false, error: "session not realized"))
        harness.advance(by: 1)
        #expect(harness.wait { harness.events().contains(.close("session not realized")) })
        #expect(!harness.events().contains(.resync))
        #expect(harness.lines.all().filter { $0.hasPrefix("phone detached") } == ["phone detached from mem:1 pane pane-1"])
    }

    @Test(arguments: [false, true])
    func gridChangeSendsGrid(_ remote: Bool) throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        let grid = harness.dir + "/grid"
        try "1 80 24 0 0 0\n".write(toFile: grid, atomically: true, encoding: .utf8)
        harness.start(RawStubServer.fakeAttach("printf hi; exec cat", screen: "cat '\(grid)'", remote: remote))
        #expect(harness.wait { harness.events().contains(.opened(80, 24)) })
        try "1 100 30 0 0 0\n".write(toFile: grid, atomically: true, encoding: .utf8)
        let interval: TimeInterval = remote ? 10 : 2
        harness.advance(by: interval - 1)
        usleep(300_000)
        #expect(!harness.events().contains(.grid(100, 30)))
        harness.advance(by: 1)
        #expect(harness.wait { harness.events().contains(.grid(100, 30)) })
        // an unchanged grid sends nothing
        harness.advance(by: interval)
        usleep(300_000)
        #expect(harness.events().filter { if case .grid = $0 { true } else { false } }.count == 1)
    }

    @Test func noCreditCloses() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        // 300 KiB: a full window goes out, the rest waits under the buffer
        harness.start(RawStubServer.fakeAttach("head -c 307200 /dev/zero | tr '\\0' x; exec cat"))
        #expect(harness.wait { harness.outputBytes() == 307_200 })
        harness.advance(by: 29)
        #expect(!harness.events().contains(.close("stalled")))
        harness.advance(by: 2)
        #expect(harness.events().suffix(2) == [.close("stalled"), .ended])
        #expect(harness.lines.all().filter { $0.hasPrefix("phone detached") }.count == 1)
    }

    /// Bytes still wait after a small CREDIT, but less than a window went out since it: the phone is slow, not stalled.
    @Test func waitingBytesWithoutAFullWindowAreNoStall() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        harness.start(RawStubServer.fakeAttach("head -c 307200 /dev/zero | tr '\\0' x; exec cat"))
        #expect(harness.wait { harness.outputBytes() == 307_200 })
        harness.credit(10_240) // 10 KiB more go out; 34 KiB still wait
        harness.advance(by: 40)
        #expect(!harness.events().contains { if case .close = $0 { true } else { false } })
    }

    /// No CREDIT for 40 s while idle, then a burst past the remaining window: the window is spent only now, and the
    /// phone's CREDIT for it comes a moment later, so the channel stays open.
    @Test func idlePhoneThenBurstIsNotStalled() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        let gate = harness.dir + "/go"
        harness.start(RawStubServer.fakeAttach(
            "printf hi; while [ ! -e '\(gate)' ]; do sleep 0.02; done; head -c 307200 /dev/zero | tr '\\0' x; exec cat"))
        #expect(harness.wait { harness.outputBytes() == 2 })
        harness.advance(by: 40)
        FileManager.default.createFile(atPath: gate, contents: nil)
        #expect(harness.wait { harness.outputBytes() == 307_202 })
        harness.advance(by: 1) // a tick lands before the phone's CREDIT
        harness.credit()
        harness.advance(by: 40)
        #expect(!harness.events().contains { if case .close = $0 { true } else { false } })
    }

    @Test func creditKeepsTheChannelOpen() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        harness.start(RawStubServer.fakeAttach("head -c 307200 /dev/zero | tr '\\0' x; exec cat"))
        #expect(harness.wait { harness.outputBytes() == 307_200 })
        harness.advance(by: 20)
        harness.credit() // the last 44 KiB go out, under a window
        harness.advance(by: 40)
        #expect(!harness.events().contains { if case .close = $0 { true } else { false } })
    }
}

/// One vt channel on channel 2, with a manual clock: timers fire only when the test advances time. The phone takes
/// every byte its credit allows and grants only when the test calls `credit()`.
private final class TerminalHarness: @unchecked Sendable {
    enum Event: Equatable {
        case opened(UInt16, UInt16), overflow, resync, grid(UInt16, UInt16), output(Data), close(String), refused(String), ended
    }

    let server = RawStubServer()
    let dir: String
    let lines = LogLines()
    private let queue = DispatchQueue(label: "test.terminal")
    private let lock = NSLock()
    private var recorded: [Event] = []
    private var largestQueue = 0
    // relay queue only
    private var now = Date(timeIntervalSinceReferenceDate: 0)
    private var timers: [(at: Date, order: Int, work: @Sendable () -> Void)] = []
    private var scheduled = 0
    private var scheduler = PhoneLinkScheduler(window: 262_144, bufferLimit: PhoneLinkSession.bufferLimit)
    private var terminal: PhoneLinkTerminal?
    init() throws {
        dir = NSTemporaryDirectory() + "elis-term-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try server.start()
    }

    func start(_ attach: ControlAttach) {
        server.answerAttach(ControlResponse(ok: true, result: ControlResult(attach: attach)))
        let link = PhoneLinkTerminal.Link(
            opened: { [self] cols, rows in
                scheduler.open(channel: 2)
                record(.opened(cols, rows))
            },
            resynced: { [self] cols, rows in
                scheduler.open(channel: 2)
                record(.resync)
                record(.grid(cols, rows))
            },
            output: { [self] bytes in
                record(.output(bytes))
                let result = scheduler.enqueue(channel: 2, bytes)
                if result == .overflowed { record(.overflow) }
                drain()
                lock.withLock { largestQueue = max(largestQueue, scheduler.pendingBytes(channel: 2)) }
                return result
            },
            frame: { [self] frame in record(Self.event(frame)) },
            ended: { [self] in
                scheduler.close(channel: 2)
                record(.ended)
            },
            windowSpent: { [self] in scheduler.windowSpent(channel: 2) })
        let terminal = PhoneLinkTerminal(
            channel: 2, request: PhoneLinkOpen(type: "vt", target: "S1", pane: "left"), socketPath: server.path, queue: queue,
            peer: "mem:1", log: { [lines] in lines.append($0) }, clock: { [self] in now },
            after: { [self] delay, work in
                scheduled += 1
                timers.append((now + delay, scheduled, work))
            }, link: link)
        queue.sync {
            self.terminal = terminal
            terminal.start()
        }
    }

    /// Moves the clock, firing every timer due by then in deadline order, at its own time.
    func advance(by seconds: TimeInterval) {
        queue.sync {
            let end = now + seconds
            while let next = timers.indices.min(by: { (timers[$0].at, timers[$0].order) < (timers[$1].at, timers[$1].order) }),
                  timers[next].at <= end {
                let timer = timers.remove(at: next)
                now = max(now, timer.at)
                timer.work()
            }
            now = end
        }
    }

    /// The phone grants `bytes` (a window by default), as the session's CREDIT handling does.
    func credit(_ bytes: UInt32 = 262_144) {
        queue.sync {
            scheduler.grant(channel: 2, bytes: bytes)
            drain()
            terminal?.credited()
        }
    }

    private func drain() { while scheduler.next(maxChunk: PhoneLinkSession.maxChunk) != nil {} }

    func events() -> [Event] { lock.withLock { recorded } }
    func maxPending() -> Int { lock.withLock { largestQueue } }
    func attaches() -> Int { server.requests().filter { $0.contains("session.attach") }.count }

    func outputBytes() -> Int {
        events().reduce(0) { if case let .output(bytes) = $1 { $0 + bytes.count } else { $0 } }
    }

    /// The output after the last RESYNC.
    func textAfterResync() -> String {
        let events = events()
        guard let resync = events.lastIndex(of: .resync) else { return "" }
        let bytes = events[resync...].reduce(Data()) { if case let .output(bytes) = $1 { $0 + bytes } else { $0 } }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Whether the relay buffer overflowed `count` times in all, the handler included.
    func waitOverflow(count: Int = 1) -> Bool {
        let overflowed = wait { self.events().filter { $0 == .overflow }.count >= count }
        queue.sync {}
        return overflowed
    }

    func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !condition() {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    func finish() {
        queue.sync { terminal?.stop() }
        server.releaseAttach()
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    private func record(_ event: Event) { lock.withLock { recorded.append(event) } }

    private static func event(_ frame: PhoneLinkFrame) -> Event {
        switch frame.kind {
        case .close: .close((try? frame.decodeJSON(PhoneLinkClose.self))?.reason ?? "")
        case .opened: .refused((try? frame.decodeJSON(PhoneLinkOpened.self))?.error ?? "")
        case .grid: .grid(frame.size?.cols ?? 0, frame.size?.rows ?? 0)
        case .resync: .resync
        default: .output(frame.payload)
        }
    }
}
#endif
