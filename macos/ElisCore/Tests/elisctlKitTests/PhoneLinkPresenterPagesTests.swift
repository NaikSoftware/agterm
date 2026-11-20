#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct PhoneLinkPresenterPagesTests {
    typealias Harness = PhoneLinkPresenterTests.Harness

    // MARK: - one presenter

    @Test func aUrlPageBecomesAPageLine() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let stream = try Self.presentation(harness)
        var page = PhoneLinkPresenterTests.urlPage
        page.offer = 7
        Self.send(stream, .pageRequest(page))
        guard case .page(let line) = harness.line() else { Issue.record("no page line"); return }
        #expect(line.kind == "url" && line.url == "https://example.com/" && line.id == "p1")
        harness.phone(.state(id: "p1", load: "loaded", title: "T", current: "https://example.com/a", canGoBack: true, appliedSeq: 0,
                             hidden: false, error: nil))
        let state = try #require(stream.frame { if case .pageState = $0 { true } else { false } })
        #expect(state.body == .pageState(PresentationPageState(page: "p1", title: "T", address: "https://example.com/a", load: .loaded,
                                                               error: nil, canGoBack: true, canGoForward: false, hidden: false,
                                                               appliedSeq: 0, offer: 7)))
    }

    @Test func aLoopbackUrlIsRejected() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let stream = try Self.presentation(harness)
        var page = PhoneLinkPresenterTests.urlPage
        page.source = .url("http://localhost:3000/")
        page.offer = 2
        Self.send(stream, .pageRequest(page))
        let rejected = try #require(stream.frame { if case .pageRejected = $0 { true } else { false } })
        #expect(rejected.body == .pageRejected(PresentationPageChange(page: "p1", reason: "a loopback page cannot be shown on the phone", offer: 2)))
        #expect(harness.remainingLines().isEmpty)
    }

    @Test func aFetchIsServedThroughThePageChannel() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let (stream, pipe) = try Self.filePage(harness)
        defer { withExtendedLifetime(stream) {} }
        let request = try JSONDecoder().decode(ControlRequest.self, from: Data(pipe.request.utf8))
        #expect(request.cmd == .sessionOverlayPageServe && request.target == "t2")
        guard case .page(let line) = harness.line() else { Issue.record("no page line"); return }
        #expect(line.kind == "file" && line.path == "/w/index.html" && line.adapter == PhoneLinkPresenter.adapterScript(javascript: false))
        #expect(line.adapter?.contains("Object.defineProperty(window, 'elis'") == false)
        harness.phone(.fetch(id: "p2", seq: 3, path: "/w/a.css"))
        let resource = try #require(Self.pipeFrame(pipe))
        #expect(resource == .resource(id: resource.id, path: "/w/a.css"))
        Self.answer(pipe, [.head(id: resource.id, mimeType: "text/css"), .chunk(id: resource.id, data: Data("body{}".utf8)), .end(id: resource.id)])
        #expect(harness.line() == .res(id: "p2", seq: 3, mime: "text/css", data: nil, end: false, error: nil))
        #expect(harness.line() == .res(id: "p2", seq: 3, mime: nil, data: Data("body{}".utf8), end: false, error: nil))
        #expect(harness.line() == .res(id: "p2", seq: 3, mime: nil, data: nil, end: true, error: nil))
    }

    @Test func aFetchOutsideTheGrantIsRefused() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let (stream, pipe) = try Self.filePage(harness)
        defer { withExtendedLifetime(stream) {} }
        _ = harness.line()
        harness.phone(.fetch(id: "p2", seq: 4, path: "/etc/passwd"))
        let resource = try #require(Self.pipeFrame(pipe))
        Self.answer(pipe, [.failure(id: resource.id, error: "file is outside the page's folder")])
        #expect(harness.line() == .res(id: "p2", seq: 4, mime: nil, data: nil, end: true, error: "file is outside the page's folder"))
    }

    @Test func aBridgeLineNeverReachesChannelZero() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let (stream, pipe) = try Self.filePage(harness)
        defer { withExtendedLifetime(stream) {} }
        _ = harness.line()
        let line = #"{"cmd":"phone.status"}"#
        harness.phone(.bridge(id: "p2", seq: 5, line: line))
        let bridge = try #require(Self.pipeFrame(pipe))
        #expect(bridge == .bridge(id: bridge.id, request: line))
        Self.answer(pipe, [.failure(id: bridge.id, error: "phone.status cannot be sent from a page")])
        #expect(harness.line() == .reply(id: "p2", seq: 5, response: nil, error: "phone.status cannot be sent from a page"))
        #expect(!harness.server.requests().contains { $0.contains("phone.status") })
    }

    @Test func aUrlPageHasNoBridge() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let stream = try Self.presentation(harness)
        Self.send(stream, .pageRequest(PhoneLinkPresenterTests.urlPage))
        _ = harness.line()
        harness.phone(.bridge(id: "p1", seq: 1, line: #"{"cmd":"notify"}"#))
        #expect(harness.line() == .reply(id: "p1", seq: 1, response: nil, error: "this page has no bridge"))
    }

    @Test func closedRecordsDismissed() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let (stream, pipe) = try Self.filePage(harness)
        _ = harness.line()
        harness.phone(.closed(id: "p2", dismissed: true))
        let closed = try #require(stream.frame { if case .pageClosed = $0 { true } else { false } })
        #expect(closed.body == .pageClosed(PresentationPageChange(page: "p2", offer: 9)))
        #expect(pipe.waitEnd())
    }

    @Test func anOriginCloseIsAnsweredUnlessTheChannelWasLost() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let (stream, pipe) = try Self.filePage(harness)
        _ = harness.line()
        Self.send(stream, .pageClose(PresentationPageChange(page: "p2", reason: PresentationPageChange.channelLost)))
        #expect(harness.line() == .command(id: "p2", seq: 0, action: "close", sizePercent: nil))
        #expect(pipe.waitEnd())
        Self.send(stream, .pageRequest(Self.file))
        let second = try #require(harness.server.nextStream())
        _ = harness.line()
        Self.send(stream, .pageClose(PresentationPageChange(page: "p2")))
        Self.send(stream, .ping)
        var seen: [PresentationFrame.Body] = []
        while let frame = stream.frame() {
            seen.append(frame.body)
            if frame.body == .ack { break }
        }
        #expect(seen.filter { if case .pageClosed = $0 { true } else { false } } == [.pageClosed(PresentationPageChange(page: "p2", offer: 9))])
        #expect(second.waitEnd())
    }

    @Test func aHideBeforeThePageLineHidesIt() throws {
        let gate = DispatchSemaphore(value: 0)
        let box = HarnessBox()
        let harness = try Harness(spawn: { origin, token in
            while box.harness == nil { usleep(1000) }
            let harness = try #require(box.harness)
            guard let token else {
                return try .socket(path: harness.server.path, request: ControlRequest(cmd: .zmxPresent, target: origin.session), queue: harness.queue)
            }
            gate.wait()
            return try .socket(path: harness.server.path, request: ControlRequest(cmd: .sessionOverlayPageServe, target: token), queue: harness.queue)
        })
        box.harness = harness
        defer { harness.stop() }
        let stream = try #require(harness.server.nextStream())
        Self.hello(stream)
        Self.send(stream, .pageRequest(Self.file))
        Self.send(stream, .pageCommand(PresentationPageCommand(page: "p2", seq: 1, action: .hide)))
        Self.send(stream, .ping)
        #expect(stream.frame { $0 == .ack } != nil)
        gate.signal()
        guard case .page(let line) = harness.line() else { Issue.record("no page line"); return }
        #expect(line.hidden)
        #expect(harness.line() == .command(id: "p2", seq: 1, action: "hide", sizePercent: nil))
    }

    @Test func aBadPageLineClosesTheChannel() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let stream = try Self.presentation(harness)
        defer { withExtendedLifetime(stream) {} }
        harness.phoneBytes(Data("{\"t\":\"nonsense\"}\n".utf8))
        #expect(harness.waitFrame(.json(.close, channel: 5, PhoneLinkClose(reason: "bad page line"))))
    }

    @Test func aLineOverTheCapClosesTheChannel() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let stream = try Self.presentation(harness)
        defer { withExtendedLifetime(stream) {} }
        harness.phoneBytes(Data(repeating: 0x20, count: ControlWire.maxRequestLineBytes + 1))
        #expect(harness.waitFrame(.json(.close, channel: 5, PhoneLinkClose(reason: "bad page line"))))
    }

    @Test func stoppingClosesThePresentationStreamBeforeThePagePipe() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let (stream, pipe) = try Self.filePage(harness)
        _ = harness.line()
        harness.stopPresenter()
        #expect(stream.waitEnd())
        #expect(!pipe.waitEnd(timeout: 0.5))
        #expect(pipe.waitEnd())
    }

    @Test func aLogPageIsNotOffered() {
        #expect(!PhoneLinkPresenter.kinds.contains { ["page.text", "page.files", "page.links"].contains($0) })
    }

    @Test func aMarkdownPageCarriesTheUnlinkScript() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let stream = try Self.presentation(harness)
        Self.send(stream, .pageRequest(Self.content(.markdown(path: "/w/r.md"))))
        let pipe = try #require(harness.server.nextStream())
        let own = try #require(Self.pipeFrame(pipe))
        #expect(own == .resource(id: own.id, path: "/w/r.md"))
        Self.answer(pipe, Self.transfer(own.id, Data("![p](p.png) [web](https://example.com) [doc](other.md)\n".utf8)))
        let picture = try #require(Self.pipeFrame(pipe))
        #expect(picture == .resource(id: picture.id, path: "/w/p.png"))
        Self.answer(pipe, Self.transfer(picture.id, Self.png(16)))
        guard case .page(let line) = harness.line() else { Issue.record("no page line"); return }
        #expect(line.kind == "content" && line.path == nil && line.adapter == nil)
        let script = try #require(Self.fetchWhole(harness, id: "p3", path: PhonePage.scriptPath, seq: 1))
        #expect(String(decoding: script, as: UTF8.self).hasSuffix(PhoneLinkPresenter.unlinkScript))
        #expect(String(decoding: script, as: UTF8.self).contains("markdownit"))
        let html = String(decoding: try #require(Self.fetchWhole(harness, id: "p3", path: PhonePage.contentPath, seq: 2)), as: UTF8.self)
        #expect(!html.contains("data-links") && html.contains("png;base64,"))
    }

    @Test func aMissingRendererFolderRejectsTheMarkdownPage() throws {
        let harness = try Harness(markdownDirectory: URL(fileURLWithPath: "/nonexistent-elis-markdown"))
        defer { harness.stop() }
        let stream = try Self.presentation(harness)
        Self.send(stream, .pageRequest(Self.content(.markdown(path: "/w/r.md"))))
        let rejected = try #require(stream.frame { if case .pageRejected = $0 { true } else { false } })
        #expect(rejected.body == .pageRejected(PresentationPageChange(page: "p3", reason: "the markdown renderer is missing", offer: 4)))
    }

    @Test func aTextPageIsBuiltWithTheTextRenderer() throws {
        let harness = try Harness()
        defer { harness.stop() }
        let stream = try Self.presentation(harness)
        Self.send(stream, .pageRequest(Self.content(.text(path: "/w/main.swift", line: 2))))
        let pipe = try #require(harness.server.nextStream())
        let own = try #require(Self.pipeFrame(pipe))
        Self.answer(pipe, Self.transfer(own.id, Data("let a = 1\nlet b = 2\n".utf8)))
        guard case .page = harness.line() else { Issue.record("no page line"); return }
        let script = try #require(Self.fetchWhole(harness, id: "p3", path: PhonePage.scriptPath, seq: 1))
        #expect(String(decoding: script, as: UTF8.self) == MarkdownAssets(directory: Harness.markdown).textScript)
    }

    // MARK: - through the link

    @Test func aLargeFileDoesNotOverflowTheChannel() throws {
        let (fixture, phone, stream) = try Self.linked()
        defer { PhoneLinkPresenterTests.finish(fixture, phone) }
        Self.send(stream, .pageRequest(Self.file))
        let pipe = try #require(fixture.server.nextStream())
        let body = Self.pattern(2 << 20)
        let reader = LinkReader()
        guard case .page = reader.line(phone) else { Issue.record("no page line"); return }
        phone.deliver(PhoneLinkFrame.data(channel: 5, Self.up(.fetch(id: "p2", seq: 1, path: "/w/big.bin"))).encoded())
        let resource = try #require(Self.pipeFrame(pipe))
        let origin = Thread { Self.answer(pipe, Self.transfer(resource.id, body)) }
        origin.start()
        var joined = Data()
        var ended = false
        while !ended, let line = reader.line(phone) {
            guard case let .res(_, seq, _, data, end, error) = line, seq == 1, error == nil else { Issue.record("unexpected \(line)"); return }
            joined.append(data ?? Data())
            ended = end
        }
        #expect(ended && joined == body)
        #expect(reader.closed.isEmpty)
        #expect(reader.vtBeforeLastPageLine())
    }

    @Test func aLargeImagePageReachesThePhoneWhole() throws {
        let (fixture, phone, stream) = try Self.linked()
        defer { PhoneLinkPresenterTests.finish(fixture, phone) }
        Self.send(stream, .pageRequest(Self.content(.image(path: "/w/big.png", width: 10, height: 10))))
        let pipe = try #require(fixture.server.nextStream())
        let image = Self.png(2 << 20)
        let own = try #require(Self.pipeFrame(pipe))
        let origin = Thread { Self.answer(pipe, Self.transfer(own.id, image)) }
        origin.start()
        let reader = LinkReader()
        guard case .page(let page) = reader.line(phone) else { Issue.record("no page line"); return }
        #expect(page.kind == "content" && reader.lastLineBytes < PhoneLinkPresenter.highWater)
        phone.deliver(PhoneLinkFrame.data(channel: 5, Self.up(.fetch(id: "p3", seq: 1, path: PhonePage.contentPath))).encoded())
        var joined = Data()
        var ended = false
        while !ended, let line = reader.line(phone) {
            guard case let .res(_, 1, _, data, end, nil) = line else { Issue.record("unexpected \(line)"); return }
            #expect((data?.count ?? 0) <= PageServeCodec.maxChunkBytes)
            joined.append(data ?? Data())
            ended = end
        }
        #expect(ended && joined == Data(ImagePage.html(data: image, mimeType: "image/png").utf8))
        #expect(reader.closed.isEmpty)
        #expect(reader.vtBeforeLastPageLine())
    }

    // MARK: - helpers

    private static let file = {
        var page = PresentationPage(
            page: "p2", token: "t2", source: .file(path: "/w/index.html", grantRoot: "/w"), identity: "index.html", chromeless: false,
            javascript: false, navigation: false, browse: false, persistent: false, backgroundColor: nil, pane: nil, sizePercent: nil,
            follow: false)
        page.offer = 9
        return page
    }()

    private static func content(_ source: PresentationPageSource) -> PresentationPage {
        var page = PresentationPage(page: "p3", token: "t3", source: source, identity: "r.md", chromeless: false, javascript: false,
                                    navigation: false, browse: false, persistent: false, backgroundColor: nil, pane: nil,
                                    sizePercent: nil, follow: false)
        page.offer = 4
        return page
    }

    /// The presentation stream, answered.
    private static func presentation(_ harness: Harness) throws -> StubStream {
        let stream = try #require(harness.server.nextStream())
        hello(stream)
        return stream
    }

    private static func hello(_ stream: StubStream) { PhoneLinkPresenterTests.answer(stream, gen: 1) }

    private static func send(_ stream: StubStream, _ body: PresentationFrame.Body) { PhoneLinkPresenterTests.send(stream, gen: 1, body) }

    /// A file page requested, with its pipe.
    private static func filePage(_ harness: Harness) throws -> (StubStream, StubStream) {
        let stream = try presentation(harness)
        send(stream, .pageRequest(file))
        return (stream, try #require(harness.server.nextStream()))
    }

    private static func pipeFrame(_ pipe: StubStream) -> PageServeFrame? {
        pipe.readLine().flatMap { try? PageServeCodec.decode($0) }
    }

    private static func answer(_ pipe: StubStream, _ frames: [PageServeFrame]) {
        for frame in frames { if let line = try? PageServeCodec.encode(frame) { pipe.send(line) } }
    }

    private static func transfer(_ id: Int, _ data: Data) -> [PageServeFrame] {
        var frames: [PageServeFrame] = [.head(id: id, mimeType: "application/octet-stream")]
        for start in stride(from: 0, to: data.count, by: PageServeCodec.maxChunkBytes) {
            frames.append(.chunk(id: id, data: data.subdata(in: start..<min(start + PageServeCodec.maxChunkBytes, data.count))))
        }
        return frames + [.end(id: id)]
    }

    private static func pattern(_ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 9) }) }

    private static func png(_ count: Int) -> Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + pattern(count) }

    private static func up(_ line: PhonePageUp) -> Data {
        var data = (try? JSONEncoder().encode(line)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Every byte of `path` the relay answers from memory.
    private static func fetchWhole(_ harness: Harness, id: String, path: String, seq: Int) -> Data? {
        harness.phone(.fetch(id: id, seq: seq, path: path))
        var joined = Data()
        while let line = harness.line() {
            guard case let .res(_, lineSeq, _, data, end, nil) = line, lineSeq == seq else { return nil }
            joined.append(data ?? Data())
            if end { return joined }
        }
        return nil
    }

    /// A link with a vt channel 2 printing steadily and a `present` channel 5 whose stream is answered.
    private static func linked() throws -> (MobileFixture, MemoryPhone, StubStream) {
        let (fixture, phone) = try MobileFixture.upgraded()
        fixture.server.holdStreams("zmx.present")
        fixture.server.holdStreams(Command.sessionOverlayPageServe.rawValue)
        fixture.server.answerAttach(ControlResponse(ok: true, result: ControlResult(attach: RawStubServer.fakeAttach(
            "while :; do printf v; sleep 0.01; done", origin: PhoneLinkPresenterTests.origin))))
        phone.deliver(PhoneLinkFrame.json(.open, channel: 2, PhoneLinkOpen(type: "vt", target: "S1", pane: "left")).encoded())
        phone.deliver(PhoneLinkPresenterTests.open(5))
        guard let stream = fixture.server.nextStream() else {
            PhoneLinkPresenterTests.finish(fixture, phone)
            throw CocoaError(.fileReadUnknown)
        }
        hello(stream)
        return (fixture, phone, stream)
    }
}

final class HarnessBox: @unchecked Sendable { var harness: PhoneLinkPresenterTests.Harness? }

/// Reads channel 5's page lines off the phone, granting their credit one frame late, and records where vt DATA fell.
private final class LinkReader {
    private var decoder = PhoneLinkDecoder()
    private var frames: [PhoneLinkFrame] = []
    private var buffer = Data()
    private var lines = 0
    private(set) var closed: [PhoneLinkFrame] = []
    private(set) var lastLineBytes = 0
    /// The page line count when each vt DATA frame arrived.
    private var vtAt: [Int] = []

    func line(_ phone: MemoryPhone) -> PhonePageDown? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                lines += 1
                lastLineBytes = line.count
                return try? JSONDecoder().decode(PhonePageDown.self, from: line)
            }
            guard let bytes = phone.readSent(), let decoded = try? decoder.feed(bytes) else { return nil }
            for frame in decoded {
                switch (frame.channel, frame.kind) {
                case (5, .data):
                    buffer.append(frame.payload)
                    // a slow phone: its credit comes back a little after the bytes
                    usleep(2_000)
                    phone.deliver(PhoneLinkFrame.credit(channel: 5, bytes: UInt32(frame.payload.count)).encoded())
                case (5, .close): closed.append(frame)
                case (2, .data): vtAt.append(lines)
                default: break
                }
            }
        }
    }

    func vtBeforeLastPageLine() -> Bool {
        vtAt.contains { $0 > 1 && $0 < lines }
    }
}
#endif
