#if os(macOS)
import Foundation
import ElisCore

/// One vt channel: asks the app for the pane's viewer attach, reads its grid with `screen`, runs the attach on a pty
/// and hands its bytes, role titles removed, to the link. Every method and callback runs on the relay queue; the
/// app request and `screen` run on a plain `Thread`.
final class PhoneLinkTerminal: @unchecked Sendable {
    /// How the terminal reaches its link; all run on the relay queue.
    struct Link {
        /// Opens the channel in the scheduler and sends OPENED.
        let opened: (_ cols: UInt16, _ rows: UInt16) -> Void
        /// Resets the channel's queue and credit to the full window, then sends RESYNC and GRID.
        let resynced: (_ cols: UInt16, _ rows: UInt16) -> Void
        /// Queues output bytes on the channel.
        let output: (Data) -> PhoneLinkScheduler.Enqueue
        /// Sends a frame that bypasses the scheduler (OPENED with an error, GRID, CLOSE).
        let frame: (PhoneLinkFrame) -> Void
        /// The channel is over: the link closes it in the scheduler and forgets this terminal.
        let ended: () -> Void
        /// Bytes queued on the channel and not sent yet, for the stall watchdog.
        let pending: () -> Int
        /// A full window went out since the phone's last CREDIT, for the stall watchdog.
        let windowSpent: () -> Bool
    }

    /// A `screen` run that has not finished by then is killed.
    static let screenTimeout: TimeInterval = 5
    /// A hung app must not hold the attach request's thread forever.
    static let attachTimeout: TimeInterval = 10
    /// The wait before a re-attach after an overflow; each overflow within `backoffReset` of the previous re-attach
    /// doubles it, up to `maxBackoff`, so an old remote daemon that replays its scrollback costs one attach per 30 s.
    static let reattachInterval: TimeInterval = 1
    static let maxBackoff: TimeInterval = 30
    static let backoffReset: TimeInterval = 10
    /// This long with no CREDIT from the phone (since OPEN if none came), while it owes one, closes the channel.
    static let stallTimeout: TimeInterval = 30
    static let localPoll: TimeInterval = 2
    /// Each remote poll is a fresh ssh connection.
    static let remotePoll: TimeInterval = 10

    let channel: UInt32
    private let request: PhoneLinkOpen
    private let socketPath: String
    private let queue: DispatchQueue
    private let peer: String
    private let log: (String) -> Void
    private let link: Link
    let clock: () -> Date
    let after: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private var pty: PhoneLinkPty?
    /// Bumped for each attach and at an overflow, so bytes and the exit of a replaced attach are dropped.
    private var epoch = 0
    /// Set from the first attach on; until then a failure answers OPENED with an error.
    private var paneID: String?
    private var filter = PhoneLinkTitleFilter()
    private var stopped = false
    private var screenArgv: [String] = []
    private var remote = false
    /// The running `screen` (open, resync or poll), killed by `stop()`; at most one at a time.
    private var screenProcess: Process?
    /// The grid the phone last heard.
    private var grid: (cols: UInt16, rows: UInt16) = (0, 0)
    private var nextPoll = Date.distantFuture
    private var backoff = PhoneLinkTerminal.reattachInterval
    /// When the last re-attach after an overflow was asked for.
    private var reattached: Date?
    /// From an overflow until the fresh attach runs.
    private var resyncing = false
    /// The phone's last CREDIT, or OPENED until one comes; a RESYNC does not move it.
    private var lastCredit = Date.distantFuture

    init(channel: UInt32, request: PhoneLinkOpen, socketPath: String, queue: DispatchQueue, peer: String,
         log: @escaping (String) -> Void, clock: @escaping () -> Date,
         after: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void, link: Link) {
        self.channel = channel
        self.request = request
        self.socketPath = socketPath
        self.queue = queue
        self.peer = peer
        self.log = log
        self.clock = clock
        self.after = after
        self.link = link
    }

    func start() { requestAttach() }

    /// The phone sent CREDIT on this channel; the scheduler has already sent what it allows.
    func credited() {
        lastCredit = clock()
    }

    /// Ends the channel without a word to the phone: the phone closed it, or the link is closing.
    func stop() {
        guard !stopped else { return }
        stopped = true
        pty?.terminate()
        if let screenProcess, screenProcess.isRunning { screenProcess.terminate() }
        if let paneID { log("phone detached from \(peer) pane \(paneID)") }
    }

    /// Asks the app for the attach off the relay queue, so it does not wait behind the phone's control requests.
    private func requestAttach() {
        var args: [String: Any] = [:]
        args["pane"] = request.pane
        let body = (try? JSONSerialization.data(withJSONObject: ["cmd": Command.sessionAttach.rawValue, "target": request.target,
                                                                 "args": args], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let socketPath = socketPath
        Thread.detachNewThread { [self] in
            let result: Result<ControlAttach, Refusal>
            do {
                let line = try SocketClient(path: socketPath).sendRaw(body, timeout: Self.attachTimeout)
                let answer = try JSONDecoder().decode(ControlResponse.self, from: line)
                guard answer.ok, let attach = answer.result?.attach else {
                    throw Refusal(answer.error ?? "Elis gave no attach for this pane")
                }
                result = .success(attach)
            } catch let refusal as Refusal {
                result = .failure(refusal)
            } catch {
                result = .failure(Refusal("Elis is not reachable: \(error)"))
            }
            queue.async { [self] in answered(result) }
        }
    }

    private func answered(_ result: Result<ControlAttach, Refusal>) {
        guard !stopped else { return }
        let attach: ControlAttach
        switch result {
        case let .success(answer): attach = answer
        case let .failure(refusal): return fail(refusal.message)
        }
        screenArgv = attach.screen
        remote = attach.remote
        readScreen { [self] screen in
            guard let screen else { return fail("could not read the pane's size") }
            spawn(attach, cols: UInt16(screen.columns), rows: UInt16(screen.rows))
        }
    }

    private func spawn(_ attach: ControlAttach, cols: UInt16, rows: UInt16) {
        epoch += 1
        let epoch = epoch
        filter = PhoneLinkTitleFilter()
        do {
            // output and exit hop to the relay queue, so they come after OPENED (or RESYNC) and the attached line
            pty = try PhoneLinkPty.spawn(attach.argv, cols: cols, rows: rows, onOutput: { [weak self, queue] bytes in
                guard let self else { return }
                queue.async { self.receive(bytes, epoch: epoch) }
            }, onExit: { [weak self, queue] _ in
                guard let self else { return }
                queue.async { self.exited(epoch: epoch) }
            })
        } catch {
            return fail("could not start the attach: \(error)")
        }
        grid = (cols, rows)
        if resyncing {
            resyncing = false
            link.resynced(cols, rows) // a resync prints no viewer lines
            return
        }
        link.opened(cols, rows)
        lastCredit = clock()
        paneID = attach.paneID
        log("phone attached from \(peer) pane \(attach.paneID)")
        nextPoll = clock() + (remote ? Self.remotePoll : Self.localPoll)
        tick()
    }

    /// Before OPENED the phone hears OPENED with the error; after it, CLOSE with it.
    private func fail(_ message: String) {
        guard paneID != nil else { return refuse(message) }
        close(reason: message)
    }

    private func refuse(_ message: String) {
        stopped = true
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened(error: message)))
        link.ended()
    }

    private func receive(_ bytes: Data, epoch: Int) {
        guard !stopped, epoch == self.epoch else { return }
        let filtered = filter.filter(bytes)
        guard !filtered.isEmpty else { return }
        if link.output(filtered) == .overflowed { overflowed() }
    }

    /// The phone fell a whole buffer behind: drop this attach and start a fresh one, which repaints the screen.
    private func overflowed() {
        epoch += 1 // first: no byte of the old attach may follow RESYNC
        pty?.terminate()
        pty = nil
        if let reattached, clock().timeIntervalSince(reattached) < Self.backoffReset {
            backoff = min(backoff * 2, Self.maxBackoff)
        } else {
            backoff = Self.reattachInterval
        }
        resyncing = true
        after(backoff) { [weak self] in
            guard let self, !stopped else { return }
            reattached = clock()
            requestAttach()
        }
    }

    private func exited(epoch: Int) {
        guard !stopped, epoch == self.epoch else { return }
        close(reason: "session ended")
    }

    /// Once a second from the first attach on: the stall watchdog and the grid poll.
    private func tick() {
        after(1) { [weak self] in
            guard let self, !stopped else { return }
            let now = clock()
            // a pending resync alone owes nothing: during a backoff wait the phone gets no bytes to grant CREDIT for
            if now.timeIntervalSince(lastCredit) >= Self.stallTimeout, link.windowSpent() || link.pending() > 0 {
                return close(reason: "stalled")
            }
            if !resyncing, screenProcess == nil, now >= nextPoll {
                nextPoll = now + (remote ? Self.remotePoll : Self.localPoll)
                readScreen { [self] screen in
                    guard let screen, !resyncing else { return }
                    let size = (cols: UInt16(screen.columns), rows: UInt16(screen.rows))
                    guard size != grid else { return }
                    grid = size
                    // the viewer pty keeps its size: zmx ignores a follower's pty size, and the phone draws the daemon's grid
                    link.frame(.grid(channel: channel, cols: size.cols, rows: size.rows))
                }
            }
            tick()
        }
    }

    /// Ends the channel and tells the phone why.
    private func close(reason: String) {
        stop()
        link.frame(.json(.close, channel: channel, PhoneLinkClose(reason: reason)))
        link.ended()
    }

    /// Runs `screen` with stdout captured and stderr dropped (an ssh warning must not reach the grid), killed after
    /// `screenTimeout`; `done` gets nil when it fails or prints no usable grid, and never runs once stopped. An
    /// earlier run still going is killed, so one runs at a time.
    private func readScreen(_ done: @escaping @Sendable (ZmxScreen?) -> Void) {
        if let screenProcess, screenProcess.isRunning { screenProcess.terminate() }
        screenProcess = nil
        guard let path = screenArgv.first else { return done(nil) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(screenArgv.dropFirst())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // started here, so `stop()` on this queue always sees the process it must kill
        guard (try? process.run()) != nil else { return done(nil) }
        screenProcess = process
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.screenTimeout) { [process] in
            if process.isRunning { process.terminate() }
        }
        Thread.detachNewThread { [self] in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let screen = process.terminationReason == .exit && process.terminationStatus == 0
                ? ZmxScreen(output: String(decoding: data, as: UTF8.self)) : nil
            let usable = screen.flatMap {
                (1...Int(UInt16.max)).contains($0.columns) && (1...Int(UInt16.max)).contains($0.rows) ? $0 : nil
            }
            queue.async { [self] in
                guard screenProcess === process else { return } // replaced, or stopped
                screenProcess = nil
                guard !stopped else { return }
                done(usable)
            }
        }
    }

    private struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
#endif
