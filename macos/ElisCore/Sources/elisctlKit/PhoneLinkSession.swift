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
    /// Open vt channels per phone.
    static let maxTerminals = 8

    /// `send`'s completion runs once, on the relay queue, even when the link failed.
    private let send: (Data, @escaping () -> Void) -> Void
    /// Answers one channel-0 request line; the answer is a whole line, newline included.
    private let forward: (Data, @escaping (Data) -> Void) -> Void
    private let socketPath: String
    private let queue: DispatchQueue
    private let clock: () -> Date
    private let peer: String
    private let log: (String) -> Void
    /// The link ended itself, after a bad frame; the owner closes the connection.
    var onEnd: (() -> Void)?
    private var decoder = PhoneLinkDecoder()
    private var scheduler: PhoneLinkScheduler
    private var events: PhoneLinkEvents!
    /// Every vt channel from its OPEN on, so a duplicate or a ninth is refused while an attach is still asked for.
    private var terminals: [UInt32: PhoneLinkTerminal] = [:]
    /// OPENED and CLOSE: they bypass the scheduler and go before its next frame.
    private var direct: [PhoneLinkFrame] = []
    private var control = Data()
    private var sending = false
    private var closed = false

    init(send: @escaping (Data, @escaping () -> Void) -> Void, forward: @escaping (Data, @escaping (Data) -> Void) -> Void,
         socketPath: String, queue: DispatchQueue, peer: String, window: UInt32, log: @escaping (String) -> Void,
         clock: @escaping () -> Date) {
        self.send = send
        self.forward = forward
        self.socketPath = socketPath
        self.queue = queue
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
            case (.open, _): open(frame)
            case (.credit, _):
                scheduler.grant(channel: frame.channel, bytes: frame.creditBytes ?? 0)
                pump()
            case (.close, _):
                guard let terminal = terminals[frame.channel] else { break }
                terminal.stop()
                closeChannel(frame.channel)
            default: break // the phone sends nothing on channel 1; vt input and RESIZE come with Take over (M5)
            }
        }
    }

    /// Stops sending and ends every vt channel, each logging its detach line; the owner closes the transport.
    func close(reason _: String) {
        closed = true
        events.stop()
        // not guarded on `closed`: after `end()` the owner's close still has to end the channels
        let open = terminals.values
        terminals = [:]
        open.forEach { $0.stop() }
    }

    private func open(_ frame: PhoneLinkFrame) {
        let channel = frame.channel
        let refusal: String?
        let request = try? frame.decodeJSON(PhoneLinkOpen.self)
        if channel < 2 {
            refusal = "channels 0 and 1 are not vt channels"
        } else if terminals[channel] != nil {
            refusal = "channel already open"
        } else if request == nil {
            refusal = "malformed open"
        } else if request?.type != "vt" {
            refusal = "unsupported channel type"
        } else if request?.claim == true {
            refusal = "take over is not available yet"
        } else if terminals.count >= Self.maxTerminals {
            refusal = "too many open panes"
        } else {
            refusal = nil
        }
        guard let request, refusal == nil else {
            return sendDirect(.json(.opened, channel: channel, PhoneLinkOpened(error: refusal)))
        }
        let queue = queue
        let link = PhoneLinkTerminal.Link(
            opened: { [weak self] cols, rows in
                self?.scheduler.open(channel: channel)
                self?.sendDirect(.json(.opened, channel: channel, PhoneLinkOpened(cols: cols, rows: rows)))
            },
            output: { [weak self] bytes in self?.enqueue(channel: channel, bytes) ?? .closed },
            frame: { [weak self] frame in self?.sendDirect(frame) },
            ended: { [weak self] in self?.closeChannel(channel) })
        let terminal = PhoneLinkTerminal(channel: channel, request: request, socketPath: socketPath, queue: queue, peer: peer,
                                         log: log, clock: clock, after: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) },
                                         link: link)
        terminals[channel] = terminal
        terminal.start()
    }

    private func closeChannel(_ channel: UInt32) {
        terminals[channel] = nil
        scheduler.close(channel: channel)
    }

    private func sendDirect(_ frame: PhoneLinkFrame) {
        guard !closed else { return }
        direct.append(frame)
        pump()
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

    @discardableResult
    private func enqueue(channel: UInt32, _ bytes: Data) -> PhoneLinkScheduler.Enqueue {
        guard !closed else { return .closed }
        let result = scheduler.enqueue(channel: channel, bytes)
        pump()
        return result
    }

    /// One transport send in flight, so the scheduler, not the transport, holds what waits.
    private func pump() {
        guard !closed else { return }
        while scheduler.pendingBytes(channel: 1) < Self.eventsHandOff, let line = events.next() {
            _ = scheduler.enqueue(channel: 1, line)
        }
        guard !sending, let frame = direct.isEmpty ? scheduler.next(maxChunk: Self.maxChunk) : direct.removeFirst() else { return }
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
