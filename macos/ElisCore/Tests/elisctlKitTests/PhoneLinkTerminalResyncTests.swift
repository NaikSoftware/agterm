#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

/// The time rules of a vt channel, on a manual clock: resync, grid poll and the stall watchdog.
struct PhoneLinkTerminalResyncTests {
    /// A viewer that sends 600 KiB, over the 512 KiB relay buffer, then reads.
    private static let burst = "head -c 614400 /dev/zero | tr '\\0' x; exec cat"

    @Test func floodResyncsAtMostOncePerSecond() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        let token = PhoneLinkTerminalTests.token()
        harness.start(RawStubServer.fakeAttach("exec yes \(token)"))
        #expect(harness.waitOverflow())
        harness.advance(by: 0.5)
        usleep(300_000)
        #expect(harness.attaches() == 1)
        harness.advance(by: 0.5)
        #expect(harness.wait { harness.events().contains(.resync) })
        // the second flood overflows within 2 s of its start too
        #expect(harness.wait { harness.events().contains(.close("session too old for the phone view")) })
        #expect(harness.attaches() == 2) // after 1 s: at most elapsed seconds + 1
        #expect(harness.maxPending() <= PhoneLinkSession.bufferLimit)
        #expect(PhoneLinkTerminalTests.waitGone(token))
        #expect(harness.lines.all().filter { $0.hasPrefix("phone detached") }.count == 1)
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

    @Test func repeatedEarlyOverflowCloses() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        harness.start(RawStubServer.fakeAttach(Self.burst))
        #expect(harness.waitOverflow())
        harness.advance(by: 1)
        #expect(harness.wait { harness.events().contains(.close("session too old for the phone view")) })
        #expect(harness.events().filter { $0 == .resync }.count == 1)
        #expect(harness.events().last == .ended)
        harness.advance(by: 5)
        usleep(300_000)
        #expect(harness.attaches() == 2)
    }

    /// An overflow 2 s or more after the attach started is a plain resync, and resets the early count.
    @Test func lateOverflowKeepsResyncing() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        let gate = harness.dir + "/go"
        // each attach waits for its own go file, so the test moves the clock before the burst
        harness.start(RawStubServer.fakeAttach(
            "n=$(ls '\(harness.dir)' | grep -c '^started'); touch '\(harness.dir)/started'$n; "
                + "while [ ! -e '\(gate)'$n ]; do sleep 0.02; done; " + Self.burst))
        #expect(harness.wait { harness.events().contains(.opened(80, 24)) }) // the attach started at the frozen time
        for round in 0..<3 {
            harness.advance(by: 2.5)
            FileManager.default.createFile(atPath: "\(gate)\(round)", contents: nil)
            #expect(harness.waitOverflow(count: round + 1))
            harness.advance(by: 0)
            #expect(harness.wait { harness.events().filter { $0 == .resync }.count == round + 1 })
        }
        #expect(!harness.events().contains { if case .close = $0 { true } else { false } })
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
        // 300 KiB: past the window, under the buffer, so the bytes wait without an overflow
        harness.start(RawStubServer.fakeAttach("head -c 307200 /dev/zero | tr '\\0' x; exec cat"))
        #expect(harness.wait { harness.outputBytes() == 307_200 })
        harness.advance(by: 29)
        #expect(!harness.events().contains(.close("stalled")))
        harness.advance(by: 2)
        #expect(harness.events().suffix(2) == [.close("stalled"), .ended])
        #expect(harness.lines.all().filter { $0.hasPrefix("phone detached") }.count == 1)
    }

    @Test func creditKeepsTheChannelOpen() throws {
        let harness = try TerminalHarness()
        defer { harness.finish() }
        harness.start(RawStubServer.fakeAttach("head -c 307200 /dev/zero | tr '\\0' x; exec cat"))
        #expect(harness.wait { harness.outputBytes() == 307_200 })
        harness.advance(by: 20)
        harness.credit()
        harness.advance(by: 20)
        #expect(!harness.events().contains(.close("stalled")))
        harness.advance(by: 11) // 31 s after the last CREDIT
        #expect(harness.events().contains(.close("stalled")))
    }
}

/// One vt channel on channel 2, with a manual clock: timers fire only when the test advances time. Nothing drains
/// the scheduler, as for a phone that sends no CREDIT.
private final class TerminalHarness: @unchecked Sendable {
    enum Event: Equatable {
        case opened(UInt16, UInt16), resync, grid(UInt16, UInt16), output(Data), close(String), refused(String), ended
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
                lock.withLock { largestQueue = max(largestQueue, scheduler.pendingBytes(channel: 2)) }
                return result
            },
            frame: { [self] frame in record(Self.event(frame)) },
            ended: { [self] in
                scheduler.close(channel: 2)
                record(.ended)
            },
            pending: { [self] in scheduler.pendingBytes(channel: 2) })
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

    func credit() { queue.sync { terminal?.credited() } }

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
        let overflowed = wait {
            // each overflow drops the queue: count the drops, as the enqueue that crossed the limit
            var queued = 0, drops = 0
            for case let .output(bytes) in self.events() {
                if queued + bytes.count > PhoneLinkSession.bufferLimit { drops += 1; queued = 0 } else { queued += bytes.count }
            }
            return drops >= count
        }
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
