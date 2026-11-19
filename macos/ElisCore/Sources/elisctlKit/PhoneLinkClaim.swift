#if os(macOS)
import Foundation
import ElisCore

/// One Take over channel: asks the app for the pane's claiming attach, runs it on a pty at the phone's size and reads
/// its output only for the zmx role report. The phone's input goes to the pty under a receive window. Every method and
/// callback runs on the relay queue; the app request and the pty writes run on plain threads.
final class PhoneLinkClaim: @unchecked Sendable {
    /// How the claim reaches its link; all run on the relay queue.
    struct Link {
        /// Sends a frame that bypasses the scheduler (OPENED, LEAD, CLOSE).
        let frame: (PhoneLinkFrame) -> Void
        /// Sends CREDIT for `bytes`; `sent` runs once the frame has gone out.
        let credit: (_ bytes: UInt32, _ sent: @escaping () -> Void) -> Void
        /// The channel is over: the link forgets this claim.
        let ended: () -> Void
        /// The claim took the lead of `paneID`, or lost it to another client.
        let leadChanged: (_ paneID: String) -> Void
        /// The claim gave the lead of `paneID` up: the phone closed it, the link closed, or the attach ended.
        let released: (_ paneID: String) -> Void
        /// The leading claim's last RESIZE was `resyncDelay` ago.
        let resized: (_ paneID: String) -> Void
    }

    /// Input bytes the phone may send ahead of CREDIT.
    static let window = 16384
    /// A claiming attach that reports no role by then runs on a zmx that cannot hand the lead over.
    static let roleTimeout: TimeInterval = 10
    static let sizes: ClosedRange<UInt16> = 1...1000
    /// Lets the daemon apply a burst of resizes before the watch channels re-attach.
    static let resyncDelay: TimeInterval = 0.15

    let channel: UInt32
    private let request: PhoneLinkOpen
    /// The watch channel's pane id: a claim by role could land on the pane that took the role since.
    private let watched: String?
    private let socketPath: String
    private let queue: DispatchQueue
    private let peer: String
    private let log: (String) -> Void
    private let after: (TimeInterval, @escaping @Sendable () -> Void) -> Void
    private let link: Link
    private var pty: PhoneLinkPty?
    private var filter = PhoneLinkTitleFilter()
    private var lead: ZmxLeadState?
    /// The pty's size: the OPEN's until a RESIZE, and what OPENED reports.
    private var size: (cols: UInt16, rows: UInt16) = (0, 0)
    /// Set once `phone leads` is logged; `phone released` follows it exactly once.
    private(set) var paneID: String?
    private var stopped = false
    /// Input received and not yet acknowledged by a CREDIT sent.
    private var unacknowledged = 0
    /// Bytes written to the pty and not credited yet; one CREDIT waits on the link at a time.
    private var owed = 0
    private var crediting = false
    /// Bumped by each RESIZE, so only the last of a burst resyncs.
    private var resizes = 0
    /// From the app request's send until its answer is back on the relay queue, even after `stop()`.
    private(set) var asking = false

    init(channel: UInt32, request: PhoneLinkOpen, watched: String?, socketPath: String, queue: DispatchQueue, peer: String,
         log: @escaping (String) -> Void, after: @escaping (TimeInterval, @escaping @Sendable () -> Void) -> Void, link: Link) {
        self.channel = channel
        self.request = request
        self.watched = watched
        self.socketPath = socketPath
        self.queue = queue
        self.peer = peer
        self.log = log
        self.after = after
        self.link = link
    }

    func start() {
        guard let cols = request.cols, let rows = request.rows, Self.sizes.contains(cols), Self.sizes.contains(rows) else {
            return refuse("bad size")
        }
        size = (cols, rows)
        var args: [String: Any] = ["claim": true]
        args["pane"] = request.pane
        if let watched { args["paneID"] = watched }
        asking = true
        PhoneLinkTerminal.requestAttach(target: request.target, args: args, socketPath: socketPath) { [self] result in
            queue.async { [self] in
                asking = false
                answered(result)
            }
        }
    }

    /// Input before OPENED is dropped: the phone has no window yet, and the attach may never lead.
    func input(_ bytes: Data) {
        guard !stopped, paneID != nil, let pty else { return }
        unacknowledged += bytes.count
        if unacknowledged > Self.window { return close(reason: "input overflow") }
        pty.write(bytes) { [weak self, queue] count in
            guard let self else { return }
            queue.async { self.written(count) }
        }
    }

    /// A size outside 1...1000 is ignored.
    func resize(cols: UInt16, rows: UInt16) {
        guard !stopped, Self.sizes.contains(cols), Self.sizes.contains(rows) else { return }
        size = (cols, rows)
        pty?.resize(cols: cols, rows: rows)
        guard paneID != nil else { return } // the leader report resyncs anyway
        resizes += 1
        let resize = resizes
        after(Self.resyncDelay) { [weak self] in
            guard let self, !stopped, resizes == resize, let paneID else { return }
            link.resized(paneID)
        }
    }

    /// Ends the claim without a word to the phone: the phone closed it, or the link is closing.
    func stop() { stop(lost: false) }

    private func stop(lost: Bool) {
        guard !stopped else { return }
        stopped = true
        pty?.terminate()
        guard let paneID else { return }
        log("phone released from \(peer) pane \(paneID)")
        if !lost { link.released(paneID) }
    }

    private func answered(_ result: Result<ControlAttach, PhoneLinkTerminal.Refusal>) {
        guard !stopped else { return }
        let attach: ControlAttach
        switch result {
        case let .success(answer): attach = answer
        case let .failure(refusal): return refuse(refusal.message)
        }
        // an app that predates the claim answers a viewer attach, which would never lead
        guard let nonce = attach.nonce else { return refuse("Elis gave no claiming attach for this pane") }
        lead = ZmxLeadState(attachment: ZmxLeadAttachment(nonce: nonce, claim: true))
        do {
            pty = try PhoneLinkPty.spawn(attach.argv, cols: size.cols, rows: size.rows, onOutput: { [weak self, queue] bytes in
                guard let self else { return }
                queue.async { self.receive(bytes, paneID: attach.paneID) }
            }, onExit: { [weak self, queue] _ in
                guard let self else { return }
                queue.async { self.exited() }
            })
        } catch {
            return refuse("could not start the attach: \(error)")
        }
        after(Self.roleTimeout) { [weak self] in
            guard let self, !stopped, paneID == nil else { return }
            refuse("this host's zmx cannot hand over the lead; update Elis there")
        }
    }

    /// Output is discarded; only the role reports of this attach's nonce count.
    private func receive(_ bytes: Data, paneID pane: String) {
        guard !stopped else { return }
        var notices: [ZmxLeadNotice] = []
        _ = filter.filter(bytes, notices: &notices)
        for notice in notices {
            guard !stopped, lead?.apply(notice) == true, let role = lead?.role else { continue }
            if paneID == nil {
                // shortcut: a first report other than leader is ignored and the role timeout refuses; zmx 0001 gives a
                // claiming attach the lead at once
                guard role == .leader else { continue }
                link.frame(.json(.opened, channel: channel, PhoneLinkOpened(cols: size.cols, rows: size.rows)))
                guard !stopped else { return }
                link.frame(.json(.lead, channel: channel, PhoneLinkLead(role: role.rawValue)))
                guard !stopped else { return }
                paneID = pane
                log("phone leads from \(peer) pane \(pane)")
                link.leadChanged(pane)
            } else if role != .leader {
                link.frame(.json(.lead, channel: channel, PhoneLinkLead(role: role.rawValue)))
                guard !stopped else { return }
                stop(lost: true)
                link.frame(.json(.close, channel: channel, PhoneLinkClose(reason: "the computer took the lead back")))
                link.ended()
                link.leadChanged(pane)
                return
            }
        }
    }

    private func written(_ count: Int) {
        guard !stopped else { return }
        owed += count
        sendCredit()
    }

    private func sendCredit() {
        guard !stopped, !crediting, owed > 0 else { return }
        let bytes = owed
        owed = 0
        unacknowledged -= bytes
        crediting = true
        link.credit(UInt32(bytes)) { [weak self] in
            self?.crediting = false
            self?.sendCredit()
        }
    }

    private func exited() {
        guard !stopped else { return }
        if paneID == nil { return refuse("could not take over: the attach ended") }
        close(reason: "session ended")
    }

    /// Before OPENED the phone hears OPENED with the error.
    private func refuse(_ message: String) {
        stop()
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened(error: message)))
        link.ended()
    }

    /// Ends the channel and tells the phone why.
    private func close(reason: String) {
        stop()
        link.frame(.json(.close, channel: channel, PhoneLinkClose(reason: reason)))
        link.ended()
    }
}
#endif
