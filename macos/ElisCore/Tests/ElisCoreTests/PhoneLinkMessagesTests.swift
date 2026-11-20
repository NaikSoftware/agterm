import Foundation
import Testing
@testable import ElisCore

@Suite struct PhoneLinkMessagesTests {
    /// Union of every payload field; a vector's `object` decodes into it, then into the struct its kind names.
    struct Object: Decodable {
        var type: String?, target: String?, pane: String?, claim: Bool?, cols: UInt16?, rows: UInt16?
        var error: String?, role: String?, reason: String?, page: String?
    }

    struct Vectors: Decodable {
        struct Vector: Decodable { let name: String, kind: String, channel: UInt32, object: Object, hex: String }
        let json: [Vector]
    }

    static func vectors() throws -> [Vectors.Vector] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/phone-link-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url)).json
    }

    static func frame(_ vector: Vectors.Vector) throws -> PhoneLinkFrame {
        let kind = try PhoneLinkFrameTests.kind(vector.kind)
        let o = vector.object
        switch kind {
        case .open:
            return .json(kind, channel: vector.channel, PhoneLinkOpen(type: try #require(o.type), target: try #require(o.target), pane: o.pane, claim: o.claim, cols: o.cols, rows: o.rows,
                                                    page: o.page))
        case .opened: return .json(kind, channel: vector.channel, PhoneLinkOpened(cols: o.cols, rows: o.rows, error: o.error))
        case .lead: return .json(kind, channel: vector.channel, PhoneLinkLead(role: try #require(o.role)))
        case .close: return .json(kind, channel: vector.channel, PhoneLinkClose(reason: try #require(o.reason)))
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: vector.kind))
        }
    }

    @Test func encodesJsonVectors() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 8)
        for vector in vectors {
            #expect(try Self.frame(vector).encoded() == PhoneLinkFrameTests.hex(vector.hex), "\(vector.name)")
        }
    }

    @Test func decodesJsonVectors() throws {
        for vector in try Self.vectors() {
            let expected = try Self.frame(vector)
            let payload = PhoneLinkFrameTests.hex(vector.hex).dropFirst(PhoneLinkFrame.headerSize)
            let frame = PhoneLinkFrame(kind: expected.kind, channel: vector.channel, payload: Data(payload))
            switch frame.kind {
            case .open: #expect(try PhoneLinkFrame.json(.open, channel: vector.channel, frame.decodeJSON(PhoneLinkOpen.self)) == expected, "\(vector.name)")
            case .opened: #expect(try PhoneLinkFrame.json(.opened, channel: vector.channel, frame.decodeJSON(PhoneLinkOpened.self)) == expected, "\(vector.name)")
            case .lead: #expect(try PhoneLinkFrame.json(.lead, channel: vector.channel, frame.decodeJSON(PhoneLinkLead.self)) == expected, "\(vector.name)")
            default: #expect(try PhoneLinkFrame.json(.close, channel: vector.channel, frame.decodeJSON(PhoneLinkClose.self)) == expected, "\(vector.name)")
            }
        }
        let page = try Self.vectors().first { $0.name == "open page" }
        let decoded = try Self.frame(#require(page)).decodeJSON(PhoneLinkOpen.self)
        #expect(decoded == PhoneLinkOpen(type: "page", target: "s1"))
    }

    @Test func aForwardOpenCarriesItsPage() throws {
        let open = PhoneLinkFrame.json(.open, channel: 7, PhoneLinkOpen(type: "forward", target: "s1", page: "p1"))
        #expect(String(decoding: open.payload, as: UTF8.self) == #"{"page":"p1","target":"s1","type":"forward"}"#)
        #expect(try open.decodeJSON(PhoneLinkOpen.self).page == "p1")
        #expect(!String(decoding: PhoneLinkFrame.json(.open, channel: 7, PhoneLinkOpen(type: "vt", target: "s1")).payload, as: UTF8.self)
            .contains("page"))
    }

    @Test func presentLines() throws {
        let command = PhonePageCodec.encode(.command(id: "p", seq: 3, action: "hide", sizePercent: nil))
        #expect(String(decoding: command, as: UTF8.self) == "{\"action\":\"hide\",\"id\":\"p\",\"seq\":3,\"t\":\"command\"}\n")
        #expect(try PhonePageCodec.decode(Data(#"{"t":"closed","id":"p","dismissed":true}"#.utf8)) == .closed(id: "p", dismissed: true))
        let state = #"{"t":"state","id":"p","load":"loaded","canGoBack":false,"appliedSeq":2,"hidden":true}"#
        #expect(try PhonePageCodec.decode(Data(state.utf8))
            == .state(id: "p", load: "loaded", title: nil, current: nil, canGoBack: false, appliedSeq: 2, hidden: true, error: nil))
        #expect(throws: DecodingError.self) { try PhonePageCodec.decode(Data(#"{"t":"nope","id":"p"}"#.utf8)) }
    }

    @Test(arguments: [
        "nope",
        #"{"t":"nope","id":"p"}"#,
        #"{"t":"state","id":"p","load":"loaded","canGoBack":false,"hidden":true}"#,
        #"{"t":"fetch","id":"p","path":"/a"}"#,
        #"{"t":"bridge","id":"p","line":"x"}"#,
    ])
    func badUpLinesThrow(line: String) {
        #expect(throws: (any Error).self) { try PhonePageCodec.decode(Data(line.utf8)) }
    }

    @Test func fetchAndBridgeLinesDecode() throws {
        #expect(try PhonePageCodec.decode(Data(#"{"t":"fetch","id":"p","seq":4,"path":"/a/b.css"}"#.utf8)) == .fetch(id: "p", seq: 4, path: "/a/b.css"))
        #expect(try PhonePageCodec.decode(Data(#"{"t":"bridge","id":"p","seq":5,"line":"{}"}"#.utf8)) == .bridge(id: "p", seq: 5, line: "{}"))
    }

    @Test func presentDownLinesRoundTrip() throws {
        let page = PhonePage(id: "p", kind: "file", path: "/a/b.html", url: nil, adapter: "x", javascript: true, chromeless: false,
                             browse: false, hidden: false, title: "b.html", sizePercent: 60)
        let lines: [PhonePageDown] = [.page(page), .res(id: "p", seq: 1, mime: "text/html", data: Data("hi".utf8), end: true, error: nil),
                                      .reply(id: "p", seq: 2, response: "{}", error: nil)]
        for line in lines {
            let data = PhonePageCodec.encode(line)
            #expect(data.last == 0x0A)
            #expect(try JSONDecoder().decode(PhonePageDown.self, from: data) == line)
        }
        #expect(String(decoding: PhonePageCodec.encode(.page(page)), as: UTF8.self).contains(#""path":"/a/b.html""#))
    }

    @Test func upgradeLines() {
        #expect(PhoneLinkUpgrade.isRequest(PhoneLinkUpgrade.request))
        #expect(PhoneLinkUpgrade.isRequest(Data("{ \"mux\" : 1 }\n".utf8)))
        #expect(PhoneLinkUpgrade.isRequest(Data("{\"mux\":1}".utf8)))
        #expect(!PhoneLinkUpgrade.isRequest(Data("{\"mux\":2}\n".utf8)))
        #expect(!PhoneLinkUpgrade.isRequest(Data("{\"auth\":\"x\"}\n".utf8)))
        #expect(!PhoneLinkUpgrade.isRequest(Data("nope\n".utf8)))
        #expect(PhoneLinkUpgrade.answer == Data("{\"ok\":true,\"mux\":1}\n".utf8))
    }
}
