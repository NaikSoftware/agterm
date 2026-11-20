#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct PhoneLinkPresenterTests {
    private static let pane = UUID()
    private static let origin = ControlAttachOrigin(session: "O1", pane: pane.uuidString, host: nil)
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
    }

    @Test func thePresentationStreamIsReadWhileAPageWaits() throws {
        let harness = try Harness(pending: PhoneLinkPresenter.highWater + 1)
        defer { harness.stop() }
        let stream = try #require(harness.server.nextStream())
        Self.answer(stream, gen: 2)
        Self.send(stream, gen: 2, .pageRequest(Self.urlPage))
        Self.send(stream, gen: 2, .ping)
        #expect(stream.frame { $0 == .ack } != nil)
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

    private static let urlPage = PresentationPage(
        page: "p1", token: "t1", source: .url("https://example.com/"), identity: "example.com", chromeless: false, javascript: false,
        navigation: false, browse: false, persistent: false, backgroundColor: nil, pane: nil, sizePercent: nil, follow: false)

    /// A link with a `present` channel 5 on S1 open, its origin stream held by the stub.
    private static func presenting() throws -> (MobileFixture, MemoryPhone, StubStream) {
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
    private static func serveOrigin(_ server: RawStubServer) {
        server.holdStreams("zmx.present")
        server.answerAttach { args in
            let attach = args["claim"] as? Bool == true ? RawStubServer.fakeAttach(leader + "exec cat >/dev/null", nonce: "n1", origin: origin)
                : RawStubServer.fakeAttach("printf 'hi'; cat", origin: origin)
            return ControlResponse(ok: true, result: ControlResult(attach: attach))
        }
    }

    private static func answer(_ stream: StubStream, gen: Int,
                               kinds: [String] = PresentationHub.supportedKinds + [PresentationHub.viewerPhoneKind]) {
        send(stream, gen: gen, .hello(PresentationHello(version: 1, kinds: kinds.filter(PhoneLinkPresenter.kinds.contains), mode: .mirror)))
    }

    private static func send(_ stream: StubStream, gen: Int, _ body: PresentationFrame.Body) {
        if let line = try? PresentationCodec.encode(PresentationFrame(gen: gen, rev: 1, body: body)) { stream.send(line) }
    }

    private static func hello(_ frame: PresentationFrame?) -> PresentationHello? {
        if case .hello(let hello) = frame?.body { hello } else { nil }
    }

    private static func open(_ channel: UInt32) -> Data {
        PhoneLinkFrame.json(.open, channel: channel, PhoneLinkOpen(type: "present", target: "S1")).encoded()
    }

    private static func claim(_ channel: UInt32) -> Data {
        PhoneLinkFrame.json(.open, channel: channel, PhoneLinkOpen(type: "vt", target: "S1", pane: "left", claim: true, cols: 80, rows: 24)).encoded()
    }

    private static func lead(_ frame: PhoneLinkFrame?) -> String? { try? frame?.decodeJSON(PhoneLinkLead.self).role }

    private static func finish(_ fixture: MobileFixture, _ phone: MemoryPhone) {
        phone.peerLeft()
        _ = fixture.waitLogged("phone disconnected from mem:1")
        fixture.stop()
    }

    /// One presenter on channel 5 over a stub app socket, with a link that records its frames.
    private final class Harness: @unchecked Sendable {
        let server = RawStubServer()
        let queue = DispatchQueue(label: "presenter.test")
        private let lock = NSLock()
        private var sent: [PhoneLinkFrame] = []
        private var didEnd = false
        private var presenter: PhoneLinkPresenter!

        init(origin: ControlAttachOrigin = PhoneLinkPresenterTests.origin, pending: Int = 0,
             output: PhoneLinkScheduler.Enqueue = .queued, spawn: PhoneLinkPresenter.Spawn? = nil) throws {
            try server.start()
            server.holdStreams("zmx.present")
            server.answerAttach(ControlResponse(ok: true, result: ControlResult(attach: RawStubServer.fakeAttach("cat", origin: origin))))
            let link = PhoneLinkPresenter.Link(
                frame: { [weak self] frame in self?.lock.withLock { self?.sent.append(frame) } },
                output: { _ in output },
                pending: { pending },
                ended: { [weak self] in self?.lock.withLock { self?.didEnd = true } })
            presenter = PhoneLinkPresenter(channel: 5, request: PhoneLinkOpen(type: "present", target: "S1"), socketPath: server.path,
                                           queue: queue, peer: "mem:1", log: { _ in }, link: link, spawn: spawn)
            queue.sync { presenter.start() }
        }

        func frames() -> [PhoneLinkFrame] {
            let deadline = Date().addingTimeInterval(30)
            while lock.withLock({ sent.isEmpty }), Date() < deadline { usleep(20_000) }
            return lock.withLock { sent }
        }

        func waitFrame(_ frame: PhoneLinkFrame) -> Bool { wait { sent.contains(frame) } }

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
