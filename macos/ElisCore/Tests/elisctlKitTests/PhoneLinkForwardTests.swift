#if os(macOS)
import Darwin
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct PhoneLinkForwardTests {
    private static let request = Data("GET / HTTP/1.1\r\n\r\n".utf8)

    @Test func bytesPassBothWays() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        phone.deliver(Self.open(10))
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened())
        phone.deliver(PhoneLinkFrame.data(channel: 10, Self.request).encoded())
        let peer = try #require(server.nextPeer())
        #expect(peer.waitReceived(Self.request.count) == Self.request)
        let reply = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello".utf8)
        peer.write(reply)
        var received = Data()
        var credited: UInt32 = 0
        while received.count < reply.count || credited < Self.request.count {
            guard let frame = reader.next(from: phone, channel: 10) else { break }
            if frame.kind == .data { received.append(frame.payload) }
            if frame.kind == .credit { credited += frame.creditBytes ?? 0 }
        }
        #expect(received == reply)
        #expect(credited == UInt32(Self.request.count))
        phone.deliver(PhoneLinkFrame.data(channel: 10, Data("last".utf8)).encoded()
            + PhoneLinkFrame.json(.close, channel: 10, PhoneLinkClose(reason: "done")).encoded())
        #expect(peer.waitReceived(Self.request.count + 4)?.suffix(4) == Data("last".utf8))
        #expect(peer.waitEOF())
    }

    @Test func linkLossClosesTheSocket() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port)
        defer { withExtendedLifetime(link.stream) { link.fixture.stop() } }
        link.phone.deliver(Self.open(10))
        #expect(link.reader.opened(from: link.phone, channel: 10) == PhoneLinkOpened())
        let peer = try #require(server.nextPeer())
        link.phone.peerLeft()
        #expect(peer.waitEOF())
    }

    @Test func aForwardForAnUnknownPageIsRefused() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        phone.deliver(Self.open(10, page: "p9"))
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened(error: "no such page"))
        phone.deliver(PhoneLinkFrame.json(.open, channel: 11, PhoneLinkOpen(type: "forward", target: "S2", page: "p1")).encoded())
        #expect(reader.opened(from: phone, channel: 11) == PhoneLinkOpened(error: "no such page"))
        phone.deliver(PhoneLinkFrame.json(.open, channel: 12, PhoneLinkOpen(type: "forward", target: "S1")).encoded())
        #expect(reader.opened(from: phone, channel: 12) == PhoneLinkOpened(error: "no such page"))
    }

    @Test func aForwardAfterThePageClosedIsRefused() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        PhoneLinkPresenterTests.send(stream, gen: 1, .pageClose(PresentationPageChange(page: "p1")))
        #expect(Self.pageLine(reader, phone) == .command(id: "p1", seq: 0, action: "close", sizePercent: nil))
        phone.deliver(Self.open(10))
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened(error: "no such page"))
    }

    @Test func aDeadServerRefusesTheChannelAndKeepsThePage() throws {
        let port = try LoopbackServer.unusedPort()
        let link = try Self.linkedPage(port: port)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        phone.deliver(Self.open(10))
        let refused = try #require(reader.opened(from: phone, channel: 10)?.error)
        #expect(refused.hasPrefix("could not connect"))
        let server = try LoopbackServer(port: port)
        defer { server.stop() }
        phone.deliver(Self.open(10))
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened())
    }

    @Test func theSeventeenthConnectionIsRefused() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        let channels = (10..<UInt32(10 + PhoneLinkForward.maxForwards))
        channels.forEach { phone.deliver(Self.open($0)) }
        for channel in channels { #expect(reader.opened(from: phone, channel: channel) == PhoneLinkOpened()) }
        phone.deliver(Self.open(40))
        #expect(reader.opened(from: phone, channel: 40) == PhoneLinkOpened(error: "too many connections"))
        phone.deliver(PhoneLinkFrame.json(.close, channel: 10, PhoneLinkClose(reason: "done")).encoded() + Self.open(41))
        #expect(reader.opened(from: phone, channel: 41) == PhoneLinkOpened())
        phone.deliver(PhoneLinkFrame.data(channel: 11, Self.request).encoded())
        var peers: [LoopbackServer.Peer] = []
        while peers.count < PhoneLinkForward.maxForwards + 1, let peer = server.nextPeer() { peers.append(peer) }
        let deadline = Date().addingTimeInterval(30)
        while !peers.contains(where: { $0.waitReceived(Self.request.count, timeout: 0.05) != nil }), Date() < deadline {}
        #expect(peers.contains { $0.waitReceived(Self.request.count, timeout: 0.05) == Self.request })
    }

    @Test func aLargeBodyAndAnOpenSocketShareTheLink() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port, vt: true)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        phone.deliver(Self.open(10))
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened())
        let socket = try #require(server.nextPeer())
        phone.deliver(Self.open(11))
        #expect(reader.opened(from: phone, channel: 11) == PhoneLinkOpened())
        let download = try #require(server.nextPeer())
        let body = Data((0..<(2 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 13) })
        let writer = Thread {
            download.write(body)
            download.close()
        }
        writer.start()
        var received = Data()
        var vtDuring = false
        var close: PhoneLinkClose?
        let deadline = Date().addingTimeInterval(60)
        while close == nil, Date() < deadline, let frame = reader.next(from: phone) {
            switch (frame.channel, frame.kind) {
            case (11, .data):
                received.append(frame.payload)
                usleep(1000)
                phone.deliver(PhoneLinkFrame.credit(channel: 11, bytes: UInt32(frame.payload.count)).encoded())
            case (11, .close): close = try? frame.decodeJSON(PhoneLinkClose.self)
            case (2, .data): vtDuring = vtDuring || (received.count > 0 && received.count < body.count)
            default: break
            }
        }
        #expect(close == PhoneLinkClose(reason: "closed"))
        #expect(received == body)
        #expect(vtDuring)
        phone.deliver(PhoneLinkFrame.data(channel: 10, Data("ping".utf8)).encoded())
        #expect(socket.waitReceived(4) == Data("ping".utf8))
    }

    @Test func vtQueuedBehindAForwardGoesFirst() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let marks = FileManager.default.temporaryDirectory.appendingPathComponent("elis-vt-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: marks + ".done") }
        let burst = "while [ ! -e '\(marks).go' ]; do sleep 0.01; done; head -c 65536 /dev/zero | tr '\\0' v; touch '\(marks).done'; exec cat"
        let link = try Self.linkedPage(port: server.port, vt: true, vtScript: burst)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        phone.deliver(Self.open(11))
        #expect(reader.opened(from: phone, channel: 11) == PhoneLinkOpened())
        let download = try #require(server.nextPeer())
        let writer = Thread { download.write(Data(repeating: 0x66, count: 4 << 20)) }
        writer.start()
        var forwarded = 0
        while forwarded < 256 * 1024, let frame = reader.next(from: phone) { forwarded += Self.take(frame, phone) }
        phone.hold()
        FileManager.default.createFile(atPath: marks + ".go", contents: nil)
        defer { try? FileManager.default.removeItem(atPath: marks + ".go") }
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: marks + ".done"), Date() < deadline { usleep(10_000) }
        phone.release()
        // the burst's first run of vt bytes, up to the first forward frame after it; a pty buffer's tail may still trail
        var run = 0
        while let frame = reader.next(from: phone) {
            guard frame.kind == .data else { continue }
            if frame.channel == 2 { run += frame.payload.count } else if frame.channel == 11, run > 0 { break }
            _ = Self.take(frame, phone)
        }
        #expect(run >= 2 * PhoneLinkSession.maxChunk)
        download.close()
    }

    @Test func closingThePresentChannelClosesItsForwards() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        phone.deliver(Self.open(10))
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened())
        let peer = try #require(server.nextPeer())
        phone.deliver(PhoneLinkFrame.json(.close, channel: 5, PhoneLinkClose(reason: "done")).encoded())
        let close = try? reader.next(from: phone, channel: 10, kind: .close)?.decodeJSON(PhoneLinkClose.self)
        #expect(close == PhoneLinkClose(reason: "page closed"))
        #expect(peer.waitEOF())
    }

    @Test func closingThePageClosesItsForwards() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        phone.deliver(Self.open(10) + Self.open(11))
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened())
        #expect(reader.opened(from: phone, channel: 11) == PhoneLinkOpened())
        let peers = [server.nextPeer(), server.nextPeer()].compactMap { $0 }
        #expect(peers.count == 2)
        PhoneLinkPresenterTests.send(stream, gen: 1, .pageClose(PresentationPageChange(page: "p1")))
        for channel: UInt32 in [10, 11] {
            let close = try? reader.next(from: phone, channel: channel, kind: .close)?.decodeJSON(PhoneLinkClose.self)
            #expect(close == PhoneLinkClose(reason: "page closed"))
        }
        #expect(peers.allSatisfy { $0.waitEOF() })
    }

    @Test func inputPastTheWindowClosesTheChannel() throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        let link = try Self.linkedPage(port: server.port)
        let (fixture, phone, reader, stream) = (link.fixture, link.phone, link.reader, link.stream)
        defer { withExtendedLifetime(stream) { PhoneLinkPresenterTests.finish(fixture, phone) } }
        phone.deliver(Self.open(10))
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened())
        let chunk = Data(repeating: 0x61, count: 16384)
        var frames = Data()
        for _ in 0..<(PhoneLinkForward.window / chunk.count) { frames += PhoneLinkFrame.data(channel: 10, chunk).encoded() }
        phone.deliver(frames + PhoneLinkFrame.data(channel: 10, Data([0x62])).encoded())
        let close = try? reader.next(from: phone, channel: 10, kind: .close)?.decodeJSON(PhoneLinkClose.self)
        #expect(close == PhoneLinkClose(reason: "input overflow"))
    }

    // MARK: - helpers

    /// Credits a vt or forward DATA frame back at once; the forward bytes it carried.
    private static func take(_ frame: PhoneLinkFrame, _ phone: MemoryPhone) -> Int {
        guard frame.kind == .data, frame.channel == 2 || frame.channel == 11 else { return 0 }
        phone.deliver(PhoneLinkFrame.credit(channel: frame.channel, bytes: UInt32(frame.payload.count)).encoded())
        return frame.channel == 11 ? frame.payload.count : 0
    }

    private static func open(_ channel: UInt32, page: String = "p1") -> Data {
        PhoneLinkFrame.json(.open, channel: channel, PhoneLinkOpen(type: "forward", target: "S1", page: page)).encoded()
    }

    /// A link presenting S1 on channel 5 with page p1 forwarded to `port`, its page line read; with `vt`, channel 2 prints.
    private struct Linked {
        let fixture: MobileFixture
        let phone: MemoryPhone
        let reader: FrameReader
        let stream: StubStream
    }

    private static func linkedPage(port: UInt16, vt: Bool = false, vtScript: String = "while :; do printf v; sleep 0.01; done") throws -> Linked {
        let (fixture, phone) = try MobileFixture.upgraded()
        fixture.server.holdStreams("zmx.present")
        fixture.server.answerAttach(ControlResponse(ok: true, result: ControlResult(attach: RawStubServer.fakeAttach(
            vtScript, origin: PhoneLinkPresenterTests.origin))))
        if vt { phone.deliver(PhoneLinkFrame.json(.open, channel: 2, PhoneLinkOpen(type: "vt", target: "S1", pane: "left")).encoded()) }
        phone.deliver(PhoneLinkPresenterTests.open(5))
        let reader = FrameReader()
        guard let stream = fixture.server.nextStream() else {
            PhoneLinkPresenterTests.finish(fixture, phone)
            throw CocoaError(.fileReadUnknown)
        }
        PhoneLinkPresenterTests.answer(stream, gen: 1)
        var page = PhoneLinkPresenterTests.urlPage
        page.source = .forwarded("http://127.0.0.1:\(port)/")
        PhoneLinkPresenterTests.send(stream, gen: 1, .pageRequest(page))
        guard case .page = pageLine(reader, phone) else {
            PhoneLinkPresenterTests.finish(fixture, phone)
            throw CocoaError(.fileReadUnknown)
        }
        return Linked(fixture: fixture, phone: phone, reader: reader, stream: stream)
    }

    /// The next page line on channel 5; each fits one frame here.
    private static func pageLine(_ reader: FrameReader, _ phone: MemoryPhone) -> PhonePageDown? {
        reader.next(from: phone, channel: 5, kind: .data).flatMap { try? JSONDecoder().decode(PhonePageDown.self, from: $0.payload.dropLast()) }
    }
}

/// A TCP listener on 127.0.0.1 whose accepts and reads run on plain threads.
final class LoopbackServer: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var accepted: [Peer] = []
    private var all: [Peer] = []
    private var stopped = false

    init(port: UInt16 = 0) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = Self.loopback(port)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard fd >= 0, bound, listen(fd, 64) == 0 else {
            if fd >= 0 { Darwin.close(fd) }
            throw CocoaError(.fileWriteUnknown)
        }
        self.port = UInt16(bigEndian: address.sin_port)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        Thread { [weak self] in
            while let self, self.acceptOne() {}
        }.start()
    }

    /// Waits up to 100 ms for a client; false once stopped. Accepts under the lock, so `stop` never closes a busy fd.
    private func acceptOne() -> Bool {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        _ = poll(&poller, 1, 100)
        return lock.withLock {
            guard !stopped else { return false }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return true }
            _ = fcntl(client, F_SETFL, 0)
            let peer = Peer(client)
            accepted.append(peer)
            all.append(peer)
            return true
        }
    }

    /// A port nothing listens on.
    static func unusedPort() throws -> UInt16 {
        let server = try LoopbackServer()
        server.stop()
        return server.port
    }

    func nextPeer(timeout: TimeInterval = 30) -> Peer? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let peer = lock.withLock({ accepted.isEmpty ? nil : accepted.removeFirst() }) { return peer }
            usleep(10_000)
        }
        return nil
    }

    func stop() {
        let peers = lock.withLock {
            if !stopped { Darwin.close(fd) }
            stopped = true
            return all
        }
        peers.forEach { $0.close() }
    }

    private static func loopback(_ port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return address
    }

    final class Peer: @unchecked Sendable {
        private let fd: Int32
        private let lock = NSLock()
        private var received = Data()
        private var eof = false
        private var closed = false

        deinit { Darwin.close(fd) }

        init(_ fd: Int32) {
            self.fd = fd
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    lock.withLock {
                        if count > 0 { received.append(contentsOf: buffer[0..<count]) } else { eof = true }
                    }
                    if count <= 0 { return }
                }
            }.start()
        }

        func write(_ data: Data) {
            var offset = 0
            while offset < data.count {
                let count = data.withUnsafeBytes { UnixSocket.write(fd, $0.baseAddress! + offset, data.count - offset) }
                guard count > 0 else { return }
                offset += count
            }
        }

        /// The first `count` bytes received, waiting for them.
        func waitReceived(_ count: Int, timeout: TimeInterval = 30) -> Data? {
            wait(timeout) { received.count >= count ? received.prefix(count) : nil }
        }

        func waitEOF(timeout: TimeInterval = 30) -> Bool { wait(timeout) { eof ? true : nil } ?? false }

        /// Shuts the socket; the read thread then sees its end and nothing else touches it.
        func close() {
            lock.withLock {
                guard !closed else { return }
                closed = true
                Darwin.shutdown(fd, SHUT_RDWR)
            }
        }

        private func wait<T>(_ timeout: TimeInterval, _ value: () -> T?) -> T? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let value = lock.withLock(value) { return value }
                usleep(10_000)
            }
            return nil
        }
    }
}
#endif
