#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct PhoneLinkTerminalTests {
    @Test func openStreamsTheAttach() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        phone.deliver(Self.open(2))
        let reader = FrameReader()
        let opened = try #require(reader.opened(from: phone, channel: 2))
        #expect(opened == PhoneLinkOpened(cols: 80, rows: 24))
        #expect(reader.text(from: phone, channel: 2, until: "hi") != nil)
        #expect(fixture.waitLogged("phone attached from mem:1 pane pane-1"))
        #expect(fixture.server.requests().contains(#"{"args":{"pane":"left"},"cmd":"session.attach","target":"S1"}"#))
    }

    @Test func attachRefusalAnswersOpenedError() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        fixture.server.answerAttach(ControlResponse(ok: false, error: "session not realized"))
        phone.deliver(Self.open(2))
        let opened = try #require(FrameReader().opened(from: phone, channel: 2))
        #expect(opened == PhoneLinkOpened(error: "session not realized"))
        #expect(!fixture.logged().contains { $0.hasPrefix("phone attached") })
    }

    @Test func refusesControlChannelsAndDuplicates() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        // the duplicate comes while the first OPEN still waits for its attach
        phone.deliver(Self.open(0) + Self.open(1) + Self.open(2) + Self.open(2))
        let reader = FrameReader()
        for channel: UInt32 in [0, 1] {
            let refusal = try #require(reader.opened(from: phone, channel: channel))
            #expect(refusal == PhoneLinkOpened(error: "channels 0 and 1 are not vt channels"))
        }
        let answers = (0..<2).compactMap { _ in reader.opened(from: phone, channel: 2) }
        #expect(answers.contains(PhoneLinkOpened(error: "channel already open")))
        #expect(answers.contains(PhoneLinkOpened(cols: 80, rows: 24)))
        #expect(fixture.waitLogged("phone attached from mem:1 pane pane-1"))
        #expect(fixture.server.requests().filter { $0.contains("session.attach") }.count == 1)
    }

    @Test func refusesUnsizedClaimAndTooManyPanes() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        phone.deliver(Self.open(2, claim: true) + Self.open(3, type: "text") + (4...12).map { Self.open($0) }.reduce(Data(), +))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 2) == PhoneLinkOpened(error: "bad size"))
        #expect(reader.opened(from: phone, channel: 3) == PhoneLinkOpened(error: "unsupported channel type"))
        // the ninth is refused before the first eight have their attach
        #expect(reader.opened(from: phone, channel: 12) == PhoneLinkOpened(error: "too many open panes"))
        for channel: UInt32 in 4...11 {
            #expect(reader.opened(from: phone, channel: channel) == PhoneLinkOpened(cols: 80, rows: 24))
        }
    }

    @Test func roleTitlesNeverReachThePhone() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        fixture.server.answerAttach(Self.answer(#"printf 'a\033]2;zmx-role;n1:viewer\007b'; cat"#))
        phone.deliver(Self.open(2))
        let text = try #require(FrameReader().text(from: phone, channel: 2, until: "b"))
        #expect(text == "ab")
    }

    @Test func phoneCloseEndsTheAttach() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        let token = Self.token()
        fixture.server.answerAttach(Self.answer("printf 'hi'; cat; : \(token)"))
        phone.deliver(Self.open(2))
        let reader = FrameReader()
        #expect(reader.text(from: phone, channel: 2, until: "hi") != nil)
        phone.deliver(PhoneLinkFrame.json(.close, channel: 2, PhoneLinkClose(reason: "done")).encoded())
        #expect(fixture.waitLogged("phone detached from mem:1 pane pane-1"))
        #expect(Self.waitGone(token))
        // the channel number is free again
        phone.deliver(Self.open(2))
        #expect(reader.opened(from: phone, channel: 2) == PhoneLinkOpened(cols: 80, rows: 24))
        #expect(fixture.logged().filter { $0.hasPrefix("phone detached") }.count == 1)
    }

    @Test func attachExitClosesTheChannel() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        fixture.server.answerAttach(Self.answer("printf 'bye'"))
        phone.deliver(Self.open(2))
        let reader = FrameReader()
        let close = try #require(reader.next(from: phone, channel: 2, kind: .close))
        #expect((try? close.decodeJSON(PhoneLinkClose.self)) == PhoneLinkClose(reason: "session ended"))
        #expect(fixture.waitLogged("phone detached from mem:1 pane pane-1"))
    }

    @Test func disconnectEndsEveryAttach() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        let token = Self.token()
        fixture.server.answerAttach(Self.answer("printf 'hi'; cat; : \(token)"))
        phone.deliver(Self.open(2) + Self.open(3))
        let reader = FrameReader()
        for channel: UInt32 in [2, 3] { #expect(reader.next(from: phone, channel: channel, kind: .opened) != nil) }
        #expect(fixture.waitLogged("phone attached from mem:1 pane pane-1"))
        phone.peerLeft()
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
        let lines = fixture.logged()
        let detached = lines.indices.filter { lines[$0] == "phone detached from mem:1 pane pane-1" }
        #expect(detached.count == 2)
        #expect(detached.allSatisfy { $0 < lines.firstIndex(of: "phone disconnected from mem:1")! })
        #expect(Self.waitGone(token))
    }

    /// The phone holds every send, so the 600 KiB burst overflows the relay buffer; the next attach is quiet.
    @Test func overflowResyncs() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        let marker = NSTemporaryDirectory() + "elis-burst-\(UUID().uuidString.prefix(8))"
        defer { try? FileManager.default.removeItem(atPath: marker) }
        fixture.server.answerAttach(Self.answer(
            "if [ -e '\(marker)' ]; then printf fresh; else touch '\(marker)'; head -c 614400 /dev/zero | tr '\\0' x; fi; exec cat"))
        let before = fixture.server.requests().count
        phone.hold()
        phone.deliver(Self.open(2))
        #expect(Self.waitAttaches(fixture, 2, after: before))
        phone.release()
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 2) == PhoneLinkOpened(cols: 80, rows: 24))
        let resync = try #require(reader.next(from: phone, channel: 2))
        #expect(resync.kind == .resync)
        let grid = try #require(reader.next(from: phone, channel: 2))
        #expect(grid.kind == .grid && grid.size?.cols == 80 && grid.size?.rows == 24)
        #expect(reader.text(from: phone, channel: 2, until: "fresh") == "fresh")
        #expect(fixture.logged().filter { $0.hasPrefix("phone attached") }.count == 1)
    }

    /// The phone closes the channel while the app still thinks about the attach: nothing starts, the slot is free.
    @Test func closeBeforeTheAttachAnswerStartsNothing() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        defer { fixture.server.releaseAttach() }
        let before = fixture.server.requests().count
        fixture.server.holdAttach()
        phone.deliver(Self.open(2))
        #expect(Self.waitAttaches(fixture, 1, after: before))
        phone.deliver(PhoneLinkFrame.json(.close, channel: 2, PhoneLinkClose(reason: "done")).encoded())
        phone.deliver(Self.open(2))
        fixture.relay.queue.sync {} // both ran before the first answer
        fixture.server.releaseAttach()
        #expect(FrameReader().opened(from: phone, channel: 2) == PhoneLinkOpened(cols: 80, rows: 24))
        #expect(fixture.waitLogged("phone attached from mem:1 pane pane-1"))
        usleep(300_000) // the first answer has landed by now
        #expect(fixture.logged().filter { $0.hasPrefix("phone attached") }.count == 1)
        #expect(!fixture.logged().contains { $0.hasPrefix("phone detached") })
    }

    /// A closed channel keeps its slot while its attach request still runs, so OPEN+CLOSE cannot pile up requests.
    @Test func closedChannelsHoldTheirSlotUntilTheAnswer() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        defer { fixture.server.releaseAttach() }
        let before = fixture.server.requests().count
        fixture.server.holdAttach()
        let close = { (channel: UInt32) in PhoneLinkFrame.json(.close, channel: channel, PhoneLinkClose(reason: "done")).encoded() }
        phone.deliver((2...9).map { Self.open($0) + close($0) }.reduce(Data(), +) + Self.open(10))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened(error: "too many open panes"))
        #expect(Self.waitAttaches(fixture, 1, after: before))
        fixture.server.releaseAttach()
        // the answers land one at a time; a fresh channel opens once one slot is back
        let deadline = Date().addingTimeInterval(30)
        var channel: UInt32 = 10
        var opened: PhoneLinkOpened?
        while opened != PhoneLinkOpened(cols: 80, rows: 24), Date() < deadline {
            channel += 1
            usleep(50_000)
            phone.deliver(Self.open(channel))
            opened = reader.opened(from: phone, channel: channel)
        }
        #expect(opened == PhoneLinkOpened(cols: 80, rows: 24))
    }

    @Test func revokedPhoneCannotOpen() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        let before = fixture.server.requests().count
        // one relay-queue turn, so the revoke timer cannot close the link first
        try fixture.relay.queue.sync {
            _ = try MobilePairing.loadToken(in: fixture.mobileDir, fresh: true)
            phone.onReceive?(Self.open(2))
        }
        #expect(FrameReader().opened(from: phone, channel: 2) == PhoneLinkOpened(error: "revoked"))
        #expect(phone.waitClosed())
        #expect(!fixture.server.requests().dropFirst(before).contains { $0.contains("session.attach") })
    }

    // MARK: - helpers

    /// Whether `count` `session.attach` requests arrive after the first `before` requests.
    private static func waitAttaches(_ fixture: MobileFixture, _ count: Int, after before: Int) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while fixture.server.requests().dropFirst(before).filter({ $0.contains("session.attach") }).count < count {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    private static func open(_ channel: UInt32, type: String = "vt", claim: Bool? = nil) -> Data {
        PhoneLinkFrame.json(.open, channel: channel, PhoneLinkOpen(type: type, target: "S1", pane: "left", claim: claim)).encoded()
    }

    static func answer(_ script: String) -> ControlResponse {
        ControlResponse(ok: true, result: ControlResult(attach: RawStubServer.fakeAttach(script)))
    }

    /// A word that names this test's fake viewer in `ps`.
    static func token() -> String { "elis-fake-\(UUID().uuidString.prefix(8))" }

    /// Whether every process with `token` in its command line is gone, within a slow-runner bound.
    static func waitGone(_ token: String) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while true {
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-f", token]
            pgrep.standardOutput = FileHandle.nullDevice
            guard (try? pgrep.run()) != nil else { return false }
            pgrep.waitUntilExit()
            if pgrep.terminationStatus == 1 { return true }
            if Date() > deadline { return false }
            usleep(50_000)
        }
    }

    /// The phone leaves, so its attaches end, before the fixture goes.
    private static func finish(_ fixture: MobileFixture, _ phone: MemoryPhone) {
        phone.peerLeft()
        _ = fixture.waitLogged("phone disconnected from mem:1")
        fixture.stop()
    }
}

/// Reads the relay's frames back, one channel at a time; frames for other channels wait for their own read.
final class FrameReader {
    private var decoder = PhoneLinkDecoder()
    private var frames: [PhoneLinkFrame] = []

    /// The next frame on `channel`, of `kind` when given (others on that channel are skipped).
    func next(from phone: MemoryPhone, channel: UInt32, kind: PhoneLinkKind? = nil) -> PhoneLinkFrame? {
        while true {
            while let index = frames.firstIndex(where: { $0.channel == channel }) {
                let frame = frames.remove(at: index)
                if kind == nil || frame.kind == kind { return frame }
            }
            guard let bytes = phone.readSent(), let decoded = try? decoder.feed(bytes) else { return nil }
            frames += decoded
        }
    }

    /// Every frame not read yet, once the phone has been quiet for half a second.
    func pending(_ phone: MemoryPhone) -> [PhoneLinkFrame] {
        while let bytes = phone.readSent(timeout: 0.5), let decoded = try? decoder.feed(bytes) { frames += decoded }
        return frames
    }

    func opened(from phone: MemoryPhone, channel: UInt32) -> PhoneLinkOpened? {
        try? next(from: phone, channel: channel, kind: .opened)?.decodeJSON(PhoneLinkOpened.self)
    }

    /// DATA on `channel` joined until it contains `text`.
    func text(from phone: MemoryPhone, channel: UInt32, until text: String) -> String? {
        var joined = Data()
        while !String(decoding: joined, as: UTF8.self).contains(text) {
            guard let frame = next(from: phone, channel: channel, kind: .data) else { return nil }
            joined.append(frame.payload)
        }
        return String(decoding: joined, as: UTF8.self)
    }
}
#endif
