#if os(macOS)
import Compression
import CryptoKit
import Foundation

// The phone relay's Bluetooth link: Noise NNpsk0 over u16-length frames, raw DEFLATE inside.
// Tests/elisctlKitTests/Fixtures/ble-vectors.json is the byte-exact contract the phone checks itself against.

public enum BleLinkError: Error, Equatable {
    case wrongKey
    case badFrame
}

public enum BleIDs {
    public static let psmCharacteristic = UUID(uuid: (0xA6, 0xE5, 0xC0, 0xDE, 0x00, 0x01, 0x4A, 0x67,
                                                      0x80, 0x00, 0x65, 0x6C, 0x69, 0x73, 0x00, 0xD1))

    /// The advertised UUID rotates every `epochSeconds`, so a passive observer cannot follow the Mac.
    public static let epochSeconds: TimeInterval = 900

    public static func epoch(at date: Date) -> Int { Int((date.timeIntervalSince1970 / epochSeconds).rounded(.down)) }

    public static func serviceUUID(token: String, epoch: Int) -> UUID { serviceUUID(token: token, message: "elis-ble-adv:\(epoch)") }

    /// `message` alone is the unrotated form the first vectors pinned.
    static func serviceUUID(token: String, message: String = "elis-ble-adv") -> UUID {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(token.utf8)))
        var b = Array(mac.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    public static func psk(token: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(token.utf8)), salt: Data(),
                               info: Data("elis-ble-psk".utf8), outputByteCount: 32)
    }
}

/// One direction's Noise CipherState: ChaChaPoly with nonce = 4 zero bytes ‖ u64 little-endian counter.
struct NoiseCipher: Sendable {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0

    init(key: Data) { self.key = SymmetricKey(data: key) }

    // Noise reserves 2^64-1, so a cipher refuses rather than reuse a nonce.
    private func nonce() throws -> ChaChaPoly.Nonce {
        guard counter < .max else { throw BleLinkError.badFrame }
        return try ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: counter.littleEndian) { Data($0) })
    }

    mutating func encrypt(_ plaintext: Data, ad: Data = Data()) throws -> Data {
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(), authenticating: ad)
            counter += 1
            return box.ciphertext + box.tag
        } catch {
            throw BleLinkError.badFrame
        }
    }

    // A failed open leaves the counter alone, so a replayed or forged frame never advances it.
    mutating func decrypt(_ ciphertext: Data, ad: Data = Data()) throws -> Data {
        guard ciphertext.count >= 16 else { throw BleLinkError.badFrame }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: ad)
            counter += 1
            return plaintext
        } catch {
            throw BleLinkError.badFrame
        }
    }
}

/// Noise SymmetricState for `Noise_NNpsk0_25519_ChaChaPoly_SHA256` (spec rev 34, §5.2, §9).
struct NoiseHandshake: Sendable {
    static let prologue = Data("elis-ble-1".utf8)
    private var ck: Data
    private(set) var h: Data
    private var cipher: NoiseCipher?
    let e: Curve25519.KeyAgreement.PrivateKey

    // The name is longer than HASHLEN, so h starts as its hash; the psk0 modifier mixes the psk before message 1.
    init(psk: SymmetricKey, ephemeral: Curve25519.KeyAgreement.PrivateKey, prologue: Data) {
        h = Data(SHA256.hash(data: Data("Noise_NNpsk0_25519_ChaChaPoly_SHA256".utf8)))
        ck = h
        e = ephemeral
        mixHash(prologue)
        mixKeyAndHash(psk.withUnsafeBytes { Data($0) })
    }

    private func hkdf(_ ikm: Data, _ outputs: Int) -> [Data] {
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: ck, info: Data(),
                                         outputByteCount: 32 * outputs).withUnsafeBytes { Data($0) }
        return (0..<outputs).map { okm.subdata(in: $0 * 32..<($0 + 1) * 32) }
    }

    private mutating func mixHash(_ data: Data) { h = Data(SHA256.hash(data: h + data)) }

    private mutating func mixKey(_ ikm: Data) {
        let out = hkdf(ikm, 2)
        ck = out[0]
        cipher = NoiseCipher(key: out[1])
    }

    private mutating func mixKeyAndHash(_ ikm: Data) {
        let out = hkdf(ikm, 3)
        ck = out[0]
        mixHash(out[1])
        cipher = NoiseCipher(key: out[2])
    }

    /// Token `e` under a psk handshake: MixHash and MixKey of the public key.
    mutating func writeE() -> Data {
        let pub = e.publicKey.rawRepresentation
        mixHash(pub)
        mixKey(pub)
        return pub
    }

    mutating func readE(_ pub: Data) {
        mixHash(pub)
        mixKey(pub)
    }

    mutating func mixEE(_ remote: Data) throws {
        do {
            let secret = try e.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: remote))
            mixKey(secret.withUnsafeBytes { Data($0) })
        } catch {
            throw BleLinkError.badFrame
        }
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard var cipher else { throw BleLinkError.badFrame }
        let ciphertext = try cipher.encrypt(plaintext, ad: h)
        self.cipher = cipher
        mixHash(ciphertext)
        return ciphertext
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard var cipher else { throw BleLinkError.badFrame }
        let plaintext = try cipher.decrypt(ciphertext, ad: h)
        self.cipher = cipher
        mixHash(ciphertext)
        return plaintext
    }

    /// Split(): the first key carries initiator to responder.
    func split() -> (initiatorToResponder: NoiseCipher, responderToInitiator: NoiseCipher) {
        let out = hkdf(Data(), 2)
        return (NoiseCipher(key: out[0]), NoiseCipher(key: out[1]))
    }
}

/// The phone's side (`-> psk, e`, `<- e, ee`); the Mac uses it only in tests, mirroring the phone.
public struct BleInitiator: ~Copyable, Sendable {
    private var state: NoiseHandshake

    public init(psk: SymmetricKey) { self.init(psk: psk, ephemeral: .init()) }

    init(psk: SymmetricKey, ephemeral: Curve25519.KeyAgreement.PrivateKey, prologue: Data = NoiseHandshake.prologue) {
        state = NoiseHandshake(psk: psk, ephemeral: ephemeral, prologue: prologue)
    }

    public mutating func start() throws -> Data { try writeMessage1(payload: Data()) }

    // Our handshake carries empty payloads, so both messages are exactly 48 bytes.
    public consuming func finish(_ reply: Data) throws -> BleTransportKeys {
        guard reply.count == 48 else { throw BleLinkError.badFrame }
        return try readMessage2(reply).transport
    }

    mutating func writeMessage1(payload: Data) throws -> Data {
        let pub = state.writeE()
        return try pub + state.encryptAndHash(payload)
    }

    mutating func readMessage2(_ message: Data) throws -> (payload: Data, transport: BleTransportKeys) {
        guard message.count >= 48 else { throw BleLinkError.badFrame }
        let remote = Data(message.prefix(32))
        state.readE(remote)
        try state.mixEE(remote)
        let payload: Data
        do { payload = try state.decryptAndHash(Data(message.dropFirst(32))) } catch { throw BleLinkError.wrongKey }
        let keys = state.split()
        return (payload, BleTransportKeys(send: keys.initiatorToResponder, receive: keys.responderToInitiator, handshakeHash: state.h))
    }
}

/// The Mac's side. Message 1's first 32 bytes are the phone's ephemeral public key (the `bt:<hex>` peer label).
public struct BleResponder: ~Copyable, Sendable {
    private var state: NoiseHandshake

    public init(psk: SymmetricKey) { self.init(psk: psk, ephemeral: .init()) }

    init(psk: SymmetricKey, ephemeral: Curve25519.KeyAgreement.PrivateKey, prologue: Data = NoiseHandshake.prologue) {
        state = NoiseHandshake(psk: psk, ephemeral: ephemeral, prologue: prologue)
    }

    public consuming func readInitiator(_ message: Data) throws -> (reply: Data, transport: BleTransportKeys) {
        guard message.count == 48 else { throw BleLinkError.badFrame }
        let read = try respond(to: message, payload: Data())
        return (read.reply, read.transport)
    }

    mutating func respond(to message: Data, payload reply: Data) throws -> (payload: Data, reply: Data, transport: BleTransportKeys) {
        guard message.count >= 48 else { throw BleLinkError.badFrame }
        state.readE(Data(message.prefix(32)))
        let payload: Data
        do { payload = try state.decryptAndHash(Data(message.dropFirst(32))) } catch { throw BleLinkError.wrongKey }
        let pub = state.writeE()
        try state.mixEE(Data(message.prefix(32)))
        let out = try pub + state.encryptAndHash(reply)
        let keys = state.split()
        return (payload, out, BleTransportKeys(send: keys.responderToInitiator, receive: keys.initiatorToResponder, handshakeHash: state.h))
    }
}

/// Transport after the handshake. Each frame is one independently deflated chunk of 1...maxChunk line-stream bytes.
public struct BleTransportKeys: Sendable {
    public static let maxChunk = 4096
    var send: NoiseCipher
    var receive: NoiseCipher
    let handshakeHash: Data

    public mutating func seal(_ chunk: Data) throws -> Data { try send.encrypt(Self.deflate(chunk)) }

    public mutating func open(_ frame: Data) throws -> Data { try Self.inflate(receive.decrypt(frame)) }

    // An empty chunk is refused because Compression reports both an empty result and a failure as 0 bytes.
    static func deflate(_ chunk: Data, limit: Int = maxChunk) throws -> Data {
        guard (1...limit).contains(chunk.count) else { throw BleLinkError.badFrame }
        let capacity = chunk.count + chunk.count / 8 + 64
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            chunk.withUnsafeBytes { src in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, chunk.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw BleLinkError.badFrame }
        return out.prefix(written)
    }

    static func inflate(_ deflated: Data) throws -> Data {
        guard !deflated.isEmpty else { throw BleLinkError.badFrame }
        let capacity = maxChunk + 1 // a full buffer means the frame inflates past the limit
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            deflated.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, deflated.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard (1...maxChunk).contains(written) else { throw BleLinkError.badFrame }
        return out.prefix(written)
    }
}

/// `u16 big-endian length ‖ body` stream framing, used for every message on the L2CAP stream.
public struct BleFramer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func push(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var bodies: [Data] = []
        while buffer.count >= 2 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 8 | Int(buffer[start + 1])
            guard buffer.count >= 2 + length else { break }
            bodies.append(Data(buffer[start + 2..<start + 2 + length]))
            buffer = Data(buffer.dropFirst(2 + length))
        }
        return bodies
    }

    public static func frame(_ body: Data) -> Data {
        precondition(body.count <= Int(UInt16.max), "BLE frame body over 65535 bytes")
        return Data([UInt8(body.count >> 8), UInt8(body.count & 0xFF)]) + body
    }
}
#endif
