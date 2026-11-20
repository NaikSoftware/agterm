#if os(macOS)
import Foundation
import ElisCore

/// One `present` channel: subscribes to a session's presentation hub on its origin as `viewer.phone`, reports the panes
/// the phone leads there, and hands the pages it is given to the phone. Every method and callback runs on the relay
/// queue; the app request and the stream's connect run on plain threads.
final class PhoneLinkPresenter: @unchecked Sendable {
    /// How the presenter reaches its link; all run on the relay queue.
    struct Link {
        /// Sends a frame that bypasses the scheduler (OPENED, CLOSE).
        let frame: (PhoneLinkFrame) -> Void
        /// Queues one page line on the channel.
        let output: (Data) -> PhoneLinkScheduler.Enqueue
        /// Bytes of the channel waiting in the scheduler.
        let pending: () -> Int
        /// The channel is over: the link forgets this presenter.
        let ended: () -> Void
        /// A page left the presenter, for any cause; called once per page.
        let pageEnded: (_ page: String) -> Void
    }

    /// Opens the presentation stream for `origin`, or with a page token that page's pipe; runs off the relay queue.
    typealias Spawn = (ControlAttachOrigin, _ pageToken: String?) throws -> PhoneLinkLineStream
    /// Starts a remote row's `ssh -N -L` listener for one forwarded page; runs off the relay queue.
    typealias ForwardSpawn = ([String]) throws -> PhoneLinkLineStream

    static let kinds = [PresentationHub.leadReportKind] + PresentationHub.pageKinds
        + [PresentationHub.pageContentKind, PresentationHub.pageDocumentKind, PresentationHub.pendingSnapshotKind,
           PresentationHub.jobTokenKind, PresentationHub.offerIdentityKind, PresentationHub.viewerPhoneKind,
           PresentationHub.pageForwardKind]
    /// Page lines waiting in the scheduler past which page pipes are not resumed and memory answers wait. One memory
    /// chunk (under 88 KiB) and one pipe line (`maxPipeLine`) may follow the check: 160 + 88 + 260 KiB stays under the
    /// session's 512 KiB channel buffer, past which the channel overflows and closes.
    static let highWater = 160 * 1024
    /// A whole origin frame and the phone line's own framing.
    static let maxPipeLine = PresentationCodec.maxFrameBytes + 4 * 1024
    static let maxMime = 256
    static let maxPresenters = 8
    /// Requests one page may have waiting on its pipe.
    static let maxWaiting = 32

    let channel: UInt32
    let request: PhoneLinkOpen
    private let socketPath: String
    let queue: DispatchQueue
    private let peer: String
    let log: (String) -> Void
    let link: Link
    let spawn: Spawn
    let forwardSpawn: ForwardSpawn
    /// The renderer scripts' folder for markdown and text pages; nil when the install has none.
    let markdownDirectory: URL?
    lazy var assets = MarkdownAssets(directory: markdownDirectory)
    private var stream: PhoneLinkLineStream?
    private(set) var origin: ControlAttachOrigin?
    /// Pages by the origin's id, from their request until they close.
    var pages: [String: PresentedPage] = [:]
    /// Phone DATA past the last newline.
    var phoneLine = Data()
    /// Content and script answers served from memory, oldest first.
    var serving: [MemoryAnswer] = []
    /// The page whose pipe was resumed last, for round robin.
    var lastPipe = ""
    private var generation = 0
    /// The origin's hello listed `viewer.phone`; an older origin would route asks to a lead the phone reports.
    private var phoneOrigin = false
    private var leads: Set<UUID> = []
    private var sentLeads: Set<UUID> = []
    private var pendingBatch = PresentationPendingBatch()
    private(set) var stopped = false
    /// From the app request's send until the stream is connected or refused, even after `stop()`.
    private(set) var asking = false

    init(channel: UInt32, request: PhoneLinkOpen, socketPath: String, queue: DispatchQueue, peer: String,
         log: @escaping (String) -> Void, link: Link, spawn: Spawn? = nil, forwardSpawn: ForwardSpawn? = nil,
         markdownDirectory: URL? = PhoneLinkPresenter.bundledMarkdown) {
        self.channel = channel
        self.request = request
        self.socketPath = socketPath
        self.queue = queue
        self.peer = peer
        self.log = log
        self.link = link
        self.markdownDirectory = markdownDirectory
        self.forwardSpawn = forwardSpawn ?? { try .process(argv: Self.tiedToInput($0), queue: queue) }
        self.spawn = spawn ?? { origin, token in
            if let host = origin.host {
                return try .process(argv: Self.remoteArgv(host: host, session: origin.session, pageToken: token), queue: queue)
            }
            let request = token.map { ControlRequest(cmd: .sessionOverlayPageServe, target: $0) }
                ?? ControlRequest(cmd: .zmxPresent, target: origin.session)
            return try .socket(path: socketPath, request: request, queue: queue)
        }
    }

    static func remoteArgv(host: String, session: String, pageToken: String?) throws -> [String] {
        if let pageToken { return try RemoteSession.pageServeCommand(host: host, token: pageToken) }
        return try RemoteSession.presentCommand(host: host, session: session)
    }

    func start() {
        asking = true
        PhoneLinkTerminal.requestAttach(target: request.target, args: [:], socketPath: socketPath) { [self] result in
            guard case let .success(attach) = result, let origin = attach.origin else {
                return queue.async { [self] in
                    asking = false
                    guard !stopped else { return }
                    switch result {
                    case let .failure(refusal): refuse(refusal.message)
                    case .success: refuse("Elis is too old to show pages")
                    }
                }
            }
            let opened = Result { try spawn(origin, nil) }
            queue.async { [self] in
                asking = false
                self.origin = origin
                connected(opened)
            }
        }
    }

    /// Sent as `lead.report` only to an origin whose hello listed `viewer.phone`, and only when it changed.
    func setLeads(_ panes: Set<UUID>) {
        leads = panes
        reportLeads()
    }

    /// Ends the presentation stream first: the origin then retires the page pipes, where a pipe ending first would
    /// read as a lost page. A pipe the origin leaves open is closed after `pipeGrace`.
    func stop() {
        guard !stopped else { return }
        stopped = true
        stream?.close()
        // a forward listener is not the origin's, so nothing waits for the origin to retire it
        pages.values.filter(\.isForwarded).forEach { $0.pipe?.close() }
        let pipes = pages.values.filter { !$0.isForwarded }.compactMap(\.pipe)
        let ended = pages.keys
        pages = [:]
        ended.forEach(link.pageEnded)
        serving = []
        guard !pipes.isEmpty else { return }
        queue.asyncAfter(deadline: .now() + Self.pipeGrace) { pipes.forEach { $0.close() } }
    }

    private func connected(_ result: Result<PhoneLinkLineStream, Error>) {
        let stream: PhoneLinkLineStream
        switch result {
        case let .success(opened): stream = opened
        case let .failure(error):
            guard !stopped else { return }
            log("phone presentation failed from \(peer): \(error)")
            return refuse("could not reach the presentation: \(error)")
        }
        guard !stopped else { return stream.close() }
        self.stream = stream
        stream.start(onLine: { [weak self] line in self?.received(line) }, onEnd: { [weak self] in self?.close(reason: "presentation ended") })
        send(.hello(PresentationHello(version: PresentationCodec.version, kinds: Self.kinds, mode: .mirror)))
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened()))
    }

    /// Resumed at once, whatever the line: the hub drops a subscriber that stops reading.
    private func received(_ line: Data) {
        defer { stream?.resume() }
        guard !stopped, let frame = try? PresentationCodec.decode(line) else { return }
        if case let .hello(answer) = frame.body {
            generation = frame.gen
            phoneOrigin = answer.kinds.contains(PresentationHub.viewerPhoneKind)
            return reportLeads()
        }
        apply(frame.body)
    }

    private func apply(_ body: PresentationFrame.Body) {
        switch body {
        case .ping: send(.ack)
        case let .pageRequest(page): pageRequest(page)
        case let .pageClose(change): pageClose(change)
        case let .pageCommand(command): pageCommand(command)
        case let .pendingChunk(chunk): pendingBatch.add(chunk)
        case .pendingCommit:
            for entry in (try? pendingBatch.commit()) ?? [] {
                switch entry {
                case .pendingChunk, .pendingCommit: continue
                default: apply(entry)
                }
            }
        default: break
        }
    }

    func output(_ line: PhonePageDown) {
        // the scheduler has already dropped the channel's queue mid-line
        if link.output(PhonePageCodec.encode(line)) == .overflowed { close(reason: "overflow") }
    }

    private func reportLeads() {
        guard phoneOrigin, !stopped, leads != sentLeads else { return }
        sentLeads = leads
        send(.leadReport(PresentationLeadReport(leaders: leads.sorted { $0.uuidString < $1.uuidString })))
    }

    func send(_ body: PresentationFrame.Body) {
        guard let stream, let line = try? PresentationCodec.encode(PresentationFrame(gen: generation, rev: 0, body: body)) else { return }
        stream.send(line)
    }

    private func refuse(_ message: String) {
        stop()
        link.frame(.json(.opened, channel: channel, PhoneLinkOpened(error: message)))
        link.ended()
    }

    func close(reason: String) {
        guard !stopped else { return }
        stop()
        link.frame(.json(.close, channel: channel, PhoneLinkClose(reason: reason)))
        link.ended()
    }
}
#endif
