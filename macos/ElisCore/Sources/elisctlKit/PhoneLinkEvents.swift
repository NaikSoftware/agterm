#if os(macOS)
import Foundation
import ElisCore

/// Channel 1's source: a poller on its own `Thread` reads `events.read` from the latest event at upgrade time on,
/// and hops each batch to the relay queue, where the rows wait in a line queue bounded at `limit` bytes. Past the
/// bound the oldest rows go, and the next line taken says how many: `{"dropped":N}`. A read restarted at the tail
/// after an error queues `{"gap":true}`, so the phone knows it missed events and re-reads `tree`.
final class PhoneLinkEvents: @unchecked Sendable {
    static let limit = 256 * 1024

    private let socketPath: String
    private let queue: DispatchQueue
    /// Runs on the relay queue after rows arrive.
    private let ready: () -> Void
    private let lock = NSLock()
    private var stopped = false // under `lock`: the poller thread reads it
    // relay queue only
    private var lines: [Data] = []
    private var bytes = 0
    private var dropped = 0
    private var gap = false

    init(socketPath: String, queue: DispatchQueue, ready: @escaping () -> Void) {
        self.socketPath = socketPath
        self.queue = queue
        self.ready = ready
    }

    func start() {
        Thread.detachNewThread { [self] in poll() }
    }

    /// The poller ends after the request in flight, if any; its answer is discarded.
    func stop() { lock.withLock { stopped = true } }

    /// The next line for channel 1, newline included. Relay queue only.
    func next() -> Data? {
        if gap {
            gap = false
            return Data("{\"gap\":true}\n".utf8)
        }
        if dropped > 0 {
            defer { dropped = 0 }
            return Data("{\"dropped\":\(dropped)}\n".utf8)
        }
        guard !lines.isEmpty else { return nil }
        let line = lines.removeFirst()
        bytes -= line.count
        return line
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func poll() {
        let client = SocketClient(path: socketPath)
        var state = EventStreamState(kinds: nil, limit: nil) // no cursor: the bootstrap read anchors at the tail
        while !isStopped {
            let rows: [Data]
            do {
                // shortcut: a hung app blocks this thread until it answers; add a receive timeout to the poller's SocketClient if leaked threads show up
                rows = try state.consume(client.send(state.makeRequest()).response).map { Data((try EventFormatter.json($0) + "\n").utf8) }
            } catch {
                // the app is gone or the cursor broke: start again from the tail, and say so if rows may be lost
                if state.cursor != nil { queue.async { [self] in markGap() } }
                state = EventStreamState(kinds: nil, limit: nil)
                Thread.sleep(forTimeInterval: 1)
                continue
            }
            guard !isStopped else { return }
            if rows.isEmpty {
                Thread.sleep(forTimeInterval: 0.25)
            } else {
                queue.async { [self] in append(rows) }
            }
        }
    }

    private func markGap() {
        guard !isStopped else { return }
        gap = true
        ready()
    }

    private func append(_ rows: [Data]) {
        guard !isStopped else { return }
        lines += rows
        bytes += rows.reduce(0) { $0 + $1.count }
        ready() // hands off to the scheduler first, so the bound counts only what waits here
        while bytes > Self.limit {
            bytes -= lines.removeFirst().count
            dropped += 1
        }
    }
}
#endif
