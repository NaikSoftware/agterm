#if os(macOS)
import CryptoKit
import Foundation
@testable import agtermctlKit
import Testing

struct BleLinkTests {
    private struct Vectors: Decodable {
        struct Message: Decodable { let payload: String, ciphertext: String }
        struct Conformance: Decodable {
            let protocolName: String, prologue: String, psk: String
            let initiatorEphemeralPrivate: String, responderEphemeralPrivate: String
            let handshakeHash: String
            let messages: [Message]
        }
        struct Frame: Decodable { let direction: String, encoder: String, plaintext: String, deflated: String, frame: String }
        struct Handshake: Decodable {
            let initiatorEphemeralPrivate: String, responderEphemeralPrivate: String
            let message1: String, message2: String, message1Wire: String, handshakeHash: String
        }
        let token: String, serviceUUID: String, psmCharacteristicUUID: String, psk: String
        let handshake: Handshake
        let frames: [Frame]
        let noiseConformance: Conformance
    }

    private static func load() throws -> Vectors {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ble-vectors.json")
        let decoder = JSONDecoder()
        return try decoder.decode(Vectors.self, from: Data(contentsOf: url))
    }

    private func hex(_ string: String) -> Data {
        var data = Data()
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            data.append(UInt8(string[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private func key(_ string: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex(string))
    }

    private func pair(psk: SymmetricKey = BleIDs.psk(token: "token")) throws -> (BleTransportKeys, BleTransportKeys) {
        var initiator = BleInitiator(psk: psk)
        let responder = BleResponder(psk: psk)
        let (reply, mac) = try responder.readInitiator(try initiator.start())
        return (try initiator.finish(reply), mac)
    }

    @Test func noiseConformanceVectorReproduces() throws {
        let v = try Self.load().noiseConformance
        #expect(v.protocolName == "Noise_NNpsk0_25519_ChaChaPoly_SHA256")
        var initiator = BleInitiator(psk: SymmetricKey(data: hex(v.psk)), ephemeral: try key(v.initiatorEphemeralPrivate), prologue: hex(v.prologue))
        var responder = BleResponder(psk: SymmetricKey(data: hex(v.psk)), ephemeral: try key(v.responderEphemeralPrivate), prologue: hex(v.prologue))
        let message1 = try initiator.writeMessage1(payload: hex(v.messages[0].payload))
        #expect(message1 == hex(v.messages[0].ciphertext))
        let read = try responder.respond(to: message1, payload: hex(v.messages[1].payload))
        #expect(read.payload == hex(v.messages[0].payload))
        #expect(read.reply == hex(v.messages[1].ciphertext))
        let (payload2, phone) = try initiator.readMessage2(read.reply)
        #expect(payload2 == hex(v.messages[1].payload))
        #expect(phone.handshakeHash == hex(v.handshakeHash))
        #expect(read.transport.handshakeHash == hex(v.handshakeHash))
        var sender = phone, receiver = read.transport
        for message in v.messages.dropFirst(2) {
            #expect(try sender.send.encrypt(hex(message.payload)) == hex(message.ciphertext))
            #expect(try receiver.receive.decrypt(hex(message.ciphertext)) == hex(message.payload))
            swap(&sender, &receiver)
        }
    }

    @Test func bleVectorsReproduce() throws {
        let v = try Self.load()
        #expect(BleIDs.serviceUUID(token: v.token).uuidString.lowercased() == v.serviceUUID)
        #expect(BleIDs.psmCharacteristic.uuidString.lowercased() == v.psmCharacteristicUUID)
        #expect(BleIDs.psk(token: v.token).withUnsafeBytes { Data($0) } == hex(v.psk))
        let psk = BleIDs.psk(token: v.token)
        var initiator = BleInitiator(psk: psk, ephemeral: try key(v.handshake.initiatorEphemeralPrivate))
        let responder = BleResponder(psk: psk, ephemeral: try key(v.handshake.responderEphemeralPrivate))
        let message1 = try initiator.start()
        #expect(message1 == hex(v.handshake.message1))
        #expect(BleFramer.frame(message1) == hex(v.handshake.message1Wire))
        let (reply, mac) = try responder.readInitiator(message1)
        #expect(reply == hex(v.handshake.message2))
        let phone = try initiator.finish(reply)
        #expect(phone.handshakeHash == hex(v.handshake.handshakeHash))
        #expect(v.frames.contains { $0.encoder == "zlib" && $0.direction == "phone-to-mac" })
        var sides = ["phone-to-mac": (phone, mac), "mac-to-phone": (mac, phone)]
        for frame in v.frames {
            var (sender, receiver) = try #require(sides[frame.direction])
            #expect(try sender.send.encrypt(hex(frame.deflated)) == hex(frame.frame))
            #expect(try receiver.open(hex(frame.frame)) == Data(frame.plaintext.utf8))
            #expect(try BleTransportKeys.inflate(hex(frame.deflated)) == Data(frame.plaintext.utf8))
            sides[frame.direction] = (sender, receiver)
            let reverse = frame.direction == "phone-to-mac" ? "mac-to-phone" : "phone-to-mac"
            sides[reverse] = (receiver, sender)
        }
    }

    @Test func handshakeMessagesAre48Bytes() throws {
        var initiator = BleInitiator(psk: BleIDs.psk(token: "t"))
        let responder = BleResponder(psk: BleIDs.psk(token: "t"))
        let message1 = try initiator.start()
        #expect(message1.count == 48)
        #expect(try responder.readInitiator(message1).reply.count == 48)
    }

    @Test func wrongPskThrowsWrongKey() throws {
        #expect(throws: BleLinkError.wrongKey) {
            var initiator = BleInitiator(psk: BleIDs.psk(token: "old"))
            try BleResponder(psk: BleIDs.psk(token: "new")).readInitiator(try initiator.start())
        }
    }

    @Test(arguments: [47, 49])
    func handshakeOfAnotherLengthThrows(length: Int) {
        #expect(throws: BleLinkError.badFrame) { try BleResponder(psk: BleIDs.psk(token: "t")).readInitiator(Data(count: length)) }
    }

    @Test func tamperedFrameThrows() throws {
        var (phone, mac) = try pair()
        var frame = try phone.seal(Data("{\"auth\":\"x\",\"id\":1}\n".utf8))
        frame[frame.startIndex + 3] ^= 0x01
        #expect(throws: BleLinkError.badFrame) { try mac.open(frame) }
    }

    @Test func replayedFrameThrows() throws {
        var (phone, mac) = try pair()
        let frame = try phone.seal(Data("line\n".utf8))
        #expect(try mac.open(frame) == Data("line\n".utf8))
        #expect(throws: BleLinkError.badFrame) { try mac.open(frame) }
    }

    @Test func outOfOrderFrameThrows() throws {
        var (phone, mac) = try pair()
        _ = try phone.seal(Data("first\n".utf8))
        let second = try phone.seal(Data("second\n".utf8))
        #expect(throws: BleLinkError.badFrame) { try mac.open(second) }
    }

    @Test func incompressibleFullChunkRoundTrips() throws {
        var (phone, mac) = try pair()
        var generator = SystemRandomNumberGenerator()
        let chunk = Data((0..<BleTransportKeys.maxChunk).map { _ in UInt8.random(in: 0...255, using: &generator) })
        #expect(try mac.open(try phone.seal(chunk)) == chunk)
    }

    @Test func longLineSplitAcrossChunksRoundTrips() throws {
        var (phone, mac) = try pair()
        let line = Data((0..<10_000).map { UInt8(ascii: "a") + UInt8($0 % 26) }) + Data("\n".utf8)
        let chunks = stride(from: 0, to: line.count, by: BleTransportKeys.maxChunk).map {
            line.subdata(in: $0..<min($0 + BleTransportKeys.maxChunk, line.count))
        }
        #expect(chunks.count >= 3)
        var framer = BleFramer()
        let wire = try chunks.reduce(into: Data()) { $0 += BleFramer.frame(try mac.seal($1)) }
        var received = Data()
        for byte in wire { // one byte per push splits every header and body
            for body in framer.push(Data([byte])) { received += try phone.open(body) }
        }
        #expect(received == line)
    }

    @Test func deflateShrinksTerminalText() throws {
        var (phone, _) = try pair()
        let row = "\u{1b}[32m~/dev/agterm\u{1b}[0m $ ls -la Sources/agtermctlKit | grep Swift\n"
        let text = Data(String(repeating: row, count: 4096 / row.utf8.count + 1).utf8.prefix(4096))
        #expect(try phone.seal(text).count < text.count / 4)
    }

    @Test func sealRejectsEmptyAndOversizedChunks() throws {
        var (phone, _) = try pair()
        #expect(throws: BleLinkError.badFrame) { try phone.seal(Data()) }
        #expect(throws: BleLinkError.badFrame) { try phone.seal(Data(count: BleTransportKeys.maxChunk + 1)) }
    }

    @Test func openRejectsInflateBeyondMaxChunk() throws {
        var (phone, mac) = try pair()
        let frame = try phone.send.encrypt(try BleTransportKeys.deflate(Data(count: 5000), limit: 8192))
        #expect(throws: BleLinkError.badFrame) { try mac.open(frame) }
    }

    @Test func framerHandlesPartialZeroLengthAndBatchedFrames() {
        var framer = BleFramer()
        #expect(framer.push(Data([0x00])).isEmpty)
        #expect(framer.push(Data([0x02, 0xAA])).isEmpty)
        #expect(framer.push(Data([0xBB, 0x00, 0x00, 0x00, 0x01, 0xCC])) == [Data([0xAA, 0xBB]), Data(), Data([0xCC])])
        #expect(BleFramer.frame(Data(count: 300)).prefix(2) == Data([0x01, 0x2C]))
    }
}
#endif
