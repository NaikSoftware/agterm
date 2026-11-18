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
        /// Queues output bytes on the channel.
        let output: (Data) -> PhoneLinkScheduler.Enqueue
        /// Sends a frame that bypasses the scheduler (OPENED with an error, CLOSE).
        let frame: (PhoneLinkFrame) -> Void
        /// The channel is over: the link closes it in the scheduler and forgets this terminal.
        let ended: () -> Void
    }

    /// A `screen` run that has not finished by then is killed.
    static let screenTimeout: TimeInterval = 5

    let channel: UInt32
    private let request: PhoneLinkOpen
    private let socketPath: String
    private let queue: DispatchQueue
    private let peer: String
    private let log: (String) -> Void
    private let link: Link
    // the resync and grid-poll timers (Task 6) read these
    let clock: () -> Date
    let after: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private var pty: PhoneLinkPty?
    private var paneID: String?
    private var filter = PhoneLinkTitleFilter()
    private var stopped = false

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

    /// Asks the app for the attach off the relay queue, so it does not wait behind the phone's control requests.
    func start() {
        var args: [String: Any] = [:]
        args["pane"] = request.pane
        let body = (try? JSONSerialization.data(withJSONObject: ["cmd": Command.sessionAttach.rawValue, "target": request.target,
                                                                 "args": args], options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        let socketPath = socketPath
        Thread.detachNewThread { [self] in
            let result: Result<(ControlAttach, ZmxScreen), Refusal>
            do {
                let answer = try JSONDecoder().decode(ControlResponse.self, from: SocketClient(path: socketPath).sendRaw(body))
                guard answer.ok, let attach = answer.result?.attach else {
                    throw Refusal(answer.error ?? "Elis gave no attach for this pane")
                }
                guard let screen = Self.screen(attach.screen) else { throw Refusal("could not read the pane's size") }
                result = .success((attach, screen))
            } catch let refusal as Refusal {
                result = .failure(refusal)
            } catch {
                result = .failure(Refusal("Elis is not reachable: \(error)"))
            }
            queue.async { [self] in attach(result) }
        }
    }

    /// Ends the channel without a word to the phone: the phone closed it, or the link is closing.
    func stop() {
        guard !stopped else { return }
        stopped = true
        pty?.terminate()
        if let paneID { log("phone detached from \(peer) pane \(paneID)") }
    }

    private func attach(_ result: Result<(ControlAttach, ZmxScreen), Refusal>) {
        guard !stopped else { return }
        let attach: ControlAttach, screen: ZmxScreen
        switch result {
        case let .success(answer): (attach, screen) = answer
        case let .failure(refusal): return refuse(refusal.message)
        }
        let cols = UInt16(screen.columns), rows = UInt16(screen.rows)
        do {
            // output and exit hop to the relay queue, so they come after OPENED and the attached line
            pty = try PhoneLinkPty.spawn(attach.argv, cols: cols, rows: rows, onOutput: { [weak self, queue] bytes in
                guard let self else { return }
                queue.async { self.receive(bytes) }
            }, onExit: { [weak self, queue] _ in
                guard let self else { return }
                queue.async { self.exited() }
            })
        } catch {
            return refuse("could not start the attach: \(error)")
        }
        link.opened(cols, rows)
        paneID = attach.paneID
        log("phone attached from \(peer) pane \(attach.paneID)")
    }

    private func refuse(_ message: String) {
        stopped = true
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened(error: message)))
        link.ended()
    }

    private func receive(_ bytes: Data) {
        guard !stopped else { return }
        let filtered = filter.filter(bytes)
        guard !filtered.isEmpty else { return }
        switch link.output(filtered) {
        case .queued, .closed: break
        // Task 6 replaces this with a resync
        case .overflowed: close(reason: "overflow")
        }
    }

    private func exited() {
        guard !stopped else { return }
        close(reason: "session ended")
    }

    /// Ends the channel and tells the phone why.
    private func close(reason: String) {
        stop()
        link.frame(.json(.close, channel: channel, PhoneLinkClose(reason: reason)))
        link.ended()
    }

    /// Runs `argv` with stdout captured and stderr dropped (an ssh warning must not reach the grid), killed after
    /// `screenTimeout`; nil when it fails or prints no usable grid. Blocks: call off the relay queue.
    private static func screen(_ argv: [String]) -> ZmxScreen? {
        guard let path = argv.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = Array(argv.dropFirst())
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + screenTimeout) { [process] in
            if process.isRunning { process.terminate() }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let screen = ZmxScreen(output: String(decoding: data, as: UTF8.self)),
              (1...Int(UInt16.max)).contains(screen.columns), (1...Int(UInt16.max)).contains(screen.rows) else { return nil }
        return screen
    }

    private struct Refusal: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
#endif
