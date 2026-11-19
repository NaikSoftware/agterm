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
    /// Open vt channels per phone, Take over channels included.
    static let maxTerminals = 8
    /// Channel 0's answers waiting in the scheduler, and frames waiting in `direct`, past which the link closes.
    static let controlLimit = 4 * 1024 * 1024
    static let directLimit = 256

    /// `send`'s completion runs once, on the relay queue, even when the link failed.
    private let send: (Data, @escaping () -> Void) -> Void
    /// Answers one channel-0 request line; the answer is a whole line, newline included.
    private let forward: (Data, @escaping (Data) -> Void) -> Void
    /// Whether the phone's pairing was revoked since it authenticated.
    private let revoked: () -> Bool
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
    /// Take over channels, which carry no DATA to the phone.
    private var claims: [UInt32: PhoneLinkClaim] = [:]
    /// Closed channels whose attach request still runs, as their `asking`: each keeps its slot until the answer, so
    /// OPEN and CLOSE in a loop cannot pile up app requests.
    private var leaving: [() -> Bool] = []
    /// OPENED, LEAD, CREDIT and CLOSE: they bypass the scheduler and go before its next frame; `sent` runs once out.
    private var direct: [(frame: PhoneLinkFrame, sent: (() -> Void)?)] = []
    private var control = Data()
    private var sending = false
    private var closed = false

    init(send: @escaping (Data, @escaping () -> Void) -> Void, forward: @escaping (Data, @escaping (Data) -> Void) -> Void,
         revoked: @escaping () -> Bool, socketPath: String, queue: DispatchQueue, peer: String, window: UInt32, log: @escaping (String) -> Void,
         clock: @escaping () -> Date) {
        self.send = send
        self.forward = forward
        self.revoked = revoked
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
                terminals[frame.channel]?.credited()
            case (.close, _):
                if let terminal = terminals[frame.channel] {
                    terminal.stop()
                } else if let claim = claims[frame.channel] {
                    claim.stop()
                } else {
                    break
                }
                closeChannel(frame.channel)
            case (.data, _): claims[frame.channel]?.input(frame.payload)
            case (.resize, _):
                guard let size = frame.size else { break }
                claims[frame.channel]?.resize(cols: size.cols, rows: size.rows)
            default: break // the phone sends nothing on channel 1, and a watch channel takes no input
            }
        }
    }

    /// Stops sending and ends every vt channel, each logging its detach line; the owner closes the transport.
    func close(reason _: String) {
        closed = true
        events.stop()
        // not guarded on `closed`: after `end()` the owner's close still has to end the channels
        let open = terminals.values
        let claimed = claims.values
        terminals = [:]
        claims = [:]
        claimed.forEach { $0.stop() }
        open.forEach { $0.stop() }
    }

    private func open(_ frame: PhoneLinkFrame) {
        let channel = frame.channel
        if revoked() { return endAfter(.json(.opened, channel: channel, PhoneLinkOpened(error: "revoked"))) }
        let refusal: String?
        let request = try? frame.decodeJSON(PhoneLinkOpen.self)
        if channel < 2 {
            refusal = "channels 0 and 1 are not vt channels"
        } else if terminals[channel] != nil || claims[channel] != nil {
            refusal = "channel already open"
        } else if request == nil {
            refusal = "malformed open"
        } else if request?.type != "vt" {
            refusal = "unsupported channel type"
        } else if terminals.count + claims.count + leaving.count(where: { $0() }) >= Self.maxTerminals {
            refusal = "too many open panes"
        } else {
            refusal = nil
        }
        guard let request, refusal == nil else {
            return sendDirect(.json(.opened, channel: channel, PhoneLinkOpened(error: refusal)))
        }
        if request.claim == true { return openClaim(channel, request) }
        let queue = queue
        let link = PhoneLinkTerminal.Link(
            opened: { [weak self] cols, rows in
                self?.scheduler.open(channel: channel)
                self?.sendDirect(.json(.opened, channel: channel, PhoneLinkOpened(cols: cols, rows: rows)))
            },
            resynced: { [weak self] cols, rows in
                self?.scheduler.open(channel: channel)
                self?.sendDirect(.resync(channel: channel))
                self?.sendDirect(.grid(channel: channel, cols: cols, rows: rows))
            },
            output: { [weak self] bytes in self?.enqueue(channel: channel, bytes) ?? .closed },
            frame: { [weak self] frame in self?.sendDirect(frame) },
            ended: { [weak self] in self?.closeChannel(channel) },
            windowSpent: { [weak self] in self?.scheduler.windowSpent(channel: channel) ?? false })
        let terminal = PhoneLinkTerminal(channel: channel, request: request, socketPath: socketPath, queue: queue, peer: peer,
                                         log: log, clock: clock, after: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) },
                                         link: link)
        terminals[channel] = terminal
        terminal.start()
    }

    private func openClaim(_ channel: UInt32, _ request: PhoneLinkOpen) {
        let queue = queue
        let link = PhoneLinkClaim.Link(
            frame: { [weak self] frame in self?.sendDirect(frame) },
            credit: { [weak self] bytes, sent in self?.sendDirect(.credit(channel: channel, bytes: bytes), sent: sent) },
            ended: { [weak self] in self?.closeChannel(channel) },
            // the daemon has resized by the report, so a fresh viewer attach is where old-grid bytes stop
            leadChanged: { [weak self] paneID in self?.watching(paneID).forEach { $0.resync() } },
            released: { [weak self] paneID in self?.watching(paneID).forEach { $0.pollSoon() } },
            // the poll catches a size the daemon applies after the fresh attach read it
            resized: { [weak self] paneID in self?.watching(paneID).forEach { $0.resync(); $0.pollSoon() } })
        let watched = terminals.values.first { $0.request.target == request.target && $0.request.pane == request.pane && $0.paneID != nil }
        let claim = PhoneLinkClaim(channel: channel, request: request, watched: watched?.paneID, socketPath: socketPath, queue: queue, peer: peer, log: log,
                                   after: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }, link: link)
        claims[channel] = claim
        claim.start()
    }

    private func watching(_ paneID: String) -> [PhoneLinkTerminal] {
        terminals.values.filter { $0.paneID == paneID }
    }

    private func closeChannel(_ channel: UInt32) {
        leaving.removeAll { !$0() }
        if let terminal = terminals.removeValue(forKey: channel), terminal.asking { leaving.append { terminal.asking } }
        if let claim = claims.removeValue(forKey: channel), claim.asking { leaving.append { claim.asking } }
        scheduler.close(channel: channel)
    }

    private func sendDirect(_ frame: PhoneLinkFrame, sent: (() -> Void)? = nil) {
        guard !closed else { return }
        direct.append((frame, sent))
        if direct.count > Self.directLimit { return overflowed() }
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
        if channel == 0, scheduler.pendingBytes(channel: 0) > Self.controlLimit {
            overflowed()
            return .closed
        }
        pump()
        return result
    }

    /// One transport send in flight, so the scheduler, not the transport, holds what waits.
    private func pump() {
        guard !closed else { return }
        while scheduler.pendingBytes(channel: 1) < Self.eventsHandOff, let line = events.next() {
            _ = scheduler.enqueue(channel: 1, line)
        }
        guard !sending, let (frame, sent) = direct.isEmpty ? scheduler.next(maxChunk: Self.maxChunk).map({ ($0, nil) }) : direct.removeFirst()
        else { return }
        sending = true
        send(frame.encoded()) { [weak self] in
            self?.sending = false
            sent?()
            self?.pump()
        }
    }

    /// Sends `frame` ahead of everything queued, then ends the link.
    private func endAfter(_ frame: PhoneLinkFrame) {
        closed = true
        events.stop()
        send(frame.encoded()) { [weak self] in self?.onEnd?() }
    }

    /// The phone reads less than it asks for; channel 1 drops instead, and vt channels resync.
    private func overflowed() {
        log("phone link overflow from \(peer)")
        end()
    }

    private func end() {
        guard !closed else { return }
        closed = true
        events.stop()
        onEnd?()
    }
}
#endif
