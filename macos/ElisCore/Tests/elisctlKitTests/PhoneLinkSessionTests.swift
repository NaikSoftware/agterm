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

    /// A phone that pipelines requests and reads nothing: past 4 MiB of answers waiting, the link closes.
    @Test func controlAnswersPastTheBoundEndTheLink() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        phone.hold()
        let cmd = String(repeating: "x", count: 40000)
        phone.deliver((1...130).map { Self.control(#"{"cmd":"\#(cmd)","id":\#($0)}"# + "\n") }.reduce(Data(), +))
        #expect(phone.waitClosed())
        #expect(fixture.waitLogged("phone link overflow from mem:1"))
    }

    /// A phone that sends OPEN after OPEN and reads nothing: past 256 waiting answers, the link closes.
    @Test func directFramesPastTheBoundEndTheLink() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        phone.hold()
        let open = PhoneLinkFrame.json(.open, channel: 0, PhoneLinkOpen(type: "vt", target: "S1", pane: "left")).encoded()
        phone.deliver(Data(Array(repeating: open, count: 300).joined()))
        #expect(phone.waitClosed())
        #expect(fixture.waitLogged("phone link overflow from mem:1"))
    }

    /// The OPENED that passes the direct bound ends the link: the pane never counts as attached.
    @Test func openedPastTheBoundLogsNoAttach() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        phone.hold()
        // one refusal in flight and 256 waiting, so the vt channel's OPENED is the 257th
        let refused = PhoneLinkFrame.json(.open, channel: 0, PhoneLinkOpen(type: "vt", target: "S1", pane: "left")).encoded()
        let open = PhoneLinkFrame.json(.open, channel: 2, PhoneLinkOpen(type: "vt", target: "S1", pane: "left")).encoded()
        phone.deliver(Data(Array(repeating: refused, count: 257).joined()) + open)
        #expect(phone.waitClosed())
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
        usleep(300_000) // a late attach line would land by now
        #expect(!fixture.logged().contains { $0.hasPrefix("phone attached") })
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

    // MARK: - Take over

    @Test func claimOpenIsRouted() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        Self.answerClaims(fixture.server, Self.leader + "exec cat >/dev/null")
        phone.deliver(Self.open(2, claim: true, cols: 100, rows: 30))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 2) == PhoneLinkOpened(cols: 100, rows: 30))
        #expect(Self.lead(reader.next(from: phone, channel: 2, kind: .lead)) == "leader")
        #expect(fixture.waitLogged("phone leads from mem:1 pane pane-1"))
    }

    @Test func dataAndResizeReachTheClaim() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        let dir = fixture.mobileDir
        Self.answerClaims(fixture.server, Self.leader + #"read line; echo "$line" > '\#(dir)/one'; read x; stty size > '\#(dir)/two'; exec cat >/dev/null"#)
        phone.deliver(Self.open(2, claim: true))
        let reader = FrameReader()
        #expect(Self.lead(reader.next(from: phone, channel: 2, kind: .lead)) == "leader")
        phone.deliver(PhoneLinkFrame.data(channel: 2, Data("hello\n".utf8)).encoded())
        #expect(Self.waitFile(dir + "/one") == "hello\n")
        phone.deliver(PhoneLinkFrame.resize(channel: 2, cols: 100, rows: 40).encoded() + PhoneLinkFrame.data(channel: 2, Data("\n".utf8)).encoded())
        #expect(Self.waitFile(dir + "/two") == "40 100\n")
        var credited: UInt32 = 0
        while credited < 7, let frame = reader.next(from: phone, channel: 2, kind: .credit) { credited += frame.creditBytes ?? 0 }
        #expect(credited == 7)
    }

    /// DATA on the watch channel of the pane the phone leads reaches no attach and earns no CREDIT.
    @Test func dataOnAWatchChannelIsIgnored() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        let claimed = fixture.mobileDir + "/claimed"
        Self.answerClaims(fixture.server, Self.leader + "exec cat > '\(claimed)'")
        phone.deliver(Self.open(2) + Self.open(3, claim: true))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 2) == PhoneLinkOpened(cols: 80, rows: 24))
        #expect(Self.lead(reader.next(from: phone, channel: 3, kind: .lead)) == "leader")
        phone.deliver(PhoneLinkFrame.data(channel: 2, Data("zz\n".utf8)).encoded() + PhoneLinkFrame.data(channel: 3, Data("ok\n".utf8)).encoded())
        #expect(Self.waitFile(claimed) == "ok\n")
        #expect(reader.next(from: phone, channel: 3, kind: .credit)?.creditBytes == 3)
        #expect(!reader.pending(phone).contains { $0.channel == 2 && ($0.kind == .credit || String(decoding: $0.payload, as: UTF8.self).contains("zz")) })
    }

    /// A claim closed while its attach request runs keeps its slot until the answer.
    @Test func closedClaimHoldsItsSlotUntilTheAnswer() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        defer { fixture.server.releaseAttach() }
        Self.answerClaims(fixture.server, Self.leader + "exec cat >/dev/null")
        fixture.server.holdAttach()
        let close = PhoneLinkFrame.json(.close, channel: 2, PhoneLinkClose(reason: "done")).encoded()
        phone.deliver(Self.open(2, claim: true) + close + (3...10).map { Self.open($0) }.reduce(Data(), +))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened(error: "too many open panes"))
        fixture.server.releaseAttach()
        for channel: UInt32 in 3...9 { #expect(reader.opened(from: phone, channel: channel) == PhoneLinkOpened(cols: 80, rows: 24)) }
    }

    @Test func claimCountsTowardTheCap() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        Self.answerClaims(fixture.server, Self.leader + "exec cat >/dev/null")
        phone.deliver(Self.open(2, claim: true) + Self.open(2) + (3...10).map { Self.open($0) }.reduce(Data(), +))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 10) == PhoneLinkOpened(error: "too many open panes"))
        let answers = (0..<2).compactMap { _ in reader.opened(from: phone, channel: 2) }
        #expect(answers.contains(PhoneLinkOpened(error: "channel already open")))
        for channel: UInt32 in 3...9 { #expect(reader.opened(from: phone, channel: channel) == PhoneLinkOpened(cols: 80, rows: 24)) }
    }

    @Test func linkCloseEndsTheClaim() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { fixture.stop() }
        let token = PhoneLinkTerminalTests.token()
        Self.answerClaims(fixture.server, Self.leader + "exec cat >/dev/null; : \(token)")
        phone.deliver(Self.open(2, claim: true))
        #expect(Self.lead(FrameReader().next(from: phone, channel: 2, kind: .lead)) == "leader")
        phone.peerLeft()
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
        let lines = fixture.logged()
        let released = try #require(lines.firstIndex(of: "phone released from mem:1 pane pane-1"))
        #expect(released < lines.firstIndex(of: "phone disconnected from mem:1")!)
        #expect(PhoneLinkTerminalTests.waitGone(token))
    }

    @Test func leadChangeResyncsTheWatchChannelOfThatPane() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        Self.answerClaims(fixture.server, Self.leader + "exec cat >/dev/null")
        phone.deliver(Self.open(2) + Self.open(3, pane: "right"))
        let reader = FrameReader()
        for channel: UInt32 in [2, 3] { #expect(reader.opened(from: phone, channel: channel) == PhoneLinkOpened(cols: 80, rows: 24)) }
        #expect(fixture.waitLogged("phone attached from mem:1 pane pane-2"))
        phone.deliver(Self.open(4, claim: true))
        #expect(Self.lead(reader.next(from: phone, channel: 4, kind: .lead)) == "leader")
        #expect(reader.next(from: phone, channel: 2, kind: .resync) != nil)
        #expect(reader.next(from: phone, channel: 2)?.kind == .grid)
        usleep(500_000) // a resync of pane-2 would be out by now
        #expect(!reader.pending(phone).contains { $0.channel == 3 && $0.kind == .resync })
    }

    /// The watch pane is remote, so its own grid poll is 30 s away: the GRID comes from the poll the claim asked for.
    @Test(arguments: [false, true])
    func phoneCloseOfTheClaimPollsSoon(_ resize: Bool) throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        let grid = fixture.mobileDir + "/grid"
        try "1 80 24 0 0 0\n".write(toFile: grid, atomically: true, encoding: .utf8)
        Self.answerClaims(fixture.server, Self.leader + "exec cat >/dev/null",
                          viewer: RawStubServer.fakeAttach("printf hi; exec cat", screen: "cat '\(grid)'", remote: true))
        phone.deliver(Self.open(2))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 2) == PhoneLinkOpened(cols: 80, rows: 24))
        phone.deliver(Self.open(3, claim: true))
        #expect(Self.lead(reader.next(from: phone, channel: 3, kind: .lead)) == "leader")
        #expect(reader.next(from: phone, channel: 2, kind: .grid)?.size?.cols == 80) // the resync's
        try "1 100 30 0 0 0\n".write(toFile: grid, atomically: true, encoding: .utf8)
        let started = Date()
        phone.deliver(resize ? PhoneLinkFrame.resize(channel: 3, cols: 100, rows: 30).encoded()
            : PhoneLinkFrame.json(.close, channel: 3, PhoneLinkClose(reason: "done")).encoded())
        if resize { #expect(reader.next(from: phone, channel: 2, kind: .resync) != nil) }
        let size = reader.next(from: phone, channel: 2, kind: .grid)?.size
        #expect(size?.cols == 100 && size?.rows == 30)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func claimNamesTheWatchedPane() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        Self.answerClaims(fixture.server, Self.leader + "exec cat >/dev/null", viewer: RawStubServer.fakeAttach("printf hi; cat", paneID: "P1"))
        phone.deliver(Self.open(2))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 2) == PhoneLinkOpened(cols: 80, rows: 24))
        phone.deliver(Self.open(3, claim: true))
        #expect(Self.lead(reader.next(from: phone, channel: 3, kind: .lead)) == "leader")
        #expect(fixture.server.requests().contains(
            #"{"args":{"claim":true,"pane":"left","paneID":"P1"},"cmd":"session.attach","target":"S1"}"#))
    }

    @Test func claimWithoutAWatchNamesTheRole() throws {
        let (fixture, phone) = try MobileFixture.upgraded()
        defer { Self.finish(fixture, phone) }
        Self.answerClaims(fixture.server, Self.leader + "exec cat >/dev/null")
        phone.deliver(Self.open(3, pane: "right") + Self.open(2, claim: true))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 3) == PhoneLinkOpened(cols: 80, rows: 24))
        #expect(Self.lead(reader.next(from: phone, channel: 2, kind: .lead)) == "leader")
        #expect(fixture.server.requests().contains(#"{"args":{"claim":true,"pane":"left"},"cmd":"session.attach","target":"S1"}"#))
    }

    @Test func resizeOfTheClaimResyncsTheWatchChannel() throws {
        let (fixture, phone, reader) = try Self.watchedClaim()
        defer { Self.finish(fixture, phone) }
        try "1 100 40 0 0 0\n".write(toFile: fixture.mobileDir + "/grid", atomically: true, encoding: .utf8)
        let viewers = Self.viewerAttaches(fixture.server)
        phone.deliver(PhoneLinkFrame.resize(channel: 3, cols: 100, rows: 40).encoded())
        #expect(reader.next(from: phone, channel: 2, kind: .resync) != nil)
        let size = reader.next(from: phone, channel: 2)?.size
        #expect(size?.cols == 100 && size?.rows == 40)
        #expect(Self.viewerAttaches(fixture.server) == viewers + 1)
        #expect(!reader.pending(phone).contains { $0.channel == 2 && $0.kind == .resync })
    }

    @Test func aBurstOfResizesResyncsOnce() throws {
        let (fixture, phone, reader) = try Self.watchedClaim()
        defer { Self.finish(fixture, phone) }
        phone.deliver([90, 95, 100].map { PhoneLinkFrame.resize(channel: 3, cols: $0, rows: 40).encoded() }.reduce(Data(), +))
        #expect(reader.next(from: phone, channel: 2, kind: .resync) != nil)
        #expect(!reader.pending(phone).contains { $0.channel == 2 && $0.kind == .resync })
    }

    @Test func resizeOutOfRangeDoesNotResync() throws {
        let (fixture, phone, reader) = try Self.watchedClaim()
        defer { Self.finish(fixture, phone) }
        try Self.expectNoResync(fixture, phone, reader, after: PhoneLinkFrame.resize(channel: 3, cols: 0, rows: 40).encoded())
    }

    @Test func resizeThenCloseDoesNotResync() throws {
        let (fixture, phone, reader) = try Self.watchedClaim()
        defer { Self.finish(fixture, phone) }
        try Self.expectNoResync(fixture, phone, reader, after: PhoneLinkFrame.resize(channel: 3, cols: 100, rows: 40).encoded()
            + PhoneLinkFrame.json(.close, channel: 3, PhoneLinkClose(reason: "done")).encoded())
    }

    // MARK: - helpers

    /// A watch on `left` (channel 2) with its screen read from `<mobileDir>/grid`, and a leading claim on channel 3,
    /// past the lead change's resync.
    private static func watchedClaim() throws -> (MobileFixture, MemoryPhone, FrameReader) {
        let (fixture, phone) = try MobileFixture.upgraded()
        let grid = fixture.mobileDir + "/grid"
        try "1 80 24 0 0 0\n".write(toFile: grid, atomically: true, encoding: .utf8)
        answerClaims(fixture.server, leader + "exec cat >/dev/null", viewer: RawStubServer.fakeAttach("printf hi; exec cat", screen: "cat '\(grid)'"))
        phone.deliver(open(2))
        let reader = FrameReader()
        #expect(reader.opened(from: phone, channel: 2) == PhoneLinkOpened(cols: 80, rows: 24))
        phone.deliver(open(3, claim: true))
        #expect(lead(reader.next(from: phone, channel: 3, kind: .lead)) == "leader")
        #expect(reader.next(from: phone, channel: 2, kind: .resync) != nil)
        #expect(reader.next(from: phone, channel: 2)?.kind == .grid)
        return (fixture, phone, reader)
    }

    private static func expectNoResync(_ fixture: MobileFixture, _ phone: MemoryPhone, _ reader: FrameReader, after frames: Data) throws {
        let viewers = viewerAttaches(fixture.server)
        phone.deliver(frames)
        usleep(500_000) // a resync would be out by now
        #expect(!reader.pending(phone).contains { $0.channel == 2 && $0.kind == .resync })
        #expect(viewerAttaches(fixture.server) == viewers)
    }

    private static func viewerAttaches(_ server: RawStubServer) -> Int {
        server.requests().filter { $0.contains("session.attach") && !$0.contains(#""claim":true"#) }.count
    }

    private static let leader = #"printf '\033]2;zmx-role;n1:leader:1\007'; "#

    /// A claim on any pane answers `claim`; a watch on the right pane is pane-2, every other watch `viewer`.
    private static func answerClaims(_ server: RawStubServer, _ claim: String,
                                     viewer: ControlAttach = RawStubServer.fakeAttach("printf 'hi'; cat")) {
        server.answerAttach { args in
            let attach = args["claim"] as? Bool == true ? RawStubServer.fakeAttach(claim, nonce: "n1")
                : args["pane"] as? String == "right" ? RawStubServer.fakeAttach("printf 'hi'; cat", paneID: "pane-2") : viewer
            return ControlResponse(ok: true, result: ControlResult(attach: attach))
        }
    }

    private static func open(_ channel: UInt32, pane: String = "left", claim: Bool? = nil, cols: UInt16? = 80, rows: UInt16? = 24) -> Data {
        let request = claim == true ? PhoneLinkOpen(type: "vt", target: "S1", pane: pane, claim: true, cols: cols, rows: rows)
            : PhoneLinkOpen(type: "vt", target: "S1", pane: pane)
        return PhoneLinkFrame.json(.open, channel: channel, request).encoded()
    }

    private static func lead(_ frame: PhoneLinkFrame?) -> String? { try? frame?.decodeJSON(PhoneLinkLead.self).role }

    private static func waitFile(_ path: String) -> String? {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8), text.hasSuffix("\n") { return text }
            usleep(20_000)
        }
        return nil
    }

    /// Every frame sent until the phone has been quiet for half a second.
    private static func drain(_ phone: MemoryPhone) -> [PhoneLinkFrame] {
        var decoder = PhoneLinkDecoder()
        var frames: [PhoneLinkFrame] = []
        while let bytes = phone.readSent(timeout: 0.5) { frames += (try? decoder.feed(bytes)) ?? [] }
        return frames
    }

    private static func finish(_ fixture: MobileFixture, _ phone: MemoryPhone) {
        phone.peerLeft()
        _ = fixture.waitLogged("phone disconnected from mem:1")
        fixture.stop()
    }

    private static func control(_ text: String) -> Data {
        PhoneLinkFrame.data(channel: 0, Data(text.utf8)).encoded()
    }
}

#endif
