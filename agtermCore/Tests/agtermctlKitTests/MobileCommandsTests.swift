#if os(macOS)
import CoreImage
import CryptoKit
import Darwin
import Foundation
import Network
import Security
import Testing
import agtermCore
@testable import agtermctlKit

struct MobileCommandsTests {
    @Test func pairLinkEncodesEveryValueTheWayThePhoneDecodesIt() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let link = MobilePairing.pairLink(host: "192.168.1.5", port: 8765, token: "tok-en_" + String(repeating: "x", count: 30),
                                          fingerprint: fingerprint, name: "Nick's Mac+Book Pro")
        #expect(link.hasPrefix("agterm://pair?h=192.168.1.5&p=8765&t="))
        #expect(!link.contains(" ") && !link.contains("'") && !link.contains("+"))
        let components = try #require(URLComponents(string: link))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(components.scheme == "agterm" && components.host == "pair")
        #expect(query["n"] == "Nick's Mac+Book Pro")
        #expect(query["t"] == "tok-en_" + String(repeating: "x", count: 30))
        #expect(query["f"]?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
        #expect(query["p"] == "8765")
    }

    @Test func lanAddressesPutVirtualInterfacesLast() {
        let ordered = MobilePairing.orderedLAN([("bridge100", "192.168.64.1"), ("utun3", "10.8.0.2"), ("en0", "192.168.1.5"),
                                                 ("vmnet8", "172.16.0.1"), ("en1", "192.168.1.5"), ("en7", "10.0.0.9")])
        #expect(ordered == ["192.168.1.5", "10.0.0.9", "192.168.64.1", "10.8.0.2", "172.16.0.1"])
    }

    @Test func tokenIsPrivateBase64URLAndResetReplacesIt() throws {
        let dir = try MobileFixture.privateDirectory()
        let token = try MobilePairing.loadToken(in: dir)
        #expect(token.count >= 32 && token.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil)
        #expect(try MobilePairing.loadToken(in: dir) == token)
        #expect(MobileFixture.mode(dir + "/token") == 0o600)
        #expect(MobileFixture.mode(dir) == 0o700)
        let fresh = try MobilePairing.loadToken(in: dir, fresh: true)
        #expect(fresh != token && MobilePairing.currentToken(in: dir) == fresh)
        #expect(MobileFixture.mode(dir + "/token") == 0o600)
    }

    @Test func sameSecretComparesWholeValues() {
        #expect(MobilePairing.sameSecret("abc", "abc"))
        #expect(!MobilePairing.sameSecret("abc", "abd"))
        #expect(!MobilePairing.sameSecret("abc", "abcd"))
        #expect(!MobilePairing.sameSecret("", "a"))
    }

    @Test func qrHasFinderPatternsInTheThreeUprightCorners() throws {
        let matrix = try MobilePairing.qrMatrix("agterm://pair?h=10.0.0.1&p=8765")
        let size = matrix.count
        #expect(size >= 21 && matrix.allSatisfy { $0.count == size })
        let finderRow = { (row: Int, from: Int) in (from..<from + 7).allSatisfy { matrix[row][$0] } }
        #expect(finderRow(0, 0) && finderRow(0, size - 7) && finderRow(size - 1, 0))
        #expect(!finderRow(size - 1, size - 7))
        #expect(MobileFixture.decodeQR(matrix) == "agterm://pair?h=10.0.0.1&p=8765")
        let rows = MobilePairing.qrRows(matrix)
        #expect(rows.count == (size + 4 + 1) / 2)
        #expect(rows[0].hasPrefix("\u{1b}[97;107m▀"))
    }

    @Test func relayAuthenticatesForwardsAndTagsAnswers() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        #expect(client.peerFingerprint == fixture.fingerprint)
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        let hello = try #require(client.readJSON())
        #expect(hello["ok"] as? Bool == true && hello["id"] as? Int == 1)
        let result = try #require(hello["result"] as? [String: Any])
        #expect(result["host"] as? String == "test-mac" && result["version"] as? String == "9.9.9")

        client.send(#"{"cmd":"tree","id":7,"args":{"unknownArg":1}}"#)
        let answer = try #require(client.readJSON())
        #expect(answer["id"] as? Int == 7 && answer["ok"] as? Bool == true)
        #expect((answer["result"] as? [String: Any])?["echo"] as? String == "tree")
        #expect(fixture.server.requests().last == #"{"args":{"unknownArg":1},"cmd":"tree"}"#)
    }

    @Test func wrongTokenIsRefusedAndClosed() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(String(repeating: "z", count: 43))","id":3}"#)
        let refusal = try #require(client.readJSON())
        #expect(refusal["ok"] as? Bool == false && refusal["id"] as? Int == 3 && refusal["error"] as? String == "unauthorized")
        #expect(client.waitClosed())
        #expect(fixture.logged().contains { $0.hasPrefix("refused ") && $0.hasSuffix(": wrong token") })
    }

    @Test func preAuthGarbageClosesTheConnection() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(String(repeating: "g", count: 5000), newline: false)
        #expect(client.waitClosed())
        #expect(client.readJSON(timeout: 0.1) == nil)
    }

    @Test func resettingTheTokenDropsAnIdlePhone() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        _ = try MobilePairing.loadToken(in: fixture.mobileDir, fresh: true)
        #expect(client.waitClosed())
    }

    @Test func aDisconnectingPhoneGivesBackTheGridsItForced() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let client = try fixture.connect()
        client.send(#"{"auth":"\#(fixture.token)","id":1}"#)
        #expect(client.readJSON()?["ok"] as? Bool == true)
        client.send(#"{"cmd":"session.grid","target":"S1","args":{"pane":"right","columns":40,"rows":20},"id":2}"#)
        client.send(#"{"cmd":"session.grid","target":"S2","args":{"columns":40,"rows":20},"id":3}"#)
        client.send(#"{"cmd":"session.grid","target":"S2","args":{"reset":true},"id":4}"#)
        for _ in 0..<3 { #expect(client.readJSON()?["ok"] as? Bool == true) }
        let before = fixture.server.requests().count
        client.close()
        let reset = #"{"args":{"pane":"right","reset":true},"cmd":"session.grid","target":"S1"}"#
        let deadline = Date().addingTimeInterval(30)
        while !fixture.server.requests().dropFirst(before).contains(reset), Date() < deadline { usleep(20_000) }
        usleep(300_000) // a wrong reset for S2 would be sent alongside S1's
        let after = Array(fixture.server.requests().dropFirst(before))
        #expect(after == [reset])
    }

    @Test func secondRelayOnTheSamePortFails() throws {
        let fixture = try MobileFixture()
        defer { fixture.stop() }
        let other = MobileRelay(identity: fixture.identity, port: fixture.port, bind: nil, mobileDir: fixture.mobileDir,
                                socketPath: fixture.server.path, hostName: "test-mac")
        #expect(throws: (any Error).self) { try other.start() }
        other.stop()
    }
}

// MARK: - fixtures

private final class MobileFixture: @unchecked Sendable {
    let mobileDir: String
    let token: String
    let identity: SecIdentity
    let fingerprint: String
    let server = RawStubServer()
    let relay: MobileRelay
    let port: UInt16
    private let lines = LogLines()

    init() throws {
        mobileDir = try Self.privateDirectory()
        token = try MobilePairing.loadToken(in: mobileDir)
        try MobilePairing.ensureCertificate(in: mobileDir)
        (identity, fingerprint) = try MobilePairing.identity(in: mobileDir)
        try server.start()
        let lines = lines
        relay = MobileRelay(identity: identity, port: 0, bind: "127.0.0.1", mobileDir: mobileDir, socketPath: server.path,
                            hostName: "test-mac", revokeInterval: 0.3, log: { lines.append($0) })
        port = try relay.start()
    }

    func logged() -> [String] { lines.all() }

    func connect() throws -> TLSLineClient { try TLSLineClient(port: port) }

    func stop() {
        relay.stop()
        server.stop()
        try? FileManager.default.removeItem(atPath: (mobileDir as NSString).deletingLastPathComponent)
    }

    static func privateDirectory() throws -> String {
        let base = NSTemporaryDirectory() + "agterm-mobile-\(UUID().uuidString.prefix(8))"
        let dir = base + "/mobile"
        try MobilePairing.ensurePrivateDirectory(dir)
        return dir
    }

    /// Reads the matrix back through CoreImage's own QR detector, at 8 pixels a module with a 4-module quiet zone.
    static func decodeQR(_ matrix: [[Bool]]) -> String? {
        let scale = 8, side = (matrix.count + 8) * scale
        var pixels = [UInt8](repeating: 255, count: side * side)
        for (y, row) in matrix.enumerated() {
            for (x, dark) in row.enumerated() where dark {
                for dy in 0..<scale { for dx in 0..<scale { pixels[((y + 4) * scale + dy) * side + (x + 4) * scale + dx] = 0 } }
            }
        }
        let image = CIImage(bitmapData: Data(pixels), bytesPerRow: side, size: CGSize(width: side, height: side),
                            format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: nil)
        return (detector?.features(in: image).first as? CIQRCodeFeature)?.messageString
    }

    static func mode(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]) as? Int ?? -1) & 0o777
    }
}

/// A blocking line client over TLS that trusts any certificate and records the one it saw.
private final class TLSLineClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "mobile.test.client")
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var closed = false
    private(set) var peerFingerprint: String?

    init(port: UInt16) throws {
        let tls = NWProtocolTLS.Options()
        let fingerprintBox = FingerprintBox()
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let chain = SecTrustCopyCertificateChain(sec_trust_copy_ref(trust).takeRetainedValue()) as? [SecCertificate]
            if let leaf = chain?.first {
                fingerprintBox.value = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
            }
            complete(true)
        }, queue)
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!,
                                  using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready.signal()
            case .failed, .cancelled: self?.markClosed(); ready.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        guard ready.wait(timeout: .now() + 30) == .success, connection.state == .ready else {
            connection.cancel()
            throw CocoaError(.fileReadUnknown)
        }
        peerFingerprint = fingerprintBox.value
        receive()
    }

    deinit { connection.cancel() }

    func close() { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            lock.withLock { if let data { buffer.append(data) } }
            changed.signal()
            if done || error != nil { markClosed() } else { receive() }
        }
    }

    private func markClosed() {
        lock.withLock { closed = true }
        changed.signal()
    }

    func send(_ text: String, newline: Bool = true) {
        connection.send(content: Data((newline ? text + "\n" : text).utf8), completion: .idempotent)
    }

    func readJSON(timeout: TimeInterval = 30) -> [String: Any]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let line: Data? = lock.withLock {
                guard let newline = buffer.firstIndex(of: 0x0A) else { return nil }
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            if let line { return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] }
            if lock.withLock({ closed }) || changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    func waitClosed(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !lock.withLock({ closed }) {
            if changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return false }
        }
        return true
    }
}

private final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func all() -> [String] { lock.withLock { lines } }
}

private final class FingerprintBox: @unchecked Sendable { var value: String? }

/// A control socket stub that answers `version` with 9.9.9 and every other line with `{"echo":cmd}`, keeping the raw lines.
private final class RawStubServer: @unchecked Sendable {
    let path = "/tmp/agm-\(UUID().uuidString.prefix(8)).sock"
    private let lock = NSLock()
    private var received: [String] = []
    private var stopped = false

    func requests() -> [String] { lock.withLock { received } }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            path.utf8CString.withUnsafeBytes { raw.copyMemory(from: $0) }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, listen(fd, 8) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }
        Thread.detachNewThread { [self] in
            while true {
                let conn = accept(fd, nil, nil)
                // stop() wakes this accept with a connection of its own; the fd closes here, never under a blocked accept
                if conn < 0 || lock.withLock({ stopped }) {
                    if conn >= 0 { close(conn) }
                    close(fd)
                    return
                }
                serve(conn)
                close(conn)
            }
        }
    }

    private func serve(_ conn: Int32) {
        var line = Data()
        var byte: UInt8 = 0
        while read(conn, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
        guard byte == 0x0A, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
        lock.withLock { received.append(String(decoding: line, as: UTF8.self)) }
        let cmd = object["cmd"] as? String ?? ""
        let reply = cmd == "version" ? #"{"ok":true,"result":{"app":{"version":"9.9.9"}}}"# : #"{"ok":true,"result":{"echo":"\#(cmd)"}}"#
        let data = Data((reply + "\n").utf8)
        data.withUnsafeBytes { _ = UnixSocket.write(conn, $0.baseAddress!, data.count) }
    }

    func stop() {
        lock.withLock { stopped = true }
        if let wake = try? SocketClient(path: path).connect() { close(wake) }
        unlink(path)
    }
}
#endif
