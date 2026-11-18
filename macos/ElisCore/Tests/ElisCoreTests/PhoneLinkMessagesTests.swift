import Foundation
import Testing
@testable import ElisCore

@Suite struct PhoneLinkMessagesTests {
    /// Union of every payload field; a vector's `object` decodes into it, then into the struct its kind names.
    struct Object: Decodable {
        var type: String?, target: String?, pane: String?, claim: Bool?, cols: UInt16?, rows: UInt16?
        var error: String?, role: String?, reason: String?
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
            return .json(kind, channel: vector.channel, PhoneLinkOpen(type: try #require(o.type), target: try #require(o.target), pane: o.pane, claim: o.claim, cols: o.cols, rows: o.rows))
        case .opened: return .json(kind, channel: vector.channel, PhoneLinkOpened(cols: o.cols, rows: o.rows, error: o.error))
        case .lead: return .json(kind, channel: vector.channel, PhoneLinkLead(role: try #require(o.role)))
        case .close: return .json(kind, channel: vector.channel, PhoneLinkClose(reason: try #require(o.reason)))
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: vector.kind))
        }
    }

    @Test func encodesJsonVectors() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 7)
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
