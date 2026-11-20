#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct PhoneLinkPresenterTests {
    static let pane = UUID()
    static let origin = ControlAttachOrigin(session: "O1", pane: pane.uuidString, host: nil)
    private static let leader = #"printf '\033]2;zmx-role;n1:leader:1\007'; "#

    // MARK: - through the link

    @Test func openPresentIsAccepted() throws {
        let (fixture, phone, stream) = try Self.presenting()
        defer { Self.finish(fixture, phone) }
        let request = try JSONDecoder().decode(ControlRequest.self, from: Data(stream.request.utf8))
        #expect(request.cmd == .zmxPresent && request.target == "O1")
        let hello = try #require(Self.hello(stream.frame()))
        #expect(hello.kinds.contains(PresentationHub.viewerPhoneKind) && hello.kinds.contains(PresentationHub.offerIdentityKind))
        #expect(!hello.kinds.contains(PresentationHub.presenterVacantKind))
        #expect(hello.mode == .mirror)
        #expect(FrameReader().opened(from: phone, channel: 5) == PhoneLinkOpened())
    }

    @Test func anAppWithoutOriginRefusesPresent() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        phone.deliver(Self.open(5))
        #expect(FrameReader().opened(from: phone, channel: 5) == PhoneLinkOpened(error: "Elis is too old to show pages"))
    }

    @Test func aSecondPresentForTheSessionIsRefused() throws {
        let (fixture, phone, stream) = try Self.presenting()
        defer { Self.finish(fixture, phone) }
        phone.deliver(Self.open(6))
        // a released stream ends the first channel, which would free the session
        withExtendedLifetime(stream) {
            #expect(FrameReader().opened(from: phone, channel: 6) == PhoneLinkOpened(error: "channel already open"))
        }
    }

    @Test func theLeadIsReportedWhileTheClaimIsOpen() throws {
        let (fixture, phone, stream) = try Self.presenting()
        defer { Self.finish(fixture, phone) }
        Self.answer(stream, gen: 3)
        phone.deliver(Self.claim(2))
        let reader = FrameReader()
        #expect(Self.lead(reader.next(from: phone, channel: 2, kind: .lead)) == "leader")
        let report = try #require(stream.frame { if case .leadReport = $0 { true } else { false } })
        #expect(report == PresentationFrame(gen: 3, rev: 0, body: .leadReport(PresentationLeadReport(leaders: [Self.pane]))))
        phone.deliver(PhoneLinkFrame.json(.close, channel: 2, PhoneLinkClose(reason: "done")).encoded())
        let withdrawn = try #require(stream.frame { if case .leadReport = $0 { true } else { false } })
        #expect(withdrawn.body == .leadReport(PresentationLeadReport(leaders: [])))
    }

    @Test func noLeadReportToAnOriginWithoutViewerPhone() throws {
        let (fixture, phone, stream) = try Self.presenting()
        defer { Self.finish(fixture, phone) }
        Self.answer(stream, gen: 3, kinds: PresentationHub.supportedKinds)
        phone.deliver(Self.claim(2))
        #expect(Self.lead(FrameReader().next(from: phone, channel: 2, kind: .lead)) == "leader")
        Self.send(stream, gen: 3, .ping)
        var seen: [PresentationFrame.Body] = []
        while let frame = stream.frame() {
            seen.append(frame.body)
            if frame.body == .ack { break }
        }
        #expect(seen.last == .ack)
        #expect(!seen.contains { if case .leadReport = $0 { true } else { false } })
    }

    @Test func aLeadHeldBeforeThePresentChannelIsReported() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        Self.serveOrigin(fixture.server)
        phone.deliver(Self.claim(2))
        #expect(Self.lead(FrameReader().next(from: phone, channel: 2, kind: .lead)) == "leader")
        phone.deliver(Self.open(5))
        let stream = try #require(fixture.server.nextStream())
        Self.answer(stream, gen: 4)
        let report = try #require(stream.frame { if case .leadReport = $0 { true } else { false } })
        #expect(report.body == .leadReport(PresentationLeadReport(leaders: [Self.pane])))
    }

    @Test func thePhoneClosingThePresentChannelEndsItsStream() throws {
        let (fixture, phone, stream) = try Self.presenting()
        defer { Self.finish(fixture, phone) }
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 5) == PhoneLinkOpened())
        phone.deliver(PhoneLinkFrame.json(.close, channel: 5, PhoneLinkClose(reason: "done")).encoded() + Self.open(6))
        #expect(stream.waitEnd())
        #expect(fixture.server.nextStream() != nil)
        #expect(reader.opened(from: phone, channel: 6) == PhoneLinkOpened())
    }

    @Test func aPingIsAcked() throws {
        let (fixture, phone, stream) = try Self.presenting()
        defer { Self.finish(fixture, phone) }
        Self.answer(stream, gen: 7)
        Self.send(stream, gen: 7, .ping)
        #expect(stream.frame { $0 == .ack } == PresentationFrame(gen: 7, rev: 0, body: .ack))
    }

    @Test func linkCloseEndsThePresenter() throws {
        let (fixture, phone, stream) = try Self.presenting()
        defer { fixture.stop() }
        phone.peerLeft()
        #expect(stream.waitEnd())
    }

    @Test func aPendingBatchDeliversItsPage() throws {
        let (fixture, phone, stream) = try Self.presenting()
        defer { Self.finish(fixture, phone) }
        Self.answer(stream, gen: 1)
        for chunk in try PresentationPendingBatch.chunks([.pageRequest(Self.urlPage)]) { Self.send(stream, gen: 1, .pendingChunk(chunk)) }
        Self.send(stream, gen: 1, .pendingCommit)
        let reader = MuxReader(channel: 5)
        let line = try #require(reader.line(from: phone))
        #expect(try JSONDecoder().decode(PhonePageDown.self, from: line) == .page(PhonePage(
            id: "p1", kind: "url", url: "https://example.com/", javascript: false, chromeless: false, browse: false, hidden: false,
            title: "example.com")))
    }

    // MARK: - one presenter

    @Test func aRemoteOriginIsReachedThroughItsArgv() throws {
        let remote = ControlAttachOrigin(session: "O1", pane: Self.pane.uuidString, host: "h")
        let harness = try Harness(origin: remote) { origin, token in
            throw SocketClientError("recorded \(origin.host ?? "-") \(token ?? "-")")
        }
        defer { harness.stop() }
        #expect(harness.frames().first == .json(.opened, channel: 5, PhoneLinkOpened(
            error: "could not reach the presentation: recorded h -")))
        #expect(try PhoneLinkPresenter.remoteArgv(host: "h", session: "O1", pageToken: nil)
            == RemoteSession.presentCommand(host: "h", session: "O1"))
        #expect(try PhoneLinkPresenter.remoteArgv(host: "h", session: "O1", pageToken: "t") == RemoteSession.pageServeCommand(host: "h", token: "t"))
    }

    @Test func thePresentationStreamIsReadWhileAPageWaits() throws {
        let harness = try Harness(pending: PhoneLinkPresenter.highWater + 1)
        defer { harness.stop() }
        let stream = try #require(harness.server.nextStream())
        Self.answer(stream, gen: 2)
        let page = PresentationPage(page: "p2", token: "t2", source: .file(path: "/w/index.html", grantRoot: "/w"), identity: "index.html",
                                    chromeless: false, javascript: false, navigation: false, browse: false, persistent: false,
                                    backgroundColor: nil, pane: nil, sizePercent: nil, follow: false)
        Self.send(stream, gen: 2, .pageRequest(page))
        let pipe = try #require(harness.server.nextStream())
        guard case .page = harness.line() else { Issue.record("no page line"); return }
        harness.phone(.fetch(id: "p2", seq: 1, path: "/w/a.css"))
        let resource = try #require(pipe.readLine().flatMap { try? PageServeCodec.decode($0) })
        for frame: PageServeFrame in [.head(id: resource.id, mimeType: "text/css"), .chunk(id: resource.id, data: Data("a".utf8)), .end(id: resource.id)] {
            pipe.send(try PageServeCodec.encode(frame))
        }
        Self.send(stream, gen: 2, .ping)
        #expect(stream.frame { $0 == .ack } != nil)
        #expect(harness.remainingLines().isEmpty)
        harness.pending = 0
        harness.drained()
        #expect(harness.line() == .res(id: "p2", seq: 1, mime: "text/css", data: nil, end: false, error: nil))
        #expect(harness.line() == .res(id: "p2", seq: 1, mime: nil, data: Data("a".utf8), end: false, error: nil))
        #expect(harness.line() == .res(id: "p2", seq: 1, mime: nil, data: nil, end: true, error: nil))
    }

    @Test func anOverflowClosesTheChannel() throws {
        let harness = try Harness(output: .overflowed)
        defer { harness.stop() }
        let stream = try #require(harness.server.nextStream())
        Self.answer(stream, gen: 2)
        Self.send(stream, gen: 2, .pageRequest(Self.urlPage))
        #expect(stream.waitEnd())
        #expect(harness.waitFrame(.json(.close, channel: 5, PhoneLinkClose(reason: "overflow"))))
        #expect(harness.waitEnded())
    }

    // MARK: - helpers

    static let urlPage = PresentationPage(
        page: "p1", token: "t1", source: .url("https://example.com/"), identity: "example.com", chromeless: false, javascript: false,
        navigation: false, browse: false, persistent: false, backgroundColor: nil, pane: nil, sizePercent: nil, follow: false)

    /// A link with a `present` channel 5 on S1 open, its origin stream held by the stub.
    static func presenting() throws -> (MobileFixture, MemoryPhone, StubStream) {
        let (fixture, phone) = try MobileFixture.upgraded()
        serveOrigin(fixture.server)
        phone.deliver(open(5))
        guard let stream = fixture.server.nextStream() else {
            finish(fixture, phone)
            throw CocoaError(.fileReadUnknown)
        }
        return (fixture, phone, stream)
    }

    /// Attaches carry the origin; a claim leads at once.
    static func serveOrigin(_ server: RawStubServer) {
        server.holdStreams("zmx.present")
        server.answerAttach { args in
            let attach = args["claim"] as? Bool == true ? RawStubServer.fakeAttach(leader + "exec cat >/dev/null", nonce: "n1", origin: origin)
                : RawStubServer.fakeAttach("printf 'hi'; cat", origin: origin)
            return ControlResponse(ok: true, result: ControlResult(attach: attach))
        }
    }

    static func answer(_ stream: StubStream, gen: Int,
                       kinds: [String] = PresentationHub.supportedKinds + [PresentationHub.viewerPhoneKind]) {
        send(stream, gen: gen, .hello(PresentationHello(version: 1, kinds: kinds.filter(PhoneLinkPresenter.kinds.contains), mode: .mirror)))
    }

    static func send(_ stream: StubStream, gen: Int, _ body: PresentationFrame.Body) {
        if let line = try? PresentationCodec.encode(PresentationFrame(gen: gen, rev: 1, body: body)) { stream.send(line) }
    }

    private static func hello(_ frame: PresentationFrame?) -> PresentationHello? {
        if case .hello(let hello) = frame?.body { hello } else { nil }
    }

    static func open(_ channel: UInt32) -> Data {
        PhoneLinkFrame.json(.open, channel: channel, PhoneLinkOpen(type: "present", target: "S1")).encoded()
    }

    private static func claim(_ channel: UInt32) -> Data {
        PhoneLinkFrame.json(.open, channel: channel, PhoneLinkOpen(type: "vt", target: "S1", pane: "left", claim: true, cols: 80, rows: 24)).encoded()
    }

    private static func lead(_ frame: PhoneLinkFrame?) -> String? { try? frame?.decodeJSON(PhoneLinkLead.self).role }

    static func finish(_ fixture: MobileFixture, _ phone: MemoryPhone) {
        phone.peerLeft()
        _ = fixture.waitLogged("phone disconnected from mem:1")
        fixture.stop()
    }

    /// One presenter on channel 5 over a stub app socket, with a link that records its frames.
    /// One presenter on channel 5 over a stub app socket, with a link that records its frames and page lines.
    final class Harness: @unchecked Sendable {
        let server = RawStubServer()
        let queue = DispatchQueue(label: "presenter.test")
        private let lock = NSLock()
        private var sent: [PhoneLinkFrame] = []
        private var lines: [Data] = []
        private var didEnd = false
        private var presenter: PhoneLinkPresenter!
        /// What `link.pending()` answers.
        var pending: Int {
            get { lock.withLock { pendingBytes } }
            set { lock.withLock { pendingBytes = newValue } }
        }
        private var pendingBytes: Int

        init(origin: ControlAttachOrigin = PhoneLinkPresenterTests.origin, pending: Int = 0,
             output: PhoneLinkScheduler.Enqueue = .queued, spawn: PhoneLinkPresenter.Spawn? = nil,
             markdownDirectory: URL? = Harness.markdown, buffer: Int? = nil) throws {
            pendingBytes = pending
            try server.start()
            server.holdStreams("zmx.present")
            server.holdStreams(Command.sessionOverlayPageServe.rawValue)
            server.answerAttach(ControlResponse(ok: true, result: ControlResult(attach: RawStubServer.fakeAttach("cat", origin: origin))))
            let link = PhoneLinkPresenter.Link(
                frame: { [weak self] frame in self?.lock.withLock { self?.sent.append(frame) } },
                // with a buffer, lines count toward `pending` and past it overflow, as the scheduler's queue does
                output: { [weak self] line in
                    self?.lock.withLock { () -> PhoneLinkScheduler.Enqueue in
                        guard let self else { return .closed }
                        self.lines.append(line)
                        guard let buffer else { return output }
                        self.pendingBytes += line.count
                        return self.pendingBytes > buffer ? .overflowed : .queued
                    } ?? .closed
                },
                pending: { [weak self] in self?.pending ?? 0 },
                ended: { [weak self] in self?.lock.withLock { self?.didEnd = true } })
            presenter = PhoneLinkPresenter(channel: 5, request: PhoneLinkOpen(type: "present", target: "S1"), socketPath: server.path,
                                           queue: queue, peer: "mem:1", log: { _ in }, link: link, spawn: spawn,
                                           markdownDirectory: markdownDirectory)
            queue.sync { presenter.start() }
        }

        /// The app bundle's renderer folder in this checkout.
        static let markdown = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../Elis/Resources/markdown")
            .standardizedFileURL

        /// Phone DATA as page lines.
        func phone(_ up: PhonePageUp) {
            var line = (try? JSONEncoder().encode(up)) ?? Data()
            line.append(0x0A)
            phoneBytes(line)
        }

        func phoneBytes(_ bytes: Data) { queue.async { [self] in presenter.receive(bytes) } }

        func drained() { queue.async { [self] in presenter.drained() } }

        func stopPresenter() { queue.sync { presenter.stop() } }

        /// The next page line, waiting for it.
        func line(timeout: TimeInterval = 30) -> PhonePageDown? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let line = lock.withLock({ lines.isEmpty ? nil : lines.removeFirst() }) {
                    return try? JSONDecoder().decode(PhonePageDown.self, from: line.dropLast())
                }
                usleep(10_000)
            }
            return nil
        }

        /// Every page line not read yet, once none came for `quiet` seconds.
        func remainingLines(quiet: TimeInterval = 0.5) -> [PhonePageDown] {
            var out: [PhonePageDown] = []
            while let line = line(timeout: quiet) { out.append(line) }
            return out
        }

        func frames() -> [PhoneLinkFrame] {
            let deadline = Date().addingTimeInterval(30)
            while lock.withLock({ sent.isEmpty }), Date() < deadline { usleep(20_000) }
            return lock.withLock { sent }
        }

        func waitFrame(_ frame: PhoneLinkFrame) -> Bool { wait { sent.contains(frame) } }

        func sentFrames() -> [PhoneLinkFrame] { lock.withLock { sent } }

        func waitEnded() -> Bool { wait { didEnd } }

        private func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(30)
            while !lock.withLock(condition) {
                if Date() > deadline { return false }
                usleep(20_000)
            }
            return true
        }

        func stop() {
            queue.sync { presenter.stop() }
            server.stop()
        }
    }
}
#endif
