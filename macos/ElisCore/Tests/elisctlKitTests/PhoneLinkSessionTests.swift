#if os(macOS)
import Foundation
import Testing
import ElisCore
@testable import elisctlKit

struct PhoneLinkSessionTests {
    @Test func upgradeAnswersThenSpeaksFrames() throws {
        let (fixture, phone) = try Self.authenticated()
        defer { fixture.stop() }
        phone.deliver(PhoneLinkUpgrade.request)
        #expect(phone.readSent() == PhoneLinkUpgrade.answer)
        phone.deliver(Self.control(#"{"cmd":"tree","id":5}"# + "\n"))
        let reader = MuxReader()
        let answer = try #require(reader.json(from: phone))
        #expect(answer["id"] as? Int == 5 && (answer["result"] as? [String: Any])?["echo"] as? String == "tree")
    }

    @Test func leftoverBytesAfterUpgradeAreDecoded() throws {
        let (fixture, phone) = try Self.authenticated()
        defer { fixture.stop() }
        phone.deliver(PhoneLinkUpgrade.request + Self.control(#"{"cmd":"tree","id":7}"# + "\n"))
        #expect(phone.readSent() == PhoneLinkUpgrade.answer)
        let reader = MuxReader()
        #expect(reader.json(from: phone)?["id"] as? Int == 7)
    }

    @Test func upgradeAnswersAfterEarlierRequests() throws {
        let (fixture, phone) = try Self.authenticated()
        defer { fixture.stop() }
        phone.deliver(#"{"cmd":"tree","id":2}"# + "\n" + String(decoding: PhoneLinkUpgrade.request, as: UTF8.self))
        #expect(phone.readJSON()?["id"] as? Int == 2)
        #expect(phone.readSent() == PhoneLinkUpgrade.answer)
    }

    @Test func aLongAnswerSpansFrames() throws {
        let (fixture, phone) = try Self.upgraded()
        defer { fixture.stop() }
        // the stub echoes the command name, so a long name makes an answer over one 16 KiB chunk
        let cmd = String(repeating: "x", count: 40000)
        phone.deliver(Self.control(#"{"cmd":"\#(cmd)","id":4}"# + "\n"))
        let reader = MuxReader()
        let answer = try #require(reader.json(from: phone))
        #expect(answer["id"] as? Int == 4 && (answer["result"] as? [String: Any])?["echo"] as? String == cmd)
    }

    @Test func aLineMaySpanFrames() throws {
        let (fixture, phone) = try Self.upgraded()
        defer { fixture.stop() }
        phone.deliver(Self.control(#"{"cmd":"tr"#))
        phone.deliver(Self.control(#"ee","id":8}"#) + Self.control("\n"))
        let reader = MuxReader()
        let answer = try #require(reader.json(from: phone))
        #expect(answer["id"] as? Int == 8 && (answer["result"] as? [String: Any])?["echo"] as? String == "tree")
    }

    @Test func controlAnswersKeepRequestOrder() throws {
        let (fixture, phone) = try Self.upgraded()
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
        let (fixture, phone) = try Self.upgraded()
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
        let (fixture, phone) = try mux ? Self.upgraded() : Self.authenticated()
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
        let (fixture, phone) = try Self.upgraded()
        defer { fixture.stop() }
        phone.deliver(Data([99, 0, 0, 0, 0, 0, 0, 0, 0]))
        #expect(phone.waitClosed())
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
    }

    @Test func revokeClosesAMuxLink() throws {
        let (fixture, phone) = try Self.upgraded()
        defer { fixture.stop() }
        _ = try MobilePairing.loadToken(in: fixture.mobileDir, fresh: true)
        #expect(phone.waitClosed())
        #expect(fixture.waitLogged("phone disconnected from mem:1"))
    }

    // MARK: - helpers

    private static func authenticated() throws -> (MobileFixture, MemoryPhone) {
        let fixture = try MobileFixture()
        let phone = MemoryPhone(queue: fixture.relay.queue)
        fixture.relay.queue.sync { fixture.relay.accept(phone) }
        phone.deliver(#"{"auth":"\#(fixture.token)","id":1}"# + "\n")
        guard phone.readJSON()?["ok"] as? Bool == true else {
            fixture.stop()
            throw CocoaError(.fileReadUnknown)
        }
        return (fixture, phone)
    }

    private static func upgraded() throws -> (MobileFixture, MemoryPhone) {
        let (fixture, phone) = try authenticated()
        phone.deliver(PhoneLinkUpgrade.request)
        guard phone.readSent() == PhoneLinkUpgrade.answer else {
            fixture.stop()
            throw CocoaError(.fileReadUnknown)
        }
        return (fixture, phone)
    }

    private static func control(_ text: String) -> Data {
        PhoneLinkFrame.data(channel: 0, Data(text.utf8)).encoded()
    }
}

/// Reads the relay's frames back and joins channel 0 into lines.
private final class MuxReader {
    private var decoder = PhoneLinkDecoder()
    private var line = Data()

    func json(from phone: MemoryPhone) -> [String: Any]? {
        while true {
            if let newline = line.firstIndex(of: 0x0A) {
                defer { line = Data(line[line.index(after: newline)...]) }
                return (try? JSONSerialization.jsonObject(with: line[line.startIndex..<newline])) as? [String: Any]
            }
            guard let bytes = phone.readSent(), let frames = try? decoder.feed(bytes) else { return nil }
            for frame in frames where frame.kind == .data && frame.channel == 0 { line.append(frame.payload) }
        }
    }
}
#endif
