import Foundation
import Testing
@testable import ElisCore

@Suite struct PhoneLinkFrameTests {
    struct Vectors: Decodable {
        struct Frame: Decodable { let name: String, kind: String, channel: UInt32, payloadHex: String, hex: String }
        let frames: [Frame]
    }

    static func load() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/phone-link-vectors.json")
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    static func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    static func kind(_ name: String) throws -> PhoneLinkKind {
        try #require(PhoneLinkKind.allCases.first { "\($0)" == name })
    }

    @Test func encodesEveryVectorFrame() throws {
        let vectors = try Self.load()
        #expect(vectors.frames.count >= 7)
        for vector in vectors.frames {
            let frame = PhoneLinkFrame(kind: try Self.kind(vector.kind), channel: vector.channel, payload: Self.hex(vector.payloadHex))
            #expect(frame.encoded() == Self.hex(vector.hex), "\(vector.name)")
        }
    }

    @Test func factoriesMatchVectors() throws {
        let byName = Dictionary(uniqueKeysWithValues: try Self.load().frames.map { ($0.name, Self.hex($0.hex)) })
        #expect(PhoneLinkFrame.credit(channel: 2, bytes: 16384).encoded() == byName["credit 16384"])
        #expect(PhoneLinkFrame.grid(channel: 3, cols: 120, rows: 40).encoded() == byName["grid 120x40"])
        #expect(PhoneLinkFrame.resize(channel: 3, cols: 60, rows: 20).encoded() == byName["resize 60x20"])
        #expect(PhoneLinkFrame.resync(channel: 2).encoded() == byName["resync"])
        #expect(PhoneLinkFrame.data(channel: 0, Data([0x68, 0x69, 0x0a])).encoded() == byName["data hi"])
    }

    @Test func kindsHaveSpecCodes() {
        #expect(PhoneLinkKind.allCases.map(\.rawValue) == Array(1...9))
    }
}
