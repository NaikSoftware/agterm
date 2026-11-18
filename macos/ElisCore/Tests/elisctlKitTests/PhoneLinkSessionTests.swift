#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct PhoneLinkSessionTests {
    @Test func upgradeAnswersThenSpeaksFrames() throws {
        let (fixture, phone) = try MobileFixture.authenticated()
        defer { fixture.stop() }
        phone.deliver(PhoneLinkUpgrade.request)
        #expect(phone.readSent() == PhoneLinkUpgrade.answer)
        phone.deliver(Self.control(#"{"cmd":"tree","id":5}"# + "\n"))
        let reader = MuxReader()
        let answer = try #require(reader.json(from: phone))
        #expect(answer["id"] as? Int == 5 && (answer["result"] as? [String: Any])?["echo"] as? String == "tree")
    }

    @Test func leftoverBytesAfterUpgradeAreDecoded() throws {
        let (fixture, phone) = try MobileFixture.authenticated()
        defer { fixture.stop() }
        phone.deliver(PhoneLinkUpgrade.request + Self.control(#"{"cmd":"tree","id":7}"# + "\n"))
        #expect(phone.readSent() == PhoneLinkUpgrade.answer)
        let reader = MuxReader()
        #expect(reader.json(from: phone)?["id"] as? Int == 7)
    }

    @Test func upgradeAnswersAfterEarlierRequests() throws {
        let (fixture, phone) = try MobileFixture.authenticated()
        defer { fixture.stop() }
        phone.deliver(#"{"cmd":"tree","id":2}"# + "\n" + String(decoding: PhoneLinkUpgrade.request, as: UTF8.self))
        #expect(phone.readJSON()?["id"] as? Int == 2)
        #expect(phone.readSent() == PhoneLinkUpgrade.answer)
    }

    @Test func aLongAnswerSpansFrames() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        // the stub echoes the command name, so a long name makes an answer over one 16 KiB chunk
        let cmd = String(repeating: "x", count: 40000)
        phone.deliver(Self.control(#"{"cmd":"\#(cmd)","id":4}"# + "\n"))
        let reader = MuxReader()
        let answer = try #require(reader.json(from: phone))
        #expect(answer["id"] as? Int == 4 && (answer["result"] as? [String: Any])?["echo"] as? String == cmd)
    }

    @Test func aLineMaySpanFrames() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        phone.deliver(Self.control(#"{"cmd":"tr"#))
        phone.deliver(Self.control(#"ee","id":8}"#) + Self.control("\n"))
        let reader = MuxReader()
        let answer = try #require(reader.json(from: phone))
        #expect(answer["id"] as? Int == 8 && (answer["result"] as? [String: Any])?["echo"] as? String == "tree")
    }

    @Test func controlAnswersKeepRequestOrder() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        let before = fixture.server.requests().count
        phone.deliver(Self.control(#"{"cmd":"session.type","target":"S1","args":{"text":"a"},"id":2}"# + "\n"
            + #"{"cmd":"session.type","target":"S1","args":{"text":"b"},"id":3}"# + "\n"))
        let reader = MuxReader()
        #expect(reader.json(from: phone)?["id"] as? Int == 2)
        #expect(reader.json(from: phone)?["id"] as? Int == 3)
        #expect(Array(fixture.server.requests().dropFirst(before)) == [#"{"args":{"text":"a"},"cmd":"session.type","target":"S1"}"#,
                                                                     #"{"args":{"text":"b"},"cmd":"session.type","target":"S1"}"#])
    }

    @Test func gridSetOverMuxIsResetOnDisconnect() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        phone.deliver(Self.control(#"{"cmd":"session.grid","target":"S1","args":{"columns":40,"rows":20},"id":2}"# + "\n"))
        let reader = MuxReader()
        #expect(reader.json(from: phone)?["id"] as? Int == 2)
        let before = fixture.server.requests().count
        phone.peerLeft()
        #expect(fixture.server.waitFor(#"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#, after: before))
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
    }

    @Test(arguments: [false, true])
    func refusesPhoneAndAttachCommands(_ mux: Bool) throws {
        let (fixture, phone) = try mux ? MobileFixture.upgraded() : MobileFixture.authenticated()
        defer { fixture.stop() }
        let before = fixture.server.requests().count
        let reader = MuxReader()
        for (id, cmd) in ["phone.revoke", "session.attach", "tree"].enumerated() {
            let line = #"{"cmd":"\#(cmd)","target":"S1","id":\#(id + 2)}"# + "\n"
            phone.deliver(mux ? Self.control(line) : Data(line.utf8))
            let answer = try #require(mux ? reader.json(from: phone) : phone.readJSON())
            #expect(answer["id"] as? Int == id + 2)
            #expect(answer["ok"] as? Bool == (cmd == "tree"))
            if cmd != "tree" { #expect(answer["error"] as? String == "\(cmd.hasPrefix("phone.") ? "phone.*" : cmd) is not available from a phone") }
        }
        #expect(Array(fixture.server.requests().dropFirst(before)) == [#"{"cmd":"tree","target":"S1"}"#])
    }

    @Test func badFrameClosesTheLink() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        phone.deliver(Data([99, 0, 0, 0, 0, 0, 0, 0, 0]))
        #expect(phone.waitClosed())
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
    }

    @Test func revokeClosesAMuxLink() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        _ = try MobilePairing.loadToken(in: fixture.mobileDir, fresh: true)
        #expect(phone.waitClosed())
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
    }

    @Test func eventsArriveOnChannelOne() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        #expect(fixture.server.waitEventRead { $0 == nil }) // rows added before it are history
        // over 64 KiB: the hand-off must top channel 1 up again as the transport drains it
        fixture.server.addEvents(400, padding: 300)
        let reader = MuxReader(channel: 1)
        for seq in 1...400 { try #require(reader.json(from: phone)?["seq"] as? Int == seq) }
    }

    @Test func startsAfterTheLatestEvent() throws {
        let (fixture, phone) = try MobileFixture.authenticated()
        defer { fixture.stop() }
        fixture.server.addEvents(2)
        phone.deliver(PhoneLinkUpgrade.request)
        #expect(phone.readSent() == PhoneLinkUpgrade.answer)
        #expect(fixture.server.waitEventRead { $0 == nil })
        fixture.server.addEvents(1)
        #expect(MuxReader(channel: 1).json(from: phone)?["seq"] as? Int == 3)
        #expect(fixture.server.eventReadCursors().first == .some(nil))
    }

    /// A phone that takes nothing: the relay keeps at most 256 KiB of rows, drops the oldest and says how many.
    @Test func aSlowPhoneDropsOldEvents() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        #expect(fixture.server.waitEventRead { $0 == nil })
        phone.hold()
        // about 700 KiB: past the 16 KiB in flight, the 64 KiB hand-off and the 256 KiB queue
        let total = 2000
        fixture.server.addEvents(total, padding: 300)
        #expect(fixture.server.waitEventRead { $0 == UInt64(total) })
        fixture.relay.queue.sync {} // the last batch's hop ran before the read after it
        phone.release()
        let reader = MuxReader(channel: 1)
        var seqs: [Int] = [], dropped: [Int] = [], bytesBeforeDrop = 0, bytesAfterDrop = 0
        while seqs.last != total {
            let line = try #require(reader.line(from: phone))
            let object = try #require((try JSONSerialization.jsonObject(with: line)) as? [String: Any])
            if let count = object["dropped"] as? Int {
                dropped.append(count)
                seqs.append(-1)
            } else {
                seqs.append(try #require(object["seq"] as? Int))
                if dropped.isEmpty { bytesBeforeDrop += line.count + 1 } else { bytesAfterDrop += line.count + 1 }
            }
        }
        let count = try #require(dropped.count == 1 ? dropped[0] : nil)
        #expect(count > 0 && seqs.count - 1 + count == total)
        let mark = try #require(seqs.firstIndex(of: -1))
        #expect(seqs[mark + 1] == seqs[mark - 1] + count + 1)
        #expect(bytesAfterDrop <= 256 * 1024)
        // what the scheduler held: the 64 KiB hand-off, one 16 KiB chunk in flight and up to two rows of overshoot
        #expect(bytesBeforeDrop <= 80 * 1024 + 1024)
    }

    /// A broken cursor restarts the read at the tail; the phone hears it missed events before the next row.
    @Test func aRestartedReadSendsAGap() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        #expect(fixture.server.waitEventRead { $0 != nil })
        fixture.server.failNextEventRead()
        #expect(fixture.server.waitEventRead { _ in fixture.server.eventReadCursors().filter { $0 == nil }.count >= 2 })
        fixture.server.addEvents(1)
        let reader = MuxReader(channel: 1)
        #expect(reader.json(from: phone)?["gap"] as? Bool == true)
        #expect(reader.json(from: phone)?["seq"] as? Int == 1)
    }

    /// Rows still queued when the cursor breaks are older than the `tree` the gap makes the phone read, so they go.
    @Test func aGapSupersedesQueuedEvents() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        #expect(fixture.server.waitEventRead { $0 == nil })
        phone.hold()
        fixture.server.addEvents(1000, padding: 300) // about 360 KiB: past the hand-off, so rows wait in the queue
        #expect(fixture.server.waitEventRead { $0 == 1000 })
        fixture.server.failNextEventRead()
        #expect(fixture.server.waitEventRead { _ in fixture.server.eventReadCursors().filter { $0 == nil }.count >= 2 })
        fixture.relay.queue.sync {} // the gap's hop ran before the restarted read
        fixture.server.addEvents(1)
        phone.release()
        let reader = MuxReader(channel: 1)
        var lines: [[String: Any]] = []
        while lines.last?["seq"] as? Int != 1001 { lines.append(try #require(reader.json(from: phone))) }
        let gap = try #require(lines.firstIndex { $0["gap"] as? Bool == true })
        let before = lines[..<gap].compactMap { $0["seq"] as? Int }
        #expect(lines[(gap + 1)...].compactMap { $0["seq"] as? Int } == [1001])
        #expect(lines[(gap + 1)...].allSatisfy { $0["dropped"] == nil })
        #expect(before == before.sorted() && (before.last ?? 0) < 1001)
    }

    @Test func pollerStopsOnClose() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        #expect(fixture.server.waitEventRead { $0 != nil })
        phone.peerLeft()
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
        usleep(500_000) // a read already in flight may still land
        let reads = fixture.server.eventReadCursors().count
        usleep(1_000_000) // four poll periods
        #expect(fixture.server.eventReadCursors().count == reads)
    }

    // MARK: - helpers

    private static func control(_ text: String) -> Data {
        PhoneLinkFrame.data(channel: 0, Data(text.utf8)).encoded()
    }
}

#endif
