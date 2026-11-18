#if os(macOS)
import Foundation
import ElisCore

/// One phone's link after `{"mux":1}`: decodes frames, routes them by channel and sends the scheduler's frames one
/// at a time. Every method and every callback runs on the relay's queue.
final class PhoneLinkSession {
    static let maxChunk = 16384
    /// A vt channel's relay buffer.
    static let bufferLimit = 512 * 1024
    /// Event rows wait in `PhoneLinkEvents` while channel 1 already holds this much in the scheduler.
    static let eventsHandOff = 64 * 1024

    /// `send`'s completion runs once, on the relay queue, even when the link failed.
    private let send: (Data, @escaping () -> Void) -> Void
    /// Answers one channel-0 request line; the answer is a whole line, newline included.
    private let forward: (Data, @escaping (Data) -> Void) -> Void
    // the vt channels (later tasks) attach through the app socket and time their polls with the clock
    let socketPath: String
    let clock: () -> Date
    private let peer: String
    private let log: (String) -> Void
    /// The link ended itself, after a bad frame; the owner closes the connection.
    var onEnd: (() -> Void)?
    private var decoder = PhoneLinkDecoder()
    private var scheduler: PhoneLinkScheduler
    private var events: PhoneLinkEvents!
    private var control = Data()
    private var sending = false
    private var closed = false

    init(send: @escaping (Data, @escaping () -> Void) -> Void, forward: @escaping (Data, @escaping (Data) -> Void) -> Void,
         socketPath: String, queue: DispatchQueue, peer: String, window: UInt32, log: @escaping (String) -> Void,
         clock: @escaping () -> Date) {
        self.send = send
        self.forward = forward
        self.socketPath = socketPath
        self.peer = peer
        self.log = log
        self.clock = clock
        scheduler = PhoneLinkScheduler(window: window, bufferLimit: Self.bufferLimit)
        events = PhoneLinkEvents(socketPath: socketPath, queue: queue) { [weak self] in self?.pump() }
        events.start()
    }

    deinit { events.stop() }

    func receive(_ bytes: Data) {
        guard !closed else { return }
        let frames: [PhoneLinkFrame]
        do {
            frames = try decoder.feed(bytes)
        } catch {
            log("bad frame from \(peer): \(error)")
            return end()
        }
        for frame in frames {
            guard !closed else { return }
            switch (frame.kind, frame.channel) {
            case (.data, 0): receiveControl(frame.payload)
            default: break // the phone sends nothing on channel 1; vt channels (n >= 2) arrive in later tasks
            }
        }
    }

    /// Stops sending; the owner closes the transport.
    func close(reason _: String) {
        closed = true
        events.stop()
    }

    private func receiveControl(_ bytes: Data) {
        control.append(bytes)
        while !closed, let newline = control.firstIndex(of: 0x0A) {
            let line = Data(control[control.startIndex..<newline])
            control.removeSubrange(control.startIndex...newline)
            forward(line) { [weak self] answer in self?.enqueue(channel: 0, answer) }
        }
        if !closed, control.count > ControlWire.maxRequestLineBytes {
            log("request line too long from \(peer)")
            end()
        }
    }

    private func enqueue(channel: UInt32, _ bytes: Data) {
        guard !closed else { return }
        _ = scheduler.enqueue(channel: channel, bytes)
        pump()
    }

    /// One transport send in flight, so the scheduler, not the transport, holds what waits.
    private func pump() {
        guard !closed else { return }
        while scheduler.pendingBytes(channel: 1) < Self.eventsHandOff, let line = events.next() {
            _ = scheduler.enqueue(channel: 1, line)
        }
        guard !sending, let frame = scheduler.next(maxChunk: Self.maxChunk) else { return }
        sending = true
        send(frame.encoded()) { [weak self] in
            self?.sending = false
            self?.pump()
        }
    }

    private func end() {
        guard !closed else { return }
        closed = true
        events.stop()
        onEnd?()
    }
}
#endif
