#if os(macOS)
import CoreImage
import CryptoKit
import Darwin
import Foundation
import Network
import Security
import ElisCore
@testable import elisctlKit

// Fixtures shared by the relay suites.

final class MobileFixture: @unchecked Sendable {
    let mobileDir: String
    let token: String
    let identity: SecIdentity
    let fingerprint: String
    let server = RawStubServer()
    let relay: MobileRelay
    let port: UInt16
    private let lines = LogLines()

    init(maxUnauthenticated: Int = 32) throws {
        mobileDir = try Self.privateDirectory()
        token = try MobilePairing.loadToken(in: mobileDir)
        try MobilePairing.ensureCertificate(in: mobileDir)
        (identity, fingerprint) = try MobilePairing.identity(in: mobileDir)
        try server.start()
        let lines = lines
        relay = MobileRelay(identity: identity, port: 0, bind: "127.0.0.1", mobileDir: mobileDir, socketPath: server.path,
                            // a release bound a loaded runner cannot run out; the stub answers at once
                            hostName: "test-mac", revokeInterval: 0.3, maxUnauthenticated: maxUnauthenticated, releaseTimeout: 30,
                            log: { lines.append($0) })
        port = try relay.start()
    }

    func logged() -> [String] { lines.all() }

    func waitLogged(_ line: String) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !logged().contains(line) {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    func connect() throws -> TLSLineClient { try TLSLineClient(port: port) }

    func stop() {
        relay.stop()
        server.stop()
        try? FileManager.default.removeItem(atPath: (mobileDir as NSString).deletingLastPathComponent)
    }

    static func privateDirectory() throws -> String {
        let base = NSTemporaryDirectory() + "elis-mobile-\(UUID().uuidString.prefix(8))"
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

extension MobileFixture {
    /// A fixture and a phone that passed auth.
    static func authenticated() throws -> (MobileFixture, MemoryPhone) {
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

    /// A fixture and a phone past `{"mux":1}`.
    static func upgraded() throws -> (MobileFixture, MemoryPhone) {
        let (fixture, phone) = try authenticated()
        phone.deliver(PhoneLinkUpgrade.request)
        guard phone.readSent() == PhoneLinkUpgrade.answer else {
            fixture.stop()
            throw CocoaError(.fileReadUnknown)
        }
        return (fixture, phone)
    }
}

/// Reads the relay's frames back and joins one channel into lines.
final class MuxReader {
    private let channel: UInt32
    private var decoder = PhoneLinkDecoder()
    private var line = Data()

    init(channel: UInt32 = 0) { self.channel = channel }

    func json(from phone: MemoryPhone) -> [String: Any]? {
        line(from: phone).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The next whole line, newline excluded.
    func line(from phone: MemoryPhone) -> Data? {
        while true {
            if let newline = line.firstIndex(of: 0x0A) {
                defer { line = Data(line[line.index(after: newline)...]) }
                return Data(line[line.startIndex..<newline])
            }
            guard let bytes = phone.readSent(), let frames = try? decoder.feed(bytes) else { return nil }
            for frame in frames where frame.kind == .data && frame.channel == channel { line.append(frame.payload) }
        }
    }
}

/// A blocking line client over TLS that trusts any certificate and records the one it saw.
final class TLSLineClient: @unchecked Sendable {
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
            case .failed, .cancelled, .waiting: self?.markClosed(); ready.signal()
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

/// A phone connection with no transport: the test feeds bytes in on the relay queue and reads the lines sent back.
final class MemoryPhone: PhoneTransportConnection, @unchecked Sendable {
    let peerLabel = "mem:1"
    var onReceive: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private var sent: [Data] = []
    private var isClosed = false
    /// Completions held back while a test plays a phone that takes no more bytes; nil while sends complete.
    private var held: [() -> Void]?

    init(queue: DispatchQueue) { self.queue = queue }

    func deliver(_ text: String) { deliver(Data(text.utf8)) }
    func deliver(_ bytes: Data) { queue.async { self.onReceive?(bytes) } }
    func peerLeft() { queue.async { self.onClose?() } }
    func closed() -> Bool { lock.withLock { isClosed } }
    /// From now on the transport makes no progress: no send completes until `release()`.
    func hold() { lock.withLock { held = [] } }
    func release() {
        let completions = lock.withLock { defer { held = nil }; return held ?? [] }
        completions.forEach { queue.async(execute: $0) }
    }

    func send(_ data: Data, completion: @escaping () -> Void) {
        let holding = lock.withLock {
            sent.append(data)
            held?.append(completion)
            return held != nil
        }
        changed.signal()
        if !holding { queue.async(execute: completion) } // later, as a real transport does
    }

    func close() { lock.withLock { isClosed = true } }

    func readJSON(timeout: TimeInterval = 30) -> [String: Any]? {
        readSent(timeout: timeout).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }

    /// The oldest bytes sent and not read yet, one `send` call at a time.
    func readSent(timeout: TimeInterval = 30) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let bytes = lock.withLock({ sent.isEmpty ? nil : sent.removeFirst() }) { return bytes }
            if changed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut { return nil }
        }
    }

    func waitClosed(timeout: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !closed() {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    func all() -> [String] { lock.withLock { lines } }
}

final class FingerprintBox: @unchecked Sendable { var value: String? }

/// A control socket stub that answers `version` with 9.9.9, `events.read` from a scripted ring, `session.attach`
/// with a fake viewer, and every other line with `{"echo":cmd}`, keeping the raw lines; `events.read` lines are kept
/// apart, as their cursors.
final class RawStubServer: @unchecked Sendable {
    let path = "/tmp/agm-\(UUID().uuidString.prefix(8)).sock"
    private let lock = NSLock()
    private var received: [String] = []
    private var stopped = false
    private let run = UUID().uuidString
    private var events: [String] = []
    /// Each `events.read`'s `after`, nil for the bootstrap read.
    private var eventReads: [UInt64?] = []
    private var failNextRead = false
    private var attachGate: DispatchSemaphore?
    private var attachPick: (@Sendable ([String: Any]) -> ControlResponse?)?
    private var raw: [String: String] = [:]

    /// What `session.attach` answers; by default the fake viewer prints "hi" and echoes what it reads.
    private var attach = ControlResponse(ok: true, result: ControlResult(attach: fakeAttach("printf 'hi'; cat")))

    /// A viewer that runs `script` under `sh`, for an 80x24 pane.
    static func fakeAttach(_ script: String, paneID: String = "pane-1", screen: String = "printf '1 80 24 0 0 0\\n'",
                           remote: Bool = false, nonce: String? = nil) -> ControlAttach {
        ControlAttach(argv: ["/bin/sh", "-c", script], paneID: paneID, screen: ["/bin/sh", "-c", screen], remote: remote, nonce: nonce)
    }

    func answerAttach(_ response: ControlResponse) { lock.withLock { attach = response } }

    /// Answers `cmd` with `text` written as is, so a stream reply can carry lines after its ok.
    func answerRaw(_ cmd: String, _ text: String) { lock.withLock { raw[cmd] = text } }

    /// Answers each `session.attach` by its `args`; nil falls back to `answerAttach`'s answer.
    func answerAttach(by pick: @escaping @Sendable ([String: Any]) -> ControlResponse?) { lock.withLock { attachPick = pick } }

    /// `session.attach` answers only after `releaseAttach()`, or after 30 s.
    func holdAttach() { lock.withLock { attachGate = DispatchSemaphore(value: 0) } }
    func releaseAttach() { lock.withLock { () -> DispatchSemaphore? in defer { attachGate = nil }; return attachGate }?.signal() }

    func requests() -> [String] { lock.withLock { received } }
    func eventReadCursors() -> [UInt64?] { lock.withLock { eventReads } }
    /// The next `events.read` answers `event run changed`, as after an app relaunch.
    func failNextEventRead() { lock.withLock { failNextRead = true } }

    /// Appends `count` `status` events with seq numbers after the last one; `padding` makes each row larger.
    func addEvents(_ count: Int, padding: Int = 0) {
        let session = String(repeating: "x", count: padding)
        lock.withLock {
            for _ in 0..<count {
                events.append(#"{"seq":\#(events.count + 1),"ts":0,"kind":"status","session":"\#(session)","payload":{}}"#)
            }
        }
    }

    /// Whether an `events.read` matching `cursor` arrives, within a slow-runner bound.
    func waitEventRead(_ cursor: (UInt64?) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !eventReadCursors().contains(where: cursor) {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

    /// The ring's answer, recorded and read under one lock so a test that saw the read knows its anchor.
    private func eventsReply(_ object: [String: Any]) -> String {
        lock.withLock {
            let after = ((object["args"] as? [String: Any])?["after"] as? String).flatMap(UInt64.init)
            eventReads.append(after)
            if failNextRead {
                failNextRead = false
                return #"{"ok":false,"error":"event run changed"}"#
            }
            let start = after.map(Int.init) ?? events.count
            let items = events[min(start, events.count)..<min(start + 100, events.count)]
            return #"{"ok":true,"result":{"events":{"run":"\#(run)","next":\#(start + items.count),"items":[\#(items.joined(separator: ","))]}}}"#
        }
    }

    /// Whether `line` arrives among the requests after the first `count`, within a slow-runner bound.
    func waitFor(_ line: String, after count: Int) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !requests().dropFirst(count).contains(line) {
            if Date() > deadline { return false }
            usleep(20_000)
        }
        return true
    }

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
                // a client that gave up on a held answer is gone by the reply: EPIPE, not a SIGPIPE that kills the run
                var noSigPipe: Int32 = 1
                setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
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
        let cmd = object["cmd"] as? String ?? ""
        if cmd != "events.read" { lock.withLock { received.append(String(decoding: line, as: UTF8.self)) } }
        if cmd == "session.attach", let gate = lock.withLock({ attachGate }) { _ = gate.wait(timeout: .now() + 30) }
        if let text = lock.withLock({ raw[cmd] }) {
            let data = Data(text.utf8)
            data.withUnsafeBytes { _ = UnixSocket.write(conn, $0.baseAddress!, data.count) }
            return
        }
        let reply = cmd == "version" ? #"{"ok":true,"result":{"app":{"version":"9.9.9"}}}"#
            : cmd == "events.read" ? eventsReply(object)
            : cmd == "session.attach" ? lock.withLock {
                let answer = attachPick?(object["args"] as? [String: Any] ?? [:]) ?? attach
                return String(decoding: (try? JSONEncoder().encode(answer)) ?? Data(), as: UTF8.self)
            }
            : #"{"ok":true,"result":{"echo":"\#(cmd)"}}"#
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
