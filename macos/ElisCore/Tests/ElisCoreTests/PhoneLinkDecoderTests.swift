import Foundation
import Testing
@testable import ElisCore

@Suite struct PhoneLinkDecoderTests {
    struct Fixture: Decodable {
        struct Frame: Decodable { let kind: String, channel: UInt32, payloadHex: String }
        struct Stream: Decodable { let name: String, hex: String, frames: [Frame] }
        struct Failure: Decodable { let name: String, hex: String, error: String }
        let streams: [Stream]
        let errors: [Failure]
    }

    static func fixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/phone-link-vectors.json")
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    static func frame(_ vector: Fixture.Frame) throws -> PhoneLinkFrame {
        PhoneLinkFrame(kind: try PhoneLinkFrameTests.kind(vector.kind), channel: vector.channel, payload: PhoneLinkFrameTests.hex(vector.payloadHex))
    }

    static func caseName(_ error: PhoneLinkError) -> String {
        switch error {
        case .unknownKind: "unknownKind"
        case .payloadTooLarge: "payloadTooLarge"
        case .badPayload: "badPayload"
        }
    }

    @Test func decodesEveryVectorFrame() throws {
        for vector in try PhoneLinkFrameTests.load().frames {
            var decoder = PhoneLinkDecoder()
            let expected = PhoneLinkFrame(kind: try PhoneLinkFrameTests.kind(vector.kind), channel: vector.channel,
                                          payload: PhoneLinkFrameTests.hex(vector.payloadHex))
            #expect(try decoder.feed(PhoneLinkFrameTests.hex(vector.hex)) == [expected], "\(vector.name)")
        }
    }

    @Test func decodesStreamsAtEveryChunkSize() throws {
        for stream in try Self.fixture().streams {
            let bytes = PhoneLinkFrameTests.hex(stream.hex)
            let expected = try stream.frames.map(Self.frame)
            for size in [1, 2, 3, 7, 9, 10, bytes.count] {
                var decoder = PhoneLinkDecoder()
                var got: [PhoneLinkFrame] = []
                var offset = 0
                while offset < bytes.count {
                    let end = min(offset + size, bytes.count)
                    got += try decoder.feed(bytes.subdata(in: offset..<end))
                    offset = end
                }
                #expect(got == expected, "\(stream.name) chunk \(size)")
            }
        }
    }

    @Test func rejectsErrorVectors() throws {
        for failure in try Self.fixture().errors {
            var decoder = PhoneLinkDecoder()
            do {
                _ = try decoder.feed(PhoneLinkFrameTests.hex(failure.hex))
                Issue.record("\(failure.name) did not throw")
            } catch {
                #expect(Self.caseName(error) == failure.error, "\(failure.name)")
            }
        }
    }

    @Test func rejectsOversizeBeforePayload() {
        var decoder = PhoneLinkDecoder()
        #expect(throws: PhoneLinkError.payloadTooLarge(65537)) {
            try decoder.feed(Data([3, 0, 0, 0, 0, 0, 1, 0, 1]))
        }
    }

    @Test func acceptsMaxPayload() throws {
        var decoder = PhoneLinkDecoder()
        let frame = PhoneLinkFrame.data(channel: 2, Data(repeating: 7, count: PhoneLinkFrame.maxPayload))
        #expect(try decoder.feed(frame.encoded()) == [frame])
    }

    @Test func staysFailedAfterError() {
        var decoder = PhoneLinkDecoder()
        #expect(throws: PhoneLinkError.unknownKind(0)) { try decoder.feed(Data(count: 9)) }
        #expect(throws: PhoneLinkError.unknownKind(0)) { try decoder.feed(PhoneLinkFrame.resync(channel: 2).encoded()) }
    }
}
